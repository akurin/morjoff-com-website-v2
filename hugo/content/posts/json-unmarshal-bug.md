+++
date = "2025-01-06"
title = "json.Unmarshal Doesn't Clear Your Struct: A Pagination Bug Story"
+++

`json.Unmarshal` only sets the fields that appear in the JSON. If you decode several responses into the same struct, a
field missing from a later response keeps its value from an earlier one. In a pagination loop that can mean the "next
page" token never becomes empty, and the loop never ends.

This started with a Go service at work that replicates users from another service, page by page. After a small change in
the API's responses, the consumer got stuck in an infinite loop.

## What happened

The user service returns users in pages, with a token for the next page:

```json
{
  "Users": [
    {
      "ID": 2,
      "Name": "Bob"
    }
  ],
  "NextIterator": "some-token-to-next-page"
}
```

On the last page, the token was `null`:

```json
{
  "Users": [
    {
      "ID": 2,
      "Name": "Bob"
    }
  ],
  "NextIterator": null
}
```

The consumer requested pages until `NextIterator` was empty. A simplified version of its code (the real one called an AWS
Lambda function rather than an HTTP endpoint, and collecting everything in memory reflects the legacy code):

```go
type User struct {
	ID   int
	Name string
}

type usersPage struct {
	Users        []User
	NextIterator *string
}

func (u *UserClient) CollectAllUsers() ([]User, error) {
	var allUsers []User
	var iterator *string
	var page usersPage // declared once, reused for every page

	for {
		body, err := u.fetchPage(iterator) // GET ?iterator=..., read the body, check the status
		if err != nil {
			return nil, err
		}

		if err := json.Unmarshal(body, &page); err != nil {
			return nil, err
		}

		allUsers = append(allUsers, page.Users...)
		iterator = page.NextIterator

		if iterator == nil {
			break
		}
	}

	return allUsers, nil
}
```

Then the user service was changed to leave the field out of the last page instead of sending `null`:

```json
{
  "Users": [
    {
      "ID": 2,
      "Name": "Bob"
    }
  ]
}
```

From that moment the consumer never stopped requesting pages.

## Why

The difference between `null` and a missing field is documented in
[`json.Unmarshal`](https://pkg.go.dev/encoding/json#Unmarshal):

- A JSON `null` sets a pointer to `nil`: "The JSON null value unmarshals into an interface, map, pointer, or slice by
  setting that Go value to nil."
- For a struct, `Unmarshal` "matches incoming object keys" to the struct's fields. A field whose key isn't in the JSON
  isn't touched.

So with `"NextIterator": null`, the reused `page` got its iterator cleared. Without the field, `page.NextIterator` kept
the token from the previous page, `iterator` was never `nil`, and the loop requested the same page again and again.

## The fix

Start every page with an empty struct. The simplest way is to declare `page` inside the loop:

```go
for {
	var page usersPage // a fresh struct for every page
	// ...
	if err := json.Unmarshal(body, &page); err != nil {
		// ...
	}
	// ...
}
```

This costs one allocation per page. Because `&page` is passed to `json.Unmarshal`, it escapes to the heap, which
`go build -gcflags=-m` confirms with `moved to heap: page`. If that matters, keep the variable outside the loop and
reset it explicitly:

```go
var page usersPage

for {
	page = usersPage{} // clear values left from the previous page
	// ...
	if err := json.Unmarshal(body, &page); err != nil {
		// ...
	}
	// ...
}
```

For a loop that makes a network request per page, the allocation is unlikely to matter, so I'd use whichever version is
easier to read.

## Why doesn't Unmarshal clear the struct?

The documentation describes the behavior but doesn't explain it. My guess: decoding into a struct that already holds
values is a common way to set defaults, for example filling in a config struct and letting the JSON override only the
fields it contains. Clearing the struct first would break that.

## Takeaways

- Don't reuse a struct across `json.Unmarshal` calls unless you reset it first.
- Many APIs treat a `null` field and a missing field as the same thing. A reused Go struct doesn't.
- Small changes in an API's responses, such as dropping a `null` field, can break consumers in ways neither side
  expects.

---

*This article was rewritten with the help of Claude, an AI assistant. I checked the content, but some details may be
inaccurate. Corrections are welcome.*

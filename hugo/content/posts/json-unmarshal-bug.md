+++
date = "2025-01-06"
title = "json.Unmarshal Doesn't Clear Your Struct: A Pagination Bug Story"
+++

Recently, I stumbled upon a rather interesting bug in a Go project I’m working on at my job. It wasn't a complex
issue, but it highlighted a subtle pitfall related to how we often handle JSON responses, particularly when dealing with
pagination. Let me share the story.

## The Setup

Our project involves a microservice, let's call it the "User Service", that provides user data. Another microservice,
let's call it the "User Consumer," needs to replicate users from the User Service. The User Service exposes an API that
returns user data in pages, along with a token to fetch the next page, if available. The API response initially looked
like this:

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

Or, if no more pages were available:

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

The Consumer would make a request to the User Service, process the returned users, check the `NextIterator`, and, if not
null, repeat the process, passing the `NextIterator` in the next request.

The Go code for this looked somewhat like the following. Note that this is a simplified version and the bug is already
fixed:

```go
package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
)

type User struct {
	ID   int
	Name string
}

type usersPage struct {
	Users        []User
	NextIterator *string
}

type UserClient struct {
	httpClient *http.Client
	baseURL    *url.URL
}

func NewUserClient(httpClient *http.Client, baseURL *url.URL) *UserClient {
	return &UserClient{httpClient: httpClient, baseURL: baseURL}
}

func (u *UserClient) CollectAllUsers() ([]User, error) {
	var allUsers []User
	var iterator *string

	// The bug was here! `page` was defined outside the loop
	var page usersPage

	for {
		userPageURL := *u.baseURL

		query := u.baseURL.Query()
		if iterator != nil {
			query.Set("iterator", *iterator)
		}
		userPageURL.RawQuery = query.Encode()

		resp, err := http.Get(userPageURL.String())
		if err != nil {
			return nil, err
		}

		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, err
		}

		_ = resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			return nil, err
		}

		// Reset the page DTO before unmarshalling the new response
		// This fix was placed here after the bug report
		page = usersPage{}
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

## The Problem

Everything worked perfectly until our team decided to simplify the response when no more pages were available. We
started returning responses like this:

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

Notice the missing `NextIterator` field.

This seemingly harmless change caused the User Consumer to get stuck in an infinite loop. The problem was in the
original code, where the `usersPage` variable was declared outside the loop and reused with every iteration:

```go
var page usersPage // !!!
for {
	// ...
	if err := json.Unmarshal(body, &page); err != nil {
		// ...
	}
	// ...
	iterator = page.NextIterator
	if iterator == nil {
		break
	}
}
```

When the User Service stopped sending `NextIterator`, the previous value of `NextIterator` in `page` wasn't being
cleared.  `json.Unmarshal` doesn't zero the struct before writing new values. As result, the `iterator` variable within
the loop kept its value from the last non-empty response, preventing the loop from breaking.

## The Fix and a Question

The fix was relatively simple: we moved the declaration of `page` into the loop:

```go
for {
	var page usersPage // fixed!
	// ...
	if err := json.Unmarshal(body, &page); err != nil { 
		// ...
	}
	// ...
	iterator = page.NextIterator
	if iterator == nil {
		break
	}
}
```

This creates a new `usersPage` struct in every iteration, effectively resetting `NextIterator` each time.

However, this fix led me to question something. The initial code likely intended to avoid unnecessary allocations by
reusing the same `page` variable. The updated code now allocates a new `usersPage` on each iteration, which feels like a
small regression for performance.

Could we achieve the same result, without introducing additional allocations? Yes. We could explicitly zero out the
struct before unmarshalling:

```go
for {
	// Reset the page DTO before unmarshalling the new response
	page = usersPage{}
	if err := json.Unmarshal(body, &page); err != nil {
		// ...
	}
	// ...
	iterator = page.NextIterator
	if iterator == nil {
		break
	}
}
```

Go's compiler will generate code to zero the struct's memory. This seems like a nice balance between correctness and
potential performance.

This got me wondering: why doesn't `encoding/json`'s `Unmarshal` function use `reflect.Zero` to zero the destination
struct by default before reading JSON data?

I haven't delved deep enough to definitively answer that, but I suspect this would lead to more overhead for most use
cases where you are unmarshalling into a clean/fresh struct.

## Conclusion

The bug was a good reminder that even seemingly simple changes in API responses can have significant impacts on the
code that consumes them. It also highlighted the importance of understanding how `json.Unmarshal` works and the need to
ensure that structs are correctly zeroed/reset before unmarshalling data into them.

I hope this story helps you avoid similar bugs in your projects. Happy coding!

+++
date = "2026-10-18"
title = "Stale Keep-Alive Connections on AWS Lambda"
description = "Why a Go HTTP client on AWS Lambda fails with EOF after a pause, why Python, Node.js and .NET don't, and what helps in Go."
+++

A Go Lambda function that reuses HTTP keep-alive connections can fail with `Post "…": EOF` on the first request after a pause. The server closed the idle connection while the function was frozen, and Go's HTTP client hands out the dead connection before it notices. Setting the transport's `IdleConnTimeout` below the server's keep-alive timeout prevents the common case, a connection the server closed for being idle. It doesn't cover servers that close connections for other reasons, such as a deploy or a restart. Python, Node.js and .NET clients didn't fail in the same test.

This started with a Go service on AWS Lambda that logged a few failed POST requests an hour, always after the function had been idle for a few seconds. Turning keep-alive off made the errors go away, but that hid the cause rather than explaining it.

## What happens

Between invocations, Lambda freezes the function's process. The kernel of the execution environment keeps running, so TCP still works even though your code doesn't run.

If the server's keep-alive timeout fires during the freeze, the server closes the idle connection and sends a FIN. The kernel acknowledges it and keeps it in the socket's receive buffer. Nothing in the process reads it, so the connection is still in the client's pool when the next invocation starts.

Go's `http.Transport` learns that a pooled connection is closed from a background goroutine that reads from it. After the thaw, that goroutine and your handler start at almost the same time, and often the handler wins. It takes the dead connection and writes the request. The server answers with RST, the client reads the FIN that was waiting, and the call fails with EOF.

Once a request has been written, Go resends it on a new connection only if it is idempotent: GET, HEAD, OPTIONS, TRACE, or a request with an `Idempotency-Key` header. A POST returns the error to the caller.

The same race exists in any long-running Go program, but there the window is a few microseconds. A Lambda freeze stretches it to the whole idle period.

## What helps in Go

Set `Transport.IdleConnTimeout` below the server's keep-alive timeout:

```go
t := http.DefaultTransport.(*http.Transport).Clone()
t.IdleConnTimeout = 3 * time.Second // pick a value below your server's keep-alive timeout
client := &http.Client{Transport: t}
```

Before the pool hands out an idle connection, it checks how long the connection has been idle against this value, using wall-clock time ([golang/go#29308](https://github.com/golang/go/issues/29308), since Go 1.14). The check runs in the goroutine that sends the request, so the race after a thaw no longer matters. Watch out for two defaults:

- A transport built as `&http.Transport{}` has `IdleConnTimeout` 0, which turns the check off.
- `http.DefaultTransport` uses 90 s. Many servers close idle connections sooner: nginx after 75 s, an AWS Application Load Balancer after 60 s, Apache and Node.js after 5 s. Servers rarely tell the client their timeout, so you may have to measure it.

`IdleConnTimeout` only covers connections the server closes for being idle. It doesn't help when a server closes connections for other reasons while your function is frozen: a graceful shutdown during a deploy, a scale-in or load balancer draining closes idle connections whatever their age, and a crash, a reboot or an AWS NAT gateway dropping a flow after 350 s sends no FIN at all. In those cases a request can still fail. Go does retry idempotent requests, including any request that carries an `Idempotency-Key` header, so make requests idempotent where the server allows it.

## Other runtimes

I ran the same test with the standard HTTP clients of Python, Node.js and .NET, each set up like the Go one: one shared client, one pooled connection, no idle timeout, no retries. None of them failed.

| Runtime and client | Failed after a pause | How it avoids the dead connection | Why Go can't do the same |
| --- | --- | --- | --- |
| Go 1.27, `net/http` | 42 of 100 | It doesn't. | — |
| Python 3.13, urllib3 2.6.3 | 0 of 100 | Polls the socket right before reusing a connection and finds the waiting FIN. | No way to poll a socket without reading it |
| Node.js 22, `http` with a keep-alive `Agent` | 0 of 100 | Has no check. Its single event loop handles the FIN and destroys the socket before it runs the handler. | Several threads; the handler often runs first |
| .NET 10, `HttpClient` | 0 of 100 | Starts a read when it takes a connection from the pool. If the read returns EOF at once, it discards the connection. | The pending read is in another goroutine |

Zero failures in 100 doesn't prove these clients never fail this way, but it makes a failure rate above about 3% unlikely.

### Why Go doesn't check the socket

What the Go project has said:

- The background reader is the intended way to notice a closed connection. In [golang/go#3514](https://github.com/golang/go/issues/3514) (2012) a maintainer wrote: "The Transport always has a goroutine reading, even if a request hasn't been sent," and that "there will still be a race if you have a busy client."
- A way to check a socket without reading from it doesn't exist. [golang/go#15735](https://github.com/golang/go/issues/15735), opened in 2016, says: "The net/http package needs a way to wait for readability on a TCPConn without actually reading from it." It is still open with no planned release; in the discussion, maintainers objected to callback-style designs as "not typical Go style".
- The remaining failure is treated as unavoidable. A comment in `net/http/transport.go` calls it "the inherent keep-alive shut down race, where the server closed the connection at the same time the client wrote".
- Retries were chosen instead. Since Go 1.12 the transport resends requests that carry an `Idempotency-Key` header ([golang/go#19943](https://github.com/golang/go/issues/19943)). For a plain POST, a maintainer called the returned error "valid and intentional" in the same issue.
- Suspend was addressed through the idle timeout: since Go 1.14 the idle check uses wall-clock time, for "a laptop or VM coming out of suspend" ([golang/go#29308](https://github.com/golang/go/issues/29308)).

My reading, not stated by the Go project:

- A second check would compete with the read loop's pending read for the same socket.
- The transport accepts any `net.Conn`, such as a TLS connection, an in-memory pipe or a wrapper, and an abstract connection has no socket to poll. The Go MySQL driver's check ([conncheck.go](https://github.com/go-sql-driver/mysql/blob/master/conncheck.go)) works only when the connection exposes its raw socket, and only on Unix-like systems.
- In a process that keeps running, the read loop sees a FIN within microseconds, so a check before every reuse would add a system call for little gain. A Lambda freeze is the case that design didn't anticipate.

## For any runtime

No client can detect a connection that was dropped without a FIN, and a server can still close a connection just as you send a request on it. Whatever the language:

- create the client once per execution environment;
- keep its idle timeout clearly below the shortest keep-alive timeout between you and the server;
- retry only requests that are safe to repeat.

AWS gives similar advice for SnapStart: re-establish network connections in the function handler ([AWS docs](https://docs.aws.amazon.com/lambda/latest/dg/snapstart-best-practices.html#snapstart-networking)).

## Under the hood

### The thaw, step by step

Lambda doesn't call into your process. Inside the execution environment, the Lambda runtime API is a local HTTP server, and the runtime code in your process asks it for the next event with a long-polling `GET /runtime/invocation/next`. The answer arriving on that socket is what wakes the process up.

```
handler returns; the runtime sends GET /next and waits
                     -- Lambda freezes the process --
server's keep-alive timeout fires: FIN arrives on socket A (pooled connection)
...
new invocation: the runtime API answers on socket B (the next event)
                     -- Lambda thaws the process --
one epoll_wait call reports both A and B as readable
```

What happens next depends on the runtime. Node.js runs all JavaScript on one thread and handles socket events one at a time, in the order the kernel reports them. A became readable first, so Node destroys the pooled socket before it gets to the event and calls the handler. Go wakes a goroutine for each socket and runs them on several threads, in an order chosen by its scheduler.

### The Go code involved

The race is a check-then-use. The pool's `isBroken()` reads a flag, `pc.closed`, that only the connection's read loop sets, after its `Peek(1)` returns. Until that goroutine runs, a dead connection looks healthy.

The only part of `net/http` that notices a closed pooled connection is the connection's read loop, which waits in a one-byte peek:

```go
// net/http/transport.go, persistConn.readLoop
_, err := pc.br.Peek(1) // returns when the server sends data or closes
pc.mu.Lock()
if pc.numExpectedResponses == 0 {
	pc.readLoopPeekFailLocked(err) // marks the connection broken and closes it
```

The pool hands out any connection that read loop hasn't marked yet:

```go
// net/http/transport.go, Transport.queueForIdleConn
if pconn.isBroken() || tooOld { // tooOld is only set when IdleConnTimeout > 0
	list = list[:len(list)-1]
	continue
}
```

At the thaw, the scheduler decides whether that read loop runs before your handler. The network poller puts each woken goroutine at the head of a list, and the scheduler runs the head:

```go
// runtime/netpoll.go, netpollready
toRun.push(rg) // push adds to the head of the list

// runtime/proc.go, findRunnable
gp := list.pop() // run the head now
injectglist(&list) // queue the rest
```

The goroutine at the head is the read loop of the runtime API connection. It delivers the event to the goroutine waiting in `client.Do`, which then calls your handler. That delivery goes through a channel, and waking a goroutine from a channel puts it in the current thread's `runnext` slot, ahead of everything else that is waiting:

```go
// runtime/proc.go, goready (called when a channel operation wakes a goroutine)
ready(gp, traceskip, true) // true: run gp next on this thread
```

Socket A became ready first and B last, so the event and then your handler run first, on one thread. The read loop for socket A waits in a queue until another thread picks it up, and by then the handler has often taken the dead connection. In Go execution traces I recorded inside Lambda (the tracer itself makes the handler win more often), both sockets were reported together in 22 of 25 thaws, and in 18 of those the handler took the dead connection. In the other 3, the FIN was reported in an earlier poll and the read loop won.

## How I tested

A Go HTTP server on an EC2 instance closed idle keep-alive connections after 2 s. One Lambda function per runtime called it over plain HTTP, outside a VPC. Each function created its client once and sent one POST per invocation. A test cycle invoked five execution environments, waited 60 s while they were frozen, then invoked them again; the second call was the sample. Lambda sometimes ran two calls back to back on one environment, so I counted only calls that followed at least 48 s of idle time and kept going until each runtime had 100. Functions had 128 MB of memory, except .NET, which needs 256 MB to start.

Details behind the results:

- **Go.** 42 of 100 requests failed, all on a reused connection. Earlier, smaller runs failed between 29% and 48% of the time. The Go test client logged every socket read and write; with that logging turned off, 48 of 100 failed, so the instrumentation didn't cause the failures. With `IdleConnTimeout` set to 1.5 s, none failed in two runs of 17 and 30 requests.
- **Python.** urllib3 reported discarding a dropped connection before all 100 requests.
- **.NET.** In 78 cases the stale connection was already gone when the handler started; in the other 22, .NET discarded it as the request took it. It never wrote to a dead connection, so it isn't hiding the failure behind an internal retry.
- **Node.js.** In my traces the old socket was already marked as destroyed when the handler started.
- **More CPU.** Lambda's CPU share grows with memory. With the Go function at 1,769 MB, one full vCPU, 18 of 50 requests failed; at 3,008 MB, 15 of 50. That is within the spread I saw between runs at 128 MB, so more CPU doesn't make the problem go away.
- **Production.** The production function calls its API over HTTPS. The API closes idle connections after about 5 s, which I worked out from the logs. Over five minutes, none of 489 requests failed when the execution environment had been idle for less than 5 s, and 10 of 33 failed after longer gaps. The EOF came back within a millisecond of sending the request, while real replies took at least 60 ms, so the requests never reached the server.

---

*The investigation and this article were done with the help of Claude, an AI assistant. I checked the findings against my own tests and logs, but some details may be inaccurate. Corrections are welcome.*

# Client Address

Who actually sent a request: the raw TCP peer always, and the real caller
behind a reverse proxy when one is explicitly trusted to say so.

## Two questions, two answers

```swift
context.request.remoteAddress   // who opened the socket — never spoofable
context.clientAddress           // the real caller, if a proxy policy says so
```

`remoteAddress` is what the kernel reports for this connection. Nothing a
client sends can change it, which is exactly why it is safe and exactly why
it is usually wrong to log or rate-limit by: behind a load balancer or a CDN,
every request's `remoteAddress` is the proxy, not the caller.

`clientAddress` is `remoteAddress`, unless a `TrustedProxies` policy is
configured and the peer is inside it — in which case it is resolved from
`X-Forwarded-For` instead. With nothing configured, the two are always the
same value, and the header is never even read.

## The default trusts nothing

```yaml
web:
  trusted-proxies: "10.0.0.0/8, 172.16.0.0/12"
```

There is no permissive spelling of this setting. Every other safe-default in
Flight has the identical shape — `Cookie`'s `httpOnly`/`sameSite`, `Sessions`'
`cookie-secure`, `RateLimiting`'s required key — and this one is stricter
than most, because trusting `X-Forwarded-For` from an unconfigured peer has
no legitimate use at all. Any caller able to open a connection to your
process can set that header to anything; the only reason to ever believe it
is that it arrived through a hop you named.

`web.trusted-proxies` is comma-separated CIDR blocks — a range
(`10.0.0.0/8`) or a single address as its narrowest block
(`203.0.113.5/32`) — naming every hop between a caller and this process that
is allowed to set the header: your load balancer's subnet, your CDN's
published edge ranges. Not the internet at large, and not your own service.
A bad entry fails composition, naming it, the same as every other config
value in Flight.

Composing it directly, for a test or a hand-built application:

```swift
let proxies = try TrustedProxies(cidrs: ["10.0.0.0/8"])
let module = try FlightWebModule<FlightTransport>(
    configuration: configuration, routes: routes, trustedProxies: proxies)
```

## How the header is resolved

`X-Forwarded-For` is a comma-separated list. Each hop appends what it saw to
the **end** before forwarding, so the rightmost entry is what the hop
closest to this process reported — which, if that hop is trusted, is worth
believing. The resolution walks from the right:

1. If `remoteAddress` itself is not inside a trusted range, `clientAddress`
   is `remoteAddress` and the header is never read at all. An untrusted peer
   cannot make itself trusted by claiming to be a proxy.
2. If it is trusted, walk the header from the right. As long as an entry is
   itself inside the trusted range, it is another vouched-for hop — keep
   walking left through it.
3. The **first entry that is not itself trusted** is the client, and the
   walk stops there. Everything further left is exactly the part of the
   header an untrusted caller could have written by hand before its request
   ever reached your first real proxy, so using it would mean trusting the
   caller's own unverified claim about itself.

```
caller (writes anything) → nginx (10.0.0.4, trusted) → this process
X-Forwarded-For: 203.0.113.9
clientAddress → 203.0.113.9
```

```
caller (writes "9.9.9.9") → nginx (10.0.0.4, trusted) → this process
X-Forwarded-For: 9.9.9.9, 203.0.113.9
clientAddress → 203.0.113.9   (9.9.9.9 is left of the boundary; never used)
```

Two failure directions are both handled by returning `nil` rather than
guessing: a proxy chain with no untrusted entry anywhere in it — nothing in
the header to identify as "the client" — and an entry that does not even
parse as an address, which is treated as the point where trust ends, not as
a name for the client.

## Multiple trusted hops

A chain of proxies you control — a CDN edge, then an internal load balancer
— works the same way, because each hop in the chain is checked against the
same trusted range:

```yaml
web:
  trusted-proxies: "173.245.48.0/20, 10.0.0.0/8"   # CDN edges, then the internal LB
```

## IPv4-mapped IPv6

A dual-stack listener sometimes reports an IPv4 peer as `::ffff:10.0.0.4`
rather than `10.0.0.4`. That form is normalized to plain IPv4 during
parsing, so a trusted-proxy list written the way an operator actually has
it — the IPv4 ranges a cloud provider publishes — matches regardless of
which form the kernel happened to report.

## Using it

```swift
@GetRoute("/")
func index(_ context: RequestContext) -> String {
    "hello, \\(context.clientAddress?.host ?? "unknown visitor")"
}
```

The most common use is a rate-limit key for anonymous traffic — see
[rate-limiting.md](rate-limiting.md#limiting-by-client-address) — but
anything wanting "which caller" for logging, an allow-list, or geo-shaped
behaviour reads the same property.

## What this is not

- **Not a hostname.** `PeerAddress.host` is always a literal IP address
  string. Nothing here does DNS, forward or reverse.
- **Not `Forwarded` (RFC 7239).** `X-Forwarded-For` is the header every major
  proxy, load balancer and CDN actually sets in practice; the standardized
  successor is rare enough in the wild that supporting it was not worth the
  header's own more intricate grammar. A deployment needing it can read
  `context.request.headers[.forwarded]` directly.
- **Not per-request configuration.** `TrustedProxies` is composed once, like
  `WebCoders` and `ErrorMapper`, and applies to every request. A deployment
  that genuinely needs different trust per route is not a case this was
  designed for.

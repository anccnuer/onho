# username/moonbit-hono

A Hono-inspired web framework in MoonBit, compiled to wasm for Wasmer Edge's WCGI model.

## What WCGI is

WCGI is RFC 3875 CGI over a WASI **executable** — there is no request-shaped ABI to
implement, only the one a shell script would see:

- the request arrives in the **environment**: `REQUEST_METHOD`, `SCRIPT_NAME`,
  `QUERY_STRING`, `CONTENT_LENGTH`, `CONTENT_TYPE`, and every client header as `HTTP_*`
- the body is exactly `CONTENT_LENGTH` bytes on **stdin**
- the response goes to **stdout** as `Status: <code> <reason>`, then the headers sorted
  by name, a blank line, then the body — separated by bare LF, not CRLF
- the runner gives each request a **fresh instance**, so no state survives a request

`cmd/wcgi` is therefore `pkgtype(kind: "executable")`, and `wasmer.toml` asks for
`runner = "https://webc.org/runner/wcgi"` with `dialect = "rfc-3875"`.

## Local test environment

`moon build` alone is not the point — the guest only works if something plays the part of
the CGI gateway. Two things do, and they are independent gates:

```
bash dev/check.sh              # build + unit tests + ABI + fixtures + wasmer
bash dev/check.sh --update     # rewrite fixtures/*.expect after an intended change
```

1. `moon test` — 24 tests over the router and the CGI mapping, on plain values, no wasm.
2. `moon build --target wasm --release`
3. `node dev/host.mjs abi` — the module must export `_start` and `memory`, and import
   **only** `environ_sizes_get`, `environ_get`, `fd_read`, `fd_write`. Anything more is
   the guest reaching past one request's sandbox.
4. `node dev/host.mjs check` — every `fixtures/*.http` re-encoded as a CGI environment,
   run through a Node WASI shim, and diffed byte-for-byte against its `.expect`.
5. `wasmer run` — the same module on the real engine, fed with `--env` and stdin.

To drive it by hand:

```
node dev/host.mjs run            # print each fixture and its CGI response
node dev/host.mjs serve 8080     # real HTTP; one instance per request, like WCGI
curl -s localhost:8080/health    # -> ok
```

```
printf 'hi' | wasmer run _build/wasm/release/build/cmd/wcgi/wcgi.wasm \
  --env REQUEST_METHOD=POST --env SCRIPT_NAME=/echo --env CONTENT_LENGTH=2
# Status: 200 OK
# content-type: text/plain; charset=utf-8
#
# hi
```

Under Git Bash, export `MSYS2_ARG_CONV_EXCL='*'` first: it rewrites `--env
SCRIPT_NAME=/echo` into a Windows path.

## The boundary

`http.mbt` holds the mapping in both directions, as plain functions on values, so it is
tested without a wasm runtime:

- `request_from_cgi(env, body)` — the route is `PATH_INFO` when the gateway splits the
  URI and `SCRIPT_NAME` when it does not, and `QUERY_STRING` never becomes part of the
  path, so a route registered for `/health` also answers `/health?debug=1`. `HTTP_*`
  unfolds back to dashed lowercase header names, and the gateway variables are mirrored
  as `x-cgi-*` the way the reference CGI implementation does. A missing `REQUEST_METHOD`
  or `SCRIPT_NAME` is a 400, not a guess.
- `serialize_cgi(res)` — the `Status:` line, sorted headers, LF, body. `Content-Length`
  and `Status` are dropped on purpose: RFC 3875 gives `Content-Length` in CGI output a
  special meaning (a non-parsed body, forwarded raw), which would stop the runner from
  framing the response at all.
- `req.header(name)`, `req.query_param(name)` (percent escapes and `+` decoded, so
  `%E4%B8%AD%E6%96%87` reads back as 中文) and `req.uri()` — the reading side a handler
  wants, because CGI hands the query string over as one undivided string.

`parse_request` / `serialize_response` are the same layer for a host that hands over raw
HTTP bytes instead of a CGI environment; WCGI does not use them.

`String` is UTF-16 on this target, so every value that crosses the boundary goes through
`@utf8` explicitly — that is why a UTF-8 body echoes back with its bytes intact and
`content-length` counts bytes rather than code units.

## Deploying

`moon build --target wasm --release` first, then `wasmer deploy` reads `app.yaml` and
`wasmer.toml`. Routing needs one of `SCRIPT_NAME` or `PATH_INFO` to come from the runner;
if a deployment answers 400 to everything, those variables are what to look at, and if it
answers the same page to every path, the runner is fixing `SCRIPT_NAME` (the template does
`env = ["SCRIPT_NAME=..."]`) and `PATH_INFO` is the variable that carries the route.

## Layout

- `http.mbt` — `Request`/`Response`, the CGI mapping, and the raw-HTTP codec
- `app.mbt` — the `App` router: method + exact path, 405 kept distinct from 404
- `cmd/wcgi/main.mbt` — the CGI program: four WASI imports, one request per instance
- `test/` — blackbox tests against the public API
- `fixtures/` — raw requests (host input) and `.expect` CGI-output snapshots
- `dev/host.mjs` — local WCGI host, on Node's `WebAssembly` runtime
- `dev/check.sh` — the gates above, chained

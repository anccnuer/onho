# anccnuer/onho

English | [中文](README.md)

A web framework in MoonBit with Hono-style routing, compiled to wasm and served over WCGI on Wasmer Edge.

## Getting started

```
moon add anccnuer/onho
```

```moonbit
let app = @onho.App::new()

app.get("/hello/:name", req => @onho.response(200, "hello \{req.param("name")}"))
app.get("/user/:id", req => @onho.response_json(200, "{\"id\":\"\\{req.param("id")}\"}"))
app.get("/static/*", req => @onho.response(200, req.param("*")))
app.post("/echo", req => @onho.response(200, req.body))
app.all("/ping", _req => @onho.response(200, "pong"))  // any method

app.get("/redirect", _req => @onho.redirect("/hello/world", status=301))
app.get("/page", _req => @onho.html(200, "<h1>hi</h1>"))
```

Reading a request:

```moonbit
req.header("x-request-id")   // names are lowercased; absent reads as ""
req.query_param("q")         // query parameter, percent-decoded (%E4%B8%AD -> 中, + -> space)
req.param("id")              // route parameter; a wildcard's capture sits under "*"
req.body                     // raw body text
```

Building a response:

```moonbit
@onho.response(204, "")                       // text/plain; charset=utf-8
@onho.response_json(200, "{\"ok\":true}")     // application/json
@onho.html(200, "<p>hi</p>")                  // text/html; charset=utf-8
@onho.redirect("/login", status=302)          // location header + empty body, defaults to 302
@onho.response_with(200, [("x-a", "1")], "已设置")          // full control
@onho.response(200, "ok").set_header("x-b", "2")            // append one header
```

Middleware (first registered runs outermost; without `path~` it applies everywhere):

```moonbit
app.use_middleware((req, next) => {
  // things you do on the way in, say auth
  let res = next(req)
  res.set_header("x-response-by", "onho")     // or touch the response on the way out
}, path="/api/*")

app.use_middleware((_req, _next) => @onho.response(401, "denied"))  // no next -> short circuit
```

Handlers may `raise`, no try-wrapping needed:

```moonbit
app.get("/api/user/:id", req => {
  let id = @string.parse_int(req.param("id")) catch { _ => raise Failure("bad id") }
  @onho.response_json(200, "{\"id\":\{id}}")
})

app.on_error((_req, _err) => @onho.response(500, "internal error"))  // defaults to a plain 500
app.not_found(_req => @onho.response_json(404, "{\"error\":\"not found\"}"))
```

Forms and multi-value parameters:

```moonbit
req.query_all("tag")     // ?tag=a&tag=b -> ["a", "b"]
req.form_param("name")   // form body field; "" when the content type is not a form
req.form_all("t")        // every value of a form field
```

The built-in logging middleware writes one summary line per request to stderr
(fd 2 in wasm, so the response itself is never polluted):

```moonbit
app.use_middleware(@onho.logger())   // GET /health -> 200 OK
```

Getting a real request in depends on the host you run behind:

```moonbit
// WCGI / CGI: the request is in the environment, the body on stdin
let res = match @onho.request_from_cgi(env, body) {
  Some(req) => app.handle(req)
  None => @onho.response(400, "bad request")
}

// a host that hands over raw HTTP bytes
@onho.parse_request(bytes)  // Request?, None when it did not parse
```

## Running the example

`cmd/wcgi` in this repo is a deployable example:

```
bash dev/check.sh            # moon test + wasm build + fixture diff + wasmer smoke test
node dev/host.mjs serve 8080 # a real HTTP server locally
curl -s localhost:8080/hello/world
```

## Deploying

```
moon build --target wasm --release
wasmer deploy        # reads app.yaml and wasmer.toml
```

If a deployment answers 400 to everything, check whether the runner supplies
`SCRIPT_NAME`/`PATH_INFO`; if every path returns the same page, the runner is fixing
`SCRIPT_NAME` and the route arrives on `PATH_INFO`.

## Layout

- `http.mbt` — `Request`/`Response`, the CGI and raw-HTTP boundary
- `app.mbt` — the `App` router: middleware, 405/404, HEAD fallback, error handling
- `cmd/wcgi/` — a deployable example program
- `test/`, `fixtures/`, `dev/` — tests and the local WCGI host

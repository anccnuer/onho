///|
/// Blackbox tests against the package's public API. The HTTP layer is what the WCGI
/// boundary hands to the router, so it is pinned here independently of wasm.
fn text(raw : Bytes) -> String {
  @utf8.decode(raw) catch {
    _ => abort("expected valid utf8")
  }
}

///|
fn parsed(raw : Bytes) -> @onho.Request {
  match @onho.parse_request(raw) {
    Some(req) => req
    None => abort("expected a parsed request")
  }
}

///|
fn request_of(verb : String, path : String, body : String) -> @onho.Request {
  parsed(
    @utf8.encode("\{verb} \{path} HTTP/1.1\r\nHost: local.test\r\n\r\n\{body}"),
  )
}

///|
test "parse_simple_get" {
  let req = parsed(
    @utf8.encode("GET /health HTTP/1.1\r\nHost: local.test\r\n\r\n"),
  )
  @testing.assert_eq(req.http_method, "GET")
  @testing.assert_eq(req.path, "/health")
  @testing.assert_eq(req.headers.length(), 1)
  @testing.assert_eq(req.body, "")
}

///|
/// LF-only input is accepted so hand-written fixtures stay usable.
test "parse_accepts_bare_lf" {
  let req = parsed(@utf8.encode("GET /a HTTP/1.1\nhost: x\n\nbody"))
  @testing.assert_eq(req.path, "/a")
  @testing.assert_eq(req.body, "body")
}

///|
test "parse_lowercases_header_names_and_trims_value" {
  let req = parsed(@utf8.encode("GET / HTTP/1.1\r\nX-Demo:   abc\r\n\r\n"))
  @testing.assert_eq(req.headers.length(), 1)
  let (name, value) = req.headers[0]
  @testing.assert_eq(name, "x-demo")
  @testing.assert_eq(value, "abc")
}

///|
test "parse_keeps_repeated_headers_in_order" {
  let req = parsed(@utf8.encode("GET / HTTP/1.1\r\nx-a: 1\r\nX-A: 2\r\n\r\n"))
  @testing.assert_eq(req.headers.length(), 2)
  @testing.assert_eq(req.headers[1].1, "2")
}

///|
/// Malformed framing must fail closed, because the boundary turns `None` into a 400.
test "parse_rejects_bad_input" {
  @testing.assert_eq(@onho.parse_request(@utf8.encode("")) is None, true)
  @testing.assert_eq(
    @onho.parse_request(@utf8.encode("GET / HTTP/1.1")) is None,
    true,
  )
  @testing.assert_eq(
    @onho.parse_request(@utf8.encode("\r\n\r\n")) is None,
    true,
  )
  @testing.assert_eq(
    @onho.parse_request(@utf8.encode("NO_SPACES\r\n\r\n")) is None,
    true,
  )
}

///|
/// A lone invalid UTF-8 byte is rejected rather than replaced, so a response cannot
/// smuggle out bytes the client never actually sent.
test "parse_rejects_invalid_utf8" {
  let raw = @utf8.encode("GET / HTTP/1.1\r\n\r\n").to_array()
  raw.push((255 : Int32).to_byte())
  @testing.assert_eq(@onho.parse_request(Bytes::from_array(raw)) is None, true)
}

///|
/// `content-length` counts bytes, not UTF-16 units — the exact bug this layer exists
/// to prevent.
test "serialize_counts_utf8_bytes" {
  let res = @onho.response(200, "你好")
  @testing.assert_eq(
    text(@onho.serialize_response(res)),
    "HTTP/1.1 200 OK\r\ncontent-type: text/plain; charset=utf-8\r\ncontent-length: 6\r\n\r\n你好",
  )
}

///|
/// An explicit length set by a handler wins, so a framework-level override survives.
test "serialize_keeps_explicit_content_length" {
  let res = @onho.response_with(204, [("content-length", "0")], "")
  @testing.assert_eq(
    text(@onho.serialize_response(res)),
    "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\n\r\n",
  )
}

///|
/// A router wired the way a library user wires one, used for router-level tests.
fn demo() -> @onho.App {
  let app = @onho.App::new()
  app.get("/", _req => @onho.response(200, "hello from onho"))
  app.get("/health", _req => @onho.response(200, "ok"))
  app.post("/health", _req => @onho.response(201, "created"))
  app.post("/echo", req => @onho.response(200, req.body))
  app.get("/header", req => {
    @onho.response(200, "x-demo=\{req.header("x-demo")}")
  })
  app.get("/search", req => @onho.response(200, "q=\{req.query_param("q")}"))
  app.get("/user/:id", req => @onho.response(200, "user:\{req.param("id")}"))
  app.get("/user/new", _req => @onho.response(200, "new user form"))
  app.get("/static/*", req => @onho.response(200, "asset:\{req.param("*")}"))
  app.get("/status.json", _req => {
    @onho.response_json(200, "{\"ok\":true,\"via\":\"onho\"}")
  })
  app.get("/redirect", _req => @onho.redirect("/health"))
  app
}

///|
test "router_matches_method_and_path" {
  let app = demo()
  @testing.assert_eq(app.handle(request_of("GET", "/health", "")).status, 200)
  @testing.assert_eq(app.handle(request_of("POST", "/health", "")).status, 201)
  @testing.assert_eq(app.handle(request_of("GET", "/nope", "")).status, 404)
}

///|
test "echo_route_returns_the_request_body" {
  let res = demo().handle(request_of("POST", "/echo", "ping"))
  @testing.assert_eq(res.body, "ping")
}

///|
test "header_route_reads_lowercase_name" {
  let req = parsed(@utf8.encode("GET /header HTTP/1.1\r\nX-Demo: abc\r\n\r\n"))
  @testing.assert_eq(demo().handle(req).body, "x-demo=abc")
}

///|
fn cgi_request(entries : Array[(String, String)]) -> @onho.Request {
  match @onho.request_from_cgi(entries, "") {
    Some(req) => req
    None => abort("expected a cgi request")
  }
}

///|
fn header_of(req : @onho.Request, name : String) -> String {
  let mut found = "?"
  for (key, value) in req.headers {
    if key == name {
      found = value
    }
  }
  found
}

///|
/// `SCRIPT_NAME` carries the route and `QUERY_STRING` stays out of it, so a route
/// registered for `/health` also answers `/health?debug=1`.
test "cgi_request_splits_path_and_query" {
  let req = cgi_request([
    ("REQUEST_METHOD", "GET"),
    ("SCRIPT_NAME", "/health"),
    ("QUERY_STRING", "debug=1"),
  ])
  @testing.assert_eq(req.http_method, "GET")
  @testing.assert_eq(req.path, "/health")
  @testing.assert_eq(req.query, "debug=1")
  @testing.assert_eq(req.uri(), "/health?debug=1")
}

///|
/// A gateway that splits the URI keeps its own prefix in `SCRIPT_NAME` and hands the
/// app-relative tail in `PATH_INFO`; either layout routes to the same handler.
test "cgi_request_prefers_path_info_over_script_name" {
  let req = cgi_request([
    ("REQUEST_METHOD", "GET"),
    ("SCRIPT_NAME", "wcgi-app"),
    ("PATH_INFO", "/health"),
  ])
  @testing.assert_eq(req.path, "/health")
  @testing.assert_eq(header_of(req, "x-cgi-script-name"), "wcgi-app")
}

///|
/// Client headers arrive with their dashes folded into underscores; the gateway
/// variables are mirrored instead, and a bare `HTTP_` is not a header at all.
test "cgi_request_unfolds_http_headers_and_mirrors_variables" {
  let req = cgi_request([
    ("REQUEST_METHOD", "GET"),
    ("SCRIPT_NAME", "/"),
    ("HTTP_", "junk"),
    ("HTTP_X_DEMO", "  abc  "),
    ("HTTP_ACCEPT_ENCODING", "gzip, br"),
    ("CONTENT_LENGTH", "0"),
  ])
  @testing.assert_eq(req.headers.length(), 5)
  @testing.assert_eq(header_of(req, "x-demo"), "abc")
  @testing.assert_eq(header_of(req, "accept-encoding"), "gzip, br")
  @testing.assert_eq(header_of(req, "x-cgi-content-length"), "0")
  @testing.assert_eq(req.headers[0].0, "x-demo")
}

///|
/// Without a method, or without any variable that says which path was asked for, there
/// is nothing to route on, so the boundary answers 400 rather than guessing.
test "cgi_request_requires_a_method_and_a_path" {
  @testing.assert_eq(
    @onho.request_from_cgi([("SCRIPT_NAME", "/")], "") is None,
    true,
  )
  @testing.assert_eq(
    @onho.request_from_cgi([("REQUEST_METHOD", "GET")], "") is None,
    true,
  )
}

///|
/// A gateway that forwards only the request line puts the path in the non-standard
/// `REQUEST_URI`, query string included; the route is the part before the `?`.
test "cgi_request_falls_back_to_request_uri" {
  let req = cgi_request([
    ("REQUEST_METHOD", "GET"),
    ("REQUEST_URI", "/health?debug=1"),
    ("QUERY_STRING", "debug=1"),
  ])
  @testing.assert_eq(req.path, "/health")
  @testing.assert_eq(req.query, "debug=1")
}

///|
/// `SCRIPT_NAME` holding an application name instead of a path is not a route, so the
/// boundary answers 400 rather than matching a path that never was one.
test "cgi_request_ignores_a_script_name_that_is_not_a_path" {
  @testing.assert_eq(
    @onho.request_from_cgi(
      [("REQUEST_METHOD", "GET"), ("SCRIPT_NAME", "onho")],
      "",
    )
    is None,
    true,
  )
}

///|
/// CGI output is LF-only, carries the status as a header, and sorts the rest by name.
test "serialize_cgi_writes_status_and_sorted_headers" {
  let res = @onho.response_with(
    301,
    [("x-a", "1"), ("content-type", "text/plain"), ("b", "2")],
    "moved",
  )
  @testing.assert_eq(
    text(@onho.serialize_cgi(res)),
    "Status: 301 Moved Permanently\nb: 2\ncontent-type: text/plain\nx-a: 1\n\nmoved",
  )
}

///|
/// `Content-Length` tells CGI the body is already a complete response and must be
/// forwarded raw, and a second `Status` is a second status line. Neither may leak in.
test "serialize_cgi_drops_content_length_and_status" {
  let res = @onho.response_with(
    200,
    [("content-length", "5"), ("status", "201")],
    "ok",
  )
  @testing.assert_eq(text(@onho.serialize_cgi(res)), "Status: 200 OK\n\nok")
}

///|
/// The body goes out as the bytes the handler wrote, not as UTF-16 units, and the
/// whole response is a byte-exact match down to the LF separators.
test "serialize_cgi_keeps_utf8_body_bytes" {
  let raw = @onho.serialize_cgi(@onho.response(200, "你好"))
  let expected = @utf8.encode(
    "Status: 200 OK\ncontent-type: text/plain; charset=utf-8\n\n",
  ).to_array()
  for b in @utf8.encode("你好") {
    expected.push(b)
  }
  @testing.assert_eq(raw.to_array(), expected)
}

///|
/// The whole boundary the guest runs, with no wasm in sight.
test "cgi_request_drives_the_demo_app" {
  let req = cgi_request([("REQUEST_METHOD", "GET"), ("SCRIPT_NAME", "/")])
  @testing.assert_eq(
    text(@onho.serialize_cgi(demo().handle(req))),
    "Status: 200 OK\ncontent-type: text/plain; charset=utf-8\n\nhello from onho",
  )
}

///|
/// `path` is what a route matches, `query` what a handler reads, and `uri()` puts them
/// back together for a redirect.
test "parse_request_splits_path_and_query" {
  let req = parsed(@utf8.encode("GET /search?q=moon%20bit HTTP/1.1\r\n\r\n"))
  @testing.assert_eq(req.path, "/search")
  @testing.assert_eq(req.query, "q=moon%20bit")
  @testing.assert_eq(req.uri(), "/search?q=moon%20bit")
  @testing.assert_eq(req.query_param("q"), "moon bit")
}

///|
/// Query values are percent-encoded, including multi-byte ones whose escapes only make
/// sense once the bytes are put back together.
test "query_param_decodes_percent_escapes" {
  let req = parsed(
    @utf8.encode("GET /search?q=%E4%B8%AD%E6%96%87&flag=on HTTP/1.1\r\n\r\n"),
  )
  @testing.assert_eq(req.query_param("q"), "中文")
  @testing.assert_eq(req.query_param("flag"), "on")
  @testing.assert_eq(req.query_param("absent"), "")
  let broken = parsed(@utf8.encode("GET /s?q=%zz1 HTTP/1.1\r\n\r\n"))
  @testing.assert_eq(broken.query_param("q"), "%zz1")
}

///|
/// The last value of a repeated parameter wins, and an empty one stays distinguishable
/// from a missing one by `query` itself.
test "query_param_handles_edges" {
  let req = parsed(@utf8.encode("GET /s?a=1&a=&b HTTP/1.1\r\n\r\n"))
  @testing.assert_eq(req.query_param("a"), "")
  @testing.assert_eq(req.query_param("b"), "")
  @testing.assert_eq(req.query, "a=1&a=&b")
}

///|
/// A `:name` capture reaches the handler, and a literal route beats the param
/// route it competes with, registration order notwithstanding.
test "router_captures_params_and_prefers_literals" {
  @testing.assert_eq(
    demo().handle(request_of("GET", "/user/123", "")).body,
    "user:123",
  )
  @testing.assert_eq(
    demo().handle(request_of("GET", "/user/new", "")).body,
    "new user form",
  )
}

///|
/// A trailing `*` captures the whole remaining tail, separators included.
test "router_captures_wildcard_tail" {
  @testing.assert_eq(
    demo().handle(request_of("GET", "/static/css/app.css", "")).body,
    "asset:css/app.css",
  )
}

///|
/// A wrong method on an existing path answers 405, and the `allow` header lists
/// the methods the path does serve, in registration order.
test "router_answers_405_with_allow_header" {
  let app = @onho.App::new()
  app.post("/thing", _req => @onho.response(200, ""))
  app.put("/thing", _req => @onho.response(200, ""))
  app.delete("/thing", _req => @onho.response(200, ""))
  let res = app.handle(request_of("GET", "/thing", ""))
  @testing.assert_eq(res.status, 405)
  @testing.assert_eq(res.header("allow"), "POST, PUT, DELETE")
}

///|
/// An `ANY` route stands in for every method without listing itself in `allow`.
test "router_any_route_serves_every_method" {
  let app = @onho.App::new()
  app.all("/any", _req => @onho.response(200, "any"))
  app.get("/plain", _req => @onho.response(200, ""))
  @testing.assert_eq(app.handle(request_of("DELETE", "/any", "")).body, "any")
  // GET exists, so DELETE /plain is a 405 with allow naming GET only.
  let res = app.handle(request_of("DELETE", "/plain", ""))
  @testing.assert_eq(res.status, 405)
  @testing.assert_eq(res.header("allow"), "GET")
}

///|
/// Middleware runs in registration order, outermost first, and may short-circuit
/// the chain by never calling `next`.
test "middleware_wraps_in_registration_order" {
  let trace : Array[String] = []
  let app = @onho.App::new()
  app.get("/x", _req => {
    trace.push("handler")
    @onho.response(200, "")
  })
  app.use_middleware((req, next) => {
    trace.push("a before")
    let res = next(req)
    trace.push("a after")
    res
  })
  app.use_middleware((req, next) => {
    trace.push("b before")
    let res = next(req)
    trace.push("b after")
    res
  })
  let _ = app.handle(request_of("GET", "/x", ""))
  @testing.assert_eq(trace[0], "a before")
  @testing.assert_eq(trace[1], "b before")
  @testing.assert_eq(trace[2], "handler")
  @testing.assert_eq(trace[3], "b after")
  @testing.assert_eq(trace[4], "a after")
}

///|
/// A middleware that answers directly stops the chain: no handler runs.
test "middleware_may_short_circuit" {
  let app = @onho.App::new()
  app.get("/blocked", _req => @onho.response(200, "should not run"))
  app.use_middleware((_req, _next) => @onho.response(401, "denied"))
  let res = app.handle(request_of("GET", "/blocked", ""))
  @testing.assert_eq(res.status, 401)
  @testing.assert_eq(res.body, "denied")
}

///|
/// `path~` scopes a middleware to the paths its pattern matches.
test "middleware_path_scope" {
  let app = @onho.App::new()
  app.get("/admin/x", req => @onho.response(200, req.header("x-scoped")))
  app.get("/open", req => @onho.response(200, req.header("x-scoped")))
  app.use_middleware(
    (req, next) => next(req.set_header("x-scoped", "1")),
    path="/admin/*",
  )
  @testing.assert_eq(app.handle(request_of("GET", "/admin/x", "")).body, "1")
  @testing.assert_eq(app.handle(request_of("GET", "/open", "")).body, "")
}

///|
/// A not-found handler replaces the default 404 body for unmatched paths, but
/// never masks a real route or a 405.
test "not_found_handler_replaces_default_404" {
  let app = @onho.App::new()
  app.get("/here", _req => @onho.response(200, "here"))
  app.post("/here", _req => @onho.response(200, ""))
  app.not_found(req => @onho.response(404, "custom: \{req.path}"))
  @testing.assert_eq(
    app.handle(request_of("GET", "/nowhere", "")).body,
    "custom: /nowhere",
  )
  @testing.assert_eq(app.handle(request_of("GET", "/here", "")).body, "here")
  @testing.assert_eq(app.handle(request_of("DELETE", "/here", "")).status, 405)
}

///|
/// An `Error` raised out of a handler reaches the app's error handler, or —
/// with none registered — collapses to a plain 500 that leaks nothing.
test "raised_errors_reach_on_error" {
  let app = @onho.App::new()
  app.get("/boom", _req => raise Failure("boom"))
  let res = app.handle(request_of("GET", "/boom", ""))
  @testing.assert_eq(res.status, 500)
  @testing.assert_eq(res.body, "internal server error")
  let app2 = @onho.App::new()
  app2.get("/boom", _req => raise Failure("boom"))
  app2.on_error((req, err) => {
    @onho.response(503, "\{req.path}: \{err.to_string()}")
  })
  let res2 = app2.handle(request_of("GET", "/boom", ""))
  @testing.assert_eq(res2.status, 503)
  assert_true(res2.body.has_prefix("/boom: "))
}

///|
/// A `HEAD` request falls back to the `GET` handler with the body dropped, but
/// a route registered for `HEAD` keeps control of its own body.
test "head_falls_back_to_get_without_a_body" {
  let app = @onho.App::new()
  app.get("/both", _req => @onho.response(200, "body"))
  app.route("HEAD", "/explicit", _req => @onho.response(200, "head body"))
  let head = app.handle(request_of("HEAD", "/both", ""))
  @testing.assert_eq(head.status, 200)
  @testing.assert_eq(head.body, "")
  @testing.assert_eq(
    app.handle(request_of("HEAD", "/explicit", "")).body,
    "head body",
  )
  // No GET route for the path either -> still a plain 404.
  @testing.assert_eq(app.handle(request_of("HEAD", "/none", "")).status, 404)
}

///|
test "set_header_appends_and_html_types_the_body" {
  let res = @onho.html(200, "<p>hi</p>")
    .set_header("x-a", "1")
    .set_header("x-b", "2")
  @testing.assert_eq(res.status, 200)
  @testing.assert_eq(res.headers[0].0, "content-type")
  @testing.assert_eq(res.headers[0].1, "text/html; charset=utf-8")
  @testing.assert_eq(res.headers[1].1, "1")
  @testing.assert_eq(res.headers[2].1, "2")
}

///|
/// A header value with a line break would break response framing, so both
/// serializers drop the header entirely.
test "serializers_drop_headers_with_line_breaks" {
  let res = @onho.response_with(
    200,
    [("x-clean", "ok"), ("x-evil", "1\r\nEvil: 2")],
    "body",
  )
  @testing.assert_eq(
    text(@onho.serialize_response(res)),
    "HTTP/1.1 200 OK\r\nx-clean: ok\r\ncontent-length: 4\r\n\r\nbody",
  )
  @testing.assert_eq(
    text(@onho.serialize_cgi(res)),
    "Status: 200 OK\nx-clean: ok\n\nbody",
  )
}

///|
/// The raw-HTTP path arrives percent-encoded and decodes once at parse, so both
/// boundaries route on the same decoded path.
test "parse_request_decodes_the_path" {
  let req = parsed(@utf8.encode("GET /user/caf%C3%A9 HTTP/1.1\r\n\r\n"))
  @testing.assert_eq(req.path, "/user/café")
}

///|
test "reason_phrase_common_codes" {
  @testing.assert_eq(@onho.reason_phrase(201), "Created")
  @testing.assert_eq(@onho.reason_phrase(401), "Unauthorized")
  @testing.assert_eq(@onho.reason_phrase(413), "Content Too Large")
  @testing.assert_eq(@onho.reason_phrase(429), "Too Many Requests")
  @testing.assert_eq(@onho.reason_phrase(503), "Service Unavailable")
}

///|
/// Every value of a repeated query parameter, in arrival order.
test "query_all_returns_every_value" {
  let req = parsed(
    @utf8.encode("GET /s?tag=a&x=1&tag=b%20c&tag= HTTP/1.1\r\n\r\n"),
  )
  @testing.assert_eq(req.query_all("tag"), ["a", "b c", ""])
  @testing.assert_eq(req.query_all("x"), ["1"])
  @testing.assert_eq(req.query_all("absent").length(), 0)
}

///|
/// Form bodies parse only when the content type says so, with the same
/// percent-decoding rules as the query string.
test "form_params_parse_urlencoded_bodies" {
  let req = parsed(
    @utf8.encode(
      "POST /form HTTP/1.1\r\ncontent-type: application/x-www-form-urlencoded\r\n\r\nname=%E4%B8%AD%E6%96%87&t=a&t=b+x",
    ),
  )
  @testing.assert_eq(req.form_param("name"), "中文")
  @testing.assert_eq(req.form_param("t"), "b x")
  @testing.assert_eq(req.form_all("t"), ["a", "b x"])
  @testing.assert_eq(req.form_param("absent"), "")
}

///|
/// A non-form body reads as empty through the form accessors, so a handler can
/// call them unconditionally.
test "form_params_ignore_other_content_types" {
  let req = parsed(
    @utf8.encode(
      "POST /form HTTP/1.1\r\ncontent-type: application/json\r\n\r\na=1",
    ),
  )
  @testing.assert_eq(req.form_param("a"), "")
  @testing.assert_eq(req.form_all("a").length(), 0)
}

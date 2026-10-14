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
test "router_matches_method_and_path" {
  let app = @onho.demo_app()
  @testing.assert_eq(app.handle(request_of("GET", "/health", "")).status, 200)
  @testing.assert_eq(app.handle(request_of("POST", "/health", "")).status, 405)
  @testing.assert_eq(app.handle(request_of("GET", "/nope", "")).status, 404)
}

///|
test "echo_route_returns_the_request_body" {
  let res = @onho.demo_app().handle(request_of("POST", "/echo", "ping"))
  @testing.assert_eq(res.body, "ping")
}

///|
test "header_route_reads_lowercase_name" {
  let req = parsed(@utf8.encode("GET /header HTTP/1.1\r\nX-Demo: abc\r\n\r\n"))
  @testing.assert_eq(@onho.demo_app().handle(req).body, "x-demo=abc")
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
    text(@onho.serialize_cgi(@onho.demo_app().handle(req))),
    "Status: 200 OK\ncontent-type: text/plain; charset=utf-8\n\nhello from moonbit",
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

// Whitebox tests run within the package scope.
// Use them to validate internal helpers or invariants.
// Keep them focused; public behavior belongs in `_test.mbt`.

///|
test "pattern_segments_splits_paths_on_slash" {
  assert_eq(pattern_segments("/"), [""])
  assert_eq(pattern_segments("/health"), ["health"])
  assert_eq(pattern_segments("/health/"), ["health", ""])
  assert_eq(pattern_segments("health"), ["health"])
}

///|
test "pattern_match_literal_route" {
  assert_eq(pattern_match("/health", "/health"), Some([]))
  assert_eq(pattern_match("/health", "/healthx") is None, true)
  assert_eq(pattern_match("/health", "/health/x") is None, true)
}

///|
test "pattern_match_param_route" {
  assert_eq(pattern_match("/user/:id", "/user/123"), Some([("id", "123")]))
  assert_eq(pattern_match("/user/:id", "/user") is None, true)
  assert_eq(pattern_match("/user/:id", "/user/") is None, true)
  assert_eq(
    pattern_match("/files/:dir/:name", "/files/photos/cat.png"),
    Some([("dir", "photos"), ("name", "cat.png")]),
  )
  assert_eq(pattern_match("/files/:dir/:name", "/files/photos") is None, true)
}

///|
test "pattern_match_wildcard_route" {
  assert_eq(pattern_match("/static/*", "/static"), Some([("*", "")]))
  assert_eq(pattern_match("/static/*", "/static/"), Some([("*", "")]))
  assert_eq(
    pattern_match("/static/*", "/static/css/app.css"),
    Some([("*", "css/app.css")]),
  )
  assert_eq(pattern_match("/static/*", "/staticfoo") is None, true)
  assert_eq(pattern_match("/static/*", "static") is None, true)
  // A bare wildcard pattern matches any path and captures the whole tail.
  assert_eq(pattern_match("*", "/a/b"), Some([("*", "a/b")]))
  assert_eq(pattern_match("*", "/"), Some([("*", "")]))
}

///|
test "pattern_match_mid_star_is_literal" {
  assert_eq(pattern_match("/a/*/b", "/a/*/b"), Some([]))
  assert_eq(pattern_match("/a/*/b", "/a/x/b") is None, true)
  assert_eq(pattern_match("/a/*/b", "/a/x/y") is None, true)
  // A segment that is just `:` has no name, so it is treated as a literal.
  assert_eq(pattern_match("/a/:/c", "/a/:/c"), Some([]))
  assert_eq(pattern_match("/a/:/c", "/a/x/c") is None, true)
}

///|
test "route_score_prefers_static_then_param_then_wildcard" {
  assert_eq(route_score("/user/new"), (0, 2, 0))
  assert_eq(route_score("/user/:id"), (0, 1, 1))
  assert_eq(route_score("/static/*"), (1, 1, 0))
  assert_eq(route_score("*"), (1, 0, 0))
}

///|
/// Registering the same method + pattern twice warns on stderr — the second
/// route would be unreachable. The first registration keeps winning, and a
/// warning fires once per duplicate, not once per call site.
test "route_duplicate_warns" {
  let app = App::new()
  app.route("GET", "/x", _req => response(200, "one"))
  app.route("GET", "/x", _req => response(200, "two"))
  app.route("POST", "/x", _req => response(200, "post"))
  // First-registered route keeps winning despite the later duplicate.
  assert_eq(
    app.handle({
      http_method: "GET",
      path: "/x",
      query: "",
      headers: [],
      body: "",
      params: [],
    }).body,
    "one",
  )
  // The POST registration is unaffected by GET duplicates.
  assert_eq(
    app.handle({
      http_method: "POST",
      path: "/x",
      query: "",
      headers: [],
      body: "",
      params: [],
    }).body,
    "post",
  )
}

///|
/// The logger middleware passes the response through untouched; the `GET ... ->
/// 200` line itself is pinned by the wasmer smoke test, which checks stderr.
test "logger_passes_response_through" {
  let app = App::new()
  app.use_middleware(logger())
  app.get("/log", _req => response(200, "ok"))
  let res = app.handle({
    http_method: "GET",
    path: "/log",
    query: "",
    headers: [],
    body: "",
    params: [],
  })
  assert_eq(res.status, 200)
  assert_eq(res.body, "ok")
  assert_eq(res.headers[0].0, "content-type")
}

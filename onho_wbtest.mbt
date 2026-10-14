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

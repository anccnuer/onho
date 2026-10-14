///|
/// A route handler. It may raise an `Error`, which the router turns into a 500
/// via the app's `on_error` handler, so one bad parse does not take the
/// response down with it. Handlers that never raise are accepted unchanged.
pub type Handler = (Request) -> Response raise Error

///|
pub type Next = (Request) -> Response raise Error

///|
/// A middleware wraps the chain. Registration order is wrapping order: the first
/// `use`d middleware is outermost. A middleware may short-circuit by returning
/// without calling `next`, or catch what the chain below it raised.
pub type Middleware = (Request, Next) -> Response raise Error

///|
/// One registered route. `path` may be a pattern: literal segments, `:name`
/// segment parameters and a single trailing `*` wildcard.
priv struct Route {
  http_method : String
  path : String
  handler : Handler
}

///|
/// One registered middleware, applied only to requests whose path matches its
/// pattern (the default matches every path).
priv struct MiddlewareEntry {
  path : String
  mw : Middleware
}

///|
/// The application object. Matching walks each registered pattern segment by
/// segment; among competing matches the most specific route wins, with
/// registration order breaking ties.
struct App {
  routes : Array[Route]
  middlewares : Array[MiddlewareEntry]
  mut not_found_handler : Handler?
  mut error_handler : ((Request, Error) -> Response)?
}

///|
pub fn App::new() -> App {
  { routes: [], middlewares: [], not_found_handler: None, error_handler: None, }
}

///|
/// Registers `handler` for `http_method` + `path`. `path` may be a pattern with
/// literal segments, `:name` parameters and at most one trailing `*` wildcard.
/// `ANY` matches every method.
pub fn App::route(
  self : App,
  http_method : String,
  path : String,
  handler : Handler,
) -> Unit {
  self.routes.push({ http_method, path, handler, })
}

///|
pub fn App::get(self : App, path : String, handler : Handler) -> Unit {
  self.route("GET", path, handler)
}

///|
pub fn App::post(self : App, path : String, handler : Handler) -> Unit {
  self.route("POST", path, handler)
}

///|
pub fn App::put(self : App, path : String, handler : Handler) -> Unit {
  self.route("PUT", path, handler)
}

///|
pub fn App::patch(self : App, path : String, handler : Handler) -> Unit {
  self.route("PATCH", path, handler)
}

///|
pub fn App::delete(self : App, path : String, handler : Handler) -> Unit {
  self.route("DELETE", path, handler)
}

///|
/// Registers `handler` for `path` under every method, recorded as `ANY`.
pub fn App::all(self : App, path : String, handler : Handler) -> Unit {
  self.route("ANY", path, handler)
}

///|
/// Appends `middleware` to the chain, applied to requests whose path matches
/// `path` (a pattern like a route's, defaulting to every path). The first
/// registered middleware is outermost.
pub fn App::use_middleware(
  self : App,
  middleware : Middleware,
  path~ : String = "*",
) -> Unit {
  self.middlewares.push({ path, mw: middleware, })
}

///|
/// Replaces the default 404 for requests that match no route.
pub fn App::not_found(self : App, handler : Handler) -> Unit {
  self.not_found_handler = Some(handler)
}

///|
/// Replaces the default 500 for an `Error` raised out of a handler or
/// middleware. The default answers plain-text 500 and leaks nothing.
pub fn App::on_error(
  self : App,
  handler : (Request, Error) -> Response,
) -> Unit {
  self.error_handler = Some(handler)
}

///|
/// Splits a path or pattern on `/`, dropping the empty segment a leading slash
/// produces, so `/health` and `health` compare the same while `/health/` keeps
/// its trailing empty segment.
fn pattern_segments(s : String) -> Array[String] {
  let out : Array[String] = []
  let mut at_start = true
  for view in s.split("/") {
    let seg = view.to_owned()
    if at_start {
      at_start = false
      if seg.length() == 0 {
        continue
      }
    }
    out.push(seg)
  }
  out
}

///|
/// Tests a pattern against `path` and returns the captured parameters, or `None`
/// when nothing matches:
/// - literal segments must be equal;
/// - a segment of the form `:name` (longer than one character) captures one
///   non-empty path segment;
/// - a final segment that is exactly `*` matches zero or more remaining segments
///   and captures them, joined by `/`, under the name `*`.
/// Segments are compared as handed over: the WCGI gateway decodes `PATH_INFO`, so
/// percent decoding is not repeated here.
fn pattern_match(pattern : String, path : String) -> Array[(String, String)]? {
  let ps = pattern_segments(pattern)
  let xs = pattern_segments(path)
  let has_star = ps.length() > 0 && ps[ps.length() - 1] == "*"
  let anchored = pattern.has_prefix("/")
  // Paths handed over by the boundary always start with a slash; a slash-anchored
  // pattern therefore never matches an unprefixed tail like `static`.
  if anchored && !path.has_prefix("/") {
    return None
  }
  let fixed = if has_star { ps.length() - 1 } else { ps.length() }
  if !has_star && xs.length() != ps.length() {
    return None
  }
  if xs.length() < fixed {
    return None
  }
  let out : Array[(String, String)] = []
  for i = 0; i < fixed; i = i + 1 {
    let pseg = ps[i]
    let xseg = xs[i]
    if pseg.has_prefix(":") && pseg.length() > 1 {
      if xseg.length() == 0 {
        return None
      }
      out.push((pseg[1:].to_owned(), xseg))
    } else if pseg != xseg {
      return None
    }
  }
  if has_star {
    let mut rest = ""
    for i = fixed; i < xs.length(); i = i + 1 {
      if i > fixed {
        rest = rest + "/"
      }
      rest = rest + xs[i]
    }
    out.push(("*", rest))
  }
  Some(out)
}

///|
/// Specificity score of a pattern: fewer wildcards, then more literal segments,
/// then fewer `:params`. Used with registration order as the final tie-break.
fn route_score(pattern : String) -> (Int32, Int32, Int32) {
  let mut wildcards = 0
  let mut literals = 0
  let mut params_count = 0
  for seg in pattern_segments(pattern) {
    if seg == "*" {
      wildcards += 1
    } else if seg.has_prefix(":") && seg.length() > 1 {
      params_count += 1
    } else {
      literals += 1
    }
  }
  (wildcards, literals, params_count)
}

///|
fn push_unique_string(arr : Array[String], value : String) -> Unit {
  for v in arr {
    if v == value {
      return
    }
  }
  arr.push(value)
}

///|
fn join_comma(arr : Array[String]) -> String {
  let buf = StringBuilder()
  for i, v in arr.iter2() {
    if i > 0 {
      buf.write_string(", ")
    }
    buf.write_string(v)
  }
  buf.to_string()
}

///|
/// Resolves a request. Routes are tested by pattern; among routes whose patterns
/// match the path, the most specific route whose method matches (or `ANY`) wins.
/// A path that only exists under different methods yields 405 with an `allow`
/// header listing them, so "no route" stays distinguishable from "wrong route".
///
/// Registered middleware wraps the outcome, a `HEAD` request falls back to the
/// `GET` handler for its path with the body dropped, and an `Error` raised out
/// of the chain becomes a 500 through the app's `on_error` handler.
pub fn App::handle(self : App, req : Request) -> Response {
  let mut best_index = -1
  let mut best_params : Array[(String, String)] = []
  let mut best_wildcards = 0
  let mut best_literals = 0
  let mut best_params_count = 0
  let allowed : Array[String] = []
  for i, route in self.routes.iter2() {
    match pattern_match(route.path, req.path) {
      None => continue
      Some(params) =>
        if method_matches(route.http_method, req.http_method) {
          let (wildcards, literals, params_count) = route_score(route.path)
          let better = best_index < 0 ||
            wildcards < best_wildcards ||
            (
              wildcards == best_wildcards &&
              (
                literals > best_literals ||
                (literals == best_literals && params_count < best_params_count)
              )
            )
          if better {
            best_index = i
            best_params = params
            best_wildcards = wildcards
            best_literals = literals
            best_params_count = params_count
          }
        } else {
          push_unique_string(allowed, route.http_method)
        }
    }
  }
  // A HEAD with no handler of its own is served by the GET route, body dropped.
  let fall_back_to_get = req.http_method == "HEAD" && best_index < 0
  if fall_back_to_get {
    for i, route in self.routes.iter2() {
      if route.http_method == "GET" || route.http_method == "ANY" {
        match pattern_match(route.path, req.path) {
          Some(params) => {
            best_index = i
            best_params = params
            break
          }
          None => ()
        }
      }
    }
  }
  let endpoint : Next = req2 => {
    if best_index >= 0 {
      let route = self.routes[best_index]
      let res = (route.handler)({ ..req2, params: best_params, })
      // Only the GET fallback fakes a HEAD reply; a route registered for HEAD
      // owns its body.
      if fall_back_to_get {
        { ..res, body: "", }
      } else {
        res
      }
    } else if allowed.length() > 0 {
      response_with(405, [("allow", join_comma(allowed))], "method not allowed")
    } else {
      match self.not_found_handler {
        Some(handler) => handler(req2)
        None => response(404, "not found: \{req2.path}")
      }
    }
  }
  let chained = fold_middlewares(self.middlewares, 0, req, endpoint)
  chained(req) catch {
    err =>
      match self.error_handler {
        Some(handler) => handler(req, err)
        None => response(500, "internal server error")
      }
  }
}

///|
/// `ANY` routes serve every method.
fn method_matches(route_method : String, request_method : String) -> Bool {
  route_method == "ANY" || route_method == request_method
}

///|
/// Folds the middlewares that match `req.path` around `endpoint`, registration
/// order wrapping outward: entry 0 ends up outermost.
fn fold_middlewares(
  entries : Array[MiddlewareEntry],
  index : Int32,
  req : Request,
  endpoint : Next,
) -> Next {
  if index >= entries.length() {
    return endpoint
  }
  let entry = entries[index]
  if pattern_match(entry.path, req.path) is None {
    return fold_middlewares(entries, index + 1, req, endpoint)
  }
  let rest = fold_middlewares(entries, index + 1, req, endpoint)
  req2 => (entry.mw)(req2, rest)
}

///|
/// A route handler. The framework core stays total: it takes a `Request` and
/// returns a `Response`, with no host or async assumptions baked in.
pub type Handler = (Request) -> Response

///|
/// One registered route. `path` may be a pattern: literal segments, `:name`
/// segment parameters and a single trailing `*` wildcard.
priv struct Route {
  http_method : String
  path : String
  handler : Handler
}

///|
/// The application object. Matching walks each registered pattern segment by
/// segment; among competing matches the most specific route wins, with
/// registration order breaking ties.
struct App {
  routes : Array[Route]
}

///|
pub fn App::new() -> App {
  { routes: [], }
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
        if route.http_method == "ANY" || route.http_method == req.http_method {
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
  if best_index >= 0 {
    let route = self.routes[best_index]
    return (route.handler)({ ..req, params: best_params, })
  }
  if allowed.length() > 0 {
    return response_with(
      405,
      [("allow", join_comma(allowed))],
      "method not allowed",
    )
  }
  response(404, "not found: \{req.path}")
}

///|
/// Demo routes, enough to prove request -> route -> response end to end, including
/// path parameters, wildcard capture, redirect and JSON helpers.
pub fn demo_app() -> App {
  let app = App::new()
  app.get("/", _req => response(200, "hello from moonbit"))
  app.get("/health", _req => response(200, "ok"))
  app.post("/echo", req => response(200, req.body))
  app.get("/header", req => response(200, "x-demo=\{req.header("x-demo")}"))
  app.get("/search", req => response(200, "q=\{req.query_param("q")}"))
  app.get("/user/:id", req => response(200, "user:\{req.param("id")}"))
  app.get("/static/*", req => response(200, "asset:\{req.param("*")}"))
  app.get("/status.json", _req => {
    response_json(200, "{\"ok\":true,\"via\":\"moonbit-hono\"}")
  })
  app.get("/redirect", _req => redirect("/health"))
  app
}

///|
/// An HTTP request, built by the boundary from whatever the host handed over.
///
/// `path` is the part routes are matched on and never contains a query string,
/// `query` is the raw text after `?`. Header names are lowercased and kept in arrival
/// order, so repeated headers survive a round trip. `params` starts empty and is
/// filled by the router when a `:name` or trailing `*` pattern matches the path.
pub struct Request {
  http_method : String
  path : String
  query : String
  headers : Array[(String, String)]
  body : String
  params : Array[(String, String)]
}

///|
/// The request line as the client wrote it, so a redirect can send the whole URI back.
pub fn Request::uri(self : Request) -> String {
  if self.query.length() > 0 {
    "\{self.path}?\{self.query}"
  } else {
    self.path
  }
}

///|
/// A request header by lowercase name; absent reads as empty.
pub fn Request::header(self : Request, name : String) -> String {
  let mut found = ""
  for (key, value) in self.headers {
    if key == name {
      found = value
    }
  }
  found
}

///|
/// One value of a `application/x-www-form-urlencoded` query parameter, with its percent
/// escapes and `+` signs decoded.
pub fn Request::query_param(self : Request, name : String) -> String {
  let mut found = ""
  for pair in self.query.split("&") {
    match pair.split_once("=") {
      None => ()
      Some((key, value)) =>
        if percent_decode(key.to_owned()) == name {
          found = percent_decode(value.to_owned())
        }
    }
  }
  found
}

///|
/// A path parameter captured by the router, for example `id` in the route
/// `/user/:id`. The value captured by a trailing `*` wildcard is stored under
/// the name `*`. Absent names read as empty, and the last value wins.
pub fn Request::param(self : Request, name : String) -> String {
  let mut found = ""
  for (key, value) in self.params {
    if key == name {
      found = value
    }
  }
  found
}

///|
/// Fields are readable so handlers can inspect what came back, but building one
/// goes through `response`/`response_with`.
pub struct Response {
  status : Int32
  headers : Array[(String, String)]
  body : String
}

///|
/// Builds a response with an exact header list, for handlers that need to set
/// `location`, `set-cookie` or their own `content-length`.
pub fn response_with(
  status : Int32,
  headers : Array[(String, String)],
  body : String,
) -> Response {
  { status, headers, body, }
}

///|
pub fn response(status : Int32, body : String) -> Response {
  response_with(status, [("content-type", "text/plain; charset=utf-8")], body)
}

///|
/// Builds a JSON response. RFC 8259 defines JSON as UTF-8-only, so the content type
/// carries no charset parameter.
pub fn response_json(status : Int32, body : String) -> Response {
  response_with(status, [("content-type", "application/json")], body)
}

///|
/// Builds a redirect response with a `location` header and an empty body.
/// Defaults to 302; pass `status~` for 301, 307 or 308.
pub fn redirect(to : String, status~ : Int32 = 302) -> Response {
  response_with(status, [("location", to)], "")
}

///|
/// Status reason phrase. Unknown codes fall back to the generic class text, so a
/// serialized response stays valid HTTP.
pub fn reason_phrase(status : Int32) -> String {
  if status == 204 {
    "No Content"
  } else if status == 301 {
    "Moved Permanently"
  } else if status == 302 {
    "Found"
  } else if status == 303 {
    "See Other"
  } else if status == 307 {
    "Temporary Redirect"
  } else if status == 308 {
    "Permanent Redirect"
  } else if status == 400 {
    "Bad Request"
  } else if status == 404 {
    "Not Found"
  } else if status == 405 {
    "Method Not Allowed"
  } else if status == 500 {
    "Internal Server Error"
  } else if status >= 500 {
    "Server Error"
  } else if status >= 400 {
    "Client Error"
  } else if status >= 300 {
    "Redirection"
  } else {
    "OK"
  }
}

///|
/// `String` is UTF-16 on this target and `to_bytes`/`to_unchecked_string` merely
/// reinterpret those bytes, so the wire format never touches them. Everything that
/// crosses the boundary goes through `@utf8` instead.
fn utf8_bytes(text : String) -> Bytes {
  @utf8.encode(text.view())
}

///|
fn utf8_length(text : String) -> Int32 {
  utf8_bytes(text).length()
}

///|
/// Rejects a request whose body or headers are not valid UTF-8, up front, so the
/// field decoders below can stay total.
fn valid_utf8(raw : Bytes) -> Bool {
  try {
    let _ = @utf8.decode(raw)
    true
  } catch {
    _ => false
  }
}

///|
/// Decodes UTF-8, and reads as empty when it is not UTF-8 at all.
fn decode_utf8(raw : Bytes) -> String {
  @utf8.decode(raw) catch {
    _ => ""
  }
}

///|
fn hex_digit(code : Int32) -> Int32? {
  if code >= 48 && code <= 57 {
    Some(code - 48)
  } else if code >= 97 && code <= 102 {
    Some(code - 87)
  } else if code >= 65 && code <= 70 {
    Some(code - 55)
  } else {
    None
  }
}

///|
/// A `%` followed by two hex digits, as the byte it stands for.
fn hex_escape(high : Int32, low : Int32) -> Int32? {
  match (hex_digit(high), hex_digit(low)) {
    (Some(a), Some(b)) => Some(a * 16 + b)
    _ => None
  }
}

///|
/// Decodes `%XX` escapes and `+` as a URL query is encoded. Bytes are gathered first and
/// decoded once at the end, because `%C3%A9` spans two escapes and cannot be turned back
/// one character at a time.
fn percent_decode(text : String) -> String {
  let src = utf8_bytes(text).to_array()
  let n = src.length()
  let out : Array[Byte] = []
  let mut i = 0
  while i < n {
    let code = src[i].to_int()
    if code == 37 && i + 2 < n {
      match hex_escape(src[i + 1].to_int(), src[i + 2].to_int()) {
        Some(value) => {
          out.push(value.to_byte())
          i = i + 3
        }
        None => {
          out.push(src[i])
          i = i + 1
        }
      }
    } else if code == 43 {
      out.push((32 : Int32).to_byte())
      i = i + 1
    } else {
      out.push(src[i])
      i = i + 1
    }
  }
  decode_utf8(Bytes::from_array(out))
}

///|
/// Decodes `src[start, stop)` as UTF-8. Callers must have validated the input; the
/// fallback only guards against a range that straddles a boundary the scan chose.
fn decode_range(src : Array[Byte], start : Int32, stop : Int32) -> String {
  let n = stop - start
  guard n > 0 else { return "" }
  let tmp : Array[Byte] = []
  for i = start; i < stop; i = i + 1 {
    tmp.push(src[i])
  }
  let b = Bytes::from_array(tmp)
  @utf8.decode(b) catch {
    _ => ""
  }
}

///|
fn byte_is(b : Byte, target : Int32) -> Bool {
  b.to_int() == target
}

///|
/// Finds `target` at or after `from`, returns its index or -1.
fn find_byte(src : Array[Byte], from : Int32, target : Int32) -> Int32 {
  let n = src.length()
  let mut i = from
  while i < n {
    if byte_is(src[i], target) {
      return i
    }
    i += 1
  }
  -1
}

///|
/// End of the current line, skipping a trailing CR so LF-only fixtures work too.
/// Returns the content stop and the index the next line starts at.
fn line_end(src : Array[Byte], from : Int32) -> (Int32, Int32) {
  let e = find_byte(src, from, 10)
  if e < 0 {
    let n = src.length()
    (n, n)
  } else {
    let stop = if e > from && byte_is(src[e - 1], 13) { e - 1 } else { e }
    (stop, e + 1)
  }
}

///|
/// Lowercases ASCII letters in a header name, leaves every other byte untouched.
fn lowercase_range(src : Array[Byte], start : Int32, stop : Int32) -> String {
  let n = stop - start
  guard n > 0 else { return "" }
  let tmp : Array[Byte] = []
  for i = start; i < stop; i = i + 1 {
    let v = src[i].to_int()
    tmp.push(if v >= 65 && v <= 90 { (v + 32).to_byte() } else { src[i] })
  }
  decode_range(tmp, 0, n)
}

///|
/// Parses raw HTTP request bytes. Returns `None` for anything without a usable
/// request line, or with invalid UTF-8, which the boundary turns into a 400.
///
/// The body is whatever follows the blank line, taken whole: the host hands over a
/// complete request, so framing does not need `content-length`.
pub fn parse_request(raw : Bytes) -> Request? {
  guard valid_utf8(raw) else { return None }
  let src = raw.to_array()
  let n = src.length()
  guard n > 0 else { return None }

  // request line: METHOD SP PATH SP VERSION
  let (line_stop, next) = line_end(src, 0)
  let sp1 = find_byte(src, 0, 32)
  guard line_stop > 0 && sp1 > 0 && sp1 < line_stop else { return None }
  let sp2 = find_byte(src, sp1 + 1, 32)
  guard sp2 > sp1 && sp2 <= line_stop else { return None }
  let verb = decode_range(src, 0, sp1)
  let target = decode_range(src, sp1 + 1, sp2)
  let (path, query) = match target.split_once("?") {
    None => (target, "")
    Some((before, after)) => (before.to_owned(), after.to_owned())
  }

  let headers : Array[(String, String)] = []
  let mut pos = next
  let mut body_start = n
  let mut framed = false
  let mut scanning = true
  while scanning && pos < n {
    let (stop, after) = line_end(src, pos)
    if stop == pos {
      body_start = after
      framed = true
      scanning = false
    } else {
      let colon = find_byte(src, pos, 58)
      if colon > pos && colon < stop {
        let mut value = colon + 1
        while value < stop &&
              (byte_is(src[value], 32) || byte_is(src[value], 9)) {
          value += 1
        }
        headers.push(
          (lowercase_range(src, pos, colon), decode_range(src, value, stop)),
        )
      }
      pos = after
    }
  }
  // Without the blank line the head was cut off mid-transfer, so the body would be
  // a guess.
  guard framed else { return None }

  Some({
    http_method: verb,
    path,
    query,
    headers,
    params: [],
    body: decode_range(src, body_start, n),
  })
}

///|
/// CGI variables the runner exposes as `x-cgi-*` request headers. Mirroring them the
/// way the reference CGI implementation does keeps a handler written for a Rust WCGI
/// app working here unchanged.
let cgi_mirror_vars : Array[(String, String)] = [
  ("AUTH_TYPE", "x-cgi-auth-type"),
  ("CONTENT_LENGTH", "x-cgi-content-length"),
  ("CONTENT_TYPE", "x-cgi-content-type"),
  ("GATEWAY_INTERFACE", "x-cgi-gateway-interface"),
  ("PATH_INFO", "x-cgi-path-info"),
  ("PATH_TRANSLATED", "x-cgi-path-translated"),
  ("QUERY_STRING", "x-cgi-query-string"),
  ("REMOTE_ADDR", "x-cgi-remote-addr"),
  ("REMOTE_HOST", "x-cgi-remote-host"),
  ("REMOTE_IDENT", "x-cgi-remote-ident"),
  ("REMOTE_USER", "x-cgi-remote-user"),
  ("REQUEST_METHOD", "x-cgi-request-method"),
  ("SCRIPT_NAME", "x-cgi-script-name"),
  ("SERVER_PORT", "x-cgi-server-port"),
  ("SERVER_PROTOCOL", "x-cgi-server-protocol"),
  ("SERVER_SOFTWARE", "x-cgi-server-software"),
]

///|
/// CGI variable names are uppercase and exact; a missing one reads as empty rather
/// than absent, since every variable below treats empty as "not provided".
fn cgi_var(env : Array[(String, String)], name : String) -> String {
  for (key, value) in env {
    if key == name {
      return value
    }
  }
  ""
}

///|
/// `ACCEPT_ENCODING` is the dash-cased form of the wire name `accept-encoding`: CGI
/// had to fold the dashes into underscores to put the header in the environment.
fn cgi_header_name(rest : String) -> String {
  rest.replace(old="_", new="-").to_lower()
}

///|
fn cgi_header_key(header : (String, String)) -> String {
  let (name, _) = header
  name
}

///|
/// The first of these that is a path. RFC 3875 requires `PATH_INFO` and `SCRIPT_NAME` to
/// begin with `/`, so a gateway that puts the application's *name* in `SCRIPT_NAME` — the
/// way the reference WCGI package's manifest does it — is skipped instead of routed on.
fn cgi_path(
  path_info : String,
  script_name : String,
  request_uri : String,
) -> String {
  let uri = match request_uri.split_once("?") {
    None => request_uri
    Some((before, _after)) => before.to_owned()
  }
  let mut found = ""
  for candidate in [path_info, script_name, uri] {
    if found.length() == 0 && candidate.has_prefix("/") {
      found = candidate
    }
  }
  found
}

///|
/// Builds a `Request` from the CGI environment and the body read off stdin.
///
/// A request with no method, or with no variable holding a path, yields `None`, which the
/// boundary turns into a 400. Which variable that is is not fixed by the spec: a gateway
/// that splits the URI hands the app-relative tail in `PATH_INFO` and keeps its own name in
/// `SCRIPT_NAME`, a runner that does not split leaves everything in `SCRIPT_NAME`, and a
/// gateway that only forwards the request line puts it in the non-standard `REQUEST_URI`.
/// Trying them in that order routes all three the same way. `QUERY_STRING` stays separate,
/// so a route registered for `/health` also answers `/health?debug=1`. Client headers
/// arrive as `HTTP_*`, and their values are trimmed because the environment keeps the
/// optional whitespace RFC 3875 allows around the `=`.
pub fn request_from_cgi(
  env : Array[(String, String)],
  body : String,
) -> Request? {
  let http_method = cgi_var(env, "REQUEST_METHOD")
  let path = cgi_path(
    cgi_var(env, "PATH_INFO"),
    cgi_var(env, "SCRIPT_NAME"),
    cgi_var(env, "REQUEST_URI"),
  )
  guard http_method.length() > 0 && path.length() > 0 else { return None }
  let query = cgi_var(env, "QUERY_STRING")
  let headers : Array[(String, String)] = []
  for (key, value) in env {
    match key.strip_prefix("HTTP_") {
      None => ()
      Some(rest) =>
        if rest.length() > 0 {
          headers.push(
            (cgi_header_name(rest.to_owned()), value.trim().to_owned()),
          )
        }
    }
  }
  for (name, header) in cgi_mirror_vars {
    let value = cgi_var(env, name)
    if value.length() > 0 {
      headers.push((header, value))
    }
  }
  Some({ http_method, path, query, headers, body, params: [], })
}

///|
/// Serializes a response the way CGI expects it on stdout: a `Status:` line, headers
/// sorted by name, a blank line, then the body, all separated by bare LF.
///
/// `Content-Length` is dropped on purpose: RFC 3875 gives it a special meaning here
/// (a non-parsed body, forwarded raw), which would stop the runner from framing the
/// response at all. `Status` is dropped for the same reason -- the status line is
/// already written.
pub fn serialize_cgi(res : Response) -> Bytes {
  let out : Array[Byte] = []
  push_utf8(out, "Status: \{res.status} \{reason_phrase(res.status)}\n")
  let lines : Array[(String, String)] = []
  for (name, value) in res.headers {
    if name != "content-length" && name != "status" {
      lines.push((name, value))
    }
  }
  lines.sort_by((a, b) => cgi_header_key(a).lexical_compare(cgi_header_key(b)))
  for (name, value) in lines {
    push_utf8(out, "\{name}: \{value}\n")
  }
  push_utf8(out, "\n")
  push_utf8(out, res.body)
  Bytes::from_array(out)
}

///|
fn push_utf8(out : Array[Byte], text : String) -> Unit {
  for b in utf8_bytes(text) {
    out.push(b)
  }
}

///|
/// Serializes to HTTP/1.1 response bytes. `content-length` is always present, which
/// is what lets the host know where the body ends.
pub fn serialize_response(res : Response) -> Bytes {
  let out : Array[Byte] = []
  push_utf8(out, "HTTP/1.1 \{res.status} \{reason_phrase(res.status)}\r\n")
  let mut has_length = false
  for (name, value) in res.headers {
    if name == "content-length" {
      has_length = true
    }
    push_utf8(out, "\{name}: \{value}\r\n")
  }
  if !has_length {
    push_utf8(out, "content-length: \{utf8_length(res.body)}\r\n")
  }
  push_utf8(out, "\r\n")
  push_utf8(out, res.body)
  Bytes::from_array(out)
}

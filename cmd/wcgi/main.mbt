///|
/// The WCGI guest: a CGI program (RFC 3875) compiled as a WASI executable. The runner
/// puts the request in the environment, pipes the body to stdin, and turns this
/// process's stdout back into an HTTP response, so one instance serves one request.
///
///   printf 'hi' | wasmer run wcgi.wasm --env REQUEST_METHOD=POST \
///     --env SCRIPT_NAME=/echo --env CONTENT_LENGTH=2
extern "wasm" fn raw_load8(addr : Int32) -> Int32 =
  #|(func (param i32) (result i32) (i32.load8_u (local.get 0)))

///|
extern "wasm" fn raw_load32(addr : Int32) -> Int32 =
  #|(func (param i32) (result i32) (i32.load (local.get 0)))

///|
extern "wasm" fn raw_store8(addr : Int32, value : Int32) -> Unit =
  #|(func (param i32 i32) (i32.store8 (local.get 0) (local.get 1)))

///|
extern "wasm" fn raw_store32(addr : Int32, value : Int32) -> Unit =
  #|(func (param i32 i32) (i32.store (local.get 0) (local.get 1)))

///|
extern "wasm" fn raw_grow(pages : Int32) -> Int32 =
  #|(func (param i32) (result i32) (memory.grow (local.get 0)))

///|
/// The WASI calls the CGI contract needs. Each signature has to match the real one
/// exactly, or Wasmer refuses to link the module.
fn environ_sizes_get(count_ptr : Int32, size_ptr : Int32) -> Int32 = "wasi_snapshot_preview1" "environ_sizes_get"

///|
fn environ_get(ptrs : Int32, buf : Int32) -> Int32 = "wasi_snapshot_preview1" "environ_get"

///|
fn fd_read(
  fd : Int32,
  iovs : Int32,
  iovs_len : Int32,
  nread_ptr : Int32,
) -> Int32 = "wasi_snapshot_preview1" "fd_read"

///|
fn fd_write(
  fd : Int32,
  iovs : Int32,
  iovs_len : Int32,
  nwritten_ptr : Int32,
) -> Int32 = "wasi_snapshot_preview1" "fd_write"

///|
let page_size : Int32 = 65536

///|
/// Claims `bytes` above everything touched so far, so two WASI calls never share a
/// scratch region: `memory.grow` only appends, and a later grow lands above this one.
/// Returns 0, which makes the call fail, when the grow itself did.
fn scratch(bytes : Int32) -> Int32 {
  let pages = (bytes + page_size - 1) / page_size
  let old = raw_grow(pages)
  if old < 0 {
    0
  } else {
    old * page_size
  }
}

///|
/// Writes a `wasi_iovec_t`: `[ptr:u32le][len:u32le]`.
fn iovec(area : Int32, buf : Int32, len : Int32) -> Unit {
  raw_store32(area, buf)
  raw_store32(area + 4, len)
}

///|
/// `String` is UTF-16 on this target, so every wire value is decoded explicitly and a
/// bad sequence reads as empty instead of trapping inside the boundary.
fn decode(raw : Bytes) -> String {
  @utf8.decode(raw) catch {
    _ => ""
  }
}

///|
/// One NUL-terminated `KEY=VALUE` from the environment block, split at the first `=`
/// in byte space so no reinterpretation can move the separator.
fn env_pair(addr : Int32) -> (String, String) {
  let raw : Array[Byte] = []
  let mut eq = -1
  let mut i = 0
  while true {
    let b = raw_load8(addr + i)
    if b == 0 {
      break
    }
    if b == 61 && eq < 0 {
      eq = i
    }
    raw.push(b.to_byte())
    i = i + 1
  }
  guard eq > 0 else { return ("", "") }
  let key : Array[Byte] = []
  let value : Array[Byte] = []
  for j, b in raw.iter2() {
    if j < eq {
      key.push(b)
    } else if j > eq {
      value.push(b)
    }
  }
  (decode(Bytes::from_array(key)), decode(Bytes::from_array(value)))
}

///|
/// The whole CGI environment as `(name, value)` pairs, in the order the host passed it.
fn env_block() -> Array[(String, String)] {
  let head = scratch(64)
  guard environ_sizes_get(head, head + 4) == 0 else { return [] }
  let count = raw_load32(head)
  let size = raw_load32(head + 4)
  guard count > 0 && size > 0 else { return [] }
  let room = scratch(count * 4 + size + 64)
  guard environ_get(room, room + count * 4 + 16) == 0 else { return [] }
  let out : Array[(String, String)] = []
  for i = 0; i < count; i = i + 1 {
    let (key, value) = env_pair(raw_load32(room + i * 4))
    if key.length() > 0 {
      out.push((key, value))
    }
  }
  out
}

///|
fn env_value(env : Array[(String, String)], name : String) -> String {
  for (key, value) in env {
    if key == name {
      return value
    }
  }
  ""
}

///|
/// CGI frames the body with `CONTENT_LENGTH`; an unparsable or negative value is taken
/// to mean there is no body.
fn content_length(env : Array[(String, String)]) -> Int32 {
  let n = @string.parse_int(env_value(env, "CONTENT_LENGTH")) catch { _ => 0 }
  if n > 0 {
    n
  } else {
    0
  }
}

///|
/// Reads up to `length` bytes of stdin. One request per instance means fd 0 holds this
/// body and nothing else, but a pipe can hand over less than asked for at a time, so
/// the read repeats until the frame is full or the host closes it.
fn read_stdin(length : Int32) -> Bytes {
  guard length > 0 else { return [] }
  let area = scratch(length + 128)
  let buf = area + 64
  let collected : Array[Byte] = []
  let mut got = 0
  let mut running = true
  while running && got < length {
    iovec(area, buf + got, length - got)
    let errno = fd_read(0, area, 1, area + 8)
    let nread = raw_load32(area + 8)
    if errno != 0 || nread <= 0 {
      running = false
    } else {
      for i = 0; i < nread; i = i + 1 {
        collected.push(raw_load8(buf + got + i).to_byte())
      }
      got = got + nread
    }
  }
  Bytes::from_array(collected)
}

///|
/// Puts the CGI response on stdout. `println` is avoided deliberately: the body has to
/// reach the runner byte for byte, and this writes the encoded bytes as they are.
fn write_stdout(data : Bytes) -> Unit {
  let n = data.length()
  guard n > 0 else { return }
  let area = scratch(n + 128)
  let buf = area + 64
  for i, b in data.iter2() {
    raw_store8(buf + i, b.to_int())
  }
  iovec(area, buf, n)
  let _ = fd_write(1, area, 1, area + 8)
}

///|
fn main {
  let env = env_block()
  let body = decode(read_stdin(content_length(env)))
  let res = match @lib.request_from_cgi(env, body) {
    None => @lib.response(400, "malformed request")
    Some(req) => @lib.demo_app().handle(req)
  }
  write_stdout(@lib.serialize_cgi(res))
}

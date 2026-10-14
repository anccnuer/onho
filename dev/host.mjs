#!/usr/bin/env node
// Local WCGI host for the MoonBit CGI executable.
//
// It plays the part the WCGI runner plays on Wasmer Edge: put the request in the WASI
// environment, pipe the body to stdin, run `_start` once, and read the CGI response off
// stdout. A fresh instance per request, because WCGI gives each request a clean sandbox.
//
//   node dev/host.mjs run                 print each fixture and its CGI response
//   node dev/host.mjs check               diff responses against *.expect (CI gate)
//   node dev/host.mjs update              rewrite *.expect from the current build
//   node dev/host.mjs serve [port]        real HTTP server on localhost
//   node dev/host.mjs abi                 report the WASI imports and exports
import { readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL(".", import.meta.url));
const root = join(here, "..");
const DEFAULT_WASM = join(root, "_build/wasm/release/build/cmd/wcgi/wcgi.wasm");
const FIXTURES = join(root, "fixtures");
const PAGE = 65536;
const WASI = "wasi_snapshot_preview1";

const wasmPath = process.env.WASM ?? DEFAULT_WASM;
if (!existsSync(wasmPath)) {
  console.error(`no module at ${wasmPath} - run: moon build --target wasm --release`);
  process.exit(1);
}
const compiled = await WebAssembly.compile(readFileSync(wasmPath));

const cgiName = name => `HTTP_${name.replace(/-/g, "_").toUpperCase()}`;

// Node hands a request line and header values over as latin-1, one character per byte,
// so the UTF-8 text the client actually sent has to be recovered before it goes into
// the environment as UTF-8 bytes.
const fromWire = text => Buffer.from(text, "latin1").toString("utf8");

const wireHeaders = headers =>
  Object.fromEntries(Object.entries(headers).map(([name, value]) => [
    name,
    Array.isArray(value) ? value.map(fromWire) : fromWire(value),
  ]));

// A gateway hands CGI a decoded path: RFC 3875 says SCRIPT_NAME is the URL with its
// percent escapes already turned back into text.
function decodedPath(target) {
  try {
    return decodeURIComponent(target);
  } catch {
    return target;
  }
}

// The spec leaves more than one way for a gateway to say which path was asked for, and a
// deployment cannot be inspected from the inside, so the harness can hand over each of
// them. CGI_LAYOUT picks one:
//   script  the runner does not split the URI, SCRIPT_NAME is the whole path
//   split   classic CGI, SCRIPT_NAME is the app and PATH_INFO the app-relative tail,
//           which is what the reference WCGI package's manifest assumes
//   uri     a gateway that only forwards the request line, in the non-standard REQUEST_URI
const cgi_layouts = {
  script: path => ({ SCRIPT_NAME: path }),
  split: path => ({ SCRIPT_NAME: "moonbit-hono", PATH_INFO: path }),
  uri: (path, query) => ({ REQUEST_URI: query ? `${path}?${query}` : path }),
};
const layoutName = process.env.CGI_LAYOUT ?? "script";
const layout = cgi_layouts[layoutName];
if (!layout) {
  console.error(`CGI_LAYOUT must be one of ${Object.keys(cgi_layouts).join(", ")}`);
  process.exit(1);
}

// The environment the CGI gateway builds from a request: the two mandatory variables,
// the body length, and every client header as HTTP_*. Content-Length and Content-Type
// are lifted to their CGI names instead of mirrored, which is what RFC 3875 requires.
function cgiEnv(method, target, version, headers, body) {
  // Only the path is handed to CGI decoded; the query string goes through exactly as
  // the client wrote it, which is why the framework decodes it itself.
  const [rawPath, query = ""] = target.split("?");
  const path = decodedPath(rawPath);
  const env = {
    REQUEST_METHOD: method,
    ...layout(path, query),
    QUERY_STRING: query,
    SERVER_PROTOCOL: version,
    GATEWAY_INTERFACE: "CGI/1.1",
  };
  if (body.length > 0) env.CONTENT_LENGTH = String(body.length);
  for (const [name, value] of Object.entries(headers)) {
    const v = Array.isArray(value) ? value.join(", ") : value;
    if (name === "content-length") env.CONTENT_LENGTH = v;
    else if (name === "content-type") env.CONTENT_TYPE = v;
    else env[cgiName(name)] = v;
  }
  return env;
}

// A fixture stays a raw HTTP request; only the host knows it has to be re-encoded as an
// environment.
function toRequest(raw) {
  const double = raw.indexOf("\r\n\r\n");
  const sep = double < 0 ? raw.indexOf("\n\n") : double;
  const width = double < 0 ? 1 : 2;
  const head = sep < 0 ? raw : raw.slice(0, sep + width);
  const body = Buffer.from(sep < 0 ? "" : raw.slice(sep + width * 2), "utf8");
  const lines = head.split(/\r?\n/).filter(Boolean);
  const [method, target = "/", version = "HTTP/1.1"] = (lines[0] ?? "").split(" ");
  const headers = {};
  for (const line of lines.slice(1)) {
    const colon = line.indexOf(":");
    if (colon > 0) headers[line.slice(0, colon).trim().toLowerCase()] = line.slice(colon + 1).trim();
  }
  return { env: cgiEnv(method, target, version, headers, body), body };
}

// The four WASI calls the guest imports, and nothing else: no preopens, no clocks, no
// sockets, so a request cannot reach past its own environment, stdin and stdout.
function spawn(env, stdin) {
  const entries = Object.entries(env).map(([k, v]) => Buffer.from(`${k}=${v}`, "utf8"));
  const envSize = entries.reduce((n, e) => n + e.length + 1, 0);
  const stdout = [];
  const stderr = [];
  const input = { 0: { bytes: stdin, pos: 0 } };
  let memory;

  const bytes = () => new Uint8Array(memory.buffer);
  const view = () => new DataView(memory.buffer);
  const put32 = (addr, value) => view().setUint32(addr, value >>> 0, true);
  const get32 = addr => view().getUint32(addr, true);

  const api = {
    environ_sizes_get(count_ptr, size_ptr) {
      put32(count_ptr, entries.length);
      put32(size_ptr, envSize);
      return 0;
    },
    environ_get(ptrs, buf) {
      let at = buf;
      entries.forEach((entry, i) => {
        put32(ptrs + i * 4, at);
        bytes().set(entry, at);
        bytes()[at + entry.length] = 0;
        at += entry.length + 1;
      });
      return 0;
    },
    fd_read(fd, iovs, iovs_len, nread_ptr) {
      const src = input[fd];
      if (!src) return 8; // EBADF
      let total = 0;
      for (let i = 0; i < iovs_len; i++) {
        const ptr = get32(iovs + i * 8);
        const len = get32(iovs + i * 8 + 4);
        const n = Math.min(len, src.bytes.length - src.pos);
        if (n > 0) {
          bytes().set(src.bytes.subarray(src.pos, src.pos + n), ptr);
          src.pos += n;
          total += n;
        }
        if (n < len) break;
      }
      put32(nread_ptr, total);
      return 0;
    },
    fd_write(fd, iovs, iovs_len, nwritten_ptr) {
      const sink = fd === 1 ? stdout : fd === 2 ? stderr : null;
      if (!sink) return 8; // EBADF
      let total = 0;
      for (let i = 0; i < iovs_len; i++) {
        const ptr = get32(iovs + i * 8);
        const len = get32(iovs + i * 8 + 4);
        sink.push(Buffer.from(bytes().slice(ptr, ptr + len)));
        total += len;
      }
      put32(nwritten_ptr, total);
      return 0;
    },
  };

  // Anything the guest asks for beyond those four is a contract change, so name it
  // instead of quietly handing back a stub that returns success.
  const imports = new Proxy({}, {
    get(_target, mod) {
      return new Proxy({}, {
        get(_x, name) {
          const fn = mod === WASI ? api[name] : undefined;
          return fn ?? (() => {
            throw new Error(`unimplemented WASI import ${String(mod)}.${String(name)}`);
          });
        },
      });
    },
  });

  const instance = new WebAssembly.Instance(compiled, imports);
  memory = instance.exports.memory;
  instance.exports._start();
  const notes = Buffer.concat(stderr).toString("utf8");
  if (notes) process.stderr.write(notes);
  return Buffer.concat(stdout);
}

// CGI output: an optional `Status:` line, headers, a blank line, then the body.
function parseCgi(out) {
  const lines = out.toString("utf8").split("\n");
  let index = 0;
  let status = 200;
  if (lines[0]?.startsWith("Status:")) {
    status = Number(lines[0].slice(7).trim().split(" ")[0]) || 200;
    index = 1;
  }
  const headers = {};
  for (; index < lines.length && lines[index] !== ""; index++) {
    const colon = lines[index].indexOf(":");
    if (colon > 0) {
      headers[lines[index].slice(0, colon).trim()] = lines[index].slice(colon + 1).trim();
    }
  }
  return { status, headers, body: lines.slice(index + 1).join("\n") };
}

function fixtureFiles() {
  if (!existsSync(FIXTURES)) return [];
  return readdirSync(FIXTURES)
    .filter(f => f.endsWith(".http"))
    .sort()
    .map(f => join(FIXTURES, f));
}

function command() {
  const args = process.argv.slice(2).filter(a => a !== "--");
  const cmd = (args[0] ?? "run").replace(/^--/, "");
  const named = args.slice(1).filter(a => !a.startsWith("-"));

  if (cmd === "abi") {
    const exports = WebAssembly.Module.exports(compiled);
    const imports = WebAssembly.Module.imports(compiled);
    const wanted = ["environ_sizes_get", "environ_get", "fd_read", "fd_write"];
    const has = (name, kind) => exports.some(e => e.name === name && e.kind === kind);
    console.log(`module: ${basename(wasmPath)}`);
    console.log(`_start: ${has("_start", "function") ? "ok" : "MISSING"}`);
    console.log(`memory: ${has("memory", "memory") ? "ok" : "MISSING"}`);
    console.log(`imports: ${imports.map(i => `${i.module}.${i.name}`).join(", ") || "none"}`);
    const extra = imports.filter(i => i.module !== WASI || !wanted.includes(i.name));
    if (extra.length > 0) {
      console.log(`unexpected: ${extra.map(i => `${i.module}.${i.name}`).join(", ")}`);
    }
    if (!has("_start", "function") || !has("memory", "memory") || extra.length > 0) {
      process.exit(1);
    }
    return;
  }

  if (cmd === "serve") {
    const port = Number(named[0] ?? 8080);
    createServer((req, res) => {
      const chunks = [];
      req.on("data", c => chunks.push(c));
      req.on("end", () => {
        const body = Buffer.concat(chunks);
        const out = parseCgi(spawn(
          cgiEnv(req.method, fromWire(req.url), "HTTP/1.1", wireHeaders(req.headers), body),
          body,
        ));
        res.writeHead(out.status, out.headers);
        res.end(out.body);
      });
    }).listen(port, () => console.log(`wcgi dev server: http://localhost:${port}`));
    return;
  }

  const files = named.length > 0
    ? named.map(f => join(FIXTURES, f.endsWith(".http") ? f : `${f}.http`))
    : fixtureFiles();
  if (files.length === 0) {
    console.error(`no fixtures in ${FIXTURES}`);
    process.exit(1);
  }
  let failed = 0;
  for (const file of files) {
    const name = basename(file, ".http");
    const { env, body } = toRequest(readFileSync(file, "utf8"));
    const text = spawn(env, body).toString("utf8");
    const expectFile = join(FIXTURES, `${name}.expect`);
    if (cmd === "update") {
      writeFileSync(expectFile, text);
      console.log(`updated ${name}.expect`);
      continue;
    }
    if (cmd === "check") {
      if (!existsSync(expectFile)) {
        console.log(`FAIL ${name}: no expectation, run: node dev/host.mjs update`);
        failed++;
        continue;
      }
      const expected = readFileSync(expectFile, "utf8");
      if (expected === text) {
        console.log(`ok   ${name}`);
      } else {
        console.log(`FAIL ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(text)}`);
        failed++;
      }
      continue;
    }
    console.log(`--- ${name}`);
    console.log(text.endsWith("\n") ? text : `${text}\n`);
  }
  process.exit(failed === 0 ? 0 : 1);
}

command();

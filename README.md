# anccnuer/onho

[English](README.en.md) | 中文

MoonBit 写的 Web 框架,路由风格类似 Hono,编译成 wasm 后以 WCGI 方式跑在 Wasmer Edge 上。

## 快速上手

```
moon add anccnuer/onho
```

```moonbit
let app = @onho.App::new()

app.get("/hello/:name", req => @onho.response(200, "hello \{req.param("name")}"))
app.get("/user/:id", req => @onho.response_json(200, "{\"id\":\"\\{req.param("id")}\"}"))
app.get("/static/*", req => @onho.response(200, req.param("*")))
app.post("/echo", req => @onho.response(200, req.body))
app.all("/ping", _req => @onho.response(200, "pong"))  // 任意方法

app.get("/redirect", _req => @onho.redirect("/hello/world", status=301))
app.get("/page", _req => @onho.html(200, "<h1>hi</h1>"))
```

读请求:

```moonbit
req.header("x-request-id")   // 头名一律小写;没有就返回 ""
req.query_param("q")         // 查询参数,已做百分号解码(%E4%B8%AD -> 中,+ -> 空格)
req.param("id")              // 路由参数,通配符的捕获值放在 "*"
req.body                     // 原始 body 文本
```

构造响应:

```moonbit
@onho.response(204, "")                       // text/plain; charset=utf-8
@onho.response_json(200, "{\"ok\":true}")     // application/json
@onho.html(200, "<p>hi</p>")                  // text/html; charset=utf-8
@onho.redirect("/login", status=302)          // location 头 + 空 body,默认 302
@onho.response_with(200, [("x-a", "1")], "已设置")          // 完全控制
@onho.response(200, "ok").set_header("x-b", "2")            // 追加一个头
```

中间件(先注册的在外层;`path~` 不传就对所有路径生效):

```moonbit
app.use_middleware((req, next) => {
  // 进来时做的事,比如鉴权
  let res = next(req)
  res.set_header("x-response-by", "onho")     // 出去时也可以改响应
}, path="/api/*")

app.use_middleware((_req, _next) => @onho.response(401, "denied"))  // 不调 next 即短路
```

handler 里可以 `raise`,不用层层 try:

```moonbit
app.get("/api/user/:id", req => {
  let id = @string.parse_int(req.param("id")) catch { _ => raise Failure("bad id") }
  @onho.response_json(200, "{\"id\":\{id}}")
})

app.on_error((_req, _err) => @onho.response(500, "internal error"))  // 不注册则默认 500
app.not_found(_req => @onho.response_json(404, "{\"error\":\"not found\"}"))
```

接到真实的请求,取决于你跑在什么宿主后面:

```moonbit
// WCGI / CGI:请求在环境变量里,body 在 stdin
let res = match @onho.request_from_cgi(env, body) {
  Some(req) => app.handle(req)
  None => @onho.response(400, "bad request")
}

// 宿主直接递原始 HTTP 字节
@onho.parse_request(bytes)  // Request?,解析失败是 None
```

## 跑通示例项目

仓库里的 `cmd/wcgi` 是一个能直接部署的例子:

```
bash dev/check.sh            # moon test + wasm 构建 + fixture 比对 + wasmer 冒烟
node dev/host.mjs serve 8080 # 本地起一个真实的 HTTP 服务
curl -s localhost:8080/hello/world
```

## 部署

```
moon build --target wasm --release
wasmer deploy        # 读 app.yaml 和 wasmer.toml
```

部署后若所有请求都 400,查 runner 是否给了 `SCRIPT_NAME`/`PATH_INFO`;若所有路径返回
同一页面,是 runner 固定了 `SCRIPT_NAME`,此时路由在 `PATH_INFO` 上。

## 目录结构

- `http.mbt` — `Request`/`Response`、CGI 与原始 HTTP 边界
- `app.mbt` — `App` 路由器:中间件、405/404、HEAD 回退、错误处理
- `cmd/wcgi/` — 可部署的示例程序
- `test/`、`fixtures/`、`dev/` — 测试与本地 WCGI 宿主


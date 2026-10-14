# anccnuer/onho

[English](README.en.md) | 中文

一个受 Hono 启发的 MoonBit Web 框架,编译为 wasm,面向 Wasmer Edge 的 WCGI 模型。

## 快速开始

```
moon add anccnuer/onho
```

```moonbit
// cmd/server/main.mbt
fn main {
  let app = @onho.App::new()
  app.get("/hello/:name", req => @onho.response(200, "hello \{req.param("name")}"))
  app.get("/redirect", _req => @onho.redirect("/hello/world"))
  // 中间件包裹整条链路;注册顺序即包裹顺序(先注册的在最外层),`path~` 按路由模式限定作用范围。
  app.use_middleware((req, next) => {
    let res = next(req)
    res.set_header("x-powered-by", "onho")
  }, path="/api/*")
  // 处理器可以抛错;未捕获的 Error 交给错误处理器。
  app.get("/api/user/:id", req => {
    let id = @string.parse_int(req.param("id")) catch { _ => raise Failure("bad id") }
    @onho.response_json(200, "{\"id\":\{id}}")
  })
  app.on_error((_req, _err) => @onho.response(500, "something broke"))
  app.not_found(_req => @onho.response_json(404, "{\"error\":\"not found\"}"))
  // 用哪个边界就从哪里拿 Request:
  // WCGI 用 @onho.request_from_cgi(env, body),原始 HTTP 用 @onho.parse_request(bytes)。
  // 然后处理请求:
  //   let res = app.handle(req)
}
```

路由:字面量段、`:name` 参数、唯一的尾部 `*` 通配符;最具体的路由获胜;405 带 `allow`
头列出可用方法;每个方法各有一个注册函数,`app.all` 匹配任意方法,其余用
`app.route(method, path, handler)`。

`HEAD` 请求在没有自己的路由时,由该路径的 `GET` 处理器响应并丢弃 body。

## WCGI 是什么

WCGI 是跑在 WASI **可执行文件**上的 RFC 3875 CGI — 没有请求形态的 ABI 要实现,
实现的只是一个 shell 脚本看到的东西:

- 请求经**环境变量**抵达:`REQUEST_METHOD`、`SCRIPT_NAME`、`QUERY_STRING`、
  `CONTENT_LENGTH`、`CONTENT_TYPE`,以及每个客户端头部的 `HTTP_*` 形式
- body 是 **stdin** 上精确的 `CONTENT_LENGTH` 字节
- 响应写到 **stdout**:`Status: <code> <reason>`,然后是按名称排序的头、空行、body —
  用裸 LF 分隔,不是 CRLF
- runner 给每个请求一个**全新实例**,请求之间不保留任何状态

因此 `cmd/wcgi` 是 `pkgtype(kind: "executable")`,`wasmer.toml` 声明
`runner = "https://webc.org/runner/wcgi"` 与 `dialect = "rfc-3875"`。

## 本地测试环境

`moon build` 本身不是重点 — guest 只有在某个东西扮演 CGI 网关时才能工作。有两样东西
扮演这个角色,它们相互独立:

```
bash dev/check.sh              # 构建 + 单测 + ABI + fixtures + wasmer
bash dev/check.sh --update     # 有意变更后重写 fixtures/*.expect
```

1. `moon test` — 覆盖路由器、中间件、CGI 映射与编解码,纯值断言,不依赖 wasm。
2. `moon build --target wasm --release`
3. `node dev/host.mjs abi` — 模块必须导出 `_start` 与 `memory`,且**只**导入
   `environ_sizes_get`、`environ_get`、`fd_read`、`fd_write`。多出一个都是 guest
   越过了单个请求的沙箱。
4. `node dev/host.mjs check` — 每个 `fixtures/*.http` 被重新编码为 CGI 环境,经过
   Node WASI shim 运行,与其 `.expect` 逐字节比对。
5. `wasmer run` — 同一模块在真实引擎上,以 `--env` 与 stdin 喂入。

手动驱动:

```
node dev/host.mjs run            # 打印每个 fixture 及其 CGI 响应
node dev/host.mjs serve 8080     # 真实 HTTP;每请求一个实例,与 WCGI 一致
curl -s localhost:8080/health    # -> ok
```

```
printf 'hi' | wasmer run _build/wasm/release/build/cmd/wcgi/wcgi.wasm \
  --env REQUEST_METHOD=POST --env SCRIPT_NAME=/echo --env CONTENT_LENGTH=2
# Status: 200 OK
# content-type: text/plain; charset=utf-8
#
# hi
```

在 Git Bash 下先 `export MSYS2_ARG_CONV_EXCL='*'`:它会把 `--env SCRIPT_NAME=/echo`
改写成 Windows 路径。

## 边界层

`http.mbt` 以纯函数在两个方向上承载映射,因此无需 wasm 运行时即可测试:

- `request_from_cgi(env, body)` — 网关拆分 URI 时路由取 `PATH_INFO`,不拆分时取
  `SCRIPT_NAME`;`QUERY_STRING` 永远不会混进路径,所以为 `/health` 注册的路由同样
  响应 `/health?debug=1`。`HTTP_*` 还原为小写带连字符的头名,网关变量按参考 CGI
  实现的方式镜像为 `x-cgi-*`。缺少 `REQUEST_METHOD` 或路径变量时回答 400,而不是猜。
- `serialize_cgi(res)` — `Status:` 行、按名排序的头、LF、body。故意丢弃
  `Content-Length` 与 `Status`:RFC 3875 给 CGI 输出里的 `Content-Length` 赋予了
  特殊含义(未解析的 body 原样转发),那会让 runner 彻底失去分帧能力。
- `req.header(name)`、`req.query_param(name)`(百分号转义与 `+` 均已解码,
  `%E4%B8%AD%E6%96%87` 读回为中文)与 `req.uri()` — 处理器要用的读取侧,因为 CGI
  把查询字符串作为一整段未拆分的字符串交过来。

`parse_request` / `serialize_response` 是同一层面向"直接递交原始 HTTP 字节"的宿主
的对应物;WCGI 不使用它们。

名字或值包含换行的响应头会被两个序列化器整行丢弃 — 出错时宁可不发,也不给客户端
重新分帧的机会。

`String` 在该目标上是 UTF-16,所以每个跨越边界的值都显式经过 `@utf8` — 这就是
UTF-8 body 能按字节完璧归赵、`content-length` 按字节而不是码元计数的原因。

guest 对请求 body 设有 1 MiB 上限:`CONTENT_LENGTH` 在客户端发送任何东西之前就已
抵达环境,恶意取值无法靠读入放大内存,超限直接回答 413。

## 部署

先 `moon build --target wasm --release`,然后 `wasmer deploy` 读取 `app.yaml` 与
`wasmer.toml`。路由需要 runner 提供 `SCRIPT_NAME` 或 `PATH_INFO` 之一;如果部署后
所有路径都回答 400,先看这两个变量;如果所有路径回答同一个页面,则是 runner 固定了
`SCRIPT_NAME`(模板里是 `env = ["SCRIPT_NAME=..."]`),此时携带路由的是 `PATH_INFO`。

## 目录结构

- `http.mbt` — `Request`/`Response`、CGI 映射与原始 HTTP 编解码
- `app.mbt` — `App` 路由器:中间件链、方法 + 精确路径、405 与 404 保持区分、
  HEAD 回退、错误处理器
- `cmd/wcgi/main.mbt` — 建立在框架之上的示例 CGI 程序:四个 WASI 导入,每请求一实例
- `test/` — 面向公开 API 的黑盒测试
- `fixtures/` — 原始请求(宿主导入)与 `.expect` CGI 输出快照
- `dev/host.mjs` — 本地 WCGI 宿主,基于 Node 的 `WebAssembly` 运行时
- `dev/check.sh` — 上述各道关卡串起来

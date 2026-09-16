# whim-dsh

把 **DeepSeek Harness (dsh)** 连同运行时一起装进脚本所在的文件夹，并用 nginx 反向代理把它包装成一个「打开即用、不需要手动带 token」的本地 Web 服务。

- Linux / macOS：`whim-dsh.sh`
- Windows：`whim-dsh.bat`

全部数据都在脚本目录内，不写系统目录、不改全局配置、不留残留：想搬家就整个文件夹拷走，想卸载就整个文件夹删掉。

---

## 目录

- [三分钟上手](#三分钟上手)
- [命令](#命令)
- [目录结构](#目录结构)
- [特点](#特点)
- [对外域名 / 隧道访问](#对外域名--隧道访问)
- [反向代理做了什么](#反向代理做了什么)
- [排错](#排错)
- [附：两平台差异对照](#附两平台差异对照)

---

## 三分钟上手

Linux / macOS：

```bash
./whim-dsh.sh install      # 下载 Node.js + 安装 dsh + pnpm
./whim-dsh.sh install_rp   # 下载 nginx（反向代理）
./whim-dsh.sh init         # 安装插件市场 dshmarket（可选）
./whim-dsh.sh start        # 后台启动 dsh + nginx
```

Windows：

```bat
whim-dsh.bat install
whim-dsh.bat install_rp
whim-dsh.bat init
whim-dsh.bat start
```

启动完成后，浏览器打开 **http://127.0.0.1:8411/** 即为 dsh 界面，无需手动粘贴 token。

停止：

```bash
./whim-dsh.sh stop      # 或 whim-dsh.bat stop
```

---

## 命令

| 命令 | 作用 |
| --- | --- |
| `install` | 下载 Node.js 到 `runtime/node`，安装 `@deepseek-ai/dsh` 与 `pnpm` 到 `runtime/npm-global` |
| `init` | 安装插件市场 `dshmarket`（已装则跳过） |
| `install_rp` | 下载 nginx 二进制到 `runtime/nginx`（反向代理，供 `start` 使用） |
| `debug` | 前台启动 dsh（调试用，Ctrl+C 退出），并把运行地址写入 `bk_url.txt` |
| `start` | 后台启动 dsh + nginx 反向代理，PID 写入 `pid.txt` / `nginx-pid.txt` |
| `stop` | 停止后台的 dsh 与 nginx 反向代理 |
| `dsh` | 运行自定义 dsh 子命令；不带参数则交互式输入，如 `./whim-dsh.sh dsh plugin --profile web list` |

除 `start` 外都是「已存在就跳过」的幂等设计，重复执行安全。`install` / `install_rp` 会先比对已安装的版本与来源，不一致才重装。

---

## 目录结构

```
whim-dsh/
├── whim-dsh.sh / whim-dsh.bat   脚本本体
├── runtime/                     运行时（可整目录删除后重装）
│   ├── node/                    Node.js（node / npm / npx）
│   ├── npm-global/              全局 npm 包：dsh、pnpm
│   ├── npm-cache/               npm 缓存
│   ├── pnpm-home/               pnpm 全局目录
│   └── nginx/                   nginx 与运行所需的 logs/ temp/
├── dsh-data/                    dsh 数据，同时作为 HOME
│   ├── profiles/                各 profile 的插件清单
│   ├── AppData/                 （Windows）APPDATA / LOCALAPPDATA 重定向目标
│   └── …                        dsh 与插件的配置、凭据、缓存
├── nginx.conf                   start 时自动生成（内含 dsh token），勿手改
├── nginx.log / nginx-access.log 反向代理错误日志 / 访问日志
├── dsh.log / dsh.err.log        后台 dsh 的标准输出 / 标准错误
├── pid.txt / nginx-pid.txt      后台进程 PID
├── bk_url.txt                   本次运行的 dsh 地址（含 token）
└── public_hosts.txt             对外域名（首次指定后自动沿用）
```

运行时脚本会把 `HOME`（Windows 上还有 `USERPROFILE` / `APPDATA` / `LOCALAPPDATA`）以及 `DSH_HOME`、`NPM_CONFIG_*`、`PATH` 临时指向本文件夹，**只对脚本启动的进程生效**，不影响系统和其它终端窗口。

---

## 特点

### 1. 完全自包含

Node.js、npm 全局包、缓存、pnpm、nginx、dsh 数据全部落在脚本目录内，不依赖系统包管理器（Linux 用的是静态链接 musl 的 nginx 单文件二进制，任何发行版可直接运行）。

### 2. 默认国内镜像

Node.js 走 npmmirror，npm 走 `registry.npmmirror.com`，多源回退：

- Node.js：npmmirror → nodejs.org
- nginx (Windows)：华为云 → 搜狐 → nginx.org 官网
- nginx (Linux)：jirutka/nginx-binaries 官方站 → jsDelivr CDN → GitHub 加速镜像
- 下载方式（Windows）：`curl.exe` → `certutil -urlcache` → PowerShell `Invoke-WebRequest`（显式启用 TLS 1.2）三层兜底

Windows 端还内置 `NGINX_SHA256` 校验值（nginx.org 不提供 `.zip.sha256`）；Linux 端若取到官方 `.sha1` 则自动校验。目录里预先放好压缩包即可**离线安装**。

### 3. 反代自动补 token，直接打开就是 dsh

`start` 会从 dsh 日志里解析出含 token 的运行地址，把 token 写进生成的 `nginx.conf`。之后访问 `http://127.0.0.1:8411/` 即可，URL 里不需要 token；dsh 校验通过后下发会话 cookie，后续请求连 token 都不再需要。

### 4. 域名 / 隧道下也能用

改写了转发给 dsh 的 `Host` / `Origin`，并对前端 bundle 做响应体替换，绕开 dsh 与插件只认回环地址的围栏（详见下一节）。配合 frp 等隧道工具即可安全地从外部访问。

### 5. 进程管理靠 PID 文件，失败不假装成功

- 启动后校验：不只判断进程活着，还确认端口真的在监听（nginx 绑定失败时会重试数秒才退出，仅看存活会误报成功）
- 停止时按 PID 文件杀，并校验映像名是否匹配，不误杀复用 PID 的其它进程；PID 文件失效则只清理文件
- Windows 端额外按命令行兜底清理残留进程，`stop` 结束还会复查端口是否仍被占用
- 端口被脚本之外的进程占用时明确报出并跳过，而不是假装启动成功

### 6. 针对流式与上传的调优

`proxy_buffering off`（SSE / 流式输出即时到达）、`client_max_body_size 1g`（默认 1m 会让大文件上传报 413）、`proxy_read_timeout 3600s`、WebSocket `Upgrade`/`Connection` 头、首页 `Cache-Control: no-store`（避免缓存出空白页）。

---

## 对外域名 / 隧道访问

dsh 默认只信任本机 Host，域名访问会出现「页面空白 / 卡在加载插件」。把对外域名通过 `PUBLIC_HOSTS` 告诉脚本，`start` 会给 dsh 追加 `--trusted-host`。

Linux：

```bash
PUBLIC_HOSTS="dsh.example.com:8443" ./whim-dsh.sh start
```

Windows：

```bat
set PUBLIC_HOSTS=dsh.example.com:8443
whim-dsh.bat start
```

- 多个域名用空格分隔
- 首次指定后写入 `public_hosts.txt`，之后 `start` 自动沿用
- 值必须是**裸的 host 或 host:port**。dsh 校验很严，值里多一个空格就会报
  `trustedHosts entry " xxx " is not a bare host[:port] authority` 并拒绝启动。
  cmd 的 `set VAR=值 & 命令` 会把 `&` 前的空格一起写进变量，所以更稳的写法是先单独 `set`、再单独 `start`
- 脚本会自动做清洗：去首尾空白 / 制表符 / 引号、折叠多余空格、剥掉 `http(s)://` 前缀与路径，逐项校验后才传给 dsh；非法项丢弃并提示

---

## 反向代理做了什么

nginx 监听 `127.0.0.1:8411`，`server_name _`（匹配任意 Host，兼容隧道/上级反代），上游是 dsh 自身端口。

| 处理 | 原因 |
| --- | --- |
| `Host` / `Origin` 改写为回环地址 | dsh 靠 `--trusted-host` 放行域名，但不少第三方插件（如 `dsh-client-ui-skill-explorer`）自带更严格的「仅限 loopback」围栏，不改写会 400 / 403，而本机访问正常 |
| `/plugins/` 下 JS bundle 里 `isLoopback` 判定强制改为 true | dsh 前端用 `location.hostname` 判定「是否本机」，只认 `localhost` / `[::1]` / `127.0.0.0/8`；域名访问时该判定为假，设置被当作不可用，模型页会报「加载提供方目录失败: settings are unavailable in this browser」 |
| 根路径无 `token` 参数且无 `dsh-auth-` cookie 时补 token 转发 | 换取会话 cookie，之后不再需要 token |
| 上游返回 401 且判定为页面导航时 `303` 回带 token 地址 | 会话 cookie 过期后自动重新认证；API 请求仍保留 401，前端不会收到 HTML |
| 首页 `no-store` | 防止缓存出空白页 |
| `proxy_buffering off` | SSE / 流式输出即时到达 |

实现方式上两个平台的差异来自 nginx 构建本身：

- **Windows**：用 nginx.org 官方构建，已编译 `--with-http_sub_module`，直接 `sub_filter` 做内容替换
- **Linux**：用 jirutka 静态构建，**没有** `http_sub_module`，改用其自带的 njs 模块（`js_header_filter` 去 `Content-Length` + `js_body_filter` 按字节替换，`buffer_type=buffer` 保证二进制安全），改写脚本在 `start` 时生成到 `runtime/nginx/dsh_rewrite.js`；探测不到 njs 时自动降级为不做改写

`nginx.conf` 由脚本生成，**每次 `start` 都会重写**，请勿手改（里面的注释统一用英文，因为 Windows 端脚本是 GBK 编码，避免 nginx 按其它编码解读）。

---

## 排错

**dsh 报 `trustedHosts entry " xxx " is not a bare host[:port] authority`**
`PUBLIC_HOSTS` 里带空格等非法字符。先确认跑的是最新脚本（`start` 与用法提示都会打印脚本版本），再看 `start` 输出的 `dsh 参数: ...` 行里 `--trusted-host` 后面到底跟了什么。建议先 `set PUBLIC_HOSTS=...` 单独一行，再 `start`。

**域名访问报 `dsh web authentication required; reopen the URL printed by dsh web.`**
这是 dsh 的 401 提示，被 nginx 原样透传。多半是浏览器留着上一轮的失效 cookie：nginx 见到 `dsh-auth-` cookie 就不再补 token，dsh 判定失效后返回 401。清掉该站点的 cookie（或用无痕窗口）重新访问通常即可；新版本脚本已让导航请求在 401 时自动 `303` 回带 token 的地址自愈。

**域名下页面空白 / 卡在加载插件**
`PUBLIC_HOSTS` 没设置或不匹配。确认域名与端口完全一致（含端口号）。

**模型页报 `settings are unavailable in this browser`**
`/plugins/` 的前端改写没生效。Windows 上确认用的 nginx 是 nginx.org 官方构建（带 `http_sub_module`）；Linux 上 `install_rp` 时若提示 njs 不可用，说明该构建不含 njs 模块。

**`start` 提示端口 8411 已被占用**
脚本已跳过反向代理，dsh 本身仍可用（直接打开 `bk_url.txt` 里的地址）。查看占用者：

```bash
ss -ltnp | grep 8411          # Linux
netstat -ano | findstr 8411   # Windows
```

也可用 `RP_PORT` 环境变量换端口。

**想看日志**
`dsh.log` / `dsh.err.log`（dsh）、`nginx.log` / `nginx-access.log`（反向代理）。

---

## 附：两平台差异对照

| | Linux / macOS (`whim-dsh.sh`) | Windows (`whim-dsh.bat`) |
| --- | --- | --- |
| 文件编码 | UTF-8 | **GBK + `chcp 936`**，且必须 **CRLF** 换行 |
| Node.js | `node-<版本>-linux-x64.tar.xz` | `node-<版本>-win-x64.zip` |
| nginx 来源 | jirutka/nginx-binaries 静态二进制 | nginx.org 官方 Windows 构建 |
| 前端改写方式 | njs（`js_body_filter`） | `sub_filter`（自带 `http_sub_module`） |
| 后台启动 | `nohup … &` | `powershell Start-Process -WindowStyle Hidden` |
| 停止 | `kill`（先 TERM，超时后 KILL） | `taskkill /T /F` + 命令行兜底 |
| 编码副本 | — | `whim-dsh.bat.txt`（UTF-8，仅供前端预览，内容相同） |

> Windows 端修改 `whim-dsh.bat` 后需重新生成 UTF-8 预览副本：
> `iconv -f GBK -t UTF-8 whim-dsh.bat > whim-dsh.bat.txt`

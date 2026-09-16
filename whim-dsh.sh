#!/usr/bin/env bash
# whim-dsh.sh - DeepSeek Harness 安装与运行管理脚本
# 用法: ./whim-dsh.sh install | init | install_rp | debug | start | stop | dsh
# 所有数据均保存在脚本所在文件夹，不污染其他目录
#   runtime/    Node.js 运行时（node / npm-global / npm-cache / pnpm-home / nginx）
#   dsh-data/   dsh 数据，同时作为 HOME（含配置、凭据、pnpm store 等）
#   pid.txt        后台运行的 PID
#   dsh.log        后台运行日志
#   bk_url.txt     运行地址（Web UI URL，含 dsh 的 token）
#   nginx.conf     nginx 反向代理配置（start 时自动生成，内含 dsh 的 token）
#   nginx-pid.txt  反向代理的 PID
#   nginx.log      反向代理错误日志（访问日志见 nginx-access.log）
#   public_hosts.txt 对外域名（PUBLIC_HOSTS 首次指定后保存，后续自动沿用）
# start 会同时启动 dsh 与 nginx 反向代理，
# 之后打开 http://127.0.0.1:8411/ 即可直接进入 dsh（无需手动携带 token）
# 注：运行时会临时把 HOME 指向 dsh-data，仅对脚本启动的进程生效，
#     不影响系统和其他终端窗口
# 域名 / 隧道访问：设置 PUBLIC_HOSTS（空格分隔），start 会给 dsh 传 --trusted-host。
# 不设置时，dsh 只信任本机 Host，域名访问会出现“页面空白 / 卡在加载插件”。
#   例: PUBLIC_HOSTS="dsh.f.whim.win:8443" ./whim-dsh.sh start
# 注：反向代理会把转发给 dsh 的 Host / Origin 统一改写为回环地址。
#     dsh 本体依靠 --trusted-host 放行域名；但不少第三方插件（如
#     dsh-client-ui-skill-explorer）自带更严格的“仅限 loopback”围栏，
#     不改写时它们会拒绝域名请求（表现为 400 / 403，而本机访问正常）。
#     改写后这些插件看到的仍是回环地址，因此域名下也能正常工作。
# 注：dsh 前端还用 location.hostname 判定“是否本机”(isLoopback)，
#     只认 localhost / [::1] / 127.0.0.0/8；域名访问时该判定为假，
#     设置会被当作不可用，表现为模型页报
#     “加载提供方目录失败: settings are unavailable in this browser”。
#     因此 nginx 对 /plugins 下分发的前端 bundle 做响应体替换，
#     把该判定强制改为 true。
#     注：官方静态构建（jirutka/nginx-binaries）未编译 http_sub_module，
#         故改用其内置的 njs（ngx_http_js_module）实现改写；
#         改写脚本 start 时生成到 runtime/nginx/dsh_rewrite.js。
# npm 镜像源已配置为国内淘宝镜像

set -e

# 脚本所在目录 = 数据目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR"

# Node.js 版本
NODE_VERSION="v24.18.0"
NODE_DIST="node-${NODE_VERSION}-linux-x64"
NODE_TARBALL="${NODE_DIST}.tar.xz"
# 使用淘宝镜像加速 Node.js 下载
NODE_URL="https://npmmirror.com/mirrors/node/${NODE_VERSION}/${NODE_TARBALL}"

# nginx 版本与下载源
# 采用 jirutka/nginx-binaries 发布的 Linux 静态二进制（单文件、静态链接 musl，
# 不依赖系统库和包管理器，任何 Linux 发行版均可直接运行）。
# 该构建自带 njs（ngx_http_js_module），用于域名访问时的前端 bundle 改写。
# 下载源按顺序尝试：官方站点 -> jsDelivr CDN -> 国内 GitHub 加速镜像。
NGINX_VERSION="1.30.4"
# 二进制文件名形如 nginx-<版本>-<架构>-linux；留空则按 uname -m 自动探测
NGINX_ARCH="${NGINX_ARCH:-}"
# 下载来源标记（写入 runtime/nginx/.source，用于判断已装版本是否需要重装）
NGINX_SOURCE="jirutka/nginx-binaries"
NGINX_URL_BASES=(
    "https://jirutka.github.io/nginx-binaries"
    "https://cdn.jsdelivr.net/gh/jirutka/nginx-binaries@binaries"
    "https://ghfast.top/https://raw.githubusercontent.com/jirutka/nginx-binaries/binaries"
    "https://gh-proxy.com/https://raw.githubusercontent.com/jirutka/nginx-binaries/binaries"
)

# 本文件夹内的路径
# Node.js 运行时相关文件统一放在 runtime/ 内，便于整体移动、备份或删除
RUNTIME_DIR="$DATA_DIR/runtime"
NODE_DIR="$RUNTIME_DIR/node"
NPM_PREFIX="$RUNTIME_DIR/npm-global"
NPM_CACHE="$RUNTIME_DIR/npm-cache"
PNPM_HOME="$RUNTIME_DIR/pnpm-home"
# nginx 目录（反向代理 / 远程访问，由 install_rp 下载安装）
NGINX_DIR="$RUNTIME_DIR/nginx"
# njs 改写脚本（start 时自动生成，用 nginx 内置的 njs 模块改写前端 bundle）
NGINX_REWRITE_JS="$NGINX_DIR/dsh_rewrite.js"
# 下载来源标记文件：记录当前 runtime/nginx 的安装来源，用于判断是否需要重装
NGINX_MARKER="$NGINX_DIR/.source"

# dsh 自身数据保留在根目录
# 该目录同时用作 HOME，因此 dsh 及插件的用户级配置、凭据、缓存都会落在这里
DSH_DATA_DIR="$DATA_DIR/dsh-data"
# web profile 的 manifest，用于判断插件是否已安装
PROFILE_MANIFEST="$DSH_DATA_DIR/profiles/web/package.json"

# 后台运行相关文件
PID_FILE="$DATA_DIR/pid.txt"
LOG_FILE="$DATA_DIR/dsh.log"
# 运行地址（Web UI URL）保存文件
URL_FILE="$DATA_DIR/bk_url.txt"
# capture_url 解析出的运行地址（供 start 生成反向代理配置使用）
CAPTURED_URL=""

# nginx 反向代理相关文件（start 时自动生成 nginx.conf 并启动）
NGINX_CONFIG="$DATA_DIR/nginx.conf"
NGINX_LOG_FILE="$DATA_DIR/nginx.log"
NGINX_ACCESS_LOG_FILE="$DATA_DIR/nginx-access.log"
NGINX_PID_FILE="$DATA_DIR/nginx-pid.txt"
# nginx 运行时目录（pid 等，统一放在 runtime/nginx 内，避免写入 dsh-data）
NGINX_RUN_DIR="$NGINX_DIR/run"
# 反向代理监听地址：打开该地址即可进入 dsh（自动补 token）
RP_HOST="127.0.0.1"
RP_PORT="${RP_PORT:-8411}"
# 对外访问域名（空格分隔），通常配合隧道 / 上级反向代理使用。
# 用法: PUBLIC_HOSTS="dsh.f.whim.win:8443" ./whim-dsh.sh start
# 作用: 启动 dsh 时追加 --trusted-host，使其接受这些域名的 Host。
#       dsh 默认只信任本机 Host，非本机 Host 的 /api 请求会返回 403，
#       表现为页面能打开但卡在“加载插件…”或不显示内容。
# 注: 反向代理本身已匹配任意 Host，无需在这里重复配置。
# 首次指定后会保存到 public_hosts.txt，之后 start 自动沿用。
PUBLIC_HOSTS_FILE="$DATA_DIR/public_hosts.txt"
PUBLIC_HOSTS="${PUBLIC_HOSTS:-}"
if [ -z "$PUBLIC_HOSTS" ] && [ -f "$PUBLIC_HOSTS_FILE" ]; then
    PUBLIC_HOSTS="$(cat "$PUBLIC_HOSTS_FILE" 2>/dev/null || true)"
fi
if [ -n "$PUBLIC_HOSTS" ]; then
    printf '%s\n' "$PUBLIC_HOSTS" >"$PUBLIC_HOSTS_FILE"
fi

# npm 国内镜像源（淘宝 npmmirror）
NPM_REGISTRY="https://registry.npmmirror.com"

# 目录需先存在，否则 HOME 指向不存在的路径会导致子进程写配置失败
mkdir -p "$DSH_DATA_DIR"

# 导出环境变量，避免污染全局配置
export PATH="$NGINX_DIR/sbin:$PNPM_HOME:$NODE_DIR/bin:$NPM_PREFIX/bin:$PATH"
export NPM_CONFIG_PREFIX="$NPM_PREFIX"
export NPM_CONFIG_CACHE="$NPM_CACHE"
export NPM_CONFIG_REGISTRY="$NPM_REGISTRY"
export PNPM_HOME="$PNPM_HOME"
# 将 HOME 指向 dsh-data：dsh 及插件（含 pnpm store、各 SDK 配置）的用户级数据
# 都会写入这里，而不是真实的用户主目录
export HOME="$DSH_DATA_DIR"
# dsh 官方的主目录覆盖变量，优先级高于 ~/.dsh；
# 指向 dsh-data 使数据直接落在该目录下（profiles/ 等），无需再多一层 .dsh
export DSH_HOME="$DSH_DATA_DIR"
# 兼容保留（dsh 本身不读取该变量）
export DSH_DATA_DIR="$DSH_DATA_DIR"

# ============================================================
# 安装 Node.js（二进制包，不依赖系统包管理器）
# ============================================================
install_node() {
    echo "====> 安装 Node.js ${NODE_VERSION} 到本文件夹..."

    # 检查 Node.js 是否已安装且版本匹配
    if [ -x "$NODE_DIR/bin/node" ]; then
        local cur_ver
        cur_ver="$("$NODE_DIR/bin/node" -v 2>/dev/null || true)"
        if [ "$cur_ver" = "$NODE_VERSION" ]; then
            echo "Node.js 已存在于 $NODE_DIR，跳过安装。"
            echo "     当前版本: $cur_ver"
            return 0
        fi
        echo "Node.js 版本不匹配（当前 $cur_ver，需要 $NODE_VERSION），重新安装..."
        rm -rf "$NODE_DIR"
    fi

    echo "     使用镜像: $NODE_URL"
    local tmp_tar="$DATA_DIR/$NODE_TARBALL"

    echo "下载 Node.js 二进制包..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$tmp_tar" "$NODE_URL"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$tmp_tar" "$NODE_URL"
    else
        echo "错误: 需要 curl 或 wget 来下载 Node.js。" >&2
        exit 1
    fi

    echo "解压到 $NODE_DIR ..."
    mkdir -p "$NODE_DIR"
    tar -xf "$tmp_tar" -C "$NODE_DIR" --strip-components=1
    rm -f "$tmp_tar"

    echo "Node.js 安装完成: $(node -v)"
}

# ============================================================
# 安装 DeepSeek Harness 与 pnpm
# ============================================================
install_dsh() {
    echo "====> 安装 DeepSeek Harness..."
    echo "     npm 镜像源: $NPM_REGISTRY"

    mkdir -p "$RUNTIME_DIR"
    mkdir -p "$NPM_PREFIX"
    mkdir -p "$NPM_CACHE"
    mkdir -p "$DSH_DATA_DIR"
    mkdir -p "$PNPM_HOME"

    # 检查 dsh 是否已安装
    if [ -x "$NPM_PREFIX/bin/dsh" ]; then
        echo "DeepSeek Harness 已安装，跳过。"
        dsh --version 2>/dev/null || true
    else
        echo "安装 dsh 中..."
        npm install -g @deepseek-ai/dsh
        echo "DeepSeek Harness 安装完成。"
    fi

    # 检查 pnpm 是否已安装
    if [ -x "$NPM_PREFIX/bin/pnpm" ]; then
        echo "pnpm 已安装，跳过。"
    else
        echo "安装 pnpm 中..."
        npm install -g pnpm
        echo "pnpm 安装完成。"
    fi
}

# ============================================================
# 探测 CPU 架构（决定下载哪个二进制）
# nginx-binaries 使用 x86_64 / aarch64 / ppc64le 三种命名
# 可用 NGINX_ARCH 环境变量覆盖
# ============================================================
nginx_arch() {
    if [ -n "$NGINX_ARCH" ]; then
        printf '%s' "$NGINX_ARCH"
        return 0
    fi
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'x86_64'
            ;;
        aarch64|arm64)
            printf 'aarch64'
            ;;
        ppc64le)
            printf 'ppc64le'
            ;;
        *)
            # 未知架构时按最常见的 x86_64 尝试，失败后由调用方给出提示
            printf 'x86_64'
            ;;
    esac
}

# ============================================================
# 安装 nginx（反向代理 / 远程访问）
# 来源: jirutka/nginx-binaries 发布的 Linux 静态二进制（单文件，静态链接 musl，
#       不依赖系统库，任何 Linux 发行版均可运行；自带 njs 模块）。
#       下载源按 NGINX_URL_BASES 顺序依次尝试，任一成功即停止。
# 安装形态: runtime/nginx/sbin/nginx（单文件）+ runtime/nginx/dsh_rewrite.js
# ============================================================
install_nginx() {
    local arch
    arch="$(nginx_arch)"
    echo "====> 安装 nginx ${NGINX_VERSION} 到本文件夹（静态二进制，${arch}）..."

    # 检查 nginx 是否已安装且版本匹配，且来自同一来源
    # （旧版本脚本用的是 hzbd/nginx-acme-build 便携包，目录结构不同、
    #   且不含 njs 模块，必须直接重装，不能因为版本号相同就跳过）
    if [ -x "$NGINX_DIR/sbin/nginx" ]; then
        local cur_ver="" cur_src=""
        cur_ver="$("$NGINX_DIR/sbin/nginx" -v 2>&1 | sed -nE 's#.*nginx/([0-9.]+).*#\1#p')"
        cur_src="$(cat "$NGINX_MARKER" 2>/dev/null || true)"
        if [ "$cur_ver" = "$NGINX_VERSION" ] && [ "$cur_src" = "$NGINX_SOURCE" ]; then
            echo "nginx 已存在于 $NGINX_DIR，跳过安装。"
            echo "     当前版本: $cur_ver（来源: $cur_src）"
            return 0
        fi
        if [ "$cur_ver" = "$NGINX_VERSION" ]; then
            echo "nginx 来源不是 ${NGINX_SOURCE}（当前 ${cur_src:-未知}），重新安装..."
        else
            echo "nginx 版本不匹配（当前 ${cur_ver:-未知}，需要 $NGINX_VERSION），重新安装..."
        fi
        rm -rf "$NGINX_DIR"
    fi

    local filename="nginx-${NGINX_VERSION}-${arch}-linux"
    local tmp_bin="$DATA_DIR/$filename"
    local tmp_sha1="$DATA_DIR/${filename}.sha1.tmp"
    local base url url_used=""

    rm -f "$tmp_bin" "$tmp_sha1"
    for base in "${NGINX_URL_BASES[@]}"; do
        url="$base/$filename"
        echo "     尝试下载源: $url"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 20 -o "$tmp_bin" "$url" || continue
            curl -fsSL --connect-timeout 20 -o "$tmp_sha1" "$url.sha1" 2>/dev/null || rm -f "$tmp_sha1"
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 20 -O "$tmp_bin" "$url" || continue
            wget -q -T 20 -O "$tmp_sha1" "$url.sha1" 2>/dev/null || rm -f "$tmp_sha1"
        else
            echo "错误: 需要 curl 或 wget 来下载 nginx。" >&2
            exit 1
        fi
        [ -s "$tmp_bin" ] || continue
        url_used="$url"
        break
    done

    if [ ! -s "$tmp_bin" ]; then
        echo "错误: nginx 下载失败，请检查网络或手动下载 $filename" >&2
        echo "     官方下载地址: https://jirutka.github.io/nginx-binaries/" >&2
        return 1
    fi
    echo "     下载成功: $url_used"

    # 若拿到官方 .sha1 文件则校验，避免下载到损坏 / 被篡改的二进制
    if [ -s "$tmp_sha1" ]; then
        local want got
        want="$(awk '{print $1}' "$tmp_sha1" | head -n 1 | tr -d '\r')"
        if command -v sha1sum >/dev/null 2>&1; then
            got="$(sha1sum "$tmp_bin" | awk '{print $1}')"
        elif command -v shasum >/dev/null 2>&1; then
            got="$(shasum -a 1 "$tmp_bin" | awk '{print $1}')"
        fi
        if [ -n "$want" ] && [ -n "$got" ]; then
            if [ "$want" != "$got" ]; then
                echo "错误: nginx 二进制校验失败（期望 $want，实际 $got）" >&2
                rm -f "$tmp_bin" "$tmp_sha1"
                return 1
            fi
            echo "     SHA-1 校验通过: $got"
        fi
    else
        echo "     提示: 未取到 .sha1 校验文件，跳过校验。"
    fi

    echo "安装到 $NGINX_DIR/sbin/nginx ..."
    mkdir -p "$NGINX_DIR/sbin"
    mv -f "$tmp_bin" "$NGINX_DIR/sbin/nginx"
    chmod +x "$NGINX_DIR/sbin/nginx"
    rm -f "$tmp_sha1"

    if [ ! -x "$NGINX_DIR/sbin/nginx" ]; then
        echo "错误: 未找到 nginx 可执行文件，目录内容如下:" >&2
        ls -l "$NGINX_DIR" >&2 || true
        return 1
    fi
    # 静态二进制在少数内核 / 安全策略下可能无法执行，这里提前暴露问题
    if ! "$NGINX_DIR/sbin/nginx" -v >/dev/null 2>&1; then
        echo "错误: nginx 无法执行，请确认系统架构（当前 ${arch}）是否匹配。" >&2
        return 1
    fi

    # 补齐运行所需目录：日志、pid、以及各类临时目录。
    # 该静态构建的默认临时目录为相对 prefix 的 client_body_temp 等，
    # prefix 即 $NGINX_DIR，因此全部落在 runtime/nginx 内。
    mkdir -p "$NGINX_RUN_DIR" "$NGINX_DIR/logs" \
        "$NGINX_DIR/client_body_temp" "$NGINX_DIR/proxy_temp" \
        "$NGINX_DIR/fastcgi_temp" "$NGINX_DIR/scgi_temp" "$NGINX_DIR/uwsgi_temp"

    # 记录下载来源，供下次安装时判断是否需要替换
    printf '%s\n' "$NGINX_SOURCE" >"$NGINX_MARKER"

    echo "nginx 安装完成: $("$NGINX_DIR/sbin/nginx" -v 2>&1)"
    if ! nginx_has_njs_module; then
        echo "提示: 该 nginx 未包含 njs 模块，域名访问时的前端改写将被跳过。" >&2
    fi
}

# ============================================================
# nginx 是否包含 njs 模块（ngx_http_js_module）
# 用于前端 bundle 改写（替代官方静态构建缺失的 http_sub_module）
# 检测方式: nginx -V 输出里有 --add-module=...njs，或 js_import 指令可用
# 这里用一份最小配置做 -t 校验来探测；结果被 start 里的 write_nginx_conf 调用
# ============================================================
nginx_has_njs_module() {
    [ -x "$NGINX_DIR/sbin/nginx" ] || return 1
    local probe_dir probe_conf probe_js
    probe_dir="$NGINX_DIR/.njsprobe"
    probe_conf="$probe_dir/nginx.conf"
    probe_js="$probe_dir/probe.js"
    rm -rf "$probe_dir"
    mkdir -p "$probe_dir"
    printf 'function probe(r) { r.return(200); }\nexport default { probe };\n' >"$probe_js"
    cat >"$probe_conf" <<EOP
daemon off;
error_log /dev/null;
events { worker_connections 8; }
http {
    js_path ${probe_dir}/;
    js_import probe from probe.js;
}
EOP
    local rc=0
    "$NGINX_DIR/sbin/nginx" -p "$probe_dir" -c "$probe_conf" -t >/dev/null 2>&1 || rc=1
    rm -rf "$probe_dir"
    return $rc
}

# ============================================================
# 生成 njs 改写脚本（dsh_rewrite.js）
# 作用: 把 /plugins/ 下前端 bundle 中的 isLoopback 判定强制改为 true
#      （域名访问时 dsh 会用 location.hostname 判定“是否本机”）
# 说明: 官方静态构建未编译 http_sub_module，无法用 sub_filter，
#       故改用 nginx 自带的 njs：js_header_filter 去掉 Content-Length，
#       js_body_filter 按字节替换（buffer_type=buffer，二进制安全）。
# ============================================================
write_rewrite_js() {
    mkdir -p "$NGINX_DIR"
    cat >"$NGINX_REWRITE_JS" <<'EOF'
// 本文件由 whim-dsh.sh 的 start 自动生成，请勿手动修改
// 作用: 把 dsh 前端 bundle 里的 isLoopback 判定强制改为 true
// 说明: 按字节匹配（buffer_type=buffer），避免多字节字符被截断；
//       跨 chunk 的匹配通过尾部保留 PATTERN.length - 1 字节实现。
const PATTERN = Buffer.from(
    'isLoopback: transport?.ownsHost === true || pageLocation === void 0 || ' +
    'isLoopbackHostname(pageLocation.hostname),');
const REPLACEMENT = Buffer.from('isLoopback: true,');

let tail = Buffer.alloc(0);
let enabled = false;

function headers(r) {
    const ct = r.headersOut['Content-Type'] || '';
    enabled = ct.indexOf('javascript') !== -1 || ct.indexOf('ecmascript') !== -1;
    // 改写可能改变响应体长度，必须去掉 Content-Length 以启用分块传输
    if (enabled) { delete r.headersOut['Content-Length']; }
}

function filter(r, data, flags) {
    const last = flags.last === true;
    if (!enabled) { r.sendBuffer(data, flags); return; }

    const buf = Buffer.concat([tail, Buffer.from(data)]);
    const out = [];
    let pos = 0;
    for (;;) {
        const i = buf.indexOf(PATTERN, pos);
        if (i === -1) { break; }
        out.push(buf.slice(pos, i));
        out.push(REPLACEMENT);
        pos = i + PATTERN.length;
    }

    if (last) {
        out.push(buf.slice(pos));
        tail = Buffer.alloc(0);
        r.sendBuffer(Buffer.concat(out), { last: true });
        return;
    }

    // 保留可能被切断的尾部，等待下一块拼接后再判断
    const keep = PATTERN.length - 1;
    if (buf.length - keep > pos) {
        out.push(buf.slice(pos, buf.length - keep));
        tail = buf.slice(buf.length - keep);
    } else {
        tail = buf.slice(pos);
    }
    if (out.length > 0) { r.sendBuffer(Buffer.concat(out), { last: false }); }
}

export default { headers, filter };
EOF
}

# ============================================================
# 生成 nginx 反向代理配置（nginx.conf）
# 用法: write_nginx_conf <上游地址> <dsh token>
# 说明: 浏览器直接访问代理地址时 URL 里没有 token，这里把 token 补上；
#       dsh 校验通过后会下发会话 cookie，此后访问就不再需要 token
# ============================================================
write_nginx_conf() {
    local upstream="$1"
    local token="$2"

    mkdir -p "$NGINX_RUN_DIR"

    # 前端 bundle 改写：dsh 客户端用 location.hostname 判定 isLoopback，
    # 域名访问时为假，导致 settings 被判为不可用（见文件头说明）。
    # 这里用 nginx 自带的 njs 模块把该表达式替换为 true；
    # 官方静态构建未编译 http_sub_module，无法用 sub_filter。
    # njs 不可用时自动降级：不加改写，域名下功能可能受限但不影响代理。
    local njs_import_block=""
    local njs_rewrite_block=""
    if nginx_has_njs_module; then
        write_rewrite_js
        njs_import_block="    js_path ${NGINX_DIR}/;
    js_import dsh_rewrite from dsh_rewrite.js;"
        njs_rewrite_block="$(cat <<EOS
        # 前端 isLoopback 改写：只作用于插件 bundle 路由（/plugins/…）
        # 注: proxy_set_header 一旦在本层级出现就不再继承上层，
        #     故此处需重复 server 层的全部头，否则域名访问与 WebSocket 会失效
        location /plugins/ {
            proxy_pass http://dsh_upstream;
            # 关闭向上游请求压缩，否则响应体经过 gzip 后无法匹配
            proxy_set_header Accept-Encoding "";
            proxy_set_header Host ${upstream};
            proxy_set_header Origin http://${upstream};
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            # 去掉 Content-Length：改写后长度会变，需改用分块传输
            js_header_filter dsh_rewrite.headers;
            # buffer_type=buffer 按字节替换，避免多字节字符跨块被截断
            js_body_filter   dsh_rewrite.filter buffer_type=buffer;
        }
EOS
)"
    else
        echo "提示: 当前 nginx 未包含 njs 模块，跳过前端 isLoopback 改写。" >&2
    fi

    # 监听固定在本机 RP_HOST:RP_PORT，但 server_name 用 _ 以匹配任意 Host
    # （含隧道 / 域名转发过来的），避免域名请求落到默认站点。
    cat >"$NGINX_CONFIG" <<EOF
# 本文件由 whim-dsh.sh 的 start 自动生成，请勿手动修改
worker_processes  1;
daemon off;
pid ${NGINX_RUN_DIR}/nginx.pid;
error_log ${NGINX_LOG_FILE} warn;

events {
    worker_connections  1024;
}

http {
    default_type  application/octet-stream;
    access_log    ${NGINX_ACCESS_LOG_FILE} combined;
    # 放开请求体大小限制（默认仅 1m，会导致大文件上传报 413 Request Entity Too Large）；
    # 超出内存缓冲的部分会落到 client_body_temp（runtime/nginx/client_body_temp）
    client_max_body_size 1g;
${njs_import_block}

    # WebSocket 升级所需的 Connection 头
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        ''      close;
    }

    # dsh 下发的会话 cookie 名以 dsh-auth- 开头
    map \$http_cookie \$dsh_has_cookie {
        default       0;
        "~*dsh-auth-" 1;
    }

    # 根路径需要补 token：既没有 token，也没有 dsh 会话 cookie
    map "\$arg_token:\$dsh_has_cookie" \$dsh_need_token {
        default 0;
        ":0"    1;
    }

    upstream dsh_upstream {
        server ${upstream};
    }

    server {
        # 匹配任意 Host（含隧道 / 域名转发），但只监听本机
        listen      ${RP_HOST}:${RP_PORT};
        server_name _;

        # dsh 拒绝请求（401，如 cookie 失效）时交给 @dsh_reauth 处理
        proxy_intercept_errors on;
        error_page 401 = @dsh_reauth;

        proxy_http_version 1.1;
        # 把 Host / Origin 统一改写为回环地址（见文件头说明）：
        # 插件常自带 loopback-only 围栏，不改写时域名访问会被拒
        proxy_set_header Host ${upstream};
        proxy_set_header Origin http://${upstream};
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        # 关闭缓冲，保证 SSE / 流式响应即时下发
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        # 首页禁止缓存：早期配置曾对域名返回空体，浏览器会缓存该空白响应，
        # 导致重新打开仍显示空白。静态资源带内容哈希，不做限制。
        # 注: 这里用 if + rewrite ... break 补 token（而非 if + proxy_pass 带 URI），
        #     因为 nginx 不允许 if 内的 proxy_pass 带 URI 部分；
        #     rewrite ... break 同样不会触发内部跳转，故本 location 的
        #     add_header 仍然生效
        location = / {
            add_header Cache-Control "no-store, no-cache, must-revalidate" always;
            # 既没有 token 也没有会话 cookie 时，补上 token 转发给 dsh，
            # dsh 校验通过后会下发会话 cookie（因此不会反复重定向）
            if (\$dsh_need_token = 1) {
                rewrite ^ /?token=${token} break;
            }
            proxy_pass http://dsh_upstream;
        }

        # 其余请求（API、静态资源等）原样转发
        location / {
            proxy_pass http://dsh_upstream;
        }

${njs_rewrite_block}
        # 页面导航：cookie 失效（如 dsh 重启、cookie 过期）被 dsh 拒绝时，
        # 自动跳回带 token 的地址重新换取 cookie，用户无需手动处理；
        # 其余请求（API 等）保持原有 401 语义，避免前端拿到 HTML
        location @dsh_reauth {
            proxy_intercept_errors off;
            if (\$http_sec_fetch_mode = navigate) {
                return 303 /?token=${token};
            }
            proxy_pass http://dsh_upstream;
        }
    }
}
EOF
}

# ============================================================
# 反向代理端口是否已被占用
# best-effort：探测工具不可用（如受限沙箱）时按“未占用”处理，
# 以免误报阻断正常启动；真正的冲突由随后的启动结果校验兜底
# ============================================================
port_in_use() {
    local port="$1" out=""
    if command -v ss >/dev/null 2>&1; then
        out="$(ss -ltn 2>/dev/null | awk 'NR>1 {print $4}')"
    elif command -v netstat >/dev/null 2>&1; then
        out="$(netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}')"
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out" | grep -qE "[:.]${port}\$"
}

# ============================================================
# 启动 nginx 反向代理（start 时自动调用）
# 用法: start_nginx <上游地址> <dsh token>
# ============================================================
start_nginx() {
    local upstream="$1"
    local token="$2"

    if [ ! -x "$NGINX_DIR/sbin/nginx" ]; then
        echo "提示: 未安装 nginx，跳过反向代理。安装: $0 install_rp" >&2
        return 0
    fi

    if [ -z "$upstream" ] || [ -z "$token" ]; then
        echo "提示: 未能解析 dsh 的运行地址或 token，跳过反向代理。" >&2
        return 0
    fi

    # 先停掉上一次的 nginx，避免端口被占用
    if [ -f "$NGINX_PID_FILE" ]; then
        stop_by_pidfile "$NGINX_PID_FILE" "nginx" >/dev/null 2>&1 || true
    fi

    # 端口仍被占：说明有脚本之外的东西占用，明确报出而不是假装成功
    if port_in_use "$RP_PORT"; then
        echo "警告: 端口 ${RP_PORT} 已被其他进程占用，跳过反向代理。" >&2
        echo "     请先释放该端口（如: ss -ltnp | grep ${RP_PORT}）后重新 start。" >&2
        return 0
    fi

    write_nginx_conf "$upstream" "$token"

    # 先校验配置，避免带着错误配置后台运行
    local test_out=""
    if ! test_out="$("$NGINX_DIR/sbin/nginx" -p "$NGINX_DIR" -c "$NGINX_CONFIG" -t 2>&1)"; then
        printf '%s\n' "$test_out" | sed 's/^/     /' >&2
        echo "警告: nginx 配置校验失败，跳过反向代理。" >&2
        return 0
    fi

    rm -f "$NGINX_LOG_FILE" "$NGINX_ACCESS_LOG_FILE"
    mkdir -p "$NGINX_RUN_DIR"
    # 配置中写了 daemon off，因此用 nohup 常驻前台并记录 PID
    nohup "$NGINX_DIR/sbin/nginx" -p "$NGINX_DIR" -c "$NGINX_CONFIG" >"$NGINX_LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" >"$NGINX_PID_FILE"

    # 启动校验：单纯 kill -0 不够——绑定失败时 nginx 会重试几秒才退出，
    # 那时 kill -0 仍为真，会把失败误报成启动成功。
    # 因此同时确认端口已监听，最多等待约 5 秒。
    local i ok=0
    for i in 1 2 3 4 5; do
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        if port_in_use "$RP_PORT"; then
            ok=1
            break
        fi
    done

    if [ "$ok" != "1" ]; then
        echo "警告: nginx 启动失败或未监听端口 ${RP_PORT}，详情见 $NGINX_LOG_FILE" >&2
        printf '%s\n' "$(tail -n 3 "$NGINX_LOG_FILE" 2>/dev/null)" | sed 's/^/     /' >&2
        rm -f "$NGINX_PID_FILE"
        return 0
    fi

    echo "反向代理已启动，PID: $pid (已保存到 $NGINX_PID_FILE)"
    echo "访问地址: http://${RP_HOST}:${RP_PORT}/  （无需 token，直接打开 dsh）"
    echo "代理配置: $NGINX_CONFIG"
}

# ============================================================
# 初始化插件（dshmarket 插件市场）
# ============================================================
init_market() {
    echo "====> 初始化插件 (dshmarket)..."

    # 检查 dsh 是否已安装
    if [ ! -x "$NPM_PREFIX/bin/dsh" ]; then
        echo "错误: 未找到 dsh 可执行文件，请先运行: $0 install" >&2
        exit 1
    fi

    # 检查 pnpm 是否已安装
    if [ ! -x "$NPM_PREFIX/bin/pnpm" ]; then
        echo "错误: 未找到 pnpm，请先运行: $0 install" >&2
        exit 1
    fi

    install_plugin dshmarket "插件市场"

    echo ""
    echo "====> 插件初始化完成。"
    echo "     重启 dsh 后，可在 设置 → 插件市场 中管理插件。"
}

# ============================================================
# 安装单个插件
# 用法: install_plugin <插件名> <中文说明>
# 已记录在 web profile 的 package.json 依赖中则跳过
# ============================================================
install_plugin() {
    local plugin_name="$1"
    local plugin_desc="$2"

    if [ -f "$PROFILE_MANIFEST" ] && grep -q "\"$plugin_name\"" "$PROFILE_MANIFEST" 2>/dev/null; then
        echo "$plugin_desc ($plugin_name) 已安装，跳过。"
        return 0
    fi

    echo "安装 $plugin_desc ($plugin_name) ..."
    "$NPM_PREFIX/bin/dsh" plugin --profile web add "$plugin_name"
}

# ============================================================
# 从日志文件中解析运行地址，写入 bk_url.txt
# 用法: capture_url <日志文件> [最大等待秒数]
# ============================================================
capture_url() {
    local log="$1"
    local max_wait="${2:-15}"
    local i=0
    local url

    while [ "$i" -lt "$max_wait" ]; do
        if [ -f "$log" ]; then
            url="$(grep -oE 'https?://[^[:space:]]+' "$log" 2>/dev/null | head -n 1 || true)"
            if [ -n "$url" ]; then
                printf '%s\n' "$url" >"$URL_FILE"
                CAPTURED_URL="$url"
                echo "运行地址: $url"
                echo "          (已保存到 $URL_FILE)"
                return 0
            fi
        fi
        i=$((i + 1))
        sleep 1
    done

    echo "警告: 未能从 $log 中解析出运行地址，请手动查看该文件。" >&2
    return 1
}

# ============================================================
# 前台运行 DeepSeek Harness（调试用，Ctrl+C 退出）
# ============================================================
debug_dsh() {
    echo "====> 前台启动 DeepSeek Harness Web UI（调试模式）..."

    if [ ! -x "$NPM_PREFIX/bin/dsh" ]; then
        echo "未找到 dsh 可执行文件，请先运行: $0 install" >&2
        exit 1
    fi

    # 清空上一次的地址记录
    rm -f "$URL_FILE"

    # 前台运行，同时捕获输出中的运行地址并写入 bk_url.txt
    "$NPM_PREFIX/bin/dsh" web --no-open  2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line"
        if [ ! -s "$URL_FILE" ] && [[ "$line" =~ (https?://[^[:space:]]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}" >"$URL_FILE"
            echo "运行地址: ${BASH_REMATCH[1]}"
            echo "          (已保存到 $URL_FILE)"
        fi
    done

    # 透传 dsh 的退出码（Ctrl+C / 异常退出）
    return "${PIPESTATUS[0]}"
}

# ============================================================
# 运行自定义 dsh 命令
# 用法: ./whim-dsh.sh dsh <命令...>
#       ./whim-dsh.sh dsh              交互式输入命令
# 示例: ./whim-dsh.sh dsh web --no-open
#       ./whim-dsh.sh dsh plugin --profile web list
# ============================================================
dsh_cmd() {
    echo "====> 运行自定义 dsh 命令..."

    if [ ! -x "$NPM_PREFIX/bin/dsh" ]; then
        echo "错误: 未找到 dsh 可执行文件，请先运行: $0 install" >&2
        exit 1
    fi

    local -a args=("$@")

    # 未提供参数时，交互式读取用户输入的命令
    if [ "${#args[@]}" -eq 0 ]; then
        local input=""
        printf '请输入 dsh 命令（不含 dsh 本身，例如 web --no-open）: '
        IFS= read -r input || true
        if [ -z "$input" ]; then
            echo "未输入命令，已取消。"
            return 0
        fi
        read -r -a args <<<"$input" || true
    fi

    "$NPM_PREFIX/bin/dsh" "${args[@]}" || return $?
}

# ============================================================
# 后台运行 DeepSeek Harness + nginx 反向代理（PID 保存到 pid.txt）
# ============================================================
start_dsh() {
    echo "====> 后台启动 DeepSeek Harness Web UI..."

    if [ ! -x "$NPM_PREFIX/bin/dsh" ]; then
        echo "未找到 dsh 可执行文件，请先运行: $0 install" >&2
        exit 1
    fi

    # 检查是否已有实例在运行
    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            echo "dsh 已在后台运行 (PID: $old_pid)，请先运行: $0 stop" >&2
            exit 1
        fi
        # 清理无效的 pid 文件
        rm -f "$PID_FILE"
    fi

    # nohup 后台运行，输出重定向到日志文件
    # PUBLIC_HOSTS 作为 --trusted-host 传给 dsh，使 dsh 接受这些域名的 Host
    rm -f "$URL_FILE"
    local -a trusted_args=()
    local h
    for h in $PUBLIC_HOSTS; do
        trusted_args+=(--trusted-host "$h")
    done
    nohup "$NPM_PREFIX/bin/dsh" web --no-open "${trusted_args[@]}" >"$LOG_FILE" 2>&1 &
    local pid=$!

    echo "$pid" >"$PID_FILE"

    # 等待片刻确认进程存活
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        echo "已在后台启动，PID: $pid (已保存到 $PID_FILE)"
        echo "日志文件: $LOG_FILE"
        capture_url "$LOG_FILE" 15 || true

        # 启动 nginx 反向代理：把 dsh 的 token 写进代理配置，
        # 之后打开代理地址即可直接进入 dsh，无需再手动携带 token
        local upstream rp_token
        upstream="$(printf '%s' "$CAPTURED_URL" | sed -E 's#^https?://##; s#/.*$##')"
        rp_token="$(printf '%s' "$CAPTURED_URL" | sed -nE 's#.*[?&]token=([^&]+).*#\1#p')"
        start_nginx "$upstream" "$rp_token"

        echo "停止服务: $0 stop"
    else
        echo "错误: 后台启动失败，请查看日志: $LOG_FILE" >&2
        rm -f "$PID_FILE"
        exit 1
    fi
}

# ============================================================
# 根据 pid 文件停止后台进程，并清理该文件
# 用法: stop_by_pidfile <pid 文件> <进程显示名>
# ============================================================
stop_by_pidfile() {
    local pid_file="$1"
    local name="$2"

    if [ ! -f "$pid_file" ]; then
        echo "未找到 $pid_file，$name 可能未在后台运行。"
        return 0
    fi

    local pid
    pid="$(cat "$pid_file" 2>/dev/null || true)"

    if [ -z "$pid" ]; then
        echo "$pid_file 内容为空，清理该文件。"
        rm -f "$pid_file"
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "PID $pid 对应的进程不存在，清理 $pid_file。"
        rm -f "$pid_file"
        return 0
    fi

    echo "正在停止 $name (PID: $pid)..."
    kill "$pid" 2>/dev/null || true

    # 最多等待 10 秒优雅退出
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if kill -0 "$pid" 2>/dev/null; then
        echo "进程未响应，强制结束..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    rm -f "$pid_file"
    echo "已停止 $name。"
}

# ============================================================
# 停止 nginx 反向代理（根据 nginx-pid.txt）
# ============================================================
stop_nginx() {
    echo "====> 停止 nginx 反向代理..."
    stop_by_pidfile "$NGINX_PID_FILE" "nginx"
}

# ============================================================
# 停止后台运行的 DeepSeek Harness（根据 pid.txt）
# ============================================================
stop_dsh() {
    echo "====> 停止 DeepSeek Harness..."
    stop_by_pidfile "$PID_FILE" "dsh"
}

# ============================================================
# 主入口
# ============================================================
case "${1:-}" in
    install)
        install_node
        install_dsh
        echo ""
        echo "====> 安装完成。所有数据位于: $DATA_DIR"
        echo "     Node.js 运行时: $RUNTIME_DIR"
        echo "运行: $0 init     # 安装插件市场 (dshmarket)"
        echo "运行: $0 install_rp  # 下载 nginx 静态二进制（反向代理，供 start 使用）"
        echo "运行: $0 debug    # 前台启动服务（调试用）"
        echo "运行: $0 start    # 后台启动服务 + nginx 反向代理（PID 保存到 pid.txt）"
        echo "运行: $0 stop     # 停止后台服务（dsh 与反向代理）"
        echo "运行: $0 dsh      # 运行自定义 dsh 命令（不带参数则交互式输入）"
        ;;
    init)
        init_market
        ;;
    install_rp)
        install_nginx
        ;;
    debug)
        debug_dsh
        ;;
    start)
        start_dsh
        ;;
    dsh)
        shift
        dsh_cmd "$@"
        ;;
    stop)
        stop_dsh
        stop_nginx
        ;;
    *)
        echo "用法: $0 {install|init|install_rp|debug|start|stop|dsh}"
        echo "  install  下载 Node.js 并安装 DeepSeek Harness 到本文件夹"
        echo "  init     安装插件市场 (dshmarket)"
        echo "  install_rp  下载 nginx 静态二进制到 runtime/nginx（反向代理）"
        echo "  debug    前台启动 DeepSeek Harness Web UI（调试用，Ctrl+C 退出）"
        echo "  start    后台启动 DeepSeek Harness，并启动 nginx 反向代理；"
        echo "           之后打开 http://${RP_HOST}:${RP_PORT}/ 即可直接进入 dsh，无需 token"
        echo "           域名/隧道访问: PUBLIC_HOSTS=\"dsh.f.whim.win:8443\" $0 start"
        echo "  stop     停止后台运行的 dsh 与 nginx 反向代理"
        echo "  dsh      运行自定义 dsh 命令（不带参数则交互式输入）"
        exit 1
        ;;
esac

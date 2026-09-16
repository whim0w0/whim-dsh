@echo off
REM 切换控制台代码页为 GBK(936)，确保本文件中的中文提示正常显示
chcp 936 >nul
setlocal EnableDelayedExpansion
REM 脚本版本：每次改动都会变。start/usage 会打印它，
REM 用来确认你跑的确实是当前这份文件（复制漏了会立刻看出来）。
set "BAT_VERSION=2026-09-16.5"

REM ============================================================
REM whim-dsh.bat - DeepSeek Harness 安装与运行管理脚本 (Windows)
REM 用法: whim-dsh.bat install ^| init ^| install_rp ^| debug ^| start ^| stop ^| dsh
REM 所有数据均保存在脚本所在文件夹，不污染其他目录
REM   runtime\    Node.js 运行时（node / npm-global / npm-cache / pnpm-home / nginx）
REM   dsh-data\   dsh 数据，同时作为 HOME（含配置、凭据、pnpm store 等）
REM   pid.txt         后台运行的 PID
REM   dsh.log         后台运行日志（标准输出）
REM   dsh.err.log     后台运行日志（标准错误）
REM   bk_url.txt      运行地址（Web UI URL，含 dsh 的 token）
REM   nginx.conf      nginx 反向代理配置（start 时自动生成，内含 dsh 的 token）
REM   nginx-pid.txt   反向代理的 PID
REM   nginx.log       反向代理错误日志（访问日志见 nginx-access.log）
REM   public_hosts.txt 对外域名（PUBLIC_HOSTS 首次指定后保存，后续自动沿用）
REM start 会同时启动 dsh 与 nginx 反向代理，
REM 之后打开 http://127.0.0.1:8411/ 即可直接进入 dsh（无需手动携带 token）
REM 注：运行时会临时把 HOME / USERPROFILE 指向 dsh-data，仅对脚本启动的进程生效，
REM     不影响系统和其他终端窗口
REM 域名 / 隧道访问：设置 PUBLIC_HOSTS（空格分隔），start 会给 dsh 传 --trusted-host。
REM 不设置时，dsh 只信任本机 Host，域名访问会出现“页面空白 / 卡在加载插件”。
REM   例: set PUBLIC_HOSTS=dsh.f.whim.win:8443 & whim-dsh.bat start
REM 注意: 值必须是裸的 host 或 host:port，且不能有多余空格。
REM       cmd 的 set 会连 "&" 前的空格一起写进变量，而 dsh 校验很严，值里带空格会报
REM       trustedHosts entry " xxx " is not a bare host[:port] authority 并拒绝启动；
REM       脚本会自动去掉首尾空格 / 制表符 / 引号兜底。
REM       更稳的写法是先单独 set，再单独 start:
REM         set PUBLIC_HOSTS=dsh.f.whim.win:8443
REM         whim-dsh.bat start
REM 注：反向代理会把转发给 dsh 的 Host / Origin 统一改写为回环地址。
REM     dsh 本体依靠 --trusted-host 放行域名；但不少第三方插件（如
REM     dsh-client-ui-skill-explorer）自带更严格的“仅限 loopback”围栏，
REM     不改写时它们会拒绝域名请求（表现为 400 / 403，而本机访问正常）。
REM     改写后这些插件看到的仍是回环地址，因此域名下也能正常工作。
REM 注：dsh 前端还用 location.hostname 判定“是否本机”(isLoopback)，
REM     只认 localhost / [::1] / 127.0.0.0/8；域名访问时该判定为假，
REM     设置会被当作不可用，表现为模型页报
REM     “加载提供方目录失败: settings are unavailable in this browser”。
REM     因此 nginx 对 /plugins 下分发的前端 bundle 做响应体替换，把该判定强制改为 true。
REM     注：官网 Windows 构建已编译 http_sub_module（Linux 静态构建没有该模块），
REM         故这里直接用 sub_filter，无需 njs。
REM 注：nginx 配置由本脚本生成，其中注释一律写英文——
REM     本文件是 GBK 编码，配置里写中文可能被 nginx 按其它编码解读。
REM nginx 二进制按顺序从多个源下载（华为云 -> 搜狐 -> 官网 nginx.org），
REM 全部失败时提示手动下载；下载方式依次为 curl.exe -> certutil -> PowerShell。
REM npm 镜像源已配置为国内淘宝镜像。
REM ============================================================

REM 脚本所在目录 = 数据目录
set "DATA_DIR=%~dp0"
if "%DATA_DIR:~-1%"=="\" set "DATA_DIR=%DATA_DIR:~0,-1%"

REM Node.js 版本（Windows x64 构建）
set "NODE_VERSION=v24.18.0"
set "NODE_ZIP=node-%NODE_VERSION%-win-x64.zip"
set "NODE_URL1=https://npmmirror.com/mirrors/node/%NODE_VERSION%/%NODE_ZIP%"
set "NODE_URL2=https://nodejs.org/dist/%NODE_VERSION%/%NODE_ZIP%"

REM nginx 版本与下载源（按顺序依次尝试，任一成功即用）
REM 采用官网（nginx.org）发布的 Windows 构建：单文件 nginx.exe，已编译 http_sub_module，
REM 用于域名访问时的前端 bundle 改写。
REM 国内环境官网常连不上，故镜像放在前面；各源内容与官网一致，可共用同一份 .sha256 校验。
set "NGINX_VERSION=1.30.4"
set "NGINX_ZIP=nginx-%NGINX_VERSION%.zip"
set "NGINX_URL1=https://mirrors.huaweicloud.com/nginx/%NGINX_ZIP%"
set "NGINX_URL2=https://mirrors.sohu.com/nginx/%NGINX_ZIP%"
set "NGINX_URL3=https://nginx.org/download/%NGINX_ZIP%"
REM 校验值（官网 nginx.org 未提供 .sha256 文件，这里是官方发布值；换版本时需同步更新）
set "NGINX_SHA256=159294214d403f34f0bb4ae598801ab1f6a0d8c8da707f8f08748e294a222a01"
set "NGINX_SHA_URL1=https://mirrors.huaweicloud.com/nginx/%NGINX_ZIP%.sha256"
REM 下载来源标记（写入 runtime\nginx\.source，用于判断已装版本是否需要重装）
set "NGINX_SOURCE=nginx.org/windows"

REM 本文件夹内的路径
REM Node.js 运行时相关文件统一放在 runtime\ 内，便于整体移动、备份或删除
set "RUNTIME_DIR=%DATA_DIR%\runtime"
set "NODE_DIR=%RUNTIME_DIR%\node"
set "NPM_PREFIX=%RUNTIME_DIR%\npm-global"
set "NPM_CACHE=%RUNTIME_DIR%\npm-cache"
set "PNPM_HOME=%RUNTIME_DIR%\pnpm-home"
REM nginx 目录（反向代理 / 远程访问，由 install_rp 下载安装）
set "NGINX_DIR=%RUNTIME_DIR%\nginx"
set "NGINX_EXE=%NGINX_DIR%\nginx.exe"
set "NGINX_MARKER=%NGINX_DIR%\.source"

REM dsh 自身数据保留在根目录
REM 该目录同时用作 HOME，因此 dsh 及插件的用户级配置、凭据、缓存都会落在这里
set "DSH_DATA_DIR=%DATA_DIR%\dsh-data"
REM web profile 的 manifest，用于判断插件是否已安装
set "PROFILE_MANIFEST=%DSH_DATA_DIR%\profiles\web\package.json"

REM 后台运行相关文件
set "PID_FILE=%DATA_DIR%\pid.txt"
set "LOG_FILE=%DATA_DIR%\dsh.log"
set "ERR_LOG_FILE=%DATA_DIR%\dsh.err.log"
REM 运行地址（Web UI URL）保存文件
set "URL_FILE=%DATA_DIR%\bk_url.txt"

REM nginx 反向代理相关文件（start 时自动生成 nginx.conf 并启动）
set "NGINX_CONFIG=%DATA_DIR%\nginx.conf"
set "NGINX_LOG_FILE=%DATA_DIR%\nginx.log"
set "NGINX_ACCESS_LOG_FILE=%DATA_DIR%\nginx-access.log"
set "NGINX_PID_FILE=%DATA_DIR%\nginx-pid.txt"
REM 反向代理监听地址：打开该地址即可进入 dsh（自动补 token）
set "RP_HOST=127.0.0.1"
if not defined RP_PORT set "RP_PORT=8411"

REM 对外访问域名（空格分隔），通常配合隧道 / 上级反向代理使用。
REM 用法: set PUBLIC_HOSTS=dsh.f.whim.win:8443 & whim-dsh.bat start
REM 作用: 启动 dsh 时追加 --trusted-host，使其接受这些域名的 Host。
REM       dsh 默认只信任本机 Host，非本机 Host 的 /api 请求会返回 403，
REM       表现为页面能打开但卡在“加载插件…”或不显示内容。
REM 注: 反向代理本身已匹配任意 Host，无需在这里重复配置。
REM 首次指定后会保存到 public_hosts.txt，之后 start 自动沿用。
REM 注: 若文件内容变化但又不想重启，改完直接重新运行 start 即可（脚本会重读并回写规整值）。
REM       排错: 若 dsh 报 trustedHosts entry " xxx " is not a bare host[:port] authority，
REM       先确认跑的是最新脚本（start/usage 都会打印脚本版本），旧脚本不清理空格；
REM       再看 start 打印的 "dsh 参数:" 行，--trusted-host 后面到底跟了什么。
set "PUBLIC_HOSTS_FILE=%DATA_DIR%\public_hosts.txt"
if not defined PUBLIC_HOSTS (
    if exist "%PUBLIC_HOSTS_FILE%" set /p PUBLIC_HOSTS=<"%PUBLIC_HOSTS_FILE%"
)
REM 关键: set VAR=值 & 命令 这种写法会把 & 前的空格也塞进变量
REM （cmd 的 set 会一直吃到 & 为止），而 dsh 对 --trusted-host 是严格校验的：
REM 值里只要多一个空格，就会报
REM   trustedHosts entry " xxx " is not a bare host[:port] authority
REM 并直接拒绝启动。所以这里统一去掉首尾空格、制表符和引号。
call :normalize_hosts
if defined PUBLIC_HOSTS call :save_public_hosts

REM npm 国内镜像源（淘宝 npmmirror）
set "NPM_REGISTRY=https://registry.npmmirror.com"

REM 设置临时环境变量（仅当前窗口及其子进程有效）
set "PATH=%NGINX_DIR%;%NODE_DIR%;%NPM_PREFIX%;%PNPM_HOME%;%PATH%"
set "NPM_CONFIG_PREFIX=%NPM_PREFIX%"
set "NPM_CONFIG_CACHE=%NPM_CACHE%"
set "NPM_CONFIG_REGISTRY=%NPM_REGISTRY%"
set "PNPM_HOME=%PNPM_HOME%"

REM 目录需先存在，否则 HOME 指向不存在的路径会导致子进程写配置失败
for %%d in ("%DSH_DATA_DIR%" "%RUNTIME_DIR%" "%NPM_PREFIX%" "%NPM_CACHE%" "%PNPM_HOME%"
            "%DSH_DATA_DIR%\AppData\Roaming" "%DSH_DATA_DIR%\AppData\Local") do (
    if not exist "%%~d" mkdir "%%~d"
)

REM 将 HOME / USERPROFILE / APPDATA 指向 dsh-data：dsh 及插件（含 pnpm store、
REM 各 SDK 配置）的用户级数据都会写入这里，而不是真实的用户主目录
set "HOME=%DSH_DATA_DIR%"
set "USERPROFILE=%DSH_DATA_DIR%"
set "APPDATA=%DSH_DATA_DIR%\AppData\Roaming"
set "LOCALAPPDATA=%DSH_DATA_DIR%\AppData\Local"
REM dsh 官方的主目录覆盖变量，优先级高于 ~\.dsh；
REM 指向 dsh-data 使数据直接落在该目录下（profiles\ 等），无需再多一层 .dsh
set "DSH_HOME=%DSH_DATA_DIR%"
REM 兼容保留（dsh 本身不读取该变量）
set "DSH_DATA_DIR_ENV=%DSH_DATA_DIR%"

REM nginx 用正斜杠路径（配置与命令行参数统一）
set "NGINX_PREFIX=%NGINX_DIR:\=/%/"
set "NGINX_CONF_FWD=%NGINX_CONFIG:\=/%"
set "NGINX_LOG_FWD=%NGINX_LOG_FILE:\=/%"
set "NGINX_ACC_FWD=%NGINX_ACCESS_LOG_FILE:\=/%"

REM dsh 入口：直接跑 npm 全局包里的 bin.js，避开 .cmd 的引号问题
set "NODE_EXE=%NODE_DIR%\node.exe"
set "DSH_BIN=%NPM_PREFIX%\node_modules\@deepseek-ai\dsh\lib\bin.js"
set "DSH_CMD=%NPM_PREFIX%\dsh.cmd"
set "PNPM_CMD=%NPM_PREFIX%\pnpm.cmd"

REM nginx 需要替换的前端片段（dsh 用 location.hostname 判定 isLoopback）
set "SUB_FILTER_MATCH=isLoopback: transport?.ownsHost === true || pageLocation === void 0 || isLoopbackHostname(pageLocation.hostname),"

REM 参数路由
if "%~1"=="install" goto install
if "%~1"=="init" goto init
if "%~1"=="install_rp" goto install_rp
if "%~1"=="debug" goto debug
if "%~1"=="start" goto start
if "%~1"=="stop" goto stop
if "%~1"=="dsh" goto dsh
if "%~1"=="" goto usage
goto usage

REM ============================================================
REM 规整 PUBLIC_HOSTS：去掉首尾空白与引号
REM 用法: call :normalize_hosts   （原地修改 PUBLIC_HOSTS）
REM 需要它是因为: set PUBLIC_HOSTS=dsh.f.whim.win:8443 & whim-dsh.bat start
REM 会把 & 前那个空格一并写进变量，dsh 侧校验不通过会直接启动失败。
REM ============================================================
:normalize_hosts
if not defined PUBLIC_HOSTS goto :eof
set "PH=!PUBLIC_HOSTS!"
:nh_lead
if not defined PH goto :eof
if "!PH:~0,1!"==" " (
    set "PH=!PH:~1!"
    goto nh_lead
)
if "!PH:~0,1!"=="	" (
    set "PH=!PH:~1!"
    goto nh_lead
)
:nh_trail
if not defined PH goto :eof
if "!PH:~-1!"==" " (
    set "PH=!PH:~0,-1!"
    goto nh_trail
)
if "!PH:~-1!"=="	" (
    set "PH=!PH:~0,-1!"
    goto nh_trail
)
REM 去掉引号（有人习惯写成 set PUBLIC_HOSTS="a:b"）
REM 注: 这一行不能用 set "PH=..." 包引号，否则内层引号会提前结束字符串
set PH=!PH:"=!
REM 多个域名之间只允许单个空格分隔
:nh_double
set "PH_TMP=!PH:  = !"
if not "!PH_TMP!"=="!PH!" (
    set "PH=!PH_TMP!"
    goto nh_double
)
REM 逐项校验：必须是裸 host 或 host:port（不含空格 / 引号 / 路径 / 用户信息）。
REM dsh 侧是硬校验，写错会让它在启动时直接抛
REM   trustedHosts entry " xxx " is not a bare host[:port] authority
REM 并拒绝加载插件树，这里先过滤掉非法项，避免整个服务起不来。
set "PH_OK="
set "PH_BAD="
for %%h in (!PH!) do (
    set "IH=%%h"
    REM 允许直接粘贴完整 URL：去掉协议头，再截掉路径部分
    set "IH=!IH:https://=!"
    set "IH=!IH:http://=!"
    for /f "tokens=1 delims=/" %%p in ("!IH!") do set "IH=%%p"
    REM 只接受裸 host / host:port / [IPv6]（与 dsh 的校验对齐）
    echo(!IH!| findstr /R "^[0-9A-Za-z][0-9A-Za-z.-]*$" >nul
    if errorlevel 1 (
        echo(!IH!| findstr /R "^[0-9A-Za-z][0-9A-Za-z.-]*:[0-9][0-9]*$" >nul
        if errorlevel 1 (
            echo(!IH!| findstr /R "^\[[0-9A-Fa-f:][0-9A-Fa-f:]*\]$" >nul
            if errorlevel 1 (
                set "PH_BAD=!PH_BAD! %%h"
            ) else (
                set "PH_OK=!PH_OK! !IH!"
            )
        ) else (
            set "PH_OK=!PH_OK! !IH!"
        )
    ) else (
        set "PH_OK=!PH_OK! !IH!"
    )
)
if defined PH_BAD echo 警告: 以下对外域名不是合法的 host 或 host:port，已忽略:!PH_BAD!
if defined PH_OK set "PH_OK=!PH_OK:~1!"
set "PUBLIC_HOSTS=!PH_OK!"
goto :eof

REM ============================================================
REM 保存 PUBLIC_HOSTS 到文件（供后续 start 自动沿用）
REM ============================================================
:save_public_hosts
>"%PUBLIC_HOSTS_FILE%" echo !PUBLIC_HOSTS!
goto :eof

REM ============================================================
REM 下载（多源回退）
REM 用法: call :download <输出文件> <URL1> [URL2] [URL3] [URL4]
REM 依次尝试各下载源，任一成功即返回；全部失败返回 errorlevel 1
REM 每个源先用系统自带 curl.exe，失败退回 powershell 的 Invoke-WebRequest
REM 若公司网络需代理：先 set HTTPS_PROXY=http://主机:端口 再运行本脚本
REM ============================================================
:download
set "DL_OUT=%~1"
set "DL_U1=%~2"
set "DL_U2=%~3"
set "DL_U3=%~4"
set "DL_U4=%~5"
if exist "%DL_OUT%" del "%DL_OUT%" >nul 2>&1
if defined DL_U1 call :download_one "!DL_U1!" "%DL_OUT%"
if exist "%DL_OUT%" exit /b 0
if defined DL_U2 call :download_one "!DL_U2!" "%DL_OUT%"
if exist "%DL_OUT%" exit /b 0
if defined DL_U3 call :download_one "!DL_U3!" "%DL_OUT%"
if exist "%DL_OUT%" exit /b 0
if defined DL_U4 call :download_one "!DL_U4!" "%DL_OUT%"
if exist "%DL_OUT%" exit /b 0
exit /b 1

REM 下载单个源：curl.exe -> certutil -> PowerShell 三种方式依次尝试
REM 三种都做不到时才判定失败（老系统没有 curl.exe，或 PowerShell 被策略限制）
:download_one
if exist "%~2" del "%~2" >nul 2>&1
echo      尝试下载源: %~1
set "DL_ERR="

REM 方式一: curl.exe（Win10 1803 起自带，自动读取 HTTPS_PROXY / HTTP_PROXY 环境变量）
where curl >nul 2>&1
if not errorlevel 1 (
    curl -fsSL -k --connect-timeout 20 -m 900 -o "%~2" "%~1"
    if exist "%~2" for %%s in ("%~2") do if %%~zs GEQ 1024 exit /b 0
    if exist "%~2" del "%~2" >nul 2>&1
    set "DL_ERR=curl 失败"
)

REM 方式二: certutil（各版本 Windows 均自带，可绕过部分代理 / TLS 问题）
certutil -urlcache -split -f "%~1" "%~2" >nul 2>&1
if exist "%~2" (
    for %%s in ("%~2") do if %%~zs GEQ 1024 exit /b 0
    del "%~2" >nul 2>&1
)
if not defined DL_ERR set "DL_ERR=certutil 失败"

REM 方式三: PowerShell（显式启用 TLS 1.2，PS 5.1 默认可能不含，会直接握手失败）
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; try { $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%~1' -OutFile '%~2' -UseBasicParsing -TimeoutSec 900 } catch { Write-Host ('     ' + $_.Exception.Message); exit 1 }"
if exist "%~2" (
    for %%s in ("%~2") do if %%~zs GEQ 1024 exit /b 0
    del "%~2" >nul 2>&1
)
if not defined DL_ERR set "DL_ERR=PowerShell 下载失败"

echo      !DL_ERR!
echo      提示: 若公司网络需代理，先执行 set HTTPS_PROXY=http://主机:端口 再重试
exit /b 1

REM 下载小文件（如 .sha256，几十字节）——最小体积门槛放宽到 16 字节
:download_raw
if exist "%~2" del "%~2" >nul 2>&1
where curl >nul 2>&1
if not errorlevel 1 (
    curl -fsSL -k --connect-timeout 20 -m 120 -o "%~2" "%~1"
    if exist "%~2" for %%s in ("%~2") do if %%~zs GEQ 16 exit /b 0
    if exist "%~2" del "%~2" >nul 2>&1
)
certutil -urlcache -split -f "%~1" "%~2" >nul 2>&1
if exist "%~2" for %%s in ("%~2") do if %%~zs GEQ 16 exit /b 0
if exist "%~2" del "%~2" >nul 2>&1
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; try { $ProgressPreference='SilentlyContinue'; Invoke-WebRequest -Uri '%~1' -OutFile '%~2' -UseBasicParsing -TimeoutSec 120 } catch { exit 1 }"
if exist "%~2" (
    for %%s in ("%~2") do if %%~zs GEQ 16 exit /b 0
)
if exist "%~2" del "%~2" >nul 2>&1
exit /b 1

REM ============================================================
REM 安装 Node.js（Windows 官方 zip，不依赖系统包管理器）
REM ============================================================
:install_node
echo ====^> 安装 Node.js %NODE_VERSION% 到本文件夹...

if exist "%NODE_EXE%" (
    set "CUR_NODE_VER="
    for /f "delims=" %%v in ('"%NODE_EXE%" -v 2^>nul') do set "CUR_NODE_VER=%%v"
    if "!CUR_NODE_VER!"=="%NODE_VERSION%" (
        echo Node.js 已存在于 %NODE_DIR%，跳过安装。
        echo      当前版本: !CUR_NODE_VER!
        goto :eof
    )
    echo Node.js 版本不匹配 ^(当前 !CUR_NODE_VER!，需要 %NODE_VERSION%^)，重新安装...
    rmdir /S /Q "%NODE_DIR%" >nul 2>&1
)

set "TMP_NODE_ZIP=%DATA_DIR%\%NODE_ZIP%"
if exist "%TMP_NODE_ZIP%" (
    echo      发现已存在的 %NODE_ZIP%，直接使用（离线安装）。
) else (
    echo 下载 Node.js 二进制包...
    call :download "%TMP_NODE_ZIP%" "%NODE_URL1%" "%NODE_URL2%"
)
if not exist "%TMP_NODE_ZIP%" (
    echo 错误: Node.js 下载失败，请手动下载 %NODE_ZIP% 放到本目录后重试:
    echo        %NODE_URL1%
    echo        %NODE_URL2%
    echo      目录: %DATA_DIR%
    exit /b 1
)

echo 解压到 %NODE_DIR% ...
set "NODE_TMP=%DATA_DIR%\node-tmp"
if exist "%NODE_TMP%" rmdir /S /Q "%NODE_TMP%" >nul 2>&1
powershell -NoProfile -Command "Expand-Archive -LiteralPath '%TMP_NODE_ZIP%' -DestinationPath '%NODE_TMP%' -Force"
if not exist "%NODE_DIR%" mkdir "%NODE_DIR%"
if exist "%NODE_TMP%\node-%NODE_VERSION%-win-x64" (
    xcopy /E /Y /Q /I "%NODE_TMP%\node-%NODE_VERSION%-win-x64\*" "%NODE_DIR%\" >nul
) else (
    for /d %%d in ("%NODE_TMP%\*") do xcopy /E /Y /Q /I "%%~d\*" "%NODE_DIR%\" >nul
)
rmdir /S /Q "%NODE_TMP%" >nul 2>&1
del "%TMP_NODE_ZIP%" >nul 2>&1

if not exist "%NODE_EXE%" (
    echo 错误: 解压后未找到 node.exe，请检查 %NODE_DIR%
    exit /b 1
)
echo Node.js 安装完成:
"%NODE_EXE%" -v
goto :eof

REM ============================================================
REM 安装 dsh 与 pnpm
REM ============================================================
:install_dsh
echo ====^> 安装 DeepSeek Harness...
echo      npm 镜像源: %NPM_REGISTRY%

if not exist "%NPM_PREFIX%" mkdir "%NPM_PREFIX%"
if not exist "%NPM_CACHE%" mkdir "%NPM_CACHE%"
if not exist "%DSH_DATA_DIR%" mkdir "%DSH_DATA_DIR%"
if not exist "%PNPM_HOME%" mkdir "%PNPM_HOME%"

if exist "%DSH_CMD%" (
    echo DeepSeek Harness 已安装，跳过。
) else (
    echo 安装 dsh 中...
    call npm install -g @deepseek-ai/dsh
    if errorlevel 1 (
        echo 错误: dsh 安装失败，请检查 npm 输出。
        exit /b 1
    )
    echo DeepSeek Harness 安装完成。
)

if exist "%PNPM_CMD%" (
    echo pnpm 已安装，跳过。
) else (
    echo 安装 pnpm 中...
    call npm install -g pnpm
    if errorlevel 1 (
        echo 错误: pnpm 安装失败，请检查 npm 输出。
        exit /b 1
    )
    echo pnpm 安装完成。
)
goto :eof

REM ============================================================
REM 安装 nginx（反向代理 / 远程访问）
REM 来源: nginx.org 官方 Windows 构建（nginx-<版本>.zip，含 nginx.exe 与 http_sub_module）
REM 下载源按顺序尝试，取到官方 .sha256 时校验，避免下载到损坏 / 被篡改的二进制
REM 安装形态: runtime\nginx\nginx.exe（官方包内容，含 conf / logs / temp 子目录）
REM ============================================================
:install_nginx
echo ====^> 安装 nginx %NGINX_VERSION% 到本文件夹（Windows 官方构建）...

if exist "%NGINX_EXE%" (
    set "CUR_NGINX_VER="
    for /f "tokens=2 delims=/" %%v in ('"%NGINX_EXE%" -v 2^>^&1') do set "CUR_NGINX_VER=%%v"
    set "CUR_NGINX_SRC="
    if exist "%NGINX_MARKER%" set /p CUR_NGINX_SRC=<"%NGINX_MARKER%"
    if "!CUR_NGINX_VER!"=="%NGINX_VERSION%" (
        if "!CUR_NGINX_SRC!"=="%NGINX_SOURCE%" (
            echo nginx 已存在于 %NGINX_DIR%，跳过安装。
            echo      当前版本: !CUR_NGINX_VER! ^(来源: !CUR_NGINX_SRC!^)
            goto :eof
        )
    )
    if "!CUR_NGINX_VER!"=="%NGINX_VERSION%" (
        echo nginx 来源不是 %NGINX_SOURCE% ^(当前 !CUR_NGINX_SRC!^)，重新安装...
    ) else (
        echo nginx 版本不匹配 ^(当前 !CUR_NGINX_VER!，需要 %NGINX_VERSION%^)，重新安装...
    )
    rmdir /S /Q "%NGINX_DIR%" >nul 2>&1
)

set "TMP_NGINX_ZIP=%DATA_DIR%\%NGINX_ZIP%"
set "TMP_NGINX_SHA=%DATA_DIR%\%NGINX_ZIP%.sha256.tmp"
if exist "%TMP_NGINX_SHA%" del "%TMP_NGINX_SHA%" >nul 2>&1

if exist "%TMP_NGINX_ZIP%" (
    echo      发现已存在的 %NGINX_ZIP%，直接使用（离线安装）。
) else (
    call :download "%TMP_NGINX_ZIP%" "%NGINX_URL1%" "%NGINX_URL2%" "%NGINX_URL3%"
)
if not exist "%TMP_NGINX_ZIP%" (
    echo 错误: nginx 下载失败，已尝试以下下载源:
    echo        %NGINX_URL1%
    echo        %NGINX_URL2%
    echo        %NGINX_URL3%
    echo      请用浏览器 / 迅雷 / 其他机器下载 %NGINX_ZIP% ^(约 2.7 MB^)，
    echo      放到本目录后重新运行: whim-dsh.bat install_rp
    echo      目录: %DATA_DIR%
    echo      下载页: https://nginx.org/en/download.html
    exit /b 1
)

REM 校验值：优先用脚本内置的官方发布值；若取到 .sha256 文件则以文件为准
set "WANT_SHA=%NGINX_SHA256%"
call :download_raw "%TMP_NGINX_SHA%" "%NGINX_SHA_URL1%"
if exist "%TMP_NGINX_SHA%" (
    set "WANT_SHA="
    set /p WANT_SHA=<"%TMP_NGINX_SHA%"
)
if defined WANT_SHA (
    set "GOT_SHA="
    for /f "delims=" %%h in ('powershell -NoProfile -Command "(Get-FileHash -LiteralPath '%TMP_NGINX_ZIP%' -Algorithm SHA256).Hash.ToLower()"') do set "GOT_SHA=%%h"
    if /i not "!WANT_SHA!"=="!GOT_SHA!" (
        echo 错误: nginx 压缩包校验失败 ^(期望 !WANT_SHA!，实际 !GOT_SHA!^)
        echo       若下载到的是精简包 / 自建包，可删除脚本里的 NGINX_SHA256 后重试。
        del "%TMP_NGINX_ZIP%" >nul 2>&1
        del "%TMP_NGINX_SHA%" >nul 2>&1
        exit /b 1
    )
    echo      SHA-256 校验通过: !GOT_SHA!
) else (
    echo      提示: 无校验值，跳过校验。
)
if exist "%TMP_NGINX_SHA%" del "%TMP_NGINX_SHA%" >nul 2>&1

echo 解压到 %NGINX_DIR% ...
if not exist "%NGINX_DIR%" mkdir "%NGINX_DIR%"
powershell -NoProfile -Command "Expand-Archive -LiteralPath '%TMP_NGINX_ZIP%' -DestinationPath '%NGINX_DIR%' -Force"
REM 官方包内是一层 nginx-<版本>\ 目录，把内容提到 runtime\nginx 下
if exist "%NGINX_DIR%\nginx-%NGINX_VERSION%" (
    xcopy /E /Y /Q /I "%NGINX_DIR%\nginx-%NGINX_VERSION%\*" "%NGINX_DIR%\" >nul
    rmdir /S /Q "%NGINX_DIR%\nginx-%NGINX_VERSION%" >nul 2>&1
)
del "%TMP_NGINX_ZIP%" >nul 2>&1

if not exist "%NGINX_EXE%" (
    echo 错误: 未找到 nginx.exe，目录内容如下:
    dir /b "%NGINX_DIR%"
    exit /b 1
)
"%NGINX_EXE%" -v
if errorlevel 1 (
    echo 错误: nginx 无法执行，请确认系统架构是否为 x64。
    exit /b 1
)

REM 补齐运行所需目录（官方包已带，这里兜底）
if not exist "%NGINX_DIR%\logs" mkdir "%NGINX_DIR%\logs"
if not exist "%NGINX_DIR%\temp\client_body_temp" mkdir "%NGINX_DIR%\temp\client_body_temp"
if not exist "%NGINX_DIR%\temp\proxy_temp" mkdir "%NGINX_DIR%\temp\proxy_temp"
if not exist "%NGINX_DIR%\temp\fastcgi_temp" mkdir "%NGINX_DIR%\temp\fastcgi_temp"
if not exist "%NGINX_DIR%\temp\scgi_temp" mkdir "%NGINX_DIR%\temp\scgi_temp"
if not exist "%NGINX_DIR%\temp\uwsgi_temp" mkdir "%NGINX_DIR%\temp\uwsgi_temp"

REM 记录下载来源，供下次安装时判断是否需要替换
>"%NGINX_MARKER%" echo %NGINX_SOURCE%

echo nginx 安装完成。
goto :eof

REM ============================================================
REM 生成 nginx 反向代理配置（nginx.conf）
REM 用法: call :write_nginx_conf <上游地址> <dsh token>
REM 说明: 浏览器直接访问代理地址时 URL 里没有 token，这里把 token 补上；
REM       dsh 校验通过后会下发会话 cookie，此后访问就不再需要 token
REM 注意: 本文件是 GBK 编码，故配置内注释一律用英文；
REM       涉及 ^| ^( ^) 等 cmd 特殊字符的行均按 cmd 语法转义。
REM ============================================================
:write_nginx_conf
set "RP_UPSTREAM=%~1"
set "RP_TOKEN=%~2"

>"%NGINX_CONFIG%" echo # This file is generated by whim-dsh.bat (start). Do not edit by hand.
>>"%NGINX_CONFIG%" echo worker_processes  1;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo # nginx/Windows is a console application; daemon off keeps it in the
>>"%NGINX_CONFIG%" echo # foreground so this script can manage it by PID file.
>>"%NGINX_CONFIG%" echo daemon off;
>>"%NGINX_CONFIG%" echo pid !NGINX_PREFIX!logs/nginx.pid;
>>"%NGINX_CONFIG%" echo error_log "!NGINX_LOG_FWD!" warn;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo events {
>>"%NGINX_CONFIG%" echo     worker_connections  1024;
>>"%NGINX_CONFIG%" echo }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo http {
>>"%NGINX_CONFIG%" echo     default_type  application/octet-stream;
>>"%NGINX_CONFIG%" echo     access_log    "!NGINX_ACC_FWD!" combined;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo     # Allow large uploads: the 1m default causes 413 on big files.
>>"%NGINX_CONFIG%" echo     # Overflow goes to temp/client_body_temp under runtime/nginx.
>>"%NGINX_CONFIG%" echo     client_max_body_size 1g;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo     # Connection header required for WebSocket upgrade.
>>"%NGINX_CONFIG%" echo     map $http_upgrade $connection_upgrade {
>>"%NGINX_CONFIG%" echo         default upgrade;
>>"%NGINX_CONFIG%" echo         ''      close;
>>"%NGINX_CONFIG%" echo     }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo     # dsh session cookies are named dsh-auth-*.
>>"%NGINX_CONFIG%" echo     map $http_cookie $dsh_has_cookie {
>>"%NGINX_CONFIG%" echo         default       0;
>>"%NGINX_CONFIG%" echo         "~*dsh-auth-" 1;
>>"%NGINX_CONFIG%" echo     }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo     # The root path needs the token only when the client has neither a
>>"%NGINX_CONFIG%" echo     # token nor a session cookie.
>>"%NGINX_CONFIG%" echo     map "$arg_token:$dsh_has_cookie" $dsh_need_token {
>>"%NGINX_CONFIG%" echo         default 0;
>>"%NGINX_CONFIG%" echo         ":0"    1;
>>"%NGINX_CONFIG%" echo     }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo     upstream dsh_upstream {
>>"%NGINX_CONFIG%" echo         server !RP_UPSTREAM!;
>>"%NGINX_CONFIG%" echo     }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo     server {
>>"%NGINX_CONFIG%" echo         # Match any Host (tunnel / domain forwarding), listen on loopback only.
>>"%NGINX_CONFIG%" echo         listen      !RP_HOST!:!RP_PORT!;
>>"%NGINX_CONFIG%" echo         server_name _;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo         # Hand dsh refusals (401, e.g. expired cookie) to @dsh_reauth.
>>"%NGINX_CONFIG%" echo         # Note: intercept_errors is enabled only in the locations below,
>>"%NGINX_CONFIG%" echo         # never here: intercepting an error_page directive that is
>>"%NGINX_CONFIG%" echo         # itself defined at this level immediately re-raises it in a
>>"%NGINX_CONFIG%" echo         # loop and nginx drops the connection with an empty reply.
>>"%NGINX_CONFIG%" echo         error_page 401 = @dsh_reauth;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo         proxy_http_version 1.1;
>>"%NGINX_CONFIG%" echo         # Rewrite Host / Origin to loopback (see the header notes):
>>"%NGINX_CONFIG%" echo         # plugins with their own loopback-only fence reject domain requests.
>>"%NGINX_CONFIG%" echo         proxy_set_header Host !RP_UPSTREAM!;
>>"%NGINX_CONFIG%" echo         proxy_set_header Origin http://!RP_UPSTREAM!;
>>"%NGINX_CONFIG%" echo         proxy_set_header Upgrade $http_upgrade;
>>"%NGINX_CONFIG%" echo         proxy_set_header Connection $connection_upgrade;
>>"%NGINX_CONFIG%" echo         proxy_set_header X-Real-IP $remote_addr;
>>"%NGINX_CONFIG%" echo         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
>>"%NGINX_CONFIG%" echo         proxy_set_header X-Forwarded-Proto $scheme;
>>"%NGINX_CONFIG%" echo         # No buffering, so SSE / streaming responses reach the browser at once.
>>"%NGINX_CONFIG%" echo         proxy_buffering off;
>>"%NGINX_CONFIG%" echo         proxy_read_timeout 3600s;
>>"%NGINX_CONFIG%" echo         proxy_send_timeout 3600s;
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo         # Never cache the index page: a cached blank response kept the
>>"%NGINX_CONFIG%" echo         # page blank after reopening. Hashed assets are left alone.
>>"%NGINX_CONFIG%" echo         # Note: the token is added with if + rewrite ... break (not
>>"%NGINX_CONFIG%" echo         # if + proxy_pass with a URI), because nginx forbids the latter,
>>"%NGINX_CONFIG%" echo         # and rewrite ... break does not trigger an internal redirect,
>>"%NGINX_CONFIG%" echo         # so add_header below still applies.
>>"%NGINX_CONFIG%" echo         location = / {
>>"%NGINX_CONFIG%" echo             add_header Cache-Control "no-store, no-cache, must-revalidate" always;
>>"%NGINX_CONFIG%" echo             proxy_intercept_errors on;
>>"%NGINX_CONFIG%" echo             if ($dsh_need_token = 1) {
>>"%NGINX_CONFIG%" echo                 rewrite ^^ /?token=!RP_TOKEN! break;
>>"%NGINX_CONFIG%" echo             }
>>"%NGINX_CONFIG%" echo             proxy_pass http://dsh_upstream;
>>"%NGINX_CONFIG%" echo         }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo         # Everything else (API, static assets) is passed through unchanged.
>>"%NGINX_CONFIG%" echo         location / {
>>"%NGINX_CONFIG%" echo             proxy_intercept_errors on;
>>"%NGINX_CONFIG%" echo             proxy_pass http://dsh_upstream;
>>"%NGINX_CONFIG%" echo         }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo         # Front-end isLoopback rewrite, for plugin bundles only (/plugins/...).
>>"%NGINX_CONFIG%" echo         # Note: proxy_set_header is not inherited once it appears at this
>>"%NGINX_CONFIG%" echo         # level, so every server-level header is repeated here.
>>"%NGINX_CONFIG%" echo         location /plugins/ {
>>"%NGINX_CONFIG%" echo             proxy_pass http://dsh_upstream;
>>"%NGINX_CONFIG%" echo             # Ask the upstream for an uncompressed body, otherwise gzip
>>"%NGINX_CONFIG%" echo             # would make the pattern unmatchable.
>>"%NGINX_CONFIG%" echo             proxy_set_header Accept-Encoding "";
>>"%NGINX_CONFIG%" echo             proxy_set_header Host !RP_UPSTREAM!;
>>"%NGINX_CONFIG%" echo             proxy_set_header Origin http://!RP_UPSTREAM!;
>>"%NGINX_CONFIG%" echo             proxy_set_header Upgrade $http_upgrade;
>>"%NGINX_CONFIG%" echo             proxy_set_header Connection $connection_upgrade;
>>"%NGINX_CONFIG%" echo             proxy_set_header X-Real-IP $remote_addr;
>>"%NGINX_CONFIG%" echo             proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
>>"%NGINX_CONFIG%" echo             proxy_set_header X-Forwarded-Proto $scheme;
>>"%NGINX_CONFIG%" echo             # The official Windows build ships http_sub_module, so a plain
>>"%NGINX_CONFIG%" echo             # case-insensitive body replacement is enough (no njs needed).
>>"%NGINX_CONFIG%" echo             sub_filter '!SUB_FILTER_MATCH!' 'isLoopback: true,';
>>"%NGINX_CONFIG%" echo             sub_filter_once off;
>>"%NGINX_CONFIG%" echo             sub_filter_types application/javascript text/javascript application/x-javascript;
>>"%NGINX_CONFIG%" echo         }
>>"%NGINX_CONFIG%" echo.
>>"%NGINX_CONFIG%" echo         # Page navigation: when an expired session cookie is rejected,
>>"%NGINX_CONFIG%" echo         # redirect back with the token to fetch a new cookie. Other
>>"%NGINX_CONFIG%" echo         # requests keep their 401 (so the front-end never gets HTML).
>>"%NGINX_CONFIG%" echo         location @dsh_reauth {
>>"%NGINX_CONFIG%" echo             proxy_intercept_errors off;
>>"%NGINX_CONFIG%" echo             # Page navigation: some browsers and proxies do not send
>>"%NGINX_CONFIG%" echo             # Sec-Fetch-Mode, so an HTML Accept also counts as navigation.
>>"%NGINX_CONFIG%" echo             # Without this, a stale cookie shows a raw 401 instead of
>>"%NGINX_CONFIG%" echo             # being re-authenticated automatically.
>>"%NGINX_CONFIG%" echo             set $dsh_reauth 0;
>>"%NGINX_CONFIG%" echo             if ($http_sec_fetch_mode = navigate) {
>>"%NGINX_CONFIG%" echo                 set $dsh_reauth 1;
>>"%NGINX_CONFIG%" echo             }
>>"%NGINX_CONFIG%" echo             if ($http_accept ~* "text/html") {
>>"%NGINX_CONFIG%" echo                 set $dsh_reauth 1;
>>"%NGINX_CONFIG%" echo             }
>>"%NGINX_CONFIG%" echo             if ($dsh_reauth = 1) {
>>"%NGINX_CONFIG%" echo                 return 303 /?token=!RP_TOKEN!;
>>"%NGINX_CONFIG%" echo             }
>>"%NGINX_CONFIG%" echo             proxy_pass http://dsh_upstream;
>>"%NGINX_CONFIG%" echo         }
>>"%NGINX_CONFIG%" echo     }
>>"%NGINX_CONFIG%" echo }
goto :eof

REM ============================================================
REM 反向代理端口是否已被占用
REM best-effort：探测不可用时按“未占用”处理，真正的冲突由启动结果校验兜底
REM ============================================================
:port_in_use
set "PORT_IN_USE="
for /f "delims=" %%l in ('netstat -an ^| findstr /R /C:":%RP_PORT% " ^| findstr /C:"LISTENING"') do set "PORT_IN_USE=1"
if defined PORT_IN_USE exit /b 0
exit /b 1

REM ============================================================
REM 启动 nginx 反向代理（start 时自动调用）
REM 用法: call :start_nginx <上游地址> <dsh token>
REM ============================================================
:start_nginx
set "RP_UPSTREAM=%~1"
set "RP_TOKEN=%~2"

if not exist "%NGINX_EXE%" (
    echo 提示: 未安装 nginx，跳过反向代理。安装: whim-dsh.bat install_rp
    goto :eof
)

if not defined RP_UPSTREAM (
    echo 提示: 未能解析 dsh 的运行地址，跳过反向代理。
    goto :eof
)
if not defined RP_TOKEN (
    echo 提示: 未能解析 dsh 的 token，跳过反向代理。
    goto :eof
)

REM 先停掉上一次的 nginx，避免端口被占用
call :stop_nginx_quiet

call :port_in_use
if not errorlevel 1 (
    echo 警告: 端口 %RP_PORT% 已被其他进程占用，跳过反向代理。
    echo       请先释放该端口 ^(如: netstat -ano ^| findstr %RP_PORT%^) 后重新 start。
    goto :eof
)

call :write_nginx_conf "!RP_UPSTREAM!" "!RP_TOKEN!"

REM 先校验配置，避免带着错误配置后台运行
"%NGINX_EXE%" -p "!NGINX_PREFIX!" -c "!NGINX_CONF_FWD!" -t >"%DATA_DIR%\nginx-test.log" 2>&1
if errorlevel 1 (
    type "%DATA_DIR%\nginx-test.log"
    echo 警告: nginx 配置校验失败，跳过反向代理。
    goto :eof
)
del "%DATA_DIR%\nginx-test.log" >nul 2>&1

if exist "%NGINX_LOG_FILE%" del "%NGINX_LOG_FILE%" >nul 2>&1
if exist "%NGINX_LOG_FILE%.err" del "%NGINX_LOG_FILE%.err" >nul 2>&1
if exist "%NGINX_ACCESS_LOG_FILE%" del "%NGINX_ACCESS_LOG_FILE%" >nul 2>&1
if exist "%NGINX_DIR%\logs\nginx.pid" del "%NGINX_DIR%\logs\nginx.pid" >nul 2>&1

REM 配置中写了 daemon off，故进程常驻前台；用 Start-Process 隐藏窗口并记录 PID
REM （用 [char]34 拼引号，避免 cmd 与 PowerShell 双重引号问题）
powershell -NoProfile -Command "$a = '-p ' + [char]34 + $env:NGINX_PREFIX + [char]34 + ' -c ' + [char]34 + $env:NGINX_CONF_FWD + [char]34; $p = Start-Process -FilePath $env:NGINX_EXE -ArgumentList $a -WindowStyle Hidden -RedirectStandardOutput $env:NGINX_LOG_FILE -RedirectStandardError ($env:NGINX_LOG_FILE + '.err') -PassThru; $p.Id | Out-File -Encoding ascii $env:NGINX_PID_FILE"
if not exist "%NGINX_PID_FILE%" (
    echo 警告: nginx 启动失败，请检查 PowerShell 是否可用。
    goto :eof
)

call :read_pid "%NGINX_PID_FILE%"
if errorlevel 1 (
    echo 警告: nginx 启动失败，未能获取 PID。
    goto :eof
)
set "NGINX_PID=!RP_PID!"

REM 启动校验：仅确认进程存活不够——绑定失败时 nginx 会先重试再退出。
REM 因此同时确认端口已监听，最多等待约 5 秒。
set "NGINX_OK="
for /l %%i in (1,1,5) do (
    if not defined NGINX_OK (
        ping -n 2 127.0.0.1 >nul 2>&1
        call :pid_alive !NGINX_PID!
        if errorlevel 1 (
            REM 进程已退出，无需再等
        ) else (
            call :port_in_use
            if not errorlevel 1 set "NGINX_OK=1"
        )
    )
)

if not defined NGINX_OK (
    echo 警告: nginx 启动失败或未监听端口 %RP_PORT%，详情见 %NGINX_LOG_FILE%
    if exist "%NGINX_LOG_FILE%" (
        powershell -NoProfile -Command "Get-Content -LiteralPath '%NGINX_LOG_FILE%' -Tail 3 -ErrorAction SilentlyContinue"
    )
    del "%NGINX_PID_FILE%" >nul 2>&1
    goto :eof
)

echo 反向代理已启动，PID: !NGINX_PID! ^(已保存到 %NGINX_PID_FILE%^)
echo 访问地址: http://%RP_HOST%:%RP_PORT%/  ^(无需 token，直接打开 dsh^)
echo 代理配置: %NGINX_CONFIG%
goto :eof

REM ============================================================
REM 停止 nginx 反向代理（根据 nginx-pid.txt）
REM 用法: call :stop_nginx_quiet  （静默，供 start 内部调用）
REM       call :stop_nginx         （带中文提示）
REM ============================================================
:stop_nginx
echo ====^> 停止 nginx 反向代理...
call :stop_nginx_quiet
goto :eof

:stop_nginx_quiet
REM 先尝试优雅退出（需要能读到配置里的 pid 文件），失败再由 PID 兜底
if exist "%NGINX_EXE%" if exist "%NGINX_CONFIG%" (
    "%NGINX_EXE%" -p "!NGINX_PREFIX!" -c "!NGINX_CONF_FWD!" -s quit >nul 2>&1
    ping -n 2 127.0.0.1 >nul 2>&1
)
call :stop_by_pidfile "%NGINX_PID_FILE%" "nginx" "nginx"
REM 兜底：pid 文件丢失时按可执行文件路径结束本目录的 nginx
if exist "%NGINX_EXE%" call :kill_by_cmdline "nginx.exe" "%NGINX_DIR%" "nginx"
goto :eof

REM ============================================================
REM 初始化插件（dshmarket 插件市场）
REM ============================================================
:init_market
echo ====^> 初始化插件 ^(dshmarket^)...

if not exist "%DSH_BIN%" (
    echo 错误: 未找到 dsh，请先运行: whim-dsh.bat install
    exit /b 1
)
if not exist "%PNPM_CMD%" (
    echo 错误: 未找到 pnpm，请先运行: whim-dsh.bat install
    exit /b 1
)

call :install_plugin dshmarket "插件市场"

echo.
echo ====^> 插件初始化完成。
echo      重启 dsh 后，可在 设置 → 插件市场 中管理插件。
goto :eof

REM ============================================================
REM 安装单个插件
REM 用法: call :install_plugin <插件名> <中文说明>
REM 已记录在 web profile 的 package.json 依赖中则跳过
REM ============================================================
:install_plugin
set "PLUGIN_NAME=%~1"
set "PLUGIN_DESC=%~2"

if exist "%PROFILE_MANIFEST%" (
    findstr /C:"!PLUGIN_NAME!" "%PROFILE_MANIFEST%" >nul 2>&1
    if not errorlevel 1 (
        echo !PLUGIN_DESC! ^(!PLUGIN_NAME!^) 已安装，跳过。
        goto :eof
    )
)

echo 安装 !PLUGIN_DESC! ^(!PLUGIN_NAME!^) ...
"%NODE_EXE%" "%DSH_BIN%" plugin --profile web add !PLUGIN_NAME!
goto :eof

REM ============================================================
REM 从日志中解析运行地址，写入 bk_url.txt
REM 用法: call :capture_url <最大等待秒数>
REM 成功时 bk_url.txt 内为 URL；失败返回 errorlevel 1
REM ============================================================
:capture_url
set "CAPTURE_WAIT=%~1"
if not defined CAPTURE_WAIT set "CAPTURE_WAIT=15"
if exist "%URL_FILE%" del "%URL_FILE%" >nul 2>&1

powershell -NoProfile -Command "$u = $null; for ($i = 0; $i -lt %CAPTURE_WAIT%; $i++) { foreach ($f in @($env:LOG_FILE, $env:ERR_LOG_FILE)) { if (Test-Path $f) { $t = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue; if ($t -and ($t -match '(https?://[^\s]+)')) { $u = $matches[1]; break } } }; if ($u) { break }; Start-Sleep -Seconds 1 }; if ($u) { Set-Content -Path $env:URL_FILE -Value $u -Encoding ascii; exit 0 } else { exit 1 }"
if errorlevel 1 (
    echo 警告: 未能从日志中解析出运行地址，请手动查看 %LOG_FILE%
    exit /b 1
)

set "CAPTURED_URL="
set /p CAPTURED_URL=<"%URL_FILE%"
echo 运行地址: !CAPTURED_URL!
echo           ^(已保存到 %URL_FILE%^)
exit /b 0

REM ============================================================
REM 前台运行 DeepSeek Harness（调试用，Ctrl+C 退出）
REM ============================================================
:debug_dsh
echo ====^> 前台启动 DeepSeek Harness Web UI（调试模式）...

if not exist "%DSH_BIN%" (
    echo 未找到 dsh 可执行文件，请先运行: whim-dsh.bat install
    exit /b 1
)
if exist "%URL_FILE%" del "%URL_FILE%" >nul 2>&1

REM 前台运行，同时捕获输出中的运行地址并写入 bk_url.txt
powershell -NoProfile -Command "$a = @([char]34 + $env:DSH_BIN + [char]34, 'web', '--no-open'); foreach ($h in ($env:PUBLIC_HOSTS -split '[\s,;]+')) { $h = ($h.Trim().Trim([char]34).Trim([char]0xFEFF) -replace '^[A-Za-z]+://','' -split '/')[0]; if ($h -match '^([A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?|\[[0-9A-Fa-f:]+\](:[0-9]+)?)$') { $a += @('--trusted-host', $h) } }; $u = $null; & $env:NODE_EXE @a 2>&1 | ForEach-Object { $_; if (-not $u -and ($_ -match '(https?://[^\s]+)')) { $u = $matches[1]; Set-Content -Path $env:URL_FILE -Value $u -Encoding ascii; Write-Host ('URL: ' + $u) } }"
goto :eof

REM ============================================================
REM 运行自定义 dsh 命令
REM 用法: call :dsh_cmd <命令...>
REM       whim-dsh.bat dsh              （不带参数则交互式输入）
REM 示例: whim-dsh.bat dsh web --no-open
REM       whim-dsh.bat dsh plugin --profile web list
REM ============================================================
:dsh_cmd
echo ====^> 运行自定义 dsh 命令...

if not exist "%DSH_BIN%" (
    echo 错误: 未找到 dsh 可执行文件，请先运行: whim-dsh.bat install
    exit /b 1
)

if "%~1"=="" (
    set "DSH_INPUT="
    set /p "DSH_INPUT=请输入 dsh 命令 (不含 dsh 本身，例如 web --no-open): "
    if not defined DSH_INPUT (
        echo 未输入命令，已取消。
        goto :eof
    )
    echo.
    "%NODE_EXE%" "%DSH_BIN%" !DSH_INPUT!
    exit /b !errorlevel!
)

"%NODE_EXE%" "%DSH_BIN%" %*
exit /b %errorlevel%

REM ============================================================
REM 后台运行 DeepSeek Harness + nginx 反向代理（PID 保存到 pid.txt）
REM ============================================================
:start_dsh
echo ====^> 后台启动 DeepSeek Harness Web UI...

if not exist "%DSH_BIN%" (
    echo 未找到 dsh 可执行文件，请先运行: whim-dsh.bat install
    exit /b 1
)

REM 检查是否已有实例在运行
if exist "%PID_FILE%" (
    call :read_pid "%PID_FILE%"
    if not errorlevel 1 (
        set "OLD_PID=!RP_PID!"
        call :pid_alive !OLD_PID!
        if not errorlevel 1 (
            echo dsh 已在后台运行 ^(PID: !OLD_PID!^)，请先运行: whim-dsh.bat stop
            exit /b 1
        )
    )
    REM 清理无效的 pid 文件
    del "%PID_FILE%" >nul 2>&1
)

echo 正在后台启动...
if exist "%URL_FILE%" del "%URL_FILE%" >nul 2>&1
if exist "%LOG_FILE%" del "%LOG_FILE%" >nul 2>&1
if exist "%ERR_LOG_FILE%" del "%ERR_LOG_FILE%" >nul 2>&1

REM PUBLIC_HOSTS 作为 --trusted-host 传给 dsh，使 dsh 接受这些域名的 Host
REM 用 node.exe 直接跑 bin.js，避免路径含空格时的引号问题
powershell -NoProfile -Command "$a = @([char]34 + $env:DSH_BIN + [char]34, 'web', '--no-open'); foreach ($h in ($env:PUBLIC_HOSTS -split '[\s,;]+')) { $h = ($h.Trim().Trim([char]34).Trim([char]0xFEFF) -replace '^[A-Za-z]+://','' -split '/')[0]; if ($h -match '^([A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?|\[[0-9A-Fa-f:]+\](:[0-9]+)?)$') { $a += @('--trusted-host', $h) } else { Write-Host ('忽略非法对外域名: [' + $h + ']') } }; Write-Host ('dsh 参数: ' + ($a -join ' ')); $p = Start-Process -FilePath $env:NODE_EXE -ArgumentList $a -WindowStyle Hidden -RedirectStandardOutput $env:LOG_FILE -RedirectStandardError $env:ERR_LOG_FILE -PassThru; $p.Id | Out-File -Encoding ascii $env:PID_FILE"
if not exist "%PID_FILE%" (
    echo 错误: 后台启动失败，请检查 PowerShell 是否可用。
    exit /b 1
)

call :read_pid "%PID_FILE%"
if errorlevel 1 (
    echo 错误: 后台启动失败，未能获取 PID。
    exit /b 1
)
set "NEW_PID=!RP_PID!"

REM 确认进程存活（留几次重试，避免刚创建就判定失败）
set "DSH_ALIVE="
for /l %%i in (1,1,3) do (
    if not defined DSH_ALIVE (
        call :pid_alive !NEW_PID!
        if not errorlevel 1 (
            set "DSH_ALIVE=1"
        ) else (
            ping -n 2 127.0.0.1 >nul 2>&1
        )
    )
)
if not defined DSH_ALIVE (
    echo 错误: 后台启动失败，进程 !NEW_PID! 已退出，日志末尾:
    if exist "%LOG_FILE%" powershell -NoProfile -Command "Get-Content -LiteralPath '%LOG_FILE%' -Tail 10 -ErrorAction SilentlyContinue"
    if exist "%ERR_LOG_FILE%" powershell -NoProfile -Command "Get-Content -LiteralPath '%ERR_LOG_FILE%' -Tail 10 -ErrorAction SilentlyContinue"
    del "%PID_FILE%" >nul 2>&1
    exit /b 1
)

echo 已在后台启动，PID: !NEW_PID! ^(已保存到 %PID_FILE%^)
echo 脚本版本: %BAT_VERSION%
echo 日志文件: %LOG_FILE%
if defined PUBLIC_HOSTS (
    echo 对外域名 ^(--trusted-host^): !PUBLIC_HOSTS!
    echo          ^(记于 %PUBLIC_HOSTS_FILE%，本次已沿用^)
) else (
    echo 提示: 未设置 PUBLIC_HOSTS，dsh 只信任本机 Host，
    echo       域名 / 隧道访问需先: set PUBLIC_HOSTS=你的域名:端口 ^& whim-dsh.bat start
)

call :capture_url 15

REM 解析出上游地址与 token，再启动 nginx 反向代理：
REM 把 dsh 的 token 写进代理配置，之后打开代理地址即可直接进入 dsh
set "RP_UPSTREAM="
set "RP_TOKEN="
if exist "%URL_FILE%" (
    set "CAPTURED_URL="
    set /p CAPTURED_URL=<"%URL_FILE%"
    if defined CAPTURED_URL (
        set "TMP_URL=!CAPTURED_URL:http://=!"
        set "TMP_URL=!TMP_URL:https://=!"
        for /f "tokens=1 delims=/" %%a in ("!TMP_URL!") do set "RP_UPSTREAM=%%a"
        for /f "tokens=2 delims==&" %%a in ("!CAPTURED_URL!") do set "RP_TOKEN=%%a"
    )
)
call :start_nginx "!RP_UPSTREAM!" "!RP_TOKEN!"

echo 停止服务: whim-dsh.bat stop
goto :eof

REM ============================================================
REM 读取 pid 文件
REM ============================================================
:read_pid
REM 用法: call :read_pid <pid 文件>  → 结果放入 RP_PID
REM 用 for /f 读第一行：set /p 在文件末尾没有换行符时会读出空值
REM （PowerShell 写成 -NoNewline 时就是这种情况），会把有效 PID 误判为非法
set "RP_PID="
if not exist "%~1" exit /b 1
for /f "usebackq delims=" %%p in ("%~1") do if not defined RP_PID set "RP_PID=%%p"
set "RP_PID=!RP_PID: =!"
set "RP_PID=!RP_PID:	=!"
if not defined RP_PID exit /b 1
echo(!RP_PID!| findstr /R "^[0-9][0-9]*$" >nul
if errorlevel 1 exit /b 1
exit /b 0

REM 判断 PID 是否存活（tasklist 加 PID 过滤，再按 CSV 里的 ",PID," 精确匹配）
:pid_alive
REM 注: 不能用 tasklist /FO CSV + findstr ",PID,"——CSV 里 PID 前后都是引号
REM     （"node.exe","12345",...），该模式永远匹配不到，会误判成「进程不存在」。
REM     也不能用 tasklist /NH 直接 find PID，短 PID 会命中别的列（如内存占用）。
powershell -NoProfile -Command "if (Get-Process -Id %~1 -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"
if errorlevel 1 exit /b 1
exit /b 0

REM 兜底：按进程名 + 命令行关键字结束进程
REM 用途: PID 文件丢失 / 内容不符时（例如手工启动过、或 dsh 被别的窗口拉起）仍能停干净
REM 用法: call :kill_by_cmdline <可执行文件名> <命令行关键字> <显示名>
:kill_by_cmdline
set "KC_NAME=%~1"
set "KC_MATCH=%~2"
set "KC_LABEL=%~3"
set "KC_FOUND="
for /f "delims=" %%p in ('powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq $env:KC_NAME -and $_.CommandLine -and $_.CommandLine.Contains($env:KC_MATCH) } | ForEach-Object { $_.ProcessId }" 2^>nul') do (
    echo(%%p| findstr /R "^[0-9][0-9]*$" >nul
    if not errorlevel 1 (
        set "KC_FOUND=1"
        echo      结束残留的 !KC_LABEL! 进程 PID: %%p
        taskkill /PID %%p /T /F >nul 2>&1
    )
)
if not defined KC_FOUND echo      未发现残留的 !KC_LABEL! 进程。
goto :eof

REM ============================================================
REM 根据 pid 文件停止后台进程，并清理该文件
REM 用法: call :stop_by_pidfile <pid 文件> <进程显示名>
REM ============================================================
:stop_by_pidfile
REM 用法: call :stop_by_pidfile <pid 文件> <显示名> [期望的进程名]
REM 期望进程名用于防 PID 复用：pid.txt 里的 PID 可能已被系统分给别的进程
set "SPF_FILE=%~1"
set "SPF_NAME=%~2"
set "SPF_IMAGE=%~3"

if not exist "%SPF_FILE%" (
    echo 未找到 %SPF_FILE%，%SPF_NAME% 可能未在后台运行。
    goto :eof
)

call :read_pid "%SPF_FILE%"
if errorlevel 1 (
    echo %SPF_FILE% 内容为空或非法，清理该文件。
    del "%SPF_FILE%" >nul 2>&1
    goto :eof
)
set "SPF_PID=!RP_PID!"

call :pid_alive !SPF_PID!
if errorlevel 1 (
    echo PID !SPF_PID! 对应的进程不存在，清理 %SPF_FILE%。
    del "%SPF_FILE%" >nul 2>&1
    goto :eof
)

if defined SPF_IMAGE (
    set "SPF_IMG="
    for /f "delims=" %%n in ('powershell -NoProfile -Command "(Get-Process -Id !SPF_PID! -ErrorAction SilentlyContinue).ProcessName" 2^>nul') do set "SPF_IMG=%%n"
    if /i not "!SPF_IMG!"=="!SPF_IMAGE!" (
        echo PID !SPF_PID! 现由 !SPF_IMG! 占用 ^(非 !SPF_IMAGE!^)，不结束它，仅清理 %SPF_FILE%。
        del "%SPF_FILE%" >nul 2>&1
        goto :eof
    )
)

echo 正在停止 %SPF_NAME% ^(PID: !SPF_PID!^)...
taskkill /PID !SPF_PID! /T /F >nul 2>&1

del "%SPF_FILE%" >nul 2>&1
echo 已停止 %SPF_NAME%。
goto :eof

REM ============================================================
REM 停止后台运行的 DeepSeek Harness（根据 pid.txt）
REM ============================================================
:stop_dsh
echo ====^> 停止 DeepSeek Harness...
call :stop_by_pidfile "%PID_FILE%" "dsh" "node"
REM pid.txt 可能已丢失或内容不符（例如手工启动、或上次被误清理），
REM 这里再按命令行匹配本目录的 dsh 入口，确保进程真的退出
if exist "%DSH_BIN%" call :kill_by_cmdline "node.exe" "%DSH_BIN%" "dsh"
goto :eof

REM ============================================================
REM 主入口
REM ============================================================
:install
call :install_node
call :install_dsh
echo.
echo ====^> 安装完成。所有数据位于: %DATA_DIR%
echo      Node.js 运行时: %RUNTIME_DIR%
echo 运行: whim-dsh.bat init        # 安装插件市场 (dshmarket)
echo 运行: whim-dsh.bat install_rp  # 从 nginx.org 下载 nginx（反向代理，供 start 使用）
echo 运行: whim-dsh.bat debug       # 前台启动服务（调试用）
echo 运行: whim-dsh.bat start       # 后台启动服务 + nginx 反向代理（PID 保存到 pid.txt）
echo 运行: whim-dsh.bat stop        # 停止后台服务（dsh 与反向代理）
echo 运行: whim-dsh.bat dsh         # 运行自定义 dsh 命令（不带参数则交互式输入）
goto :end

:init
call :init_market
goto :end

:install_rp
call :install_nginx
goto :end

:debug
call :debug_dsh
goto :end

:start
call :start_dsh
goto :end

:dsh
call :dsh_cmd %2 %3 %4 %5 %6 %7 %8 %9
goto :end

:stop
call :stop_dsh
call :stop_nginx
call :port_in_use
if not errorlevel 1 (
    echo 警告: 端口 %RP_PORT% 仍被占用，可能还有其他实例在运行:
    echo        netstat -ano ^| findstr %RP_PORT%
)
goto :end

:usage
echo 用法: whim-dsh.bat {install^|init^|install_rp^|debug^|start^|stop^|dsh}
echo   install     下载 Node.js 并安装 DeepSeek Harness 到本文件夹
echo   init        安装插件市场 (dshmarket)
echo   install_rp  从 nginx.org 下载 nginx（反向代理，供 start 使用）
echo   debug       前台启动 DeepSeek Harness Web UI（调试用，Ctrl+C 退出）
echo   start       后台启动 DeepSeek Harness，并启动 nginx 反向代理；
echo               之后打开 http://%RP_HOST%:%RP_PORT%/ 即可直接进入 dsh，无需 token
echo               域名/隧道访问: set PUBLIC_HOSTS=dsh.f.whim.win:8443 ^& whim-dsh.bat start
echo               脚本版本: %BAT_VERSION%
if defined PUBLIC_HOSTS echo               当前对外域名: !PUBLIC_HOSTS!  ^(来自 %PUBLIC_HOSTS_FILE%^)
echo   stop        停止后台运行的 dsh 与 nginx 反向代理
echo   dsh         运行自定义 dsh 命令（不带参数则交互式输入）
exit /b 1

:end
endlocal

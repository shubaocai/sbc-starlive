#!/usr/bin/env bash
# StarLive 一键部署脚本 · MIT License © 2026 鼠宝财
set -euo pipefail

TOOL_VERSION="1.0.0"
PROJECT_NAME="starlive"                    # 决定容器/卷名前缀
INSTALL_DIR="/opt/starlive"
WEB_PORT=3000
RTMP_PORT=1935
WEBRTC_PORT=8889
REPO_URL="https://github.com/SMNETSTUDIO/StarLive"
REPO_BRANCH="main"
WITH_RECORDING=0
USE_NPM_MIRROR=1
ADMIN_USER="admin"
ADMIN_PASS=""
ADMIN_CREATED=0
SITE_URL=""
GIT_PROXY=""
ASSUME_YES=0
ACTION="install"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi
step() { printf '\n%s▸ %s%s\n' "$C_BOLD$C_BLUE" "$*" "$C_RESET"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}StarLive（星播）一键部署脚本${C_RESET}  v${TOOL_VERSION}
自部署直播互动平台：弹幕 / 礼物 / 红包 / 抽奖 / 星币充值提现 + 主播工作台 + 管理后台

${C_BOLD}用法${C_RESET}
  bash install_starlive.sh [选项]

${C_BOLD}选项${C_RESET}
  --dir PATH         安装目录（默认 ${INSTALL_DIR}）
  --port N           网页/API/HLS 端口（默认 ${WEB_PORT}）
  --rtmp-port N      RTMP 推流端口（默认 ${RTMP_PORT}）
  --webrtc-port N    WebRTC 端口（默认 ${WEBRTC_PORT}）
  --url URL          站点对外地址，如 https://live.example.com（默认自动探测公网 IP）
  --git-proxy PFX    GitHub 加速前缀，如 --git-proxy https://ghfast.top/
                     （默认会依次尝试：官方源 → ghfast.top → gh-proxy.com → ghproxy.net）
  --admin-user NAME  自动创建的管理员账号（默认 ${ADMIN_USER}）
  --admin-pass PASS  自动创建的管理员密码（给了才会自动建号，否则首次访问网页向导建）
  --recording        同时部署录播/转码 Worker（FFmpeg，默认关闭）
  --no-mirror        构建时不使用 npmmirror 国内镜像源
  --upgrade          拉取上游最新代码、重新打补丁并重建（等同于再跑一次安装）
  --uninstall        卸载：删除容器、数据卷、镜像与安装目录（需配合 --yes 或交互确认）
  --yes              不询问，直接执行（用于 --uninstall）
  -h, --help         显示本帮助

${C_BOLD}脚本打的 5 个补丁（不改就功能不全，均为幂等）${C_RESET}
  1. infra/mediamtx.yml   api: no → yes（后端要靠它判断是否在推流）
  2. infra/mediamtx.yml   补 authMethod/authHTTPAddress（推流鉴权钩子，房间状态才会变 active）
  3. infra/mediamtx.yml   补 paths: all_others（否则推流被拒：path is not configured）
  4. infra/docker-compose.yml  Redis 端口绑到 127.0.0.1（上游默认把无密码 Redis 敞开公网）
  5. apps/server/src/main.ts   /hls 反代剥掉前缀（否则 HLS 一律 404，浏览器播不了）
     （附带：vite.config.ts 开发代理同样补 rewrite；Dockerfile 加国内 npm 源）

${C_BOLD}装完记得${C_RESET}
  安全组放行 ${WEB_PORT}（网页/API/HLS）与 ${RTMP_PORT}（OBS 推流），WebRTC 可选 ${WEBRTC_PORT}
  首次访问  http://<服务器IP>:${WEB_PORT}/  会进初始化向导创建管理员
  管理后台  http://<服务器IP>:${WEB_PORT}/admin
  OBS 推流  服务器 rtmp://<服务器IP>:${RTMP_PORT}   串流密钥 = 房间的 streamKey

${C_BOLD}示例${C_RESET}
  bash install_starlive.sh                                  # 默认 3000 端口
  bash install_starlive.sh --url https://live.example.com --admin-pass 'MyPass123'
  bash install_starlive.sh --port 8080 --recording           # 换端口 + 开录播
  bash install_starlive.sh --uninstall --yes                 # 彻底卸载
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)          INSTALL_DIR="${2:?}"; shift 2 ;;
    --port)         WEB_PORT="${2:?}"; shift 2 ;;
    --rtmp-port)    RTMP_PORT="${2:?}"; shift 2 ;;
    --webrtc-port)  WEBRTC_PORT="${2:?}"; shift 2 ;;
    --url)          SITE_URL="${2:?}"; shift 2 ;;
    --git-proxy)    GIT_PROXY="${2:?}"; shift 2 ;;
    --admin-user)   ADMIN_USER="${2:?}"; shift 2 ;;
    --admin-pass)   ADMIN_PASS="${2:?}"; shift 2 ;;
    --recording)    WITH_RECORDING=1; shift ;;
    --no-mirror)    USE_NPM_MIRROR=0; shift ;;
    --upgrade)      ACTION="upgrade"; shift ;;
    --uninstall)    ACTION="uninstall"; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              err "未知参数：$1"; echo; usage; exit 1 ;;
  esac
done

for n in "$WEB_PORT" "$RTMP_PORT" "$WEBRTC_PORT"; do
  case "$n" in ''|*[!0-9]*) die "端口必须是数字：$n" ;; esac
done

require_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash $0 ...）"; }

do_uninstall() {
  step "卸载 StarLive"
  info "将删除：容器与数据卷（含全部业务数据）、构建出的镜像、$INSTALL_DIR"
  if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      printf '  确认卸载？输入 yes 继续：'
      read -r ans
      [ "$ans" = "yes" ] || { info "已取消"; exit 0; }
    else
      die "非交互环境请加 --yes 确认卸载"
    fi
  fi
  if [ -d "$INSTALL_DIR/infra" ]; then
    ( cd "$INSTALL_DIR/infra" && docker compose -p "$PROJECT_NAME" down -v 2>/dev/null ) || true
  fi
  for img in "${PROJECT_NAME}-server" "${PROJECT_NAME}-worker" "infra-server" "infra-worker"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      docker ps -a --format '{{.Image}}' | grep -qx "$img" || docker rmi "$img" >/dev/null 2>&1 || true
    fi
  done
  for img in bluenviron/mediamtx:1.11.3 redis:7-alpine; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      docker ps -a --format '{{.Image}}' | grep -qx "$img" || docker rmi "$img" >/dev/null 2>&1 || true
    fi
  done
  docker network rm "${PROJECT_NAME}_default" >/dev/null 2>&1 || true
  rm -rf "$INSTALL_DIR"
  ok "已卸载（$INSTALL_DIR 与本项目容器/卷/镜像均已删除）"
  info "共享镜像 redis:7-alpine / mediamtx 若仍被其它容器引用则保留"
  exit 0
}

DC=""

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  else echo none; fi
}

ensure_base_pkgs() {
  step "检查基础依赖"
  local pm; pm="$(detect_pkg_mgr)"
  local need=()
  for c in curl git openssl python3; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
  if [ "${#need[@]}" -eq 0 ]; then ok "curl / git / openssl / python3 均已就绪"; return; fi
  info "需要安装：${need[*]}"
  [ "$pm" = none ] && die "找不到包管理器，请手动安装：${need[*]}"
  case "$pm" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1 || true
         apt-get install -y -qq "${need[@]}" >/dev/null || die "依赖安装失败" ;;
    dnf) dnf install -y -q "${need[@]}" >/dev/null || die "依赖安装失败" ;;
    yum) yum install -y -q "${need[@]}" >/dev/null || die "依赖安装失败" ;;
  esac
  ok "基础依赖安装完成"
}

setup_docker_registry_mirror() {
  [ -f /etc/docker/daemon.json ] && return
  if curl -s --max-time 3 http://metadata.tencentyun.com/latest/meta-data/ >/dev/null 2>&1; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
    info "已写入 Docker 镜像加速（腾讯云内网）"
  fi
}

ensure_docker() {
  step "检查 Docker"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker 已就绪：$(docker --version | cut -d, -f1)"
  else
    local pm; pm="$(detect_pkg_mgr)"
    [ "$pm" = none ] && die "请先安装 Docker：https://docs.docker.com/engine/install/"
    info "正在安装 Docker（自动探测可用软件源）…"
    case "$pm" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        local done_ok=0 m
        for m in "https://mirrors.tencentyun.com" "https://mirrors.cloud.tencent.com" \
                 "https://mirrors.aliyun.com" "https://mirrors.ustc.edu.cn" "https://deb.debian.org"; do
          info "尝试镜像源：$m"
          apt-get update -qq >/dev/null 2>&1 || true
          if apt-get install -y -qq docker.io >/dev/null 2>&1; then done_ok=1; break; fi
        done
        [ "$done_ok" -eq 1 ] || die "Docker 安装失败，请检查网络或手动安装"
        ;;
      dnf|yum)
        "$pm" install -y -q docker >/dev/null || die "Docker 安装失败"
        ;;
    esac
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker 安装完成：$(docker --version | cut -d, -f1)"
  fi

  setup_docker_registry_mirror
  systemctl start docker >/dev/null 2>&1 || true

  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    info "缺少 compose 插件，尝试安装…"
    local pm; pm="$(detect_pkg_mgr)"
    case "$pm" in
      apt) apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || apt-get install -y -qq docker-compose >/dev/null 2>&1 || true ;;
      dnf|yum) "$pm" install -y -q docker-compose-plugin >/dev/null 2>&1 || true ;;
    esac
    if docker compose version >/dev/null 2>&1; then DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
    else die "compose 不可用，请手动安装 docker-compose-plugin"; fi
  fi
  ok "compose 命令：$DC"
}

port_listening() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

check_ports() {
  step "检查端口占用"
  local bad=0 p
  for p in "$WEB_PORT" "$RTMP_PORT" "$WEBRTC_PORT"; do
    if port_listening "$p"; then
      if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "${PROJECT_NAME}-.*:${p}->"; then
        ok "端口 $p 由本项目容器占用，将继续复用"
      else
        err "端口 $p 已被其它程序占用：$(ss -ltnpH "sport = :$p" 2>/dev/null | head -1 | sed 's/  */ /g')"
        bad=1
      fi
    else
      ok "端口 $p 空闲"
    fi
  done
  [ "$bad" -eq 0 ] || die "请先释放端口，或用 --port / --rtmp-port / --webrtc-port 换端口"
}

fetch_repo() {
  step "获取源码"
  local ok_flag=1

  clone_from_sources() {
    local target="$1" err="" src
    local sources=()
    [ -n "$GIT_PROXY" ] && sources+=("${GIT_PROXY}${REPO_URL}")
    sources+=("$REPO_URL")
    sources+=("https://ghfast.top/${REPO_URL}" "https://gh-proxy.com/${REPO_URL}" "https://ghproxy.net/${REPO_URL}")
    for src in "${sources[@]}"; do
      rm -rf "$target"
      if timeout 90 git clone --depth 1 --branch "$REPO_BRANCH" "$src" "$target" >/tmp/.starlive-git.log 2>&1; then
        ok "已克隆（源：$(echo "$src" | cut -c1-40)…）"
        return 0
      fi
      err="$(tail -2 /tmp/.starlive-git.log | tr '\n' ' ' | cut -c1-140)"
      info "该源失败，换下一个：$err"
    done
    err "全部源码地址都失败，最后一个错误：$err"
    return 1
  }

  if [ -d "$INSTALL_DIR/.git" ]; then
    info "已存在仓库，尝试拉取最新代码…"
    if git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH" >/tmp/.starlive-git.log 2>&1 &&
       git -C "$INSTALL_DIR" reset --hard "origin/$REPO_BRANCH" >/dev/null 2>&1; then
      git -C "$INSTALL_DIR" clean -fd >/dev/null 2>&1 || true
      ok "已更新到 $(git -C "$INSTALL_DIR" log -1 --format='%h %ad' --date=short)"
    else
      warn "拉取失败（$(tail -1 /tmp/.starlive-git.log | cut -c1-120)），改为重新克隆（保留 .env）"
      local keep_env=""
      [ -f "$INSTALL_DIR/.env" ] && keep_env="$(mktemp)" && cp "$INSTALL_DIR/.env" "$keep_env"
      rm -rf "$INSTALL_DIR"
      clone_from_sources "$INSTALL_DIR" || die "源码获取失败"
      [ -n "$keep_env" ] && cp "$keep_env" "$INSTALL_DIR/.env" && rm -f "$keep_env" && info "已恢复原有 .env（JWT 密钥不变）"
    fi
  else
    [ -e "$INSTALL_DIR" ] && die "$INSTALL_DIR 已存在且不是 git 仓库，请先移走或删掉"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    clone_from_sources "$INSTALL_DIR" || die "源码获取失败"
    ok_flag=0
  fi
  rm -f /tmp/.starlive-git.log
  [ -f "$INSTALL_DIR/infra/docker-compose.yml" ] || die "仓库结构异常：找不到 infra/docker-compose.yml"
}

detect_site_url() {
  [ -n "$SITE_URL" ] && { echo "$SITE_URL"; return; }
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
    ip="$(curl -s -4 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')" || true
    case "$ip" in *[!0-9.]*|"") ip="" ;; *) break ;; esac
  done
  [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "http://${ip:-127.0.0.1}:${WEB_PORT}"
}

write_env() {
  step "生成 .env"
  local envf="$INSTALL_DIR/.env"
  local url; url="$(detect_site_url)"
  local secure="false"
  case "$url" in https://*) secure="true" ;; esac
  python3 - "$envf" "$url" "$secure" "$INSTALL_DIR" <<'PY'
import os, re, secrets, sys, pathlib
envf, url, secure, root = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
p = pathlib.Path(envf)
example = pathlib.Path(root, '.env.example')
text = p.read_text(encoding='utf-8') if p.exists() else example.read_text(encoding='utf-8')

m = re.search(r'^JWT_SECRET=(.+)$', text, flags=re.M)
secret = m.group(1).strip() if m and m.group(1).strip() not in ('', 'change-me-to-a-long-random-secret') else secrets.token_hex(32)

def setkv(t, k, v):
    if re.search(rf'^{k}=.*$', t, flags=re.M):
        return re.sub(rf'^{k}=.*$', f'{k}={v}', t, flags=re.M)
    return t.rstrip('\n') + f'\n{k}={v}\n'

text = setkv(text, 'NODE_ENV', 'production')
text = setkv(text, 'JWT_SECRET', secret)
text = setkv(text, 'APP_BASE_URL', url)
text = setkv(text, 'COOKIE_SECURE', secure)
text = setkv(text, 'STREAM_PROVIDER', 'selfhosted')
p.write_text(text, encoding='utf-8')
print(f'  .env 已写入：APP_BASE_URL={url}  COOKIE_SECURE={secure}  JWT_SECRET=…{secret[-6:]}（已复用/新生成）')
PY
  ok ".env 就绪"
}

apply_patches() {
  step "打补丁（上游配置/代码未接上的地方，幂等）"
  local color=0; [ -t 1 ] && color=1
  python3 - "$INSTALL_DIR" "$USE_NPM_MIRROR" "$WEB_PORT" "$RTMP_PORT" "$WEBRTC_PORT" "$color" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
mirror = sys.argv[2] == '1'
web, rtmp, rtc = sys.argv[3], sys.argv[4], sys.argv[5]
color = len(sys.argv) > 6 and sys.argv[6] == '1'
report = []

def patch(rel, rules, label):
    f = root / rel
    if not f.exists():
        report.append(('SKIP', label, f'{rel} 不存在'))
        return
    s = orig = f.read_text(encoding='utf-8')
    notes = []
    for kind, a, b, mark in rules:
        if mark and mark in s:
            continue
        if kind == 'replace':
            if a in s:
                s = s.replace(a, b, 1); notes.append('替换')
        elif kind == 'append':
            s = s.rstrip('\n') + '\n' + b; notes.append('追加')
    if s != orig:
        f.write_text(s, encoding='utf-8')
        report.append(('PATCH', label, '、'.join(notes) or '已修改'))
    else:
        report.append(('OK', label, '已是目标状态'))

patch('infra/mediamtx.yml', [
    ('replace', 'api: no', 'api: yes\napiAddress: :9997', 'apiAddress: :9997'),
    ('append', '', '# [install-starlive] auth\n'
                   'authMethod: http\nauthHTTPAddress: http://server:3000/api/stream/hook\nauthHTTPExclude: []',
     '# [install-starlive] auth'),
    ('append', '', '# [install-starlive] paths\n'
                   'paths:\n  all_others:',
     '# [install-starlive] paths'),
], 'mediamtx.yml：API / 鉴权钩子 / 通配路径')

compose_rules = [
    ('replace', '      - "6379:6379"', '      - "127.0.0.1:6379:6379"', '127.0.0.1:6379:6379'),
]
if web != '3000':
    compose_rules.append(('replace', '      - "3000:3000"', f'      - "{web}:3000"', f'"{web}:3000"'))
if rtmp != '1935':
    compose_rules.append(('replace', '      - "1935:1935" # RTMP 推流', f'      - "{rtmp}:1935" # RTMP 推流', f'"{rtmp}:1935"'))
if rtc != '8889':
    for old in ('      - "8889:8889" # WebRTC', '      - "8889:8889"', '      - "8889:8889/udp" # WebRTC'):
        compose_rules.append(('replace', old, old.replace('"8889:8889', f'"{rtc}:8889'), f'"{rtc}:8889'))
patch('infra/docker-compose.yml', compose_rules, 'docker-compose.yml：Redis 仅本机 + 端口')

patch('apps/server/src/main.ts', [
    ('replace', '        path: req.originalUrl,',
     '        path: req.originalUrl.replace(/^\\/hls/, "") || "/",',
     'replace(/^\\/hls/'),
], 'main.ts：/hls 反代剥前缀')

patch('apps/web/vite.config.ts', [
    ('replace', '''        "/hls": {
          target: env.HLS_PROXY_TARGET || "http://localhost:8888",
          changeOrigin: true,
        },''', '''        "/hls": {
          target: env.HLS_PROXY_TARGET || "http://localhost:8888",
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\\/hls/, ""),
        },''', 'rewrite: (p) => p.replace'),
], 'vite.config.ts：/hls 代理 rewrite')

if mirror:
    patch('apps/server/Dockerfile', [
        ('replace', 'RUN npm install -g pnpm@11.17.0',
         'RUN npm install -g pnpm@11.17.0 --registry=https://registry.npmmirror.com\n'
         'RUN pnpm config set registry https://registry.npmmirror.com',
         'registry.npmmirror.com'),
    ], 'Dockerfile：npm 国内源')
else:
    report.append(('SKIP', 'Dockerfile：npm 国内源', '按 --no-mirror 跳过'))

icon = {'PATCH': '\033[32m✓\033[0m', 'OK': '\033[2m=\033[0m', 'SKIP': '\033[33m-\033[0m'} if color \
       else {'PATCH': '✓', 'OK': '=', 'SKIP': '-'}
for kind, label, note in report:
    print(f'  {icon.get(kind, "?")} {label}  [{note}]')
PY
  if [ "$USE_NPM_MIRROR" -eq 1 ] && [ -f "$INSTALL_DIR/apps/worker/Dockerfile" ]; then
    if ! grep -q 'npmmirror' "$INSTALL_DIR/apps/worker/Dockerfile"; then
      python3 - "$INSTALL_DIR/apps/worker/Dockerfile" "$color" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding='utf-8')
mark = '\033[32m✓\033[0m' if len(sys.argv) > 2 and sys.argv[2] == '1' else '✓'
s2 = re.sub(r'(RUN npm install -g pnpm@[\d.]+)', r'\1 --registry=https://registry.npmmirror.com\nRUN pnpm config set registry https://registry.npmmirror.com', s, count=1)
if s2 != s:
    p.write_text(s2, encoding='utf-8'); print(f'  {mark} apps/worker/Dockerfile：npm 国内源  [替换]')
PY
    fi
  fi
  ok "补丁处理完毕"
}

compose_up() {
  step "构建并启动（首次要装依赖+编译，约 2~5 分钟）"
  local args=(up -d --build)
  [ "$WITH_RECORDING" -eq 1 ] && args=(--profile recording "${args[@]}")
  ( cd "$INSTALL_DIR/infra" && $DC -p "$PROJECT_NAME" "${args[@]}" ) 2>&1 | tail -12 | sed 's/^/  /'
  ok "容器已启动"
}

wait_health() {
  step "等待健康检查"
  local tries="${STARLIVE_HEALTH_TRIES:-45}" i code
  for i in $(seq 1 "$tries"); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${WEB_PORT}/api/health" || true)"
    if [ "$code" = "200" ]; then
      ok "服务已就绪：$(curl -s --max-time 3 "http://127.0.0.1:${WEB_PORT}/api/health")"
      return 0
    fi
    sleep 2
  done
  warn "健康检查超时，看日志排查：cd $INSTALL_DIR/infra && $DC -p $PROJECT_NAME logs --tail 50 server"
  return 1
}

create_admin() {
  [ -n "$ADMIN_PASS" ] || return 0
  step "创建管理员"
  local resp need
  resp="$(curl -s --max-time 5 "http://127.0.0.1:${WEB_PORT}/api/auth/setup-status" || true)"
  if [ -z "$resp" ]; then
    warn "服务尚未响应，跳过自动建号；等服务起来后首次访问网页向导，或重跑本脚本加 --admin-pass"
    return 0
  fi
  need="$(echo "$resp" | grep -o '"needsSetup":[a-z]*' | cut -d: -f2 || true)"
  if [ "$need" != "true" ]; then
    warn "已存在管理员，跳过自动建号（改密码请登录后在个人资料里改）"
    return 0
  fi
  resp="$(curl -s --max-time 10 -X POST -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" \
    "http://127.0.0.1:${WEB_PORT}/api/auth/setup" || true)"
  case "$resp" in *'"code":0'*) ok "管理员已创建：${ADMIN_USER}"; ADMIN_CREATED=1 ;;
                 *) warn "自动建号失败（可首次访问网页向导建）：${resp:0:160}" ;;
  esac
}

summary() {
  local url; url="$(detect_site_url)"
  echo
  printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"
  printf '%s StarLive 部署完成%s\n' "$C_BOLD$C_GREEN" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"
  printf '  访问地址   %s%s%s\n' "$C_BOLD" "$url" "$C_RESET"
  printf '  管理后台   %s/admin\n' "$url"
  if [ "$ADMIN_CREATED" -eq 1 ]; then
    printf '  管理员     %s / %s\n' "$ADMIN_USER" "$ADMIN_PASS"
  elif [ -n "$ADMIN_PASS" ]; then
    printf '  管理员     %s未自动创建成功%s（服务未就绪或已存在）—— 访问网页向导建，或重跑脚本加 --admin-pass\n' "$C_YELLOW" "$C_RESET"
  else
    printf '  管理员     %s首次访问网页会进初始化向导，自己设账号密码%s\n' "$C_YELLOW" "$C_RESET"
  fi
  printf '  OBS 推流   rtmp://<服务器IP>:%s    串流密钥 = 房间的 streamKey\n' "$RTMP_PORT"
  printf '  安装目录   %s（compose 项目名 %s）\n' "$INSTALL_DIR" "$PROJECT_NAME"
  echo
  printf '  %s必须放行的端口%s：%s（网页/API/HLS）、%s（RTMP 推流）' \
    "$C_BOLD$C_YELLOW" "$C_RESET" "$WEB_PORT" "$RTMP_PORT"
  [ "$WEBRTC_PORT" != "" ] && printf '，可选 %s（WebRTC）' "$WEBRTC_PORT"
  echo
  printf '  %s安全提醒%s\n' "$C_BOLD$C_YELLOW" "$C_RESET"
  printf '    · NODE_ENV=production，mock 支付网关默认关闭；正式收款请在后台配置真实网关\n'
  printf '    · Redis 已改为只绑 127.0.0.1；数据全在卷 %s_redis-data，请定期备份\n' "$PROJECT_NAME"
  printf '    · 公网使用建议加一层 HTTPS 反代（COOKIE_SECURE 会随 --url 是 https 自动置 true）\n'
  echo
  printf '  %s常用命令%s\n' "$C_BOLD" "$C_RESET"
  printf '    日志    cd %s/infra && %s -p %s logs -f server\n' "$INSTALL_DIR" "$DC" "$PROJECT_NAME"
  printf '    重启    cd %s/infra && %s -p %s restart\n' "$INSTALL_DIR" "$DC" "$PROJECT_NAME"
  printf '    备份    docker run --rm -v %s_redis-data:/d -v /root:/b alpine tar czf /b/redis-$(date +%%F).tar.gz -C /d .\n' "$PROJECT_NAME"
  printf '    升级    bash %s --upgrade\n' "$0"
  printf '    卸载    bash %s --uninstall --yes\n' "$0"
  echo
  printf '  %s上游项目 StarLive（Apache-2.0）· 本脚本 MIT © 2026 鼠宝财%s\n' "$C_DIM" "$C_RESET"
  echo
}

main() {
  [ "$ACTION" = "uninstall" ] && { require_root; do_uninstall; }
  require_root
  printf '\n%s StarLive（星播）一键部署%s  v%s\n' "$C_BOLD" "$C_RESET" "$TOOL_VERSION"
  info "安装目录：$INSTALL_DIR    网页端口：$WEB_PORT    RTMP：$RTMP_PORT"
  ensure_base_pkgs
  ensure_docker
  check_ports
  fetch_repo
  write_env
  apply_patches
  compose_up
  wait_health || true
  create_admin
  summary
}

main "$@"

#!/usr/bin/env bash
# AnyTLS 一键管理脚本（Production Stable Edition）
# 参考实现：https://github.com/anytls/anytls-go
# 设计目标：
# - 默认不自动升级：稳定跑为主，升级由菜单触发
# - 原子升级 + 失败回滚：避免半成品导致掉线
# - 配置持久化：避免靠解析 systemd 文件导出配置
# - systemd 自愈：服务异常自动重启，限制重启风暴
#
# 兼容：Debian/Ubuntu（apt）、CentOS/RHEL（yum/dnf）、Arch（pacman，尽力）
# 使用：bash anytls_manager_production.sh

set -euo pipefail

# -------------------- 全局配置 --------------------
SHELL_VERSION="2.0.0"
CONFIG_DIR="/etc/AnyTLS"
BIN_PATH="${CONFIG_DIR}/anytls-server"
ENV_FILE="${CONFIG_DIR}/anytls.env"
VERSION_FILE="${CONFIG_DIR}/version"
SERVICE_NAME="anytls.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LOCK_FILE="/var/lock/anytls_manager.lock"

# -------------------- 颜色输出 --------------------
Font="\033[0m"
Red="\033[31m"
Green="\033[32m"
Yellow="\033[33m"
Blue="\033[34m"
Purple="\033[35m"
Cyan="\033[36m"
BGreen="\033[1;32m"

print_info(){ echo -e "${Blue}[INFO]${Font} $*"; }
print_ok(){ echo -e "${Green}[ OK ]${Font} $*"; }
print_warn(){ echo -e "${Yellow}[WARN]${Font} $*"; }
print_error(){ echo -e "${Red}[ERR ]${Font} $*" 1>&2; }

# -------------------- 互斥锁（防止并发踩踏） --------------------
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
  exec 9>"$LOCK_FILE"
  if ! command -v flock >/dev/null 2>&1; then
    # 没有 flock 就退化为“尽量不并发”，不强制退出
    print_warn "系统未安装 flock，无法加锁（建议安装 util-linux）。"
    return 0
  fi
  if ! flock -n 9; then
    print_error "脚本正在运行中（锁：$LOCK_FILE），请稍后再试。"
    exit 1
  fi
}

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    print_error "请使用 root 运行（或 sudo）。"
    exit 1
  fi
}

# -------------------- 基础工具 --------------------
has_cmd(){ command -v "$1" >/dev/null 2>&1; }

detect_pkg_mgr() {
  if has_cmd apt-get; then echo "apt"
  elif has_cmd dnf; then echo "dnf"
  elif has_cmd yum; then echo "yum"
  elif has_cmd pacman; then echo "pacman"
  else echo "unknown"
  fi
}

install_deps() {
  local pm; pm="$(detect_pkg_mgr)"
  print_info "安装依赖（wget/curl/unzip/qrencode/ss）..."
  case "$pm" in
    apt)
      apt-get update -qq || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget curl unzip qrencode ca-certificates iproute2 >/dev/null 2>&1 || {
        print_warn "依赖安装可能未完全成功，请手动确认：wget curl unzip qrencode iproute2"
      }
      ;;
    dnf)
      dnf install -y -q wget curl unzip qrencode ca-certificates iproute >/dev/null 2>&1 || true
      ;;
    yum)
      yum install -y -q wget curl unzip qrencode ca-certificates iproute >/dev/null 2>&1 || true
      ;;
    pacman)
      pacman -Sy --noconfirm wget curl unzip qrencode ca-certificates iproute2 >/dev/null 2>&1 || true
      ;;
    *)
      print_warn "未知包管理器，跳过自动安装依赖。请确保已安装：wget/curl/unzip/qrencode/ss(iproute2)。"
      ;;
  esac
}

detect_arch() {
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)
      print_error "不支持的架构：$arch（仅支持 amd64/arm64）"
      return 1
      ;;
  esac
}

get_ip() {
  # 多源兜底：任何一个成功即可
  local ip=""
  ip="$(curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s4 --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="SERVER_IP"
  echo "$ip"
}

# -------------------- 版本获取：优先 API，失败回退 HTML 重定向 --------------------
get_latest_version() {
  local tag=""
  tag="$(curl -fsSL --max-time 8 https://api.github.com/repos/anytls/anytls-go/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  if [[ -n "$tag" ]]; then
    echo "$tag"; return 0
  fi
  # 回退：解析 releases/latest 的最终跳转 URL
  local final_url=""
  final_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 10 -L \
              https://github.com/anytls/anytls-go/releases/latest 2>/dev/null || true)"
  tag="${final_url##*/}"
  if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$tag"; return 0
  fi
  return 1
}

get_installed_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    cat "$VERSION_FILE" 2>/dev/null || true
  else
    echo ""
  fi
}

# -------------------- 配置持久化 --------------------
write_env() {
  local port="$1" pass="$2" sni="$3"
  mkdir -p "$CONFIG_DIR"
  cat > "$ENV_FILE" <<EOF
ANYTLS_PORT=${port}
ANYTLS_PASS=${pass}
ANYTLS_SNI=${sni}
EOF
  chmod 600 "$ENV_FILE"
}

read_env() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
  fi
  ANYTLS_PORT="${ANYTLS_PORT:-8443}"
  ANYTLS_PASS="${ANYTLS_PASS:-password}"
  ANYTLS_SNI="${ANYTLS_SNI:-}"
}

# -------------------- systemd --------------------
write_service() {
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/AnyTLS
EnvironmentFile=/etc/AnyTLS/anytls.env
ExecStart=/etc/AnyTLS/anytls-server -l 0.0.0.0:${ANYTLS_PORT} -p ${ANYTLS_PASS}
Restart=on-failure
RestartSec=3
# 限制重启风暴
StartLimitIntervalSec=60
StartLimitBurst=10
# 资源与安全（尽量选择老 systemd 也支持的项）
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

service_restart() {
  systemctl restart "$SERVICE_NAME"
}

service_start() {
  systemctl start "$SERVICE_NAME"
}

service_stop() {
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
}

service_status() {
  systemctl status "$SERVICE_NAME" --no-pager || true
}

health_check() {
  read_env
  if ! systemctl is-active --quiet "$SERVICE_NAME"; then
    print_error "服务未处于运行状态。"
    return 1
  fi
  if has_cmd ss; then
    if ! ss -lntp 2>/dev/null | grep -q ":${ANYTLS_PORT} "; then
      print_error "未检测到端口监听：${ANYTLS_PORT}"
      return 1
    fi
  fi
  print_ok "健康检查通过（active + 端口监听）"
  return 0
}

# -------------------- 下载/安装（原子替换 + 回滚） --------------------
download_release_zip() {
  local version="$1" arch="$2" out="$3"
  local ver_no_v="${version#v}"
  local url="https://github.com/anytls/anytls-go/releases/download/${version}/anytls_${ver_no_v}_linux_${arch}.zip"

  # 尽量稳：重试 + 超时
  if has_cmd curl; then
    curl -fL --retry 3 --retry-delay 1 --connect-timeout 6 --max-time 60 -o "$out" "$url"
  else
    wget -q --tries=3 --timeout=20 -O "$out" "$url"
  fi
}

install_version_atomically() {
  local version="$1"
  local arch; arch="$(detect_arch)"

  local tmpdir; tmpdir="$(mktemp -d)"
  local zip="${tmpdir}/anytls.zip"
  local bak=""
  trap 'rm -rf "$tmpdir"' RETURN

  print_info "下载 AnyTLS ${version}（${arch}）..."
  if ! download_release_zip "$version" "$arch" "$zip"; then
    print_error "下载失败：请检查服务器到 GitHub 的网络连通性。"
    return 1
  fi

  if ! unzip -qo "$zip" -d "$tmpdir"; then
    print_error "解压失败（zip 可能损坏）。"
    return 1
  fi

  if [[ ! -f "${tmpdir}/anytls-server" ]]; then
    print_error "压缩包内未找到 anytls-server"
    return 1
  fi

  chmod +x "${tmpdir}/anytls-server"

  mkdir -p "$CONFIG_DIR"

  # 备份旧二进制
  if [[ -f "$BIN_PATH" ]]; then
    bak="${BIN_PATH}.bak.$(date +%s)"
    cp -f "$BIN_PATH" "$bak"
  fi

  # 原子安装：install 会写到目标文件
  install -m 755 "${tmpdir}/anytls-server" "$BIN_PATH"

  # 若后续失败，调用方负责回滚（使用返回的 bak 路径）
  echo "$bak"
}

rollback_binary() {
  local bak="$1"
  if [[ -n "$bak" && -f "$bak" ]]; then
    cp -f "$bak" "$BIN_PATH"
    chmod +x "$BIN_PATH"
    print_warn "已回滚二进制：$bak -> $BIN_PATH"
  else
    print_warn "未找到可用备份，无法回滚。"
  fi
}

# -------------------- 安装/重装 --------------------
random_password() {
  # 32 位随机（只用安全字符）
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

choose_port() {
  local p
  while true; do
    read -rp "请输入监听端口（回车默认 8443）: " p
    p="${p:-8443}"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )); then
      echo "$p"; return 0
    fi
    print_warn "端口无效，请重试。"
  done
}

choose_sni() {
  # 生产优先：给个默认值，用户可改；不做花哨随机库（长期可控更重要）
  local sni
  read -rp "请输入 SNI（回车默认 learn.microsoft.com，可留空）: " sni
  sni="${sni:-learn.microsoft.com}"
  echo "$sni"
}

install_or_reinstall() {
  ensure_root
  acquire_lock
  install_deps

  local installed=""
  installed="$(get_installed_version)"
  if [[ -f "$BIN_PATH" || -f "$SERVICE_FILE" ]]; then
    print_warn "检测到已安装 AnyTLS（版本：${installed:-未知}）。"
    echo "1) 重装（重新下载二进制 + 可选改端口/密码/SNI）"
    echo "2) 仅修复 systemd/配置（不重新下载）"
    echo "0) 返回"
    read -rp "请选择 [0-2]: " c
    case "$c" in
      1) ;;
      2)
        read_env
        write_env "$ANYTLS_PORT" "$ANYTLS_PASS" "$ANYTLS_SNI"
        write_service
        service_restart || true
        health_check || true
        print_ok "修复完成。"
        return
        ;;
      0) return ;;
      *) print_warn "无效选择"; return ;;
    esac
  fi

  local latest
  if ! latest="$(get_latest_version)"; then
    print_error "获取最新版本失败（可能 GitHub API 限流/网络问题）。"
    print_error "为避免不稳定，本次安装已中止（不会改动现有服务）。"
    return 1
  fi

  local port pass sni
  port="$(choose_port)"
  read -rp "请输入密码（回车自动生成）: " pass
  pass="${pass:-$(random_password)}"
  sni="$(choose_sni)"

  print_info "将写入配置：port=${port}  pass=***  sni=${sni}"
  write_env "$port" "$pass" "$sni"

  # 写 service（先写好，再装二进制也行）
  write_service

  # 装二进制（原子）
  local bak
  bak="$(install_version_atomically "$latest")" || return 1

  # 启动服务
  if ! service_restart; then
    print_error "启动/重启失败，开始回滚..."
    rollback_binary "$bak"
    service_restart || true
    return 1
  fi

  if ! health_check; then
    print_error "健康检查失败，开始回滚..."
    rollback_binary "$bak"
    service_restart || true
    return 1
  fi

  echo "$latest" > "$VERSION_FILE"
  chmod 644 "$VERSION_FILE"

  print_ok "安装完成：${latest}"
  client_export
}

# -------------------- 检查更新/升级（由菜单触发） --------------------
check_update() {
  ensure_root
  acquire_lock

  if [[ ! -f "$BIN_PATH" || ! -f "$SERVICE_FILE" ]]; then
    print_error "未安装 AnyTLS，无法检查更新。"
    return 1
  fi

  local current latest
  current="$(get_installed_version)"
  if ! latest="$(get_latest_version)"; then
    print_error "获取最新版本失败（可能 GitHub API 限流/网络问题）。"
    return 1
  fi

  print_info "当前版本：${current:-未知}"
  print_info "最新版本：${latest}"

  if [[ -n "$current" && "$current" == "$latest" ]]; then
    print_ok "已是最新版本。"
    return 0
  fi

  echo "1) 立即升级到 ${latest}"
  echo "0) 返回"
  read -rp "请选择 [0-1]: " c
  [[ "$c" != "1" ]] && return 0

  # 升级：只换二进制，不动 anytls.env
  local bak
  print_info "开始升级（仅替换二进制，不改配置）..."
  bak="$(install_version_atomically "$latest")" || return 1

  if ! service_restart; then
    print_error "重启失败，开始回滚..."
    rollback_binary "$bak"
    service_restart || true
    return 1
  fi

  if ! health_check; then
    print_error "健康检查失败，开始回滚..."
    rollback_binary "$bak"
    service_restart || true
    return 1
  fi

  echo "$latest" > "$VERSION_FILE"
  chmod 644 "$VERSION_FILE"
  print_ok "升级成功：${current:-未知} -> ${latest}"
}

# -------------------- 导出（只保留 3 种格式：AnyTLS URI / Surge / Shadowrocket 手动） --------------------
client_export() {
  ensure_root
  read_env

  local ip name uri
  ip="$(get_ip)"
  name="AnyTLS_$(hostname)"

  uri="anytls://${ANYTLS_PASS}@${ip}:${ANYTLS_PORT}/?insecure=1"
  [[ -n "$ANYTLS_SNI" ]] && uri="${uri}&sni=${ANYTLS_SNI}"
  uri="${uri}#${name}"

  echo
  print_info "================= ① AnyTLS URI（Shadowrocket 可扫/可粘贴）================="
  echo "$uri"
  echo

  print_info "================= ② Surge 配置（复制到配置文件 [Proxy]）================="
  # Surge 文档：AnyTLS 基本格式：name = anytls, host, port, password=pwd
  # TLS 通用参数：skip-cert-verify / sni（可选）
  local surge_line
  surge_line="${name} = anytls, ${ip}, ${ANYTLS_PORT}, password=${ANYTLS_PASS}, skip-cert-verify=true"
  [[ -n "$ANYTLS_SNI" ]] && surge_line="${surge_line}, sni=${ANYTLS_SNI}"
  echo "[Proxy]"
  echo "$surge_line"
  echo

  print_info "================= ③ Shadowrocket 手动添加（最稳）================="
  echo "类型(Type): AnyTLS"
  echo "地址(Host): ${ip}"
  echo "端口(Port): ${ANYTLS_PORT}"
  echo "密码(Password): ${ANYTLS_PASS}"
  if [[ -n "$ANYTLS_SNI" ]]; then
    echo "SNI: ${ANYTLS_SNI}"
  else
    echo "SNI: （留空或用 Host）"
  fi
  echo "TLS 证书校验: 关闭/允许不安全（对应 insecure=1）"
  echo "备注(Remark): ${name}"
  echo

  if has_cmd qrencode; then
    print_info "二维码（AnyTLS URI）:"
    qrencode -t ANSIUTF8 "$uri"
  else
    print_warn "未安装 qrencode，无法生成二维码（可安装后再导出）。"
  fi
}

# -------------------- 启停/卸载 --------------------
restart_service() {
  ensure_root
  acquire_lock
  service_restart
  health_check || true
}

stop_service() {
  ensure_root
  acquire_lock
  service_stop
  print_ok "服务已停止。"
}

uninstall_anytls() {
  ensure_root
  acquire_lock
  read -rp "确认卸载 AnyTLS 并删除配置？(y/n): " yn
  [[ "$yn" != "y" ]] && { print_info "已取消。"; return; }

  service_stop
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload

  rm -rf "$CONFIG_DIR"

  print_ok "卸载完成。"
}

show_status() {
  ensure_root
  read_env
  echo
  print_info "版本：$(get_installed_version || true)"
  print_info "配置：port=${ANYTLS_PORT}  sni=${ANYTLS_SNI:-<empty>}"
  echo
  service_status
  echo
  if has_cmd ss; then
    ss -lntp | grep -E ":${ANYTLS_PORT}\s" || true
  fi
  echo
  print_info "最近日志（最后 80 行）："
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
}

# -------------------- 菜单 --------------------
show_menu() {
  clear
  echo -e "${BGreen}AnyTLS 一键管理面板（Production Stable）${Font} ${Cyan}v${SHELL_VERSION}${Font}"
  echo -e "---"
  echo -e "${Green}1.${Font} 安装 / 重装（默认不自动升级）"
  echo -e "${Green}2.${Font} 查看连接配置 / 节点二维码（3 种格式）"
  echo -e "${Yellow}3.${Font} 启动 / 重启服务"
  echo -e "${Yellow}4.${Font} 停止服务"
  echo -e "${Cyan}5.${Font} 检查更新 / 升级到最新版本（手动触发）"
  echo -e "${Purple}6.${Font} 状态与日志诊断"
  echo -e "${Red}7.${Font} 彻底卸载"
  echo -e "${Cyan}0.${Font} 退出"
  echo -e "---"
  echo -n "请选择 [0-7]: "
}

main() {
  while true; do
    show_menu
    read -r choice
    case "${choice:-}" in
      1) install_or_reinstall ;;
      2) client_export ;;
      3) restart_service ;;
      4) stop_service ;;
      5) check_update ;;
      6) show_status ;;
      7) uninstall_anytls ;;
      0) exit 0 ;;
      *) print_warn "无效输入，请重试。" ;;
    esac
    echo
    read -rp "按回车返回菜单..." _ || true
  done
}

main "$@"

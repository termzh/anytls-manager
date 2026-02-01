#!/usr/bin/env bash
# AnyTLS 一键管理脚本（稳定版 / 生产向）
# 官方参考实现: https://github.com/anytls/anytls-go
#
# 设计原则（围绕“长期稳定”）：
# - 默认不在“查看/重启/导出”等动作中做联网更新；升级必须用户显式选择
# - 下载/升级采用临时目录 + 原子替换 + 失败回滚，避免半成品导致服务掉线
# - 配置持久化到 /etc/AnyTLS/anytls.env，导出不再依赖解析 systemd 文本
# - systemd 采用自愈重启，并限制重启风暴
#
# 兼容：Debian/Ubuntu（apt）、RHEL/CentOS（yum/dnf）、Arch（pacman，尽力）
# 注意：脚本一次只执行一个菜单动作，执行完即结束（保持你原脚本习惯）

SHELL_VERSION="1.6.0-stable"

# --- 路径与服务名 ---
CONFIG_DIR="/etc/AnyTLS"
ENV_FILE="${CONFIG_DIR}/anytls.env"
VERSION_FILE="${CONFIG_DIR}/version"
ANYTLS_SERVER="${CONFIG_DIR}/anytls-server"
ANYTLS_SERVICE_NAME="anytls.service"
ANYTLS_SERVICE_FILE="/etc/systemd/system/${ANYTLS_SERVICE_NAME}"

# --- 颜色输出 ---
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

ensure_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    print_error "请使用 root 运行（或 sudo）。"
    exit 1
  fi
}

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
  print_info "安装依赖（wget/curl/unzip/qrencode/iproute2）..."
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

# --- 公网 IP（多源兜底；失败则返回占位符） ---
get_ip() {
  local ip=""
  ip="$(curl -s4 --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(curl -s4 --max-time 6 https://ifconfig.me 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="SERVER_IP"
  echo "$ip"
}

# --- 获取 latest tag：优先 GitHub API；失败回退到 releases/latest 跳转 ---
get_latest_version() {
  local tag=""
  tag="$(curl -fsSL --max-time 8 https://api.github.com/repos/anytls/anytls-go/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
  if [[ -n "$tag" ]]; then
    echo "$tag"; return 0
  fi
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

# --- 配置持久化（导出/诊断用，避免解析 systemd 文本） ---
write_env() {
  local port="$1" pass="$2" sni="$3"
  # 防御：确保 env 文件只有 KEY=VALUE，不包含换行/控制字符
  port="${port//$'
'/}"
  pass="${pass//$'
'/}"
  sni="${sni//$'
'/}"
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

# --- systemd service（使用“直写端口/密码”，避免变量替换差异导致端口失效） ---
write_service() {
  local port="$1" pass="$2" sni="$3"
  cat > "$ANYTLS_SERVICE_FILE" <<EOF
[Unit]
Description=AnyTLS Server (Cloaked: ${sni:-None})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${CONFIG_DIR}
ExecStart=${ANYTLS_SERVER} -l 0.0.0.0:${port} -p ${pass}
Restart=on-failure
RestartSec=3
StartLimitIntervalSec=60
StartLimitBurst=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true
}

health_check() {
  local port="$1"
  if ! systemctl is-active --quiet "$ANYTLS_SERVICE_NAME"; then
    print_error "服务未处于运行状态。"
    return 1
  fi
  if has_cmd ss; then
    if ! ss -lntp 2>/dev/null | grep -q ":${port} "; then
      print_error "未检测到端口监听：${port}"
      return 1
    fi
  fi
  return 0
}

# --- 下载 release zip（重试 + 超时）---
download_release_zip() {
  local version="$1" arch="$2" out="$3"
  local ver_no_v="${version#v}"
  local url="https://github.com/anytls/anytls-go/releases/download/${version}/anytls_${ver_no_v}_linux_${arch}.zip"
  if has_cmd curl; then
    curl -fL --retry 3 --retry-delay 1 --connect-timeout 6 --max-time 60 -o "$out" "$url"
  else
    wget -q --tries=3 --timeout=20 -O "$out" "$url"
  fi
}

# --- 原子安装/升级：返回备份路径（可能为空） ---
install_version_atomically() {
  local version="$1"
  local arch; arch="$(detect_arch)" || return 1

  local tmpdir; tmpdir="$(mktemp -d)"
  local zip="${tmpdir}/anytls.zip"
  local bak=""
  trap 'rm -rf "$tmpdir"' RETURN

  print_info "下载 AnyTLS ${version}（${arch}）..."
  download_release_zip "$version" "$arch" "$zip" || {
    print_error "下载失败：请检查服务器到 GitHub 的网络。"
    return 1
  }

  unzip -qo "$zip" -d "$tmpdir" || {
    print_error "解压失败（zip 可能损坏）。"
    return 1
  }

  [[ -f "${tmpdir}/anytls-server" ]] || {
    print_error "压缩包内未找到 anytls-server"
    return 1
  }

  chmod +x "${tmpdir}/anytls-server"
  mkdir -p "$CONFIG_DIR"

  if [[ -f "$ANYTLS_SERVER" ]]; then
    bak="${ANYTLS_SERVER}.bak.$(date +%s)"
    cp -f "$ANYTLS_SERVER" "$bak"
  fi

  install -m 755 "${tmpdir}/anytls-server" "$ANYTLS_SERVER"
  echo "$bak"
}

rollback_binary() {
  local bak="$1"
  if [[ -n "$bak" && -f "$bak" ]]; then
    cp -f "$bak" "$ANYTLS_SERVER"
    chmod +x "$ANYTLS_SERVER"
    print_warn "已回滚二进制。"
  else
    print_warn "无可用备份，无法回滚。"
  fi
}

random_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

choose_port() {
  local p
  while true; do
    read -rp "设置监听端口 (默认: 8443): " p
    p="${p:-8443}"
    if [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 )); then
      echo "$p"; return 0
    fi
    print_warn "端口无效，请重试。"
  done
}

# --- 精选伪装域（保留你原思路，但去掉“...”并保证稳定） ---
COMMON_SNI_LIST=(
  "learn.microsoft.com"
  "www.cloudflare.com"
  "developer.apple.com"
  "aws.amazon.com"
  "www.google.com"
  "www.wikipedia.org"
  "www.bing.com"
  "www.office.com"
  "www.github.com"
  "www.dropbox.com"
)

choose_sni() {
  # 重要：此函数会被命令替换捕获（final_sni="$(choose_sni)"）
  # 因此所有提示必须输出到 /dev/tty（或 stderr），仅把最终结果输出到 stdout。
  echo -e "
${Cyan}--- SNI 流量伪装配置 ---${Font}" > /dev/tty
  echo -e "1. 随机大厂域名 (推荐)" > /dev/tty
  echo -e "2. 手动自定义域名" > /dev/tty
  echo -e "3. 不使用伪装 (直连 IP)" > /dev/tty
  read -rp "请选择 [1-3] (默认 1): " sni_choice < /dev/tty
  sni_choice="${sni_choice:-1}"

  local final_sni=""
  case "$sni_choice" in
    1)
      final_sni="${COMMON_SNI_LIST[$RANDOM % ${#COMMON_SNI_LIST[@]}]}"
      echo -e "${Green}[ OK ]${Font} 已随机选择伪装名: ${final_sni}" > /dev/tty
      ;;
    2)
      read -rp "请输入您想伪装的域名: " final_sni < /dev/tty
      ;;
    3)
      final_sni=""
      ;;
    *)
      final_sni="${COMMON_SNI_LIST[$RANDOM % ${#COMMON_SNI_LIST[@]}]}"
      echo -e "${Green}[ OK ]${Font} 已随机选择伪装名: ${final_sni}" > /dev/tty
      ;;
  esac

  # 仅输出最终值（或空），供调用方捕获写入 env
  echo "$final_sni"
}

# --- 防火墙放行（尽量不误伤；失败不终止） ---
handle_firewall() {
  local port="$1"
  if has_cmd ufw; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if has_cmd firewall-cmd; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

# --- 导出（只保留：AnyTLS URI / Surge / Shadowrocket 手动） ---
client_export() {
  if [[ ! -f "$ANYTLS_SERVICE_FILE" ]]; then
    print_error "未检测到已安装的服务"
    return 1
  fi

  read_env

  local ip; ip="$(get_ip)"
  local name="AnyTLS_$(hostname)"

  local link="anytls://${ANYTLS_PASS}@${ip}:${ANYTLS_PORT}/?insecure=1"
  [[ -n "$ANYTLS_SNI" ]] && link="${link}&sni=${ANYTLS_SNI}"
  link="${link}#${name}"

  echo -e "\n${Purple}========== AnyTLS 节点配置输出 ==========${Font}"
  echo -e "${Cyan}[1] AnyTLS URI（Shadowrocket 可扫/可粘贴）${Font}"
  echo -e " ${Yellow}${link}${Font}\n"

  echo -e "${Cyan}[2] Surge 配置（复制到配置文件 [Proxy]）${Font}"
  local surge_line="${name} = anytls, ${ip}, ${ANYTLS_PORT}, password=${ANYTLS_PASS}, skip-cert-verify=true"
  [[ -n "$ANYTLS_SNI" ]] && surge_line="${surge_line}, sni=${ANYTLS_SNI}"
  echo -e " ${Yellow}[Proxy]${Font}"
  echo -e " ${Yellow}${surge_line}${Font}\n"

  echo -e "${Cyan}[3] Shadowrocket 手动添加（最稳）${Font}"
  echo -e " 类型(Type): AnyTLS"
  echo -e " 地址(Host): ${ip}"
  echo -e " 端口(Port): ${ANYTLS_PORT}"
  echo -e " 密码(Password): ${ANYTLS_PASS}"
  echo -e " SNI: ${ANYTLS_SNI:-（留空或用 Host）}"
  echo -e " TLS 证书校验: 关闭/允许不安全（对应 insecure=1）"
  echo -e " 备注(Remark): ${name}\n"

  if has_cmd qrencode; then
    echo -e "${Cyan}二维码 (AnyTLS URI):${Font}"
    qrencode -t ANSIUTF8 -m 1 "${link}"
  else
    print_warn "未安装 qrencode，无法生成二维码。"
  fi

  echo -e "${Purple}=========================================${Font}\n"
  return 0
}

# --- 安装/重装 ---
install_anytls() {
  ensure_root
  install_deps

  print_info "开始安装/重装 AnyTLS（脚本版本 v${SHELL_VERSION}）..."

  local latest
  if ! latest="$(get_latest_version)"; then
    print_error "获取最新版本失败（可能 GitHub API 限流/网络问题）。"
    print_error "为避免不稳定，本次安装已中止（不会更改现有服务）。"
    return 1
  fi

  echo -e "\n${Cyan}--- 基础参数配置 ---${Font}"
  local port; port="$(choose_port)"
  local pass
  read -rp "设置连接密码 (回车自动生成): " pass
  pass="${pass:-$(random_password)}"
  local final_sni; final_sni="$(choose_sni)"

  mkdir -p "$CONFIG_DIR"
  write_env "$port" "$pass" "$final_sni"

  # 安装二进制（原子）
  local bak
  bak="$(install_version_atomically "$latest")" || return 1

  # 写 systemd（直写端口/密码，避免变量替换差异）
  write_service "$port" "$pass" "$final_sni"

  handle_firewall "$port"

  # 启动/重启
  if systemctl restart "$ANYTLS_SERVICE_NAME"; then
    if health_check "$port"; then
      echo "$latest" > "$VERSION_FILE"
      chmod 644 "$VERSION_FILE"
      print_ok "AnyTLS 安装并启动成功（${latest}）！"
      client_export || true
      return 0
    fi
  fi

  print_error "启动或健康检查失败，开始回滚..."
  rollback_binary "$bak"
  systemctl restart "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true
  return 1
}

# --- 检查更新 / 升级（用户显式触发） ---
upgrade_anytls() {
  ensure_root
  install_deps

  if [[ ! -f "$ANYTLS_SERVICE_FILE" || ! -f "$ANYTLS_SERVER" ]]; then
    print_error "未检测到已安装 AnyTLS，无法升级。"
    return 1
  fi

  local current; current="$(get_installed_version)"
  local latest
  if ! latest="$(get_latest_version)"; then
    print_error "获取最新版本失败（可能 GitHub API 限流/网络问题）。"
    return 1
  fi

  print_info "当前版本：${current:-未知}"
  print_info "最新版本：${latest}"

  if [[ -n "$current" && "$current" == "$latest" ]]; then
    print_ok "已是最新版本，无需升级。"
    return 0
  fi

  read -rp "发现新版本 ${latest}，是否升级？(y/n): " yn
  [[ "$yn" != "y" ]] && { print_info "已取消升级。"; return 0; }

  read_env
  local port="${ANYTLS_PORT}"

  # 停服务 -> 替换二进制 -> 起服务 -> 健康检查 -> 失败回滚
  systemctl stop "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true

  local bak
  bak="$(install_version_atomically "$latest")" || {
    print_error "下载/安装失败，服务未改动（将尝试恢复启动）。"
    systemctl start "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true
    return 1
  }

  if systemctl start "$ANYTLS_SERVICE_NAME"; then
    if health_check "$port"; then
      echo "$latest" > "$VERSION_FILE"
      chmod 644 "$VERSION_FILE"
      print_ok "升级成功：${current:-未知} -> ${latest}"
      return 0
    fi
  fi

  print_error "升级后启动/健康检查失败，开始回滚..."
  rollback_binary "$bak"
  systemctl start "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true
  return 1
}

# --- 卸载（做完即退出，符合“一键卸载”直觉） ---
uninstall_anytls() {
  ensure_root
  read -rp "确认卸载 AnyTLS 并删除配置？(y/n): " yn
  [[ "$yn" != "y" ]] && { print_info "已取消。"; return 0; }

  systemctl disable "$ANYTLS_SERVICE_NAME" --now >/dev/null 2>&1 || true
  rm -f "$ANYTLS_SERVICE_FILE"
  rm -rf "$CONFIG_DIR"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 || true

  print_ok "AnyTLS 已成功卸载，配置已清理。"
  return 0
}

# --- 菜单界面（保持你原脚本：执行一个动作后退出） ---
show_menu() {
  clear
  echo -e "${BGreen}AnyTLS 一键管理面板（Stable）${Font} ${Cyan}v${SHELL_VERSION}${Font}"
  echo -e "---"
  echo -e "${Green}1.${Font} 安装 / 重装 AnyTLS"
  echo -e "${Green}2.${Font} 查看连接配置 / 节点二维码（Surge / Shadowrocket）"
  echo -e "${Yellow}3.${Font} 启动 / 重启 AnyTLS 服务"
  echo -e "${Yellow}4.${Font} 停止 AnyTLS 服务"
  echo -e "${Cyan}5.${Font} 检查更新 / 升级到最新版本（手动触发）"
  echo -e "${Red}6.${Font} 彻底卸载 AnyTLS"
  echo -e "${Cyan}0.${Font} 退出面板"
  echo -e "---"
  echo -n "请选择 [0-6]: "
}

ACTION="${1:-menu}"

case "$ACTION" in
  install) install_anytls ;;
  export) client_export ;;
  upgrade|update) upgrade_anytls ;;
  uninstall) uninstall_anytls ;;
  menu|*)
    while true; do
      show_menu
      read -r choice
      case "$choice" in
        1) install_anytls; break ;;
        2) client_export; break ;;
        3) systemctl restart "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 && print_ok "服务已重启" || print_error "重启失败"; break ;;
        4) systemctl stop "$ANYTLS_SERVICE_NAME" >/dev/null 2>&1 && print_ok "服务已停止" || print_error "停止失败"; break ;;
        5) upgrade_anytls; break ;;
        6) uninstall_anytls; break ;;
        0) exit 0 ;;
        *) print_error "无效选项"; sleep 1 ;;
      esac
    done
    ;;
esac

#!/usr/bin/env bash

umask 077

export LANG=en_US.UTF-8
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
cyan='\033[0;36m'
plain='\033[0m'
bold='\033[1m'

CONFIG_DIR="/etc/tofu"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DATA_FILE="${CONFIG_DIR}/node_info.env"
NODES_TXT="${CONFIG_DIR}/nodes.txt"
IPTABLES_SCRIPT="${CONFIG_DIR}/iptables.sh"
SYSTEM_STATE_FILE="${CONFIG_DIR}/system_state.tsv"
XRAY_BIN="/usr/local/bin/xray"
TOFU_BIN="/usr/local/bin/tofu"
SYSTEMD_FILE="/etc/systemd/system/tofu.service"
OPENRC_FILE="/etc/init.d/tofu"
FALLBACK_PID_FILE="/run/tofu.pid"

DEFAULT_REALITY_PORT=443
DEFAULT_HY2_PORT=8443
DEFAULT_XHTTP_PORT=2053
DEFAULT_HOP_PORTS="20000-50000"
TLS_SNI=""
DEFAULT_SNI_LIST=(
    "itunes.apple.com"
    "gateway.icloud.com"
    "swdist.apple.com"
    "updates.cdn-apple.com"
    "samsung.com"
    "api.onedrive.com"
    "speedtest.net"
    "addons.mozilla.org"
    "download.docker.com"
    "amazon.com"
)

info() { echo -e "${cyan}[信息]${plain} $1"; }
success() { echo -e "${green}[成功]${plain} $1"; }
warn() { echo -e "${yellow}[警告]${plain} $1"; }
error() { echo -e "${red}[错误]${plain} $1"; }

show_logo() {
    echo -e "${cyan}"
    cat <<'EOF'
 ████████╗ ██████╗ ███████╗██╗   ██╗
 ╚══██╔══╝██╔═══██╗██╔════╝██║   ██║
    ██║   ██║   ██║█████╗  ██║   ██║
    ██║   ██║   ██║██╔══╝  ██║   ██║
    ██║   ╚██████╔╝██║     ╚██████╔╝
    ╚═╝    ╚═════╝ ╚═╝      ╚═════╝ 

EOF
    printf '\033]8;;https://github.com/YGGYDW/ToFu\033\\https://github.com/YGGYDW/ToFu\033]8;;\033\\\n'
    echo -e "${plain}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 权限运行！请使用 sudo -i 或切换为 root 后再执行。"
        exit 1
    fi
}

check_arch() {
    local raw_arch
    raw_arch=$(uname -m)
    case "${raw_arch}" in
        x86_64 | amd64)
            ARCH="64"
            ARCH_NAME="amd64"
            ;;
        aarch64 | arm64)
            ARCH="arm64-v8a"
            ARCH_NAME="arm64"
            ;;
        *)
            error "目前不支持此 CPU 架构: ${raw_arch}"
            exit 1
            ;;
    esac
}

check_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS_TYPE="centos"
        PKG_MANAGER="yum"
    elif grep -qi "ubuntu" /etc/os-release; then
        OS_TYPE="ubuntu"
        PKG_MANAGER="apt-get"
    elif grep -qi "debian" /etc/os-release; then
        OS_TYPE="debian"
        PKG_MANAGER="apt-get"
    elif grep -qi "alpine" /etc/os-release; then
        OS_TYPE="alpine"
        PKG_MANAGER="apk"
    else
        error "未受支持的操作系统类型，仅支持 Debian/Ubuntu/CentOS/Rocky/Alma/Alpine。"
        exit 1
    fi
}

install_deps() {
    info "正在准备必要的系统依赖。"
    mkdir -p "$CONFIG_DIR"
    if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        record_new_packages curl wget tar unzip jq openssl iptables iproute2 qrencode python3
        run_package_task "更新软件包索引" apt-get update || return 1
        run_package_task "安装系统依赖" apt-get install -y curl wget tar unzip jq openssl iptables iproute2 qrencode python3 || return 1
    elif [[ "${PKG_MANAGER}" == "yum" ]]; then
        record_new_packages epel-release curl wget tar unzip jq openssl iptables iproute qrencode python3
        run_package_task "安装 EPEL 仓库" yum install -y epel-release || return 1
        run_package_task "安装系统依赖" yum install -y curl wget tar unzip jq openssl iptables iproute qrencode python3 || return 1
    elif [[ "${PKG_MANAGER}" == "apk" ]]; then
        record_new_packages curl wget tar unzip jq openssl iptables iproute2 bash python3
        run_package_task "更新软件包索引" apk update || return 1
        run_package_task "安装系统依赖" apk add --no-cache curl wget tar unzip jq openssl iptables iproute2 bash python3 || return 1
    fi
    success "基础依赖组件准备完毕。"
}

run_package_task() {
    local label=$1; shift
    local log_file fifo_file fifo_dir progress_pid status bar offset direction
    log_file=$(mktemp) || return 1
    if [[ "$1" == "apt-get" ]]; then
        shift
        fifo_dir=$(mktemp -d) || { rm -f "$log_file"; return 1; }
        fifo_file="${fifo_dir}/status"
        mkfifo "$fifo_file" || { rm -rf "$fifo_dir"; rm -f "$log_file"; return 1; }
        awk -F: '
            /^(dlstatus|pmstatus):/ && $3 ~ /^[0-9]+([.][0-9]+)?$/ {
                pct=$3+0; filled=int(pct/2+0.5); if (filled>50) filled=50
                eq=sprintf("%*s",filled,""); gsub(/ /,"=",eq)
                gap=26-filled; if (gap<0) gap=0
                pct_text=sprintf("%.1f%%",pct)
                tail=56-filled-gap-length(pct_text); if (tail<0) tail=0
                printf "\r%s [%s%*s%s%*s]", label, eq, gap, "", pct_text, tail, ""
                fflush()
            }
        ' label="$label" "$fifo_file" &
        progress_pid=$!
        DEBIAN_FRONTEND=noninteractive apt-get -o APT::Status-Fd=3 "$@" 3>"$fifo_file" >"$log_file" 2>&1
        status=$?
        wait "$progress_pid" 2>/dev/null || true
        rm -rf "$fifo_dir"
    else
        offset=0; direction=1
        "$@" >"$log_file" 2>&1 &
        progress_pid=$!
        while kill -0 "$progress_pid" 2>/dev/null; do
            sleep 0.15
            bar=""
            for ((i=0; i<50; i++)); do
                if (( i >= offset && i < offset + 9 )); then bar+="="; else bar+=" "; fi
            done
            printf "\r%s [%s处理中]" "$label" "$bar"
            ((offset+=direction))
            if (( offset >= 41 )); then direction=-1; elif (( offset <= 0 )); then direction=1; fi
        done
        wait "$progress_pid"; status=$?
    fi
    if [[ $status -eq 0 ]]; then
        printf "\r%s [==================================================100.0%%]\n" "$label"
    else
        printf "\n[错误] %s失败，简要诊断：\n" "$label"
        tail -n 12 "$log_file"
    fi
    rm -f "$log_file"
    return "$status"
}

render_curl_progress() {
    local label=$1
    tr '\r' '\n' | awk -v label="$label" '
        {
            if (match($0, /[0-9]+([.][0-9]+)?%/)) {
                pct_text = substr($0, RSTART, RLENGTH)
                sub(/%$/, "", pct_text)
                pct = pct_text + 0
                filled = int(pct / 2 + 0.5)
                if (filled > 50) filled = 50
                eq = sprintf("%*s", filled, "")
                gsub(/ /, "=", eq)
                pct_text = sprintf("%.1f%%", pct)
                printf "\r%s [%s%s]", label, eq, pct_text
                fflush()
            } else if ($0 ~ /^[#O= .\/-]+$/) {
                next
            } else if ($0 ~ /[^[:space:]]/) {
                print $0 > "/dev/stderr"
            }
        }
        END { printf "\n" }
    '
}

curl_with_progress() {
    local label=$1
    shift
    curl --fail --location --show-error --progress-bar --stderr >(render_curl_progress "$label") "$@"
}

record_new_packages() {
    local package
    local manifest="${CONFIG_DIR}/packages-installed.txt"
    touch "$manifest"
    for package in "$@"; do
        local installed=false
        case "$PKG_MANAGER" in
            apt-get) dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed && installed=true ;;
            yum) rpm -q "$package" >/dev/null 2>&1 && installed=true ;;
            apk) apk info -e "$package" >/dev/null 2>&1 && installed=true ;;
        esac
        if [[ "$installed" == false ]] && ! grep -Fxq "$package" "$manifest"; then
            printf '%s\n' "$package" >> "$manifest"
        fi
    done
    chmod 600 "$manifest"
}

remove_recorded_packages() {
    local manifest="${CONFIG_DIR}/packages-installed.txt"
    [[ -s "$manifest" ]] || return 0
    local -a packages=()
    mapfile -t packages < "$manifest"
    ((${#packages[@]})) || return 0
    info "卸载清单中的依赖包..."
    case "$PKG_MANAGER" in
        apt-get) run_package_task "卸载依赖包" apt-get remove -y "${packages[@]}" || warn "部分依赖包未能移除。" ;;
        yum) run_package_task "卸载依赖包" yum remove -y "${packages[@]}" || warn "部分依赖包未能移除。" ;;
        apk) run_package_task "卸载依赖包" apk del "${packages[@]}" || warn "部分依赖包未能移除。" ;;
    esac
}

enable_bbr() {
    info "正在检测并优化系统 TCP BBR 加速..."
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$SYSTEM_STATE_FILE" ]]; then
        printf 'tcp_congestion_control\t%s\ndefault_qdisc\t%s\n' \
            "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)" \
            "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)" > "$SYSTEM_STATE_FILE"
    fi
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        if [[ -e /etc/sysctl.d/99-tofu-bbr.conf ]]; then
            warn "发现已有 /etc/sysctl.d/99-tofu-bbr.conf，未覆盖该文件；请手动检查 BBR 设置。"
        else
            cat > /etc/sysctl.d/99-tofu-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
            touch "${CONFIG_DIR}/tofu_bbr_managed"
            sysctl --system >/dev/null 2>&1
        fi
    fi
    success "Linux TCP BBR 内核加速已启用！"
}

get_public_ip() {
    info "正在智能获取服务器公网 IP..."
    IP=$(curl -s4m5 "https://api.ipify.org" || curl -s4m5 "https://icanhazip.com" || curl -s4m5 "https://ip.sb")
    if [[ -z "${IP}" ]]; then
        IP=$(curl -s6m5 "https://api64.ipify.org" || curl -s6m5 "https://icanhazip.com")
        warn "未检测到有效 IPv4 地址，将以 IPv6 地址模式继续: ${IP}"
    else
        success "检测到公网 IPv4: ${IP}"
    fi
}

scan_port_status() {
    local port=$1
    local proto=${2:-"tcp"}
    local name=""
    if command -v ss >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            if ss -uln | grep -q ":${port} "; then
                name=$(ss -ulpn "sport = :${port}" 2>/dev/null | awk 'NR>1 {print $NF}' | cut -d'"' -f2 | head -n1)
                echo "${name:-占用}"
                return 1
            fi
        else
            if ss -tln | grep -q ":${port} "; then
                name=$(ss -tlpn "sport = :${port}" 2>/dev/null | awk 'NR>1 {print $NF}' | cut -d'"' -f2 | head -n1)
                echo "${name:-占用}"
                return 1
            fi
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            if netstat -uln | grep -q ":${port} "; then
                echo "占用"
                return 1
            fi
        else
            if netstat -tln | grep -q ":${port} "; then
                echo "占用"
                return 1
            fi
        fi
    fi
    echo "可用"
    return 0
}

scan_and_display_ports() {
    echo -e "${cyan}[端口]${plain} 检查以下端口开放状态:"
    local http_ports=(80 8080 8880 2052 2082 2086 2095)
    local https_ports=(443 2053 2083 2087 2096)
    local p status
    echo -e "  * 80系端口 (HTTP TCP) :"
    for p in "${http_ports[@]}"; do
        printf "	[检测 %s ...]" "$p"
        sleep 0.12
        status=$(scan_port_status "$p" "tcp")
        if [[ "$status" == "可用" ]]; then
            printf "[K	${green}[✔ %s]${plain}
" "$p"
        else
            printf "[K	${red}[✖ %s %s]${plain}
" "$p" "$status"
        fi
    done

    echo -e "  * 443系端口 (HTTPS TCP):"
    for p in "${https_ports[@]}"; do
        printf "	[检测 %s ...]" "$p"
        sleep 0.12
        status=$(scan_port_status "$p" "tcp")
        if [[ "$status" == "可用" ]]; then
            printf "[K	${green}[✔ %s]${plain}
" "$p"
        else
            printf "[K	${red}[✖ %s %s]${plain}
" "$p" "$status"
        fi
    done

    echo -e "  * Hysteria 2 主端口 (UDP):"
    local hy2_scan_port=${PORT_HY2:-8443}
    printf "	[检测 %s ...]" "$hy2_scan_port"
    sleep 0.12
    status=$(scan_port_status "$hy2_scan_port" "udp")
    if [[ "$status" == "可用" ]]; then
        printf "[K	${green}[✔ %s]${plain}
" "$hy2_scan_port"
    else
        printf "[K	${red}[✖ %s %s]${plain}
" "$hy2_scan_port" "$status"
    fi

    local udp_conflict_count=0
    if command -v ss >/dev/null 2>&1; then
        udp_conflict_count=$(ss -uln | awk '{print $5}' | awk -F: '{print $NF}' | awk '$1>=20000 && $1<=50000' | wc -l)
    fi
    if [[ "$udp_conflict_count" -eq 0 ]]; then
        echo -e "  * 端口跳跃段 (UDP) : 
	${green}[✔ 20000 ~ 50000] 未发现监听冲突 (共 30001 个端口)${plain}"
    else
        echo -e "  * 端口跳跃段 (UDP) : 
	${yellow}[⚠ 20000 ~ 50000] 检测到 ${udp_conflict_count} 个监听项${plain}"
    fi
}

configure_firewalls() {
    echo -e "${cyan}[信息]提示：请确保以上端口在 VPS 防火墙中开放服务。${plain}"
}

check_port_occupied() {
    local port=$1
    local proto=${2:-"tcp"}
    if command -v ss >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            ss -uln | grep -q ":${port} "
        else
            ss -tln | grep -q ":${port} "
        fi
        return $?
    elif command -v netstat >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            netstat -uln | grep -q ":${port} "
        else
            netstat -tln | grep -q ":${port} "
        fi
        return $?
    fi
    return 1
}

validate_hop_ports() {
    local list=$1 token start end
    local -a parts
    [[ -n "$list" && "$list" != ,* && "$list" != *, && "$list" != *,,* ]] || return 1
    IFS=',' read -ra parts <<< "$list"
    for token in "${parts[@]}"; do
        if [[ "$token" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
            start=$((10#${BASH_REMATCH[1]})); end=$((10#${BASH_REMATCH[2]}))
        elif [[ "$token" =~ ^[0-9]{1,5}$ ]]; then
            start=$((10#$token)); end=$start
        else
            return 1
        fi
        (( start >= 1025 && end >= start && end <= 65535 )) || return 1
    done
    return 0
}

check_hop_ports_available() {
    local list=$1 addr port token start end conflicts=0 shown=""
    local -a parts
    IFS=',' read -ra parts <<< "$list"
    if ! command -v ss >/dev/null 2>&1; then
        warn "系统没有 ss，无法检查 UDP 跳跃端口占用情况。"
        return 0
    fi
    while IFS= read -r addr; do
        port=${addr##*:}
        [[ "$port" =~ ^[0-9]+$ ]] || continue
        for token in "${parts[@]}"; do
            if [[ "$token" == *-* ]]; then start=$((10#${token%-*})); end=$((10#${token#*-})); else start=$((10#$token)); end=$start; fi
            if (( port >= start && port <= end )); then
                ((conflicts++))
                if (( conflicts <= 12 )); then shown+=" ${port}"; fi
                break
            fi
        done
    done < <(ss -H -lun | awk '{print $5}')
    if (( conflicts > 0 )); then
        warn "所选 UDP 跳跃端口中发现 ${conflicts} 个已监听端口（示例：${shown}）；请更换端口后重试。"
        return 1
    fi
    success "所选 UDP 跳跃端口未发现本机监听冲突。"
}

find_free_port() {
    local start_port=${1:-10000}
    local port=$start_port
    local tries=0
    while [[ $tries -lt 500 ]]; do
        if ! check_port_occupied "$port" "tcp" && ! check_port_occupied "$port" "udp"; then
            echo "$port"
            return 0
        fi
        ((port++))
        ((tries++))
        if [[ $port -gt 65000 ]]; then
            port=10000
        fi
    done
    echo "$start_port"
}

install_xray_core() {
    info "正在从 GitHub 获取 Xray-core 官方最新正式版..."
    [[ -z "${ARCH}" ]] && check_arch

    local latest_tag release_api
    release_api=$(mktemp) || return 1
    if ! curl -fLsS --connect-timeout 10 --max-time 60 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" -o "$release_api"; then
        error "无法读取 Xray 官方 Release API；已停止安装，未使用未验证的旧版本或第三方镜像。"
        rm -f "$release_api"
        return 1
    fi
    latest_tag=$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$release_api" 2>/dev/null) || latest_tag=""
    rm -f "$release_api"
    if [[ -z "$latest_tag" ]]; then
        error "官方版本号缺失或格式异常，已停止安装。"
        return 1
    fi

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${ARCH}.zip"
    info "下载地址: ${download_url}"

    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    echo -e "${cyan}[下载 1/2]${plain} 正在从 Xray 官方发布地址下载核心（显示 curl 实际传输进度）..."
    if ! curl_with_progress "下载 Xray 核心" --connect-timeout 10 --retry 2 --retry-delay 2 "${download_url}" -o "${tmp_dir}/xray.zip"; then
        error "官方核心包下载失败；已停止安装。"
        rm -rf "$tmp_dir"
        return 1
    fi
    echo -e "${cyan}[下载 2/2]${plain} 正在下载官方 SHA-256 校验文件..."
    if ! curl -fLsS --connect-timeout 10 --retry 2 --retry-delay 2 "${download_url}.dgst" -o "${tmp_dir}/xray.zip.dgst"; then
        error "官方校验文件下载失败；已停止安装。"
        rm -rf "$tmp_dir"
        return 1
    fi
    local expected_sha actual_sha
    expected_sha=$(awk -F '= ' '/256=/ {print $2; exit}' "${tmp_dir}/xray.zip.dgst" | tr -d '\r ')
    if [[ ! "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]]; then
        error "官方 SHA-256 文件格式无效；已停止安装。"
        rm -rf "$tmp_dir"
        return 1
    fi
    actual_sha=$(sha256sum "${tmp_dir}/xray.zip" | awk '{print $1}')
    if [[ "${actual_sha,,}" != "${expected_sha,,}" ]]; then
        error "Xray 核心包 SHA-256 校验失败；未替换现有核心。"
        rm -rf "$tmp_dir"
        return 1
    fi
    success "官方 SHA-256 校验通过。"

    if ! unzip -q -o "${tmp_dir}/xray.zip" -d "${tmp_dir}" || [[ ! -s "${tmp_dir}/xray" ]]; then
        error "解压 Xray 二进制失败！"
        rm -rf "${tmp_dir}"
        return 1
    fi
    if ! "${tmp_dir}/xray" version >/dev/null 2>&1; then
        error "下载的 Xray 二进制无法在本机运行（架构或文件格式不符）；未替换现有核心。"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p "${CONFIG_DIR}"
    mkdir -p "${CONFIG_DIR}/certs"
    chmod 700 "${CONFIG_DIR}" "${CONFIG_DIR}/certs"
    if [[ -e "${XRAY_BIN}" && ! -f "${CONFIG_DIR}/xray_managed" && ! -f "${CONFIG_DIR}/xray.original" ]]; then
        cp -p "${XRAY_BIN}" "${CONFIG_DIR}/xray.original" || { error "无法备份已有的 ${XRAY_BIN}，为避免覆盖现有服务而中止。"; rm -rf "$tmp_dir"; exit 1; }
    fi
    install -m 0755 "${tmp_dir}/xray" "${XRAY_BIN}.new" || { rm -rf "$tmp_dir"; return 1; }
    mv -f "${XRAY_BIN}.new" "${XRAY_BIN}" || { rm -f "${XRAY_BIN}.new"; rm -rf "$tmp_dir"; return 1; }
    touch "${CONFIG_DIR}/xray_managed"

    if [[ ! -d /usr/local/share/xray ]]; then
        mkdir -p /usr/local/share/xray
        touch "${CONFIG_DIR}/xray_share_dir_managed"
    fi
    if [[ -f "${tmp_dir}/geoip.dat" ]]; then
        install_managed_asset "${tmp_dir}/geoip.dat" /usr/local/share/xray/geoip.dat geoip_share
        install_managed_asset "${tmp_dir}/geoip.dat" /usr/local/bin/geoip.dat geoip_bin
    fi
    if [[ -f "${tmp_dir}/geosite.dat" ]]; then
        install_managed_asset "${tmp_dir}/geosite.dat" /usr/local/share/xray/geosite.dat geosite_share
        install_managed_asset "${tmp_dir}/geosite.dat" /usr/local/bin/geosite.dat geosite_bin
    fi

    rm -rf "${tmp_dir}"

    local installed_version
    installed_version=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    success "Xray 官方内核已成功就绪: Version ${installed_version}"
}

install_managed_asset() {
    local source=$1 destination=$2 name=$3 backup_dir="${CONFIG_DIR}/originals"
    mkdir -p "$(dirname "$destination")" "$backup_dir"
    if [[ -e "$destination" && ! -f "${CONFIG_DIR}/${name}.managed" && ! -e "${backup_dir}/${name}" ]]; then
        cp -p "$destination" "${backup_dir}/${name}" || { error "无法备份现有文件：${destination}"; return 1; }
    fi
    cp -f "$source" "$destination" || return 1
    touch "${CONFIG_DIR}/${name}.managed"
}

restore_managed_asset() {
    local destination=$1 name=$2 backup
    backup="${CONFIG_DIR}/originals/${name}"
    if [[ -e "$backup" ]]; then
        cp -p "$backup" "$destination"
    elif [[ -f "${CONFIG_DIR}/${name}.managed" ]]; then
        rm -f "$destination"
    fi
}

configure_hy2_custom_cert() {
    local set_idx=${1:-1}
    local cert_file="${CONFIG_DIR}/certs/hy2.crt"
    local key_file="${CONFIG_DIR}/certs/hy2.key"
    if [[ "$set_idx" -eq 2 ]]; then
        cert_file="${CONFIG_DIR}/certs/hy2_set2.crt"
        key_file="${CONFIG_DIR}/certs/hy2_set2.key"
    fi
    echo -e "${cyan}------------------------------------------------------------${plain}"
    echo -e "自备域名与证书配置方式："
    echo -e "  1. 手动指定现有证书与私钥路径 (已有 .crt / .key)"
    echo -e "  2. 使用 acme.sh 自动申请真实 SSL 证书 (需域名已解析到本机 IP)"
    echo -e "${cyan}------------------------------------------------------------${plain}"
    local c_choice domain path_crt path_key
    read -rp "请输入选项 [默认: 1]: " c_choice
    c_choice=${c_choice:-1}
    if [[ "$c_choice" == "2" ]]; then
        read -rp "请输入 Hysteria 2 绑定域名 (需已解析至 ${IP}): " domain
        domain=${domain,,}
        if ! command -v ~/.acme.sh/acme.sh >/dev/null 2>&1; then
            info "正在安装 acme.sh 工具..."
            curl -s https://get.acme.sh | sh -s email=tofu_admin@gmail.com >/dev/null 2>&1 || true
        fi
        if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
            ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
            info "正在通过 acme.sh 申请证书..."
            ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --force
            ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
                --key-file "$key_file" \
                --fullchain-file "$cert_file" >/dev/null 2>&1 || true
            chmod 600 "$key_file" "$cert_file" 2>/dev/null || true
        fi
        if [[ -f "$cert_file" && -f "$key_file" ]]; then
            success "证书配置成功！"
            if [[ "$set_idx" -eq 2 ]]; then HY2_DOMAIN_2="$domain"; else HY2_DOMAIN="$domain"; fi
            return 0
        fi
        warn "acme.sh 申请失败，切换为手动填写模式。"
    fi
    read -rp "请输入 Hysteria 2 绑定域名 (如 hy2.example.com): " domain
    domain=${domain,,}
    while true; do
        read -rp "请输入证书完整路径 (.crt/.pem): " path_crt
        if [[ -f "$path_crt" ]]; then break; else warn "文件不存在，请重新输入"; fi
    done
    while true; do
        read -rp "请输入私钥完整路径 (.key): " path_key
        if [[ -f "$path_key" ]]; then break; else warn "文件不存在，请重新输入"; fi
    done
    cp -f "$path_crt" "$cert_file"
    cp -f "$path_key" "$key_file"
    chmod 600 "$key_file" "$cert_file"
    if [[ "$set_idx" -eq 2 ]]; then HY2_DOMAIN_2="$domain"; else HY2_DOMAIN="$domain"; fi
    success "自备域名证书已就绪！"
}

configure_hy2_security() {
    local set_idx=${1:-1}
    echo -e "${cyan}------------------------------------------------------------${plain}"
    echo -e "请选择 Hysteria 2 安全与证书模式："
    echo -e "  1. 自签证书 + 跳过验证 (无需域名)"
    echo -e "  2. 自签证书 + pinSHA-256 指纹锁定 (无需域名)"
    echo -e "  3. 自备域名 + 真实 SSL 证书 (需已有域名)"
    echo -e "${cyan}------------------------------------------------------------${plain}"
    local h_choice
    read -rp "请输入选项 [默认: 1]: " h_choice
    h_choice=${h_choice:-1}
    if [[ "$set_idx" -eq 2 ]]; then
        HY2_MODE_2="$h_choice"
        HY2_DOMAIN_2=""
        HY2_PIN_SHA256_2=""
        if [[ "$h_choice" == "2" ]]; then
            HY2_PIN_SHA256_2="${CERT_SHA256_2:-$CERT_SHA256}"
        elif [[ "$h_choice" == "3" ]]; then
            configure_hy2_custom_cert 2
        fi
    else
        HY2_MODE="$h_choice"
        HY2_DOMAIN=""
        HY2_PIN_SHA256=""
        if [[ "$h_choice" == "2" ]]; then
            HY2_PIN_SHA256="$CERT_SHA256"
        elif [[ "$h_choice" == "3" ]]; then
            configure_hy2_custom_cert 1
        fi
    fi
}

probe_best_sni() {
    local choice sni
    echo -e "${cyan}============================================================${plain}"
    echo -e "请选择 REALITY 伪装域名 (SNI)："
    for i in "${!DEFAULT_SNI_LIST[@]}"; do
        printf "  %2d. %s
" "$((i+1))" "${DEFAULT_SNI_LIST[$i]}"
    done
    echo -e "------------------------------------------------------------"
    echo -e "输入序号 [1-10] 选择上方域名，直接回车默认选择第 1 个"
    echo -e "输入 m 手动填写自定义域名"
    echo -e "${cyan}============================================================${plain}"
    read -rp "请输入您的选择 [默认: 1]: " choice
    choice=${choice:-1}
    if [[ "$choice" == "m" || "$choice" == "M" ]]; then
        while true; do
            read -rp "请输入 REALITY SNI 域名: " sni
            if [[ "$sni" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
                REALITY_SNI="${sni,,}"
                break
            else
                warn "域名格式无效，请重新输入（如 itunes.apple.com）"
            fi
        done
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DEFAULT_SNI_LIST[@]} )); then
        REALITY_SNI="${DEFAULT_SNI_LIST[$((choice-1))]}"
    else
        warn "输入无效，已默认选择第 1 个: ${DEFAULT_SNI_LIST[0]}"
        REALITY_SNI="${DEFAULT_SNI_LIST[0]}"
    fi
    TLS_SNI="${REALITY_SNI}"
    success "已选择 REALITY SNI：${REALITY_SNI}"
}

generate_credentials() {
    local mode=${1:-"custom"}
    if [[ "$mode" == "custom" ]]; then
        info "正在配置节点 UUID..."
        while true; do
            echo "  1. 自动生成 UUID（推荐）"
            echo "  2. 手动填写 UUID"
            read -rp "请选择 [默认: 1]: " uuid_mode
            uuid_mode=${uuid_mode:-1}
            case "$uuid_mode" in
                1)
                    UUID=$("${XRAY_BIN}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
                    break
                    ;;
                2)
                    read -rp "请输入 UUID（格式 XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX）: " user_uuid
                    if [[ "$user_uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
                        UUID=${user_uuid,,}
                        break
                    fi
                    warn "UUID 格式无效，请按标准 UUID 格式重新输入。"
                    ;;
                *) warn "选择无效，请输入 1 或 2。" ;;
            esac
        done
    else
        UUID=$("${XRAY_BIN}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    fi

    info "正在生成 REALITY 密钥与 TLS 证书..."
    local key_pair
    key_pair=$("${XRAY_BIN}" x25519)
    REALITY_PRIVATE_KEY=$(echo "$key_pair" | grep -i "Private" | awk '{print $NF}')
    REALITY_PUBLIC_KEY=$(echo "$key_pair" | grep -i "Public" | awk '{print $NF}')
    REALITY_SHORT_ID=$(openssl rand -hex 4)

    info "正在生成 ECC P-256 自签名安全证书 (符合标准 SAN)..."
    mkdir -p "${CONFIG_DIR}/certs"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "${CONFIG_DIR}/certs/ecc.key" \
        -out "${CONFIG_DIR}/certs/ecc.crt" \
        -subj "/CN=${TLS_SNI}" -days 3650 \
        -addext "subjectAltName=DNS:${TLS_SNI}" >/dev/null 2>&1
    chmod 600 "${CONFIG_DIR}/certs/ecc.key" "${CONFIG_DIR}/certs/ecc.crt"

    CERT_SHA256=$(openssl x509 -noout -fingerprint -sha256 -in "${CONFIG_DIR}/certs/ecc.crt" | cut -d'=' -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')

    if [[ "$mode" == "custom" ]]; then
        configure_hy2_security 1
    else
        HY2_MODE=1
        HY2_DOMAIN=""
        HY2_PIN_SHA256=""
    fi
    success "凭证与证书生成完毕。"
}

setup_iptables_port_hopping() {
    info "正在配置 Hysteria 2 端口跳跃转发规则 (${PORT_HOP_PORTS} -> ${PORT_HY2})..."
    cat > "${IPTABLES_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
CONFIG_DIR="/etc/tofu"
DATA_FILE="${CONFIG_DIR}/data.env"

ACTION=$1
TARGET_PORT=$2
PORT_LIST=$3

apply_redirect() {
    local tport=$1
    local plist=$2
    [[ -z "$tport" || -z "$plist" ]] && return 0
    local IFS=','
    read -ra PORTS <<< "$plist"
    for PORT_SPEC in "${PORTS[@]}"; do
        PORT_SPEC=${PORT_SPEC/-/:}
        iptables -t nat -C PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || \
            iptables -t nat -A PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" || true
        ip6tables -t nat -C PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || \
            ip6tables -t nat -A PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || true
    done
}

flush_redirect() {
    local tport=$1
    local plist=$2
    if [[ -n "$tport" && -n "$plist" ]]; then
        local IFS=','
        read -ra PORTS <<< "$plist"
        for PORT_SPEC in "${PORTS[@]}"; do
            PORT_SPEC=${PORT_SPEC/-/:}
            while iptables -t nat -D PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null; do :; done
            while ip6tables -t nat -D PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null; do :; done
        done
    else
        while iptables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT 2>/dev/null; do :; done
        while iptables -t nat -D PREROUTING -p udp --dport 20000:35000 -j REDIRECT 2>/dev/null; do :; done
        while iptables -t nat -D PREROUTING -p udp --dport 35001:50000 -j REDIRECT 2>/dev/null; do :; done
        while ip6tables -t nat -D PREROUTING -p udp --dport 20000:50000 -j REDIRECT 2>/dev/null; do :; done
        while ip6tables -t nat -D PREROUTING -p udp --dport 20000:35000 -j REDIRECT 2>/dev/null; do :; done
        while ip6tables -t nat -D PREROUTING -p udp --dport 35001:50000 -j REDIRECT 2>/dev/null; do :; done
    fi
}

case "$ACTION" in
    apply)
        if [[ -f "$DATA_FILE" ]]; then
            source "$DATA_FILE"
            apply_redirect "${PORT_HY2}" "${PORT_HOP_PORTS}"
            if [[ "${NODE_SET_COUNT}" == "2" && -n "${PORT_HY2_2}" && -n "${PORT_HOP_PORTS_2}" ]]; then
                apply_redirect "${PORT_HY2_2}" "${PORT_HOP_PORTS_2}"
            fi
        fi
        ;;
    flush)
        if [[ -f "$DATA_FILE" ]]; then
            source "$DATA_FILE"
            flush_redirect "${PORT_HY2}" "${PORT_HOP_PORTS}"
            if [[ -n "${PORT_HY2_2}" && -n "${PORT_HOP_PORTS_2}" ]]; then
                flush_redirect "${PORT_HY2_2}" "${PORT_HOP_PORTS_2}"
            fi
        fi
        flush_redirect
        ;;
    enable)
        apply_redirect "$TARGET_PORT" "$PORT_LIST"
        ;;
    disable)
        flush_redirect "$TARGET_PORT" "$PORT_LIST"
        ;;
    *)
        echo "Usage: $0 {apply|flush|enable <port> <range>|disable <port> <range>}"
        exit 1
        ;;
esac
EOF
    chmod +x "${IPTABLES_SCRIPT}"
    /bin/bash "${IPTABLES_SCRIPT}" apply
    success "Hysteria 2 端口跳跃内核级 NAT 转发已就绪！"
}

generate_server_config() {
    info "正在合成服务端主配置文件 (${CONFIG_FILE})..."
    local hy2_cert="${CONFIG_DIR}/certs/ecc.crt"
    local hy2_key="${CONFIG_DIR}/certs/ecc.key"
    if [[ "$HY2_MODE" == "3" && -f "${CONFIG_DIR}/certs/hy2.crt" && -f "${CONFIG_DIR}/certs/hy2.key" ]]; then
        hy2_cert="${CONFIG_DIR}/certs/hy2.crt"
        hy2_key="${CONFIG_DIR}/certs/hy2.key"
    fi

    local set2_inbounds=""
    local xhttp_routing_inbounds='"vless-xhttp"'
    if [[ "${NODE_SET_COUNT}" == "2" && -n "${PORT_REALITY_2}" ]]; then
        local hy2_cert_2="${CONFIG_DIR}/certs/ecc.crt"
        local hy2_key_2="${CONFIG_DIR}/certs/ecc.key"
        if [[ "$HY2_MODE_2" == "3" && -f "${CONFIG_DIR}/certs/hy2_set2.crt" && -f "${CONFIG_DIR}/certs/hy2_set2.key" ]]; then
            hy2_cert_2="${CONFIG_DIR}/certs/hy2_set2.crt"
            hy2_key_2="${CONFIG_DIR}/certs/hy2_set2.key"
        fi
        xhttp_routing_inbounds='"vless-xhttp", "vless-xhttp-2"'
        set2_inbounds=$(cat <<SET2_EOF
,
    {
      "tag": "vless-reality-2",
      "listen": "::",
      "port": ${PORT_REALITY_2},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_2}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SNI_2}:443",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI_2}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY_2}",
          "shortIds": [
            "${REALITY_SHORT_ID_2}"
          ],
          "spiderX": "/"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "hysteria2-2",
      "listen": "::",
      "port": ${PORT_HY2_2},
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${UUID_2}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "${hy2_cert_2}",
              "keyFile": "${hy2_key_2}"
            }
          ]
        }
      }
    },
    {
      "tag": "vless-xhttp-2",
      "listen": "::",
      "port": ${PORT_XHTTP_2},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_2}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "path": "/xraybox2-${UUID_2}",
          "mode": "auto"
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${CONFIG_DIR}/certs/ecc.crt",
              "keyFile": "${CONFIG_DIR}/certs/ecc.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
SET2_EOF
)
    fi

    cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "::",
      "port": ${PORT_REALITY},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_SNI}:443",
          "xver": 0,
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${REALITY_SHORT_ID}"
          ],
          "spiderX": "/"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "hysteria2",
      "listen": "::",
      "port": ${PORT_HY2},
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "clients": [
          {
            "auth": "${UUID}"
          }
        ]
      },
      "streamSettings": {
        "network": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["h3"],
          "certificates": [
            {
              "certificateFile": "${hy2_cert}",
              "keyFile": "${hy2_key}"
            }
          ]
        }
      }
    },
    {
      "tag": "vless-xhttp",
      "listen": "::",
      "port": ${PORT_XHTTP},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "xhttpSettings": {
          "path": "/xraybox-${UUID}",
          "mode": "auto"
        },
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${CONFIG_DIR}/certs/ecc.crt",
              "keyFile": "${CONFIG_DIR}/certs/ecc.key"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }${set2_inbounds}
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    },
    {
      "tag": "warp-socks",
      "protocol": "socks",
      "settings": {
        "servers": [
          {
            "address": "127.0.0.1",
            "port": 40000
          }
        ]
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          ${xhttp_routing_inbounds}
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
EOF

    chmod 600 "${CONFIG_FILE}"
    info "执行 Xray 配置文件严格语法检查..."
    if ! "${XRAY_BIN}" -test -config "${CONFIG_FILE}" >/dev/null 2>&1; then
        error "配置文件检查未通过！详细日志如下："
        "${XRAY_BIN}" -test -config "${CONFIG_FILE}"
        exit 1
    fi
    success "Xray 配置文件检查通过。"
}

setup_system_service() {
    info "正在配置后台守护进程服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        cat > "${SYSTEMD_FILE}" <<EOF
[Unit]
Description=ToFu Anti-Censorship Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStartPre=-/bin/bash ${IPTABLES_SCRIPT} apply
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
ExecStopPost=-/bin/bash ${IPTABLES_SCRIPT} flush
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tofu >/dev/null 2>&1
        systemctl restart tofu
    elif command -v rc-service >/dev/null 2>&1 || [[ -f /etc/init.d/cron ]]; then
        cat > "${OPENRC_FILE}" <<EOF
#!/sbin/openrc-run
description="ToFu Service"
command="${XRAY_BIN}"
command_args="run -config ${CONFIG_FILE}"
pidfile="/run/tofu.pid"
command_background="yes"

start_pre() {
    /bin/bash ${IPTABLES_SCRIPT} apply
}

stop_post() {
    /bin/bash ${IPTABLES_SCRIPT} flush
}
EOF
        chmod +x "${OPENRC_FILE}"
        rc-update add tofu default >/dev/null 2>&1
        rc-service tofu restart
    else
        start_fallback_service
    fi
    success "ToFu 后台守护进程启动成功！"
}

start_fallback_service() {
    if [[ -f "$FALLBACK_PID_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$FALLBACK_PID_FILE" 2>/dev/null)
        if is_tofu_fallback_pid "$old_pid"; then
            kill -0 "$old_pid" 2>/dev/null && { info "ToFu 已在运行（PID ${old_pid}）。"; return 0; }
        fi
        rm -f "$FALLBACK_PID_FILE"
    fi
    nohup "${XRAY_BIN}" run -config "${CONFIG_FILE}" >/dev/null 2>&1 &
    echo $! > "$FALLBACK_PID_FILE"
    sleep 1
    kill -0 "$(cat "$FALLBACK_PID_FILE")" 2>/dev/null || { rm -f "$FALLBACK_PID_FILE"; error "ToFu 启动失败。"; return 1; }
}

is_tofu_fallback_pid() {
    local pid=$1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$(readlink -f "/proc/${pid}/exe" 2>/dev/null)" == "$(readlink -f "$XRAY_BIN")" ]] || return 1
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null | grep -Fq -- "$CONFIG_FILE"
}

stop_fallback_service() {
    [[ -f "$FALLBACK_PID_FILE" ]] || return 0
    local pid
    pid=$(cat "$FALLBACK_PID_FILE" 2>/dev/null)
    if is_tofu_fallback_pid "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in {1..10}; do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -f "$FALLBACK_PID_FILE"
}

save_env_data() {
    cat > "${DATA_FILE}" <<EOF
NODE_SET_COUNT=${NODE_SET_COUNT:-1}
IP="${IP}"
UUID="${UUID}"
PORT_REALITY=${PORT_REALITY}
PORT_HY2=${PORT_HY2}
PORT_XHTTP=${PORT_XHTTP}
PORT_HOP_PORTS="${PORT_HOP_PORTS}"
REALITY_SNI="${REALITY_SNI}"
TLS_SNI="${TLS_SNI}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY}"
REALITY_SHORT_ID="${REALITY_SHORT_ID}"
CERT_SHA256="${CERT_SHA256}"
HY2_MODE="${HY2_MODE:-1}"
HY2_DOMAIN="${HY2_DOMAIN}"
HY2_PIN_SHA256="${HY2_PIN_SHA256}"
UUID_2="${UUID_2}"
PORT_REALITY_2=${PORT_REALITY_2}
PORT_HY2_2=${PORT_HY2_2}
PORT_XHTTP_2=${PORT_XHTTP_2}
PORT_HOP_PORTS_2="${PORT_HOP_PORTS_2}"
REALITY_SNI_2="${REALITY_SNI_2}"
TLS_SNI_2="${TLS_SNI_2}"
REALITY_PUBLIC_KEY_2="${REALITY_PUBLIC_KEY_2}"
REALITY_PRIVATE_KEY_2="${REALITY_PRIVATE_KEY_2}"
REALITY_SHORT_ID_2="${REALITY_SHORT_ID_2}"
CERT_SHA256_2="${CERT_SHA256_2}"
HY2_MODE_2="${HY2_MODE_2:-1}"
HY2_DOMAIN_2="${HY2_DOMAIN_2}"
HY2_PIN_SHA256_2="${HY2_PIN_SHA256_2}"
EOF
    chmod 600 "$DATA_FILE"
}

load_env_data() {
    local env_file="$DATA_FILE" line key value
    PORT_REALITY=${PORT_REALITY:-$DEFAULT_REALITY_PORT}
    PORT_HY2=${PORT_HY2:-$DEFAULT_HY2_PORT}
    PORT_XHTTP=${PORT_XHTTP:-$DEFAULT_XHTTP_PORT}
    PORT_HOP_PORTS=${PORT_HOP_PORTS:-$DEFAULT_HOP_PORTS}
    NODE_SET_COUNT=${NODE_SET_COUNT:-1}
    [[ -f "$env_file" ]] || return 0
    chmod 700 "$CONFIG_DIR" 2>/dev/null || true
    chmod 600 "$env_file" "$CONFIG_FILE" "${CONFIG_DIR}/certs/ecc.key" "$NODES_TXT" 2>/dev/null || true
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key=${line%%=*}
        value=${line#*=}
        value=${value#\"}
        value=${value%\"}
        case "$key" in
            NODE_SET_COUNT) [[ "$value" =~ ^[12]$ ]] && NODE_SET_COUNT=$value ;;
            IP) [[ "$value" =~ ^[A-Fa-f0-9:.]+$ ]] && IP=$value ;;
            UUID|UUID_2) [[ "$value" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] && printf -v "$key" '%s' "${value,,}" ;;
            PORT_REALITY|PORT_HY2|PORT_XHTTP|PORT_REALITY_2|PORT_HY2_2|PORT_XHTTP_2)
                if [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( value >= 1 && value <= 65535 )); then printf -v "$key" '%s' "$value"; fi
                ;;
            PORT_HOP_PORTS|PORT_HOP_PORTS_2) [[ "$value" =~ ^[0-9,-]+$ ]] && printf -v "$key" '%s' "$value" ;;
            REALITY_SNI|TLS_SNI|REALITY_SNI_2|TLS_SNI_2|HY2_DOMAIN|HY2_DOMAIN_2)
                if [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then printf -v "$key" '%s' "${value,,}"; fi
                ;;
            REALITY_PUBLIC_KEY|REALITY_PUBLIC_KEY_2|REALITY_PRIVATE_KEY|REALITY_PRIVATE_KEY_2)
                [[ "$value" =~ ^[A-Za-z0-9_+/=-]+$ ]] && printf -v "$key" '%s' "$value"
                ;;
            REALITY_SHORT_ID|REALITY_SHORT_ID_2)
                [[ "$value" =~ ^[[:xdigit:]]{8,16}$ ]] && printf -v "$key" '%s' "$value"
                ;;
            CERT_SHA256|CERT_SHA256_2|HY2_PIN_SHA256|HY2_PIN_SHA256_2)
                [[ "$value" =~ ^[[:xdigit:]]{64}$ ]] && printf -v "$key" '%s' "${value,,}"
                ;;
            HY2_MODE|HY2_MODE_2)
                [[ "$value" =~ ^[123]$ ]] && printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$env_file"
}

generate_client_links() {
    local host_ip="${IP}"
    if [[ "${IP}" =~ : ]]; then
        host_ip="[${IP}]"
    fi

    local fragment_reality fragment_hy2 fragment_xhttp
    fragment_reality=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="-._~"))' 'REALITY-VLESS+XTLS-Vision-（主力节点）')
    fragment_hy2=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="-._~"))' 'Hysteria 2-（UDP端口跳跃）')
    fragment_xhttp=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="-._~"))' 'XHTTP-VLESS+TLS-(可套CDN+WARP)')
    LINK_REALITY="vless://${UUID}@${host_ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${fragment_reality}"

    if [[ "$HY2_MODE" == "2" ]]; then
        LINK_HY2="hysteria2://${UUID}@${host_ip}:${PORT_HY2}?mport=${PORT_HOP_PORTS//,/%2C}&security=tls&alpn=h3&insecure=1&pinSHA256=${HY2_PIN_SHA256}&sni=${TLS_SNI}#${fragment_hy2}"
    elif [[ "$HY2_MODE" == "3" && -n "$HY2_DOMAIN" ]]; then
        LINK_HY2="hysteria2://${UUID}@${HY2_DOMAIN}:${PORT_HY2}?mport=${PORT_HOP_PORTS//,/%2C}&security=tls&alpn=h3&sni=${HY2_DOMAIN}#${fragment_hy2}"
    else
        LINK_HY2="hysteria2://${UUID}@${host_ip}:${PORT_HY2}?mport=${PORT_HOP_PORTS//,/%2C}&security=tls&alpn=h3&insecure=1&sni=${TLS_SNI}#${fragment_hy2}"
    fi

    LINK_XHTTP="vless://${UUID}@${host_ip}:${PORT_XHTTP}?encryption=none&security=tls&sni=${TLS_SNI}&type=xhttp&path=%2Fxraybox-${UUID}&mode=auto&pcs=${CERT_SHA256}&pinnedPeerCertSha256=${CERT_SHA256}#${fragment_xhttp}"

    local set2_txt=""
    if [[ "${NODE_SET_COUNT}" == "2" && -n "${UUID_2}" ]]; then
        local fragment_reality_2 fragment_hy2_2 fragment_xhttp_2
        fragment_reality_2=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="-._~"))' 'REALITY-VLESS+XTLS-Vision-（第二套主力）')
        fragment_hy2_2=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="-._~"))' 'Hysteria 2-（第二套UDP跳跃）')
        fragment_xhttp_2=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe="-._~"))' 'XHTTP-VLESS+TLS-(第二套可套CDN)')

        LINK_REALITY_2="vless://${UUID_2}@${host_ip}:${PORT_REALITY_2}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI_2}&fp=chrome&pbk=${REALITY_PUBLIC_KEY_2}&sid=${REALITY_SHORT_ID_2}&type=tcp#${fragment_reality_2}"

        if [[ "$HY2_MODE_2" == "2" ]]; then
            LINK_HY2_2="hysteria2://${UUID_2}@${host_ip}:${PORT_HY2_2}?mport=${PORT_HOP_PORTS_2//,/%2C}&security=tls&alpn=h3&insecure=1&pinSHA256=${HY2_PIN_SHA256_2}&sni=${TLS_SNI_2}#${fragment_hy2_2}"
        elif [[ "$HY2_MODE_2" == "3" && -n "$HY2_DOMAIN_2" ]]; then
            LINK_HY2_2="hysteria2://${UUID_2}@${HY2_DOMAIN_2}:${PORT_HY2_2}?mport=${PORT_HOP_PORTS_2//,/%2C}&security=tls&alpn=h3&sni=${HY2_DOMAIN_2}#${fragment_hy2_2}"
        else
            LINK_HY2_2="hysteria2://${UUID_2}@${host_ip}:${PORT_HY2_2}?mport=${PORT_HOP_PORTS_2//,/%2C}&security=tls&alpn=h3&insecure=1&sni=${TLS_SNI_2}#${fragment_hy2_2}"
        fi

        LINK_XHTTP_2="vless://${UUID_2}@${host_ip}:${PORT_XHTTP_2}?encryption=none&security=tls&sni=${TLS_SNI_2}&type=xhttp&path=%2Fxraybox2-${UUID_2}&mode=auto&pcs=${CERT_SHA256_2:-$CERT_SHA256}&pinnedPeerCertSha256=${CERT_SHA256_2:-$CERT_SHA256}#${fragment_xhttp_2}"

        set2_txt=$(cat <<SET2_TXT_EOF

========================================================================
【第二套节点】
【节点2-1】REALITY-VLESS+XTLS-Vision-（第二套主力）
${LINK_REALITY_2}

【节点2-2】Hysteria 2-（第二套UDP跳跃）
${LINK_HY2_2}

【节点2-3】XHTTP-VLESS+TLS-(第二套可套CDN)
${LINK_XHTTP_2}
SET2_TXT_EOF
)
    fi

    cat > "${NODES_TXT}" <<EOF
========================================================================
                      ToFu 节点配置直连与备份
========================================================================
【第 1 套节点】
【节点1-1】REALITY-VLESS+XTLS-Vision-（主力节点）
${LINK_REALITY}

【节点1-2】Hysteria 2-（UDP端口跳跃）
${LINK_HY2}

【节点1-3】XHTTP-VLESS+TLS-(可套CDN+WARP)
${LINK_XHTTP}${set2_txt}
========================================================================
EOF
    chmod 600 "${NODES_TXT}"
}

show_cdn_tutorial() {
    local return_target=${1:-"info"}
    clear
    echo -e "${cyan}========================================================================${plain}"
    echo -e "       🌐 为节点 3【VLESS + XHTTP + TLS】套 Cloudflare CDN 步骤说明"
	echo -e "       不明白什么是 CND 先回去看文档：https://github.com/YGGYDW/ToFu"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "注册域名并在 Cloudflare 托管（以下以二级域名bbb.aaa.com为例），完成此步请按回车 [Enter] 查看步骤 1..."
    read -r
    
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 1：添加 DNS 解析 A 记录】"
    echo -e "  1. 登录 Cloudflare 网页后台，在域名处点击【DNS】➔【记录】；"
    echo -e "  2. 点击【添加记录】："
    echo -e "     - 类型 (Type)     : A"
    echo -e "     - 名称 (Name)     : ccc (自定义前缀)"
    echo -e "     - IPv4 地址       : ${IP:-111.222.333.444} (当前服务器 IP)"
    echo -e "     - 代理状态 (Proxy): 开启【小黄云 ☁️ 已代理状态】"
    echo -e "  3. 点击保存。新添加的完整域名为：ccc.bbb.aaa.com\n"
    echo -e "${yellow}完成此步后，请按回车 [Enter] 查看步骤 2...${plain}"
    read -r

    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 2：设置 SSL/TLS 为完全加密模式】"
    echo -e "  1. 点击 Cloudflare 左侧菜单【SSL/TLS】➔【概述】；"
    echo -e "  2. 将当前加密模式选择为：【完全】（Full，在部分中文面板显示为“完整”）。"
    echo -e "     （注：此模式下 Cloudflare 会加密到您的源服务器，接受自签名证书）"
    echo -e "     ⚠️ 切勿选择“灵活”，否则会导致重定向死循环。\n"
    echo -e "${yellow}完成此步后，请按回车 [Enter] 查看步骤 3...${plain}"
    read -r

    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 3：配置源服务器规则 (Origin Rules) 端口重写到 2053】"
    echo -e "  1. 点击 Cloudflare 左侧菜单【规则】➔【概述】（或直接点击【源服务器规则 Origin Rules】）；"
    echo -e "  2. 点击【创建规则】："
    echo -e "     - 规则名称: 自定义填写（如：tofu-xhttp）"
    echo -e "     - 在“当传入请求匹配时...”区域："
    echo -e "       * 字段选择: 主机名 (Hostname) | 运算符: 等于 | 值: 填入 ccc.bbb.aaa.com"
    echo -e "       * 点击 Add 增加一行: 字段选择 SSL/HTTPS | 打开蓝色开关按钮"
    echo -e "       * 表达式预览将显示: (http.host eq \"ccc.bbb.aaa.com\" and ssl)"
    echo -e "     - 最下方目标端口:"
    echo -e "       * 选择【重写到...】，在右侧填空处填入: ${PORT_XHTTP:-2053}"
    echo -e "  3. 点击右下角【部署】保存。\n"
    echo -e "${yellow}完成此步后，请按回车 [Enter] 查看步骤 4...${plain}"
    read -r

    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "【步骤 4：客户端 (如 v2rayN) 编辑设置】"
    echo -e "  1. 在 Windows v2rayN 中双击打开导入的【XHTTP】节点编辑界面；"
    echo -e "  2. 修改以下基础连接信息："
    echo -e "     - 地址 (Address)  : 改为 ccc.bbb.aaa.com (或 Cloudflare 官方优选 IP)"
    echo -e "     - 端口 (Port)     : 改为 ${PORT_XHTTP:-2053} (或 Cloudflare 支持的 HTTPS 端口: 443、2083、2087、2096、8443)"
    echo -e "     - 伪装域名 (Host) : 改为 ccc.bbb.aaa.com"
    echo -e "     - SNI             : 改为 ccc.bbb.aaa.com"
    echo -e "  3. ${yellow}⚠️【关键操作·清除固定证书】（必做，否则真连接延迟必为 -1）：${plain}"
    echo -e "     - 找到【固定证书】选项，若右侧显示为“证书已设置”；"
    echo -e "     - 点击右侧【...】按钮打开窗口，将里面的【证书指纹】内容全选删除清空；"
    echo -e "     - 点击空白处关闭弹窗，此时状态显示为【证书未设置】即代表操作成功！"
    echo -e "     （原理：套 CDN 后面对的是 Cloudflare 官方受信任证书，无需比对 VPS 自签指纹）"
    echo -e "  4. 其余用户 ID、路径、底层传输设置保持不变，点击确定保存并测试即可！"
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "教程阅读完毕，按回车 [Enter] 返回..."
    read -r
    if [[ "$return_target" == "cf_menu" ]]; then
        return 0
    elif [[ "$return_target" == "info" ]]; then
        show_node_info
    else
        main_menu
    fi
}

show_qr() {
    local title=$1
    local link=$2
    echo -e "\n${green}=== ${title} ===${plain}"
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "${link}"
    else
        warn "未检测到 qrencode 组件，无法在终端渲染二维码。"
    fi
}

show_node_info() {
    load_env_data
    generate_client_links

    clear
    echo -e "${cyan}========================================================================${plain}"
    if [[ "${NODE_SET_COUNT}" == "2" ]]; then
        echo -e "              ${bold}${green}🎉  ToFu 节点部署完成 (共 2 套独立节点)！${plain}"
    else
        echo -e "              ${bold}${green}🎉  ToFu 节点部署完成！${plain}"
    fi
    echo -e "${cyan}========================================================================${plain}"
    echo -e "✅ 提示：复制以下客户端链接，或回车使用二维码，导入代理工具；链接已同步写入 ${NODES_TXT}"
    echo -e "✅ 提示：Hysteria 2 节点，如果在V2rayN客户端中使用，务必将配置右上角的Core类型更改为sing-box"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    if [[ "${NODE_SET_COUNT}" == "2" ]]; then
        echo -e "【第 1 套节点】"
    fi
    echo -e "${bold}${yellow}【节点1】REALITY-VLESS+XTLS-Vision-（主力节点）${plain}"
    echo -e "${cyan}${LINK_REALITY}${plain}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "${bold}${yellow}【节点2】Hysteria 2-（UDP端口跳跃）${plain}"
    echo -e "${cyan}${LINK_HY2}${plain}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "${bold}${yellow}【节点3】XHTTP-VLESS+TLS-(可套CDN+WARP)${plain}"
    echo -e "${cyan}${LINK_XHTTP}${plain}"
    if [[ "${NODE_SET_COUNT}" == "2" ]]; then
        echo -e "${cyan}========================================================================${plain}"
        echo -e "【第 2 套节点】"
        echo -e "${bold}${yellow}【节点2-1】REALITY-VLESS+XTLS-Vision-（第二套主力）${plain}"
        echo -e "${cyan}${LINK_REALITY_2}${plain}"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo -e "${bold}${yellow}【节点2-2】Hysteria 2-（第二套UDP跳跃）${plain}"
        echo -e "${cyan}${LINK_HY2_2}${plain}"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo -e "${bold}${yellow}【节点2-3】XHTTP-VLESS+TLS-(第二套可套CDN)${plain}"
        echo -e "${cyan}${LINK_XHTTP_2}${plain}"
    fi
    echo -e "${cyan}========================================================================${plain}"
    if [[ "${NODE_SET_COUNT}" == "2" ]]; then
        echo -e "  ${green}1.${plain} 显示全部节点二维码 (共 6 个节点二维码，回车默认)"
        echo
        echo -e "  ${green}2.${plain} 仅显示【第 1 套节点】二维码"
        echo
        echo -e "  ${green}3.${plain} 仅显示【第 2 套节点】二维码"
        echo
        echo -e "  ${green}4.${plain} Cloudflare CDN + WARP 专区"
        echo
        echo -e "  ${green}0.${plain} 返回管理菜单"
        echo -e "${cyan}========================================================================${plain}"
        read -rp "请输入选项 [默认: 1]: " qr_choice
        qr_choice=${qr_choice:-1}
        case "$qr_choice" in
            1)
                show_qr "【第1套】REALITY-VLESS+XTLS-Vision" "${LINK_REALITY}"
                show_qr "【第1套】Hysteria 2 (UDP跳跃)" "${LINK_HY2}"
                show_qr "【第1套】XHTTP-VLESS+TLS" "${LINK_XHTTP}"
                show_qr "【第2套】REALITY-VLESS+XTLS-Vision" "${LINK_REALITY_2}"
                show_qr "【第2套】Hysteria 2 (UDP跳跃)" "${LINK_HY2_2}"
                show_qr "【第2套】XHTTP-VLESS+TLS" "${LINK_XHTTP_2}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            2)
                show_qr "【第1套】REALITY-VLESS+XTLS-Vision" "${LINK_REALITY}"
                show_qr "【第1套】Hysteria 2 (UDP跳跃)" "${LINK_HY2}"
                show_qr "【第1套】XHTTP-VLESS+TLS" "${LINK_XHTTP}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            3)
                show_qr "【第2套】REALITY-VLESS+XTLS-Vision" "${LINK_REALITY_2}"
                show_qr "【第2套】Hysteria 2 (UDP跳跃)" "${LINK_HY2_2}"
                show_qr "【第2套】XHTTP-VLESS+TLS" "${LINK_XHTTP_2}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            4) cloudflare_cdn_menu "info" ;;
            *) main_menu ;;
        esac
    else
        echo -e "  ${green}1.${plain} 显示所有节点二维码 (依次输出 3 个节点二维码，回车默认)"
        echo
        echo -e "  ${green}2.${plain} 仅显示 【节点1】VLESS + REALITY 节点二维码"
        echo
        echo -e "  ${green}3.${plain} 仅显示 【节点2】Hysteria 2 (带端口跳跃) 节点二维码"
        echo
        echo -e "  ${green}4.${plain} 仅显示 【节点3】VLESS + XHTTP 节点二维码"
        echo
        echo -e "  ${green}5.${plain} Cloudflare CDN + WARP 专区"
        echo
        echo -e "  ${green}0.${plain} 返回管理菜单"
        echo -e "${cyan}========================================================================${plain}"
        read -rp "请输入选项 [默认: 1]: " qr_choice
        qr_choice=${qr_choice:-1}
        case "$qr_choice" in
            1)
                show_qr "REALITY-VLESS+XTLS-Vision-（主力节点）" "${LINK_REALITY}"
                show_qr "Hysteria 2-（UDP端口跳跃）" "${LINK_HY2}"
                show_qr "XHTTP-VLESS+TLS-(可套CDN+WARP)" "${LINK_XHTTP}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            2)
                show_qr "REALITY-VLESS+XTLS-Vision-（主力节点）" "${LINK_REALITY}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            3)
                show_qr "Hysteria 2-（UDP端口跳跃）" "${LINK_HY2}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            4)
                show_qr "XHTTP-VLESS+TLS-(可套CDN+WARP)" "${LINK_XHTTP}"
                echo -e "
按任意键返回管理菜单..."
                read -n 1 -s -r
                main_menu
                ;;
            5) cloudflare_cdn_menu "info" ;;
            *) main_menu ;;
        esac
    fi
}

install_all() {
    clear
    show_logo
    echo -e "${bold}${cyan}ToFu 节点部署运行中......${plain}"
    echo -e "${cyan}========================================================================${plain}"
    check_root
    check_arch
    check_os

    install_deps || { error "依赖安装失败；已停止部署，请按包管理器输出检查原因。"; return 1; }
    enable_bbr
    get_public_ip
    scan_and_display_ports

    echo -e "${cyan}========================================================================${plain}"
    echo -e "✅ 提示：如果你使用的是主流云服务商（如 AWS、甲骨文 Oracle、谷歌云 GCP、"
    echo -e "   腾讯云/阿里云国际、Hetzner、搬瓦工等），务必在云服务器后台的"
    echo -e "   “安全组 / 防火墙（Security Group / Firewall）”中至少开放以下端口："
    echo -e "   ${green}443、8443、2053、20000 ~ 50000${plain} (或自定义端口)"
    echo -e "${cyan}========================================================================${plain}"

    echo -e "\n${bold}${cyan}ToFu 节点部署将生成 3 套核心协议组合：${plain}\n"

    echo -e "✅ ${bold}${yellow}节点 1【REALITY】：${plain}"
    echo -e "   ${bold}VLESS + REALITY + XTLS-Vision${plain}"
    echo -e "   ├─ 协议架构: 应用层 VLESS │ 安全层 REALITY │ 传输层 TCP │ 流控 XTLS-Vision"
    echo -e "   ├─ 端口分配: 端口 443 (TCP)"
    echo -e "   ├─ 核心定位: 【主力直连】"
    echo -e "   ├─ 特点属性: 无需域名、免证书、CPU 占用几乎为 0，适合轻量主机，不可套 CDN"
    echo -e "   └─ 调度内核: 客户端调度 ${green}Xray${plain} 内核\n"

    echo -e "✅ ${bold}${yellow}节点 2【Hysteria 2】：${plain}"
    echo -e "   ${bold}Hysteria 2 (UDP 端口跳跃)${plain}"
    echo -e "   ├─ 协议架构: 应用层 Hysteria 2 │ 传输层 UDP (Brutal) │ 内核 NAT 端口跳跃"
    echo -e "   ├─ 端口分配: 主端口 8443 │ 动态跳跃段 ${DEFAULT_HOP_PORTS}"
    echo -e "   ├─ 核心定位: 【暴力带宽】"
    echo -e "   ├─ 特点属性: 面向 UDP 网络与高延迟/丢包场景；实际速度和稳定性取决于网络，不可套 CDN"
    echo -e "   └─ 调度内核: 客户端调度 ${green}sing-box${plain} 内核\n"

    echo -e "✅ ${bold}${yellow}节点 3【XHTTP】：${plain}"
    echo -e "   ${bold}VLESS + XHTTP + TLS (可套CDN+WARP)${plain}"
    echo -e "   ├─ 协议架构: 应用层 VLESS │ 传输层 XHTTP │ 安全层 TLS │ 分流扩展 Cloudflare WARP 出口"
    echo -e "   ├─ 端口分配: 端口 2053 (TCP)"
    echo -e "   ├─ 核心定位: 【多样化DIY】"
    echo -e "   ├─ 特点属性: 可直连或经 Cloudflare CDN 回源；源站地址仍可能因 DNS 或旁路访问暴露"
    echo -e "   └─ 调度内核: 客户端调度 ${green}Xray${plain} 内核\n"

    echo -e "${cyan}============================ 请选择部署模式 ============================${plain}"
    echo -e "  ${green}1.${plain} 小白模式 (回车即可，自动分配端口)"
    echo
    echo -e "  ${green}2.${plain} 自定义端口与参数模式"
    echo
    echo -e "  ${green}0.${plain} 取消安装并返回"
    echo -e "${cyan}========================================================================${plain}"
    read -rp "请输入模式编号 [默认: 1]: " mode_choice
    mode_choice=${mode_choice:-1}

    if [[ "$mode_choice" == "0" ]]; then
        info "已取消安装。"
        return 0
    elif [[ "$mode_choice" != "1" && "$mode_choice" != "2" ]]; then
        warn "无效选项，已取消安装。"
        return 1
    fi

    if [[ "$mode_choice" == "2" ]]; then
        echo -e "\n${cyan}--- 进入自定义参数配置 ---${plain}"
        while true; do
            read -rp "请输入 REALITY 端口 [默认: 443]: " user_reality_port
            user_reality_port=${user_reality_port:-443}
            if [[ "$user_reality_port" =~ ^[0-9]+$ ]] && [ "$user_reality_port" -ge 1 ] && [ "$user_reality_port" -le 65535 ]; then
                PORT_REALITY=$user_reality_port
                break
            else
                warn "端口范围无效 (1-65535)，请重新输入！"
            fi
        done

        while true; do
            read -rp "请输入 Hysteria 2 主端口 [默认: 8443]: " user_hy2_port
            user_hy2_port=${user_hy2_port:-8443}
            if [[ "$user_hy2_port" =~ ^[0-9]+$ ]] && [ "$user_hy2_port" -ge 1 ] && [ "$user_hy2_port" -le 65535 ]; then
                PORT_HY2=$user_hy2_port
                break
            else
                warn "端口范围无效 (1-65535)，请重新输入！"
            fi
        done

        while true; do
            echo
            echo "Hy2 跳跃端口格式："
            echo "  1. 多个单端口（例：1234,5678,9012）"
            echo "  2. 连续端口范围（例：20000-50000）"
            echo "  3. 端口组合（例：1234,5000-6000,7044,8000-9000）"
            read -rp "请选择格式 [默认: 2]: " hop_mode
            hop_mode=${hop_mode:-2}
            case "$hop_mode" in
                1) read -rp "请输入单端口列表（英文逗号分隔）: " user_hop_ports ;;
                2) read -rp "请输入端口范围（例如 20000-50000）[默认: 20000-50000]: " user_hop_ports
                   user_hop_ports=${user_hop_ports:-$DEFAULT_HOP_PORTS} ;;
                3) read -rp "请输入端口组合（英文逗号分隔，范围用连字符）: " user_hop_ports ;;
                *) warn "请选择 1、2 或 3。"; continue ;;
            esac
            if ! validate_hop_ports "$user_hop_ports"; then
                warn "格式或端口范围不正确。单端口用英文逗号，范围用连字符；端口须为 1025-65535，范围起点不能大于终点。"
                continue
            fi
            if ! check_hop_ports_available "$user_hop_ports"; then continue; fi
            PORT_HOP_PORTS=$user_hop_ports
            break
        done

        while true; do
            read -rp "请输入 VLESS-XHTTP 端口 [默认: 2053]: " user_xhttp_port
            user_xhttp_port=${user_xhttp_port:-2053}
            if [[ "$user_xhttp_port" =~ ^[0-9]+$ ]] && [ "$user_xhttp_port" -ge 1 ] && [ "$user_xhttp_port" -le 65535 ]; then
                PORT_XHTTP=$user_xhttp_port
                break
            else
                warn "端口范围无效 (1-65535)，请重新输入！"
            fi
        done

        probe_best_sni
    else
        PORT_HOP_PORTS=$DEFAULT_HOP_PORTS

        if check_port_occupied 443 "tcp"; then
            warn "端口 443 已被占用，正在动态寻找可用高位端口..."
            PORT_REALITY=$(find_free_port 10443)
        else
            PORT_REALITY=443
        fi

        if check_port_occupied 8443 "udp"; then
            PORT_HY2=$(find_free_port 18443)
        else
            PORT_HY2=8443
        fi

        if check_port_occupied 2053 "tcp"; then
            PORT_XHTTP=$(find_free_port 12053)
        else
            PORT_XHTTP=2053
        fi

        local top3=("itunes.apple.com" "gateway.icloud.com" "swdist.apple.com")
        REALITY_SNI="${top3[$((RANDOM % 3))]}"
        TLS_SNI="${REALITY_SNI}"
        success "小白模式已随机选定 REALITY SNI：${REALITY_SNI}"
    fi

    TLS_SNI=${REALITY_SNI}

    echo -e "\n${cyan}========================================================================${plain}"
    info "选定端口: REALITY: ${PORT_REALITY}, Hysteria2 主端口: ${PORT_HY2}，跳跃端口: ${PORT_HOP_PORTS}, XHTTP: ${PORT_XHTTP}"

    configure_firewalls "${PORT_REALITY}" "${PORT_HY2}" "${PORT_XHTTP}" "${PORT_HOP_PORTS}"
    install_xray_core || { error "Xray 核心安装失败，停止部署。"; return 1; }
    if [[ "$mode_choice" == "2" ]]; then generate_credentials "custom"; else generate_credentials "auto"; fi
    NODE_SET_COUNT=1
    setup_iptables_port_hopping
    generate_server_config
    setup_system_service
    save_env_data

    if [[ -f "$0" && ! "$0" =~ ^/dev/fd/ && ! "$0" =~ ^/proc/ && "$0" != "bash" && "$0" != "-bash" && "$0" != "sh" ]]; then
        cp -f "$0" "${CONFIG_DIR}/tofu.sh" >/dev/null 2>&1
        cp -f "$0" "${TOFU_BIN}" >/dev/null 2>&1
        local source_path
        source_path=$(readlink -f "$0" 2>/dev/null || true)
        if [[ -n "$source_path" && "$(basename "$source_path")" == "tofu.sh" && "$source_path" != "$TOFU_BIN" ]]; then
            printf '%s\n' "$source_path" > "${CONFIG_DIR}/install_source_path"
            chmod 600 "${CONFIG_DIR}/install_source_path"
        fi
    elif [[ -s "${CONFIG_DIR}/tofu.sh" ]]; then
        cp -f "${CONFIG_DIR}/tofu.sh" "${TOFU_BIN}" >/dev/null 2>&1
    else
        local script_src="https://raw.githubusercontent.com/YGGYDW/ToFu/refs/heads/main/tofu.sh"
        echo -e "${cyan}[下载]${plain} 正在注册全局快捷命令 tofu..."
        local script_tmp="${CONFIG_DIR}/tofu.sh.download"
        if curl_with_progress "下载 ToFu 更新" --retry 2 --connect-timeout 8 -m 60 "${script_src}" -o "$script_tmp" && bash -n "$script_tmp"; then
            install -m 700 "$script_tmp" "${CONFIG_DIR}/tofu.sh"
            install -m 755 "$script_tmp" "${TOFU_BIN}"
            rm -f "$script_tmp"
            success "ToFu 管理命令下载并通过 Bash 语法检查。"
        else
            rm -f "$script_tmp"
            warn "无法从项目官方地址下载管理命令；当前服务已安装，但全局 tofu 命令未注册。"
        fi
    fi
    chmod +x "${TOFU_BIN}" >/dev/null 2>&1
    chmod +x "${CONFIG_DIR}/tofu.sh" >/dev/null 2>&1

    show_node_info
}

uninstall_all() {
    clear
    show_logo
    echo -e "${yellow}此操作将完整卸载 ToFu：停止服务、删除 ToFu 文件与规则，并恢复可识别的安装前系统设置。${plain}"
    read -rp "确认完整卸载 ToFu？[Y/n]: " delete_confirm
    if [[ "$delete_confirm" == "n" || "$delete_confirm" == "N" ]]; then
        info "已取消卸载。"
        main_menu
        return 0
    elif [[ -n "$delete_confirm" && "$delete_confirm" != "y" && "$delete_confirm" != "Y" ]]; then
        warn "输入无效，已取消卸载。"
        main_menu
        return 1
    fi
    local install_source_path=""
    [[ -f "${CONFIG_DIR}/install_source_path" ]] && IFS= read -r install_source_path < "${CONFIG_DIR}/install_source_path"
    load_env_data

    if [[ -f "${IPTABLES_SCRIPT}" ]]; then
        /bin/bash "$IPTABLES_SCRIPT" disable "${PORT_HY2}" "${PORT_HOP_PORTS}" >/dev/null 2>&1 || true
    fi

    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu >/dev/null 2>&1
        systemctl disable tofu >/dev/null 2>&1
        rm -f "${SYSTEMD_FILE}"
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1 || [[ -f "${OPENRC_FILE}" ]]; then
        rc-service tofu stop >/dev/null 2>&1
        rc-update del tofu default >/dev/null 2>&1
        rm -f "${OPENRC_FILE}"
    fi

    stop_fallback_service

    if [[ -f "${CONFIG_DIR}/xray.original" ]]; then
        cp -p "${CONFIG_DIR}/xray.original" "${XRAY_BIN}"
    elif [[ -f "${CONFIG_DIR}/xray_managed" ]]; then
        rm -f "${XRAY_BIN}"
    fi
    restore_managed_asset /usr/local/share/xray/geoip.dat geoip_share
    restore_managed_asset /usr/local/bin/geoip.dat geoip_bin
    restore_managed_asset /usr/local/share/xray/geosite.dat geosite_share
    restore_managed_asset /usr/local/bin/geosite.dat geosite_bin
    [[ -f "${CONFIG_DIR}/xray_share_dir_managed" ]] && rmdir /usr/local/share/xray 2>/dev/null || true
    rm -f "$FALLBACK_PID_FILE"
    if [[ -f "$SYSTEM_STATE_FILE" ]]; then
        local prior_cc prior_qdisc
        prior_cc=$(awk -F '\t' '$1=="tcp_congestion_control" {print $2}' "$SYSTEM_STATE_FILE")
        prior_qdisc=$(awk -F '\t' '$1=="default_qdisc" {print $2}' "$SYSTEM_STATE_FILE")
        if [[ -f "${CONFIG_DIR}/tofu_bbr_managed" ]]; then rm -f /etc/sysctl.d/99-tofu-bbr.conf; fi
        [[ -n "$prior_cc" && "$prior_cc" != unknown ]] && sysctl -w "net.ipv4.tcp_congestion_control=$prior_cc" >/dev/null 2>&1 || true
        [[ -n "$prior_qdisc" && "$prior_qdisc" != unknown ]] && sysctl -w "net.core.default_qdisc=$prior_qdisc" >/dev/null 2>&1 || true
    fi
    if [[ -f "${CONFIG_DIR}/warp_managed" || -f "${CONFIG_DIR}/warp_repo_managed" ]]; then
        command -v warp-cli >/dev/null 2>&1 && warp-cli disconnect >/dev/null 2>&1 || true
        if [[ -f "${CONFIG_DIR}/warp_managed" ]]; then
            case "$PKG_MANAGER" in
                apt-get) run_package_task "卸载 Cloudflare WARP" apt-get remove -y cloudflare-warp || warn "Cloudflare WARP 软件包未能移除。" ;;
                yum) run_package_task "卸载 Cloudflare WARP" yum remove -y cloudflare-warp || warn "Cloudflare WARP 软件包未能移除。" ;;
            esac
        fi
        rm -f /etc/apt/sources.list.d/cloudflare-warp.list /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg /etc/yum.repos.d/cloudflare-warp.repo
    fi
    remove_recorded_packages
    rm -rf "${CONFIG_DIR}"
    rm -f "${TOFU_BIN}"
    if [[ "$install_source_path" == /* && "$(basename "$install_source_path")" == "tofu.sh" && "$install_source_path" != "$TOFU_BIN" && "$install_source_path" != "$CONFIG_DIR"/* ]]; then
        rm -f -- "$install_source_path"
    fi
    success "ToFu 服务、程序文件、配置、可识别规则及 ToFu 安装的 WARP 组件已清理。"
    echo "如果你从任意临时路径直接运行过下载的 tofu.sh，该脚本副本不在 ToFu 安装清单中，请自行删除。"
}

start_service() {
    info "正在启动 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        if systemctl start tofu; then
            success "服务已成功启动。"
        else
            error "服务启动失败！请运行 'journalctl -u tofu -n 30' 查看错误日志。"
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu start
        success "服务已成功启动。"
    else
        start_fallback_service
        success "服务已成功启动。"
    fi
}

stop_service() {
    info "正在停止 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu stop >/dev/null 2>&1
    fi
    stop_fallback_service
    success "ToFu 服务已成功停止。"
}

restart_service() {
    info "正在重启 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        if systemctl restart tofu; then
            success "服务已重启完毕。"
        else
            error "服务重启失败！请运行 'journalctl -u tofu -n 30' 查看错误日志。"
            return 1
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu restart || { error "OpenRC 服务重启失败。"; return 1; }
        success "服务已重启完毕。"
    else
        stop_fallback_service
        start_fallback_service || { error "ToFu 后台进程启动失败。"; return 1; }
        success "服务已重启完毕。"
    fi
}

upgrade_xray_core() {
    info "正在检测 Xray-core 官方最新版本..."
    check_arch
    check_os
    local current_ver
    current_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    local latest_tag release_api
    release_api=$(mktemp) || return 1
    if ! curl -fLsS --connect-timeout 10 --max-time 60 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" -o "$release_api"; then
        error "获取 GitHub 最新版本失败，请检查网络！"
        rm -f "$release_api"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    latest_tag=$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$release_api" 2>/dev/null) || latest_tag=""
    rm -f "$release_api"
    if [[ -z "$latest_tag" ]]; then
        error "官方版本号缺失或格式异常，已停止升级。"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    info "当前版本: ${current_ver:-未知} ➔ 最新版本: ${latest_tag}"
    if [[ "${current_ver}" == "${latest_tag}" || "v${current_ver}" == "${latest_tag}" ]]; then
        success "当前内核已是最新版本 (${current_ver})，无需重复升级！"
        read -rp "是否强制重新拉取覆盖？[y/N]: " force_update
        if [[ "${force_update}" != "y" && "${force_update}" != "Y" ]]; then
            read -n 1 -s -r -p "按任意键返回菜单..."
            return 0
        fi
    fi
    local backup_bin="${CONFIG_DIR}/xray.upgrade-backup"
    if [[ -x "$XRAY_BIN" ]]; then cp -p "$XRAY_BIN" "$backup_bin" || { error "无法备份当前 Xray，已停止升级。"; return 1; }; fi
    if ! install_xray_core; then
        rm -f "$backup_bin"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    if [[ -f "$CONFIG_FILE" ]] && ! "$XRAY_BIN" -test -config "$CONFIG_FILE"; then
        error "新版本配置检查失败，正在恢复旧核心。"
        [[ -f "$backup_bin" ]] && mv -f "$backup_bin" "$XRAY_BIN"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    if ! restart_service; then
        error "新核心启动失败，正在恢复旧版本。"
        [[ -f "$backup_bin" ]] && mv -f "$backup_bin" "$XRAY_BIN"
        restart_service || true
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    rm -f "$backup_bin"
    success "Xray-core 已成功升级至 ${latest_tag}！"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

get_status_banner() {
    local pid
    pid=$(pgrep -f "${XRAY_BIN}" | head -n 1)
    if [[ -n "$pid" ]]; then
        local mem_kb
        mem_kb=$(grep -i VmRSS /proc/${pid}/status 2>/dev/null | awk '{print $2}')
        local mem_mb="35.0"
        if [[ -n "$mem_kb" ]]; then
            mem_mb=$(awk -v k="$mem_kb" 'BEGIN {printf "%.1f", k/1024}')
        fi
        local cpu_usage
        cpu_usage=$(ps -p "${pid}" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0.1")
        echo -e "${green}● 正在运行${plain} (进程PID: ${cyan}${pid}${plain} │ 内存占用: ${green}${mem_mb} MB${plain} │ CPU: ${cyan}${cpu_usage}%${plain})"
    else
        echo -e "${red}○ 未运行${plain}"
    fi
}

get_system_info_banner() {
    local xray_ver
    xray_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    local os_pretty=""
    if [[ -f /etc/os-release ]]; then
        os_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    fi
    [[ -z "$os_pretty" ]] && os_pretty="${OS_TYPE} (${ARCH_NAME})"

    local bbr_str="${yellow}○ 未开启${plain}"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        bbr_str="${green}● 已开启${plain}"
    fi

    echo -e "   本机 IP  : ${cyan}${IP:-检测中}${plain} │ 系统环境: ${yellow}${os_pretty}${plain}"
    echo -e "   核心版本 : ${cyan}Xray-core ${xray_ver:-v26}${plain} │ TCP BBR : ${bbr_str}"
    echo -e "   运行端口 : 节点1：REALITY: ${green}${PORT_REALITY:-443}${plain} │ 节点2 Hy2: ${green}${PORT_HY2:-8443}${plain} (${PORT_HOP_PORTS:-$DEFAULT_HOP_PORTS}) │ 节点3：XHTTP: ${green}${PORT_XHTTP:-2053}${plain}"
    echo -e "   当前XHTTP出站状态：$(get_cf_egress_status)"
}

get_cf_egress_status() {
    if [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
        echo -e "${green}● Cloudflare WARP ${plain}"
    else
        echo -e "${yellow}○ 原生 VPS 直连${plain}"
    fi
}

get_cf_egress_banner() {
    local title color frame
    if [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
        title="● Cloudflare WARP"
        color=$green
    else
        title="○ 原生 VPS 直连"
        color=$yellow
    fi
    frame=$(python3 - "$title" <<'PY'
import sys, unicodedata
status = sys.argv[1]
lines = ["ToFu · 出站状态", status]
def width(s):
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
w = max(width(s) for s in lines)
def row(s):
    print("│ " + s + " " * (w - width(s)) + " │")
print("╭" + "─" * (w + 2) + "╮")
row(lines[0])
print("├" + "─" * (w + 2) + "┤")
row(lines[1])
print("╰" + "─" * (w + 2) + "╯")
PY
)
    echo -e "${color}${frame}${plain}"
}

show_warp_success_card() {
    local frame
    frame=$(python3 <<'PY'
import unicodedata
lines = ["节点 3 XHTTP-VLESS+TLS 节点", "✅已成功配置 WARP 出站✅"]
def width(s):
    return sum(0 if unicodedata.category(c) in ("Mn", "Cf") else 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s)
w = max(width(s) for s in lines)
def row(s):
    padding = w - width(s)
    left = padding // 2
    right = padding - left
    print("│ " + " " * left + s + " " * right + " │")
print("╭" + "─" * (w + 2) + "╮")
row(lines[0])
print("├" + "─" * (w + 2) + "┤")
row(lines[1])
print("╰" + "─" * (w + 2) + "╯")
PY
)
    echo -e "${green}${frame}${plain}"
}

set_xhttp_warp_egress() {
    local enabled=$1 tmp backup
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    backup=$(mktemp "${CONFIG_FILE}.bak.XXXXXX") || { rm -f "$tmp"; return 1; }
    cp -p "$CONFIG_FILE" "$backup" || { rm -f "$tmp" "$backup"; return 1; }
    cp "$CONFIG_FILE" "$tmp" || { rm -f "$tmp" "$backup"; return 1; }
    if ! python3 - "$tmp" "$enabled" <<'PY'
import json, sys
p, enabled = sys.argv[1], sys.argv[2] == "on"
with open(p, "r", encoding="utf-8") as f:
    cfg = json.load(f)
rules = cfg.setdefault("routing", {}).setdefault("rules", [])
found = False
for rule in rules:
    inbound_tags = rule.get("inboundTag", [])
    if isinstance(inbound_tags, list) and any("vless-xhttp" in t for t in inbound_tags):
        rule["outboundTag"] = "warp-socks" if enabled else "direct"
        found = True
if not found:
    raise SystemExit("XHTTP inbound route was not found")
if enabled and not any(x.get("tag") == "warp-socks" for x in cfg.get("outbounds", [])):
    cfg.setdefault("outbounds", []).append({
        "tag": "warp-socks", "protocol": "socks",
        "settings": {"servers": [{"address": "127.0.0.1", "port": 40000}]}
    })
with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.flush()
    import os
    os.fsync(f.fileno())
PY
    then
        error "修改 Xray 路由配置失败，原配置未变更。"
        rm -f "$tmp" "$backup"
        return 1
    fi
    chmod --reference="$CONFIG_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE" || { mv -f "$backup" "$CONFIG_FILE"; return 1; }
    if ! restart_service; then
        error "服务未能使用新路由启动，正在恢复旧配置。"
        mv -f "$backup" "$CONFIG_FILE"
        restart_service || true
        return 1
    fi
    rm -f "$backup"
    return 0
}

confirm_warp_toggle() {
    local answer
    if ! read -r -p "确认切换吗？[Y/n]: " answer; then
        warn "未读取到确认输入，本次不切换。"
        return 1
    fi
    case "$answer" in
        ""|y|Y) return 0 ;;
        n|N) info "已取消切换。"; return 1 ;;
        *) warn "输入无效；请输入 y 或 n，本次不切换。"; return 1 ;;
    esac
}

toggle_cf_egress() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                   🌐 切换节点 3 (CDN) 出口分流模式"
    echo -e "${cyan}========================================================================${plain}"

    local is_cf_on=false
    if grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
        is_cf_on=true
    fi

    if [[ "$is_cf_on" == true ]]; then
        echo -e "当前状态: ${green}【● Cloudflare WARP 出口模式】${plain}"
        echo -e "即将切换为: ${yellow}【○ 原生 VPS 直连出口模式】${plain}\n"
        confirm_warp_toggle || return 0

        info "正在更新 Xray 路由规则至原生直连..."
        set_xhttp_warp_egress off || { read -n 1 -s -r -p "按任意键返回 Cloudflare CDN+WARP 专区..."; return 1; }
        success "已成功切换为【○ 原生 VPS 直连出口模式】！"
        echo -e "✅ 此时为 VPS 原生出站。\n"
        read -n 1 -s -r -p "按任意键返回 Cloudflare CDN+WARP 专区..."
    else
        echo -e "当前状态: ${yellow}【○ 原生 VPS 直连出口模式】${plain}"
        echo -e "即将切换为: ${green}【● Cloudflare WARP 出口模式】${plain}\n"
        confirm_warp_toggle || return 0

        if ! command -v warp-cli >/dev/null 2>&1; then
            info "正在初次安装 Cloudflare 官方 WARP 出口组件..."
            if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
                record_new_packages curl gpg
                if ! run_package_task "准备 WARP 安装工具" apt-get install -y curl gpg; then
                    error "安装 curl/gpg 依赖失败；请根据上方包管理器输出排查。"
                    return 1
                fi
                echo -e "${cyan}[下载]${plain} 正在拉取 Cloudflare 认证密钥..."
                local warp_key_tmp
                warp_key_tmp=$(mktemp)
                mkdir -p /usr/share/keyrings
                if ! curl_with_progress "下载 Cloudflare 认证密钥" https://pkg.cloudflareclient.com/pubkey.gpg -o "$warp_key_tmp"; then
                    rm -f "$warp_key_tmp"
                    error "Cloudflare 仓库公钥下载失败。"
                    return 1
                fi
                if ! gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg "$warp_key_tmp"; then
                    rm -f "$warp_key_tmp"
                    error "Cloudflare 仓库公钥导入失败。"
                    return 1
                fi
                rm -f "$warp_key_tmp"
                chmod 644 /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
                touch "${CONFIG_DIR}/warp_repo_managed"
                success "Cloudflare 认证密钥已导入。"
                local codename
                codename=$(grep VERSION_CODENAME /etc/os-release 2>/dev/null | cut -d'=' -f2)
                [[ -z "$codename" ]] && codename="bookworm"
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main" | tee /etc/apt/sources.list.d/cloudflare-warp.list >/dev/null 2>&1
                chmod 644 /etc/apt/sources.list.d/cloudflare-warp.list
                if ! run_package_task "更新 Cloudflare 软件包索引" apt-get update; then
                    error "更新 APT 软件源失败；请根据上方输出检查发行版代号、仓库和密钥权限。"
                    return 1
                fi
                if ! run_package_task "安装 Cloudflare WARP" apt-get install -y cloudflare-warp; then
                    error "安装 Cloudflare WARP 软件包失败；请根据上方输出排查。"
                    return 1
                fi
                touch "${CONFIG_DIR}/warp_managed"
            elif [[ "${PKG_MANAGER}" == "yum" ]]; then
                echo -e "${cyan}[下载]${plain} 正在拉取 Cloudflare WARP 仓库配置..."
                mkdir -p /etc/yum.repos.d
                if ! curl_with_progress "下载 Cloudflare WARP 仓库配置" https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo -o /etc/yum.repos.d/cloudflare-warp.repo; then
                    error "Cloudflare WARP 仓库配置下载失败。"
                    return 1
                fi
                chmod 644 /etc/yum.repos.d/cloudflare-warp.repo
                touch "${CONFIG_DIR}/warp_repo_managed"
                if ! run_package_task "安装 Cloudflare WARP" yum install -y cloudflare-warp; then
                    error "安装 Cloudflare WARP 软件包失败；请根据上方输出排查。"
                    return 1
                fi
                touch "${CONFIG_DIR}/warp_managed"
            fi
        fi

        if command -v warp-cli >/dev/null 2>&1; then
            info "正在初始化本地 WARP 代理网关 (127.0.0.1:40000)..."
            warp-cli --accept-tos register >/dev/null 2>&1 || warp-cli --accept-tos registration new >/dev/null 2>&1 || true
            warp-cli --accept-tos mode proxy >/dev/null 2>&1 || warp-cli --accept-tos set-mode proxy >/dev/null 2>&1 || true
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 || warp-cli --accept-tos set-proxy-port 40000 >/dev/null 2>&1 || true
            warp-cli --accept-tos connect >/dev/null 2>&1 || true
            local test_ip=""
            for _ in {1..5}; do
                test_ip=$(curl -s4m5 -x socks5h://127.0.0.1:40000 https://api.ipify.org 2>/dev/null || true)
                [[ -n "$test_ip" ]] && break
                sleep 2
            done
            if [[ -z "$test_ip" ]]; then
                error "WARP 代理尚未连通，Xray 路由保持原状；请检查 warp-cli status 与网络。"
                read -n 1 -s -r -p "按任意键返回 Cloudflare CDN+WARP 专区..."
                return 1
            fi
        else
            error "安装 Cloudflare 官方客户端失败，请检查 VPS 外网连接！"
            read -n 1 -s -r -p "按任意键返回 Cloudflare CDN 专区..."
            return 1
        fi

        info "正在更新 Xray 路由规则至 Cloudflare 出口..."
        set_xhttp_warp_egress on || { read -n 1 -s -r -p "按任意键返回 Cloudflare CDN+WARP 专区..."; return 1; }
        success "已成功切换为【● Cloudflare】出口模式！"
        
        success "WARP 代理出口验证成功，出口 IP: ${test_ip}"
        echo
        show_warp_success_card
        echo
        read -n 1 -s -r -p "按任意键返回 Cloudflare CDN 专区..."
    fi
}

cloudflare_cdn_menu() {
    local return_target=${1:-"main"}
    while true; do
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                      ${bold}🌐 Cloudflare CDN 管理专区${plain}                 "
        echo -e "${cyan}========================================================================${plain}"
        echo -e "【当前节点 3 出口状态】:"
        get_cf_egress_banner
        echo -e ""
        echo -e "【出口模式作用与用途解析】:"
        echo -e "  ${bold}├─ 模式 A【○ 原生 VPS 直连出口】${plain} (速度最快 · 日常推荐):"
        echo -e "  │  ▸ 原理: 入口走 CDN 防护，出站由 VPS 物理网卡直连访问目标网站。"
        echo -e "  │  ▸ 优势: 速度极速、延迟最低。"
        echo -e "  │  ▸ 表现: 在网站查 IP，显示【VPS 真实物理 IP】。"
        echo -e "  │"
        echo -e "  ${bold}├─ 模式 B【● Cloudflare WARP 出口】${plain}:"
        echo -e "  │  ▸ 原理: 入口与出站首尾全走 Cloudflare，VPS 物理真实 IP 全程隐匿。"
        echo -e "  │  ▸ 作用: 节点 3 的出站流量经 WARP 转发；目标站点看到该连接的出口 IP。"
        echo -e "  │  ▸ 边界: 只影响出站路由，不隐藏 VPS 入站地址，也不代表匿名。"
        echo -e "  │"
        echo -e "  ${cyan}└─ ✅ 提示: 此切换仅对节点 3 VLESS + XHTTP + TLS 生效。${plain}"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo -e "  ${green}1.${plain} 为节点3【VLESS + XHTTP + TLS】套 CDN 的方法 (步骤说明)"
        echo
        local toggle_label="切换为【● Cloudflare WARP 出口】"
        if [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null; then
            toggle_label="切换为【○ 原生 VPS 直连出口】"
        fi
        echo -e "  ${green}2.${plain} ${toggle_label}"
        echo
        echo -e "  ${green}0.${plain} 返回管理菜单"
        echo -e "${cyan}========================================================================${plain}"
        read -rp "请输入操作序号 [0-2]: " cf_choice
        case "$cf_choice" in
            1)
                show_cdn_tutorial "cf_menu"
                ;;
            2)
                toggle_cf_egress
                ;;
            0)
                if [[ "$return_target" == "info" ]]; then
                    show_node_info
                else
                    main_menu
                fi
                return 0
                ;;
            *)
                error "输入错误，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

clean_wipe_for_reinstall() {
    info "正在停止现有服务并释放端口与转发规则..."
    stop_service
    pkill -9 xray >/dev/null 2>&1 || true
    if [[ -f "${IPTABLES_SCRIPT}" ]]; then
        /bin/bash "${IPTABLES_SCRIPT}" flush >/dev/null 2>&1 || true
    fi
    rm -f "${CONFIG_FILE}" "${DATA_FILE}" "${NODES_TXT}"
    NODE_SET_COUNT=1
    unset PORT_REALITY_2 PORT_HY2_2 PORT_XHTTP_2 PORT_HOP_PORTS_2 UUID_2 REALITY_SNI_2 TLS_SNI_2
    unset REALITY_PUBLIC_KEY_2 REALITY_PRIVATE_KEY_2 REALITY_SHORT_ID_2 CERT_SHA256_2 HY2_MODE_2 HY2_DOMAIN_2 HY2_PIN_SHA256_2
    success "历史服务已停止，端口与转发规则已全部释放。"
}

deploy_second_set() {
    clear
    show_logo
    echo -e "${bold}${cyan}正在部署第 2 套全新节点...${plain}"
    echo -e "${cyan}========================================================================${plain}"
    if [[ "${PORT_HOP_PORTS}" == "20000-50000" ]]; then
        info "正在调整第 1 套节点端口跳跃段为 20000-35000，为第 2 套预留 35001-50000..."
        PORT_HOP_PORTS="20000-35000"
    fi

    echo -e "请选择第 2 套节点部署模式："
    echo -e "  ${green}1.${plain} 小白模式 (自动分配端口与参数)"
    echo -e "  ${green}2.${plain} 自定义端口与参数模式"
    echo -e "  ${green}0.${plain} 取消返回"
    echo -e "${cyan}------------------------------------------------------------${plain}"
    local m_choice
    read -rp "请输入选项 [默认: 1]: " m_choice
    m_choice=${m_choice:-1}
    if [[ "$m_choice" == "0" ]]; then return 0; fi

    if [[ "$m_choice" == "2" ]]; then
        while true; do
            read -rp "请输入第 2 套 REALITY 端口 [默认: 10443]: " user_p
            user_p=${user_p:-10443}
            if [[ "$user_p" =~ ^[0-9]+$ ]] && (( user_p >= 1 && user_p <= 65535 )) && [[ "$user_p" != "$PORT_REALITY" && "$user_p" != "$PORT_HY2" && "$user_p" != "$PORT_XHTTP" ]]; then
                PORT_REALITY_2=$user_p; break
            else warn "端口无效或与第 1 套冲突，请重新输入！"; fi
        done
        while true; do
            read -rp "请输入第 2 套 Hysteria 2 主端口 [默认: 18443]: " user_p
            user_p=${user_p:-18443}
            if [[ "$user_p" =~ ^[0-9]+$ ]] && (( user_p >= 1 && user_p <= 65535 )) && [[ "$user_p" != "$PORT_REALITY" && "$user_p" != "$PORT_HY2" && "$user_p" != "$PORT_XHTTP" && "$user_p" != "$PORT_REALITY_2" ]]; then
                PORT_HY2_2=$user_p; break
            else warn "端口无效或与现有端口冲突，请重新输入！"; fi
        done
        while true; do
            read -rp "请输入第 2 套端口跳跃段 [默认: 35001-50000]: " user_h
            user_h=${user_h:-"35001-50000"}
            if [[ "$user_h" =~ ^[0-9]+-[0-9]+$ ]]; then
                PORT_HOP_PORTS_2=$user_h; break
            else warn "格式无效，格式示例: 35001-50000"; fi
        done
        while true; do
            read -rp "请输入第 2 套 VLESS-XHTTP 端口 [默认: 12053]: " user_p
            user_p=${user_p:-12053}
            if [[ "$user_p" =~ ^[0-9]+$ ]] && (( user_p >= 1 && user_p <= 65535 )) && [[ "$user_p" != "$PORT_REALITY" && "$user_p" != "$PORT_HY2" && "$user_p" != "$PORT_XHTTP" && "$user_p" != "$PORT_REALITY_2" && "$user_p" != "$PORT_HY2_2" ]]; then
                PORT_XHTTP_2=$user_p; break
            else warn "端口无效或与现有端口冲突，请重新输入！"; fi
        done
        echo -e "${cyan}请选择第 2 套 REALITY 伪装域名 (SNI)：${plain}"
        local orig_sni=$REALITY_SNI
        probe_best_sni
        REALITY_SNI_2=$REALITY_SNI
        TLS_SNI_2=$REALITY_SNI_2
        REALITY_SNI=$orig_sni

        info "正在配置第 2 套 UUID..."
        UUID_2=$("${XRAY_BIN}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        configure_hy2_security 2
    else
        PORT_REALITY_2=$(find_free_port 10443)
        PORT_HY2_2=$(find_free_port 18443)
        PORT_XHTTP_2=$(find_free_port 12053)
        PORT_HOP_PORTS_2="35001-50000"
        local top3=("gateway.icloud.com" "swdist.apple.com" "itunes.apple.com")
        for s in "${top3[@]}"; do
            if [[ "$s" != "$REALITY_SNI" ]]; then REALITY_SNI_2="$s"; break; fi
        done
        REALITY_SNI_2=${REALITY_SNI_2:-"gateway.icloud.com"}
        TLS_SNI_2=$REALITY_SNI_2
        UUID_2=$("${XRAY_BIN}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        HY2_MODE_2=1
        HY2_DOMAIN_2=""
        HY2_PIN_SHA256_2=""
    fi

    local key_pair_2
    key_pair_2=$("${XRAY_BIN}" x25519)
    REALITY_PRIVATE_KEY_2=$(echo "$key_pair_2" | grep -i "Private" | awk '{print $NF}')
    REALITY_PUBLIC_KEY_2=$(echo "$key_pair_2" | grep -i "Public" | awk '{print $NF}')
    REALITY_SHORT_ID_2=$(openssl rand -hex 4)
    CERT_SHA256_2=$CERT_SHA256

    NODE_SET_COUNT=2
    info "选定第 2 套端口: REALITY: ${PORT_REALITY_2}, Hysteria 2: ${PORT_HY2_2} (跳跃: ${PORT_HOP_PORTS_2}), XHTTP: ${PORT_XHTTP_2}"
    setup_iptables_port_hopping
    generate_server_config
    save_env_data
    restart_service
    success "第 2 套节点部署成功！"
    show_node_info
}

reset_single_set_menu() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                      ToFu 独立节点管理"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "  ${green}1.${plain} 重置第 1 套节点"
    echo -e "  ${green}2.${plain} 删除第 1 套节点 (保留第 2 套)"
    echo -e "  ${green}3.${plain} 重置第 2 套节点"
    echo -e "  ${green}4.${plain} 删除第 2 套节点 (保留第 1 套)"
    echo -e "  ${green}0.${plain} 返回上一级"
    echo -e "${cyan}========================================================================${plain}"
    local sub_choice
    read -rp "请输入操作序号 [0-4]: " sub_choice
    case "$sub_choice" in
        1)
            info "正在重置第 1 套节点..."
            install_all
            ;;
        2)
            info "正在删除第 1 套节点并将第 2 套提升为主节点..."
            UUID=$UUID_2
            PORT_REALITY=$PORT_REALITY_2
            PORT_HY2=$PORT_HY2_2
            PORT_XHTTP=$PORT_XHTTP_2
            PORT_HOP_PORTS=$PORT_HOP_PORTS_2
            REALITY_SNI=$REALITY_SNI_2
            TLS_SNI=$TLS_SNI_2
            REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY_2
            REALITY_PRIVATE_KEY=$REALITY_PRIVATE_KEY_2
            REALITY_SHORT_ID=$REALITY_SHORT_ID_2
            CERT_SHA256=${CERT_SHA256_2:-$CERT_SHA256}
            HY2_MODE=$HY2_MODE_2
            HY2_DOMAIN=$HY2_DOMAIN_2
            HY2_PIN_SHA256=$HY2_PIN_SHA256_2
            NODE_SET_COUNT=1
            unset PORT_REALITY_2 PORT_HY2_2 PORT_XHTTP_2 PORT_HOP_PORTS_2 UUID_2 REALITY_SNI_2 TLS_SNI_2
            unset REALITY_PUBLIC_KEY_2 REALITY_PRIVATE_KEY_2 REALITY_SHORT_ID_2 CERT_SHA256_2 HY2_MODE_2 HY2_DOMAIN_2 HY2_PIN_SHA256_2
            /bin/bash "${IPTABLES_SCRIPT}" flush >/dev/null 2>&1 || true
            setup_iptables_port_hopping
            generate_server_config
            save_env_data
            restart_service
            success "原第 1 套已删除，现已转为单套节点运行！"
            show_node_info
            ;;
        3)
            info "正在重置第 2 套节点..."
            deploy_second_set
            ;;
        4)
            info "正在删除第 2 套节点..."
            NODE_SET_COUNT=1
            PORT_HOP_PORTS="20000-50000"
            unset PORT_REALITY_2 PORT_HY2_2 PORT_XHTTP_2 PORT_HOP_PORTS_2 UUID_2 REALITY_SNI_2 TLS_SNI_2
            unset REALITY_PUBLIC_KEY_2 REALITY_PRIVATE_KEY_2 REALITY_SHORT_ID_2 CERT_SHA256_2 HY2_MODE_2 HY2_DOMAIN_2 HY2_PIN_SHA256_2
            /bin/bash "${IPTABLES_SCRIPT}" flush >/dev/null 2>&1 || true
            setup_iptables_port_hopping
            generate_server_config
            save_env_data
            restart_service
            success "第 2 套节点已彻底删除！"
            show_node_info
            ;;
        0) return 0 ;;
        *) warn "无效输入"; sleep 1 ;;
    esac
}

reinstall_or_reset_menu() {
    load_env_data
    if [[ ! -f "${CONFIG_FILE}" && ! -f "${DATA_FILE}" ]]; then
        install_all
        return 0
    fi

    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    if [[ "${NODE_SET_COUNT}" == "2" ]]; then
        echo -e "                   ToFu 节点重置与部署管理 (已部署 2 套节点)"
    else
        echo -e "                   ToFu 节点重置与部署管理"
    fi
    echo -e "${cyan}========================================================================${plain}"
    echo -e "  ${green}1.${plain} 全新重置 (清空现有配置，彻底重新安装)"
    if [[ "${NODE_SET_COUNT}" == "2" ]]; then
        echo
        echo -e "  ${green}2.${plain} 独立管理节点 (重置或删除第 1 套 / 第 2 套)"
    else
        echo
        echo -e "  ${green}2.${plain} 额外部署一套新节点 (保留第 1 套，追加第 2 套)"
    fi
    echo
    echo -e "  ${green}0.${plain} 返回主菜单"
    echo -e "${cyan}========================================================================${plain}"
    local r_choice
    read -rp "请输入操作序号 [默认: 1]: " r_choice
    r_choice=${r_choice:-1}
    case "$r_choice" in
        1)
            clean_wipe_for_reinstall
            install_all
            ;;
        2)
            if [[ "${NODE_SET_COUNT}" == "2" ]]; then
                reset_single_set_menu
            else
                deploy_second_set
            fi
            ;;
        0) main_menu ;;
        *) warn "无效选项，返回主菜单"; sleep 1; main_menu ;;
    esac
}

main_menu() {
    load_env_data
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                         ${bold}ToFu 节点部署 管理菜单${plain}                 "
    echo -e "   服务状态 : $(get_status_banner)"
    get_system_info_banner
    echo -e "${cyan}========================================================================${plain}"
    echo -e "✅ 提示：在终端任意路径输入 ${green}${bold}tofu${plain} 即可随时进入本管理菜单"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "  ${green}1.${plain} 查看所有节点连接信息与二维码"
    echo
    echo -e "  ${green}2.${plain} Cloudflare CDN+WARP 专区"
    echo
    echo -e "  ${green}3.${plain} 重启 ToFu 服务"
    echo
    echo -e "  ${green}4.${plain} 停止 ToFu 服务"
    echo
    echo -e "  ${green}5.${plain} 重新安装 / 自定义重置全部配置"
    echo
    echo -e "  ${green}6.${plain} 一键升级 Xray-core 核心"
    echo
    echo -e "  ${green}7.${plain} 完整卸载 ToFu 组件"
    echo
    echo -e "  ${green}0.${plain} 退出菜单"
    echo -e "${cyan}========================================================================${plain}"
    read -rp "请输入操作序号 [0-7]: " choice
    case "$choice" in
        1) show_node_info ;;
        2) cloudflare_cdn_menu "main" ;;
        3) 
            restart_service
            sleep 1
            main_menu
            ;;
        4) 
            stop_service
            sleep 1
            main_menu
            ;;
        5) reinstall_or_reset_menu ;;
        6)
            upgrade_xray_core
            main_menu
            ;;
        7) uninstall_all ;;
        0) 
            echo -e "\n✅ 感谢使用 ToFu！随时在终端输入 ${green}tofu${plain} 即可再次唤出管理菜单。\n"
            exit 0 
            ;;
        *) error "输入错误，请重新选择！"; sleep 1; main_menu ;;
    esac
}

check_arch
check_os

case "$1" in
    install)        install_all ;;
    uninstall)      uninstall_all ;;
    info)           show_node_info ;;
    restart)        restart_service ;;
    start)          start_service ;;
    stop)           stop_service ;;
    cdn)            cloudflare_cdn_menu "main" ;;
    update|upgrade) upgrade_xray_core ;;
    *)
        if [[ -f "${DATA_FILE}" || -f "${CONFIG_FILE}" ]]; then
            main_menu
        else
            install_all
        fi
        ;;
esac

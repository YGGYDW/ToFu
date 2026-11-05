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
is_warp_egress_enabled() {
    [[ -f "${CONFIG_FILE}" ]] && grep -q '"outboundTag": "warp-socks"' "${CONFIG_FILE}" 2>/dev/null
}

DATA_FILE="${CONFIG_DIR}/node_info.env"
NODES_TXT="${CONFIG_DIR}/nodes.txt"
IPTABLES_SCRIPT="${CONFIG_DIR}/iptables.sh"
SYSTEM_STATE_FILE="${CONFIG_DIR}/system_state.tsv"
XRAY_BIN="/usr/local/bin/xray"
TOFU_BIN="/usr/local/bin/tofu"
XRAY_STABLE_VERSION="v26.6.27"
SYSTEMD_FILE="/etc/systemd/system/tofu.service"
OPENRC_FILE="/etc/init.d/tofu"
FALLBACK_PID_FILE="/run/tofu.pid"
SUB_SERVICE_FILE="/etc/systemd/system/tofu-sub.service"
SUB_FALLBACK_PID_FILE="/run/tofu-sub.pid"
SUB_SERVER_SCRIPT="${CONFIG_DIR}/sub_server.py"

DEFAULT_REALITY_PORT=443
DEFAULT_HY2_PORT=8443
DEFAULT_XHTTP_PORT=2053
DEFAULT_HOP_PORTS="20000-50000"
CF_CDN_DOMAIN=""
CF_CDN_PORT=""
TLS_SNI=""
ACME_PREFERRED_CA="letsencrypt"
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
        record_new_packages curl wget tar unzip jq openssl iptables iproute2 qrencode python3 socat
        run_package_task "更新软件包索引" apt-get update || return 1
        run_package_task "安装系统依赖" apt-get install -y curl wget tar unzip jq openssl iptables iproute2 qrencode python3 socat || return 1
    elif [[ "${PKG_MANAGER}" == "yum" ]]; then
        record_new_packages epel-release curl wget tar unzip jq openssl iptables iproute qrencode python3 socat
        run_package_task "安装 EPEL 仓库" yum install -y epel-release || return 1
        run_package_task "安装系统依赖" yum install -y curl wget tar unzip jq openssl iptables iproute qrencode python3 socat || return 1
    elif [[ "${PKG_MANAGER}" == "apk" ]]; then
        record_new_packages curl wget tar unzip jq openssl iptables iproute2 bash python3 socat
        run_package_task "更新软件包索引" apk update || return 1
        run_package_task "安装系统依赖" apk add --no-cache curl wget tar unzip jq openssl iptables iproute2 bash python3 socat || return 1
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
        local man_flag="/var/lib/man-db/auto-update"
        local man_disabled=0
        if [[ -f "$man_flag" ]]; then
            mv -f "$man_flag" "${man_flag}.tofu_bak" 2>/dev/null && man_disabled=1
        elif [[ -f "${man_flag}.tofu_bak" ]]; then
            man_disabled=1
        fi

        DEBIAN_FRONTEND=noninteractive apt-get -o APT::Status-Fd=3 "$@" 3>"$fifo_file" >"$log_file" 2>&1
        status=$?

        if [[ $man_disabled -eq 1 && -f "${man_flag}.tofu_bak" ]]; then
            mv -f "${man_flag}.tofu_bak" "$man_flag" 2>/dev/null || true
        fi

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

scan_and_display_ports() {
    echo -e "${cyan}[端口] 检查以下必要端口开放状态:${plain}"
    echo -e "${cyan}─────────────────────────────────────────────────────${plain}"
    
    local http_ports=(80 8080 8880 2052 2082 2086 2095)
    local https_ports=(443 2053 2083 2087 2096)
    local p

    echo -e "  🔹【 80系端口 (HTTP TCP) 】"
    for p in "${http_ports[@]}"; do
        printf "    • %-4s ------------------------------ " "$p"
        sleep 0.03
        if check_port_occupied "$p" "tcp"; then
            echo -e "[ ${red}❌ 占用${plain} ]"
        else
            echo -e "[ ${green}✅${plain} ]"
        fi
    done
    echo

    echo -e "  🔹【 443系端口 (HTTPS TCP) 】"
    for p in "${https_ports[@]}"; do
        printf "    • %-4s ------------------------------ " "$p"
        sleep 0.03
        if check_port_occupied "$p" "tcp"; then
            echo -e "[ ${red}❌ 占用${plain} ]"
        else
            echo -e "[ ${green}✅${plain} ]"
        fi
    done
    echo

    echo -e "  🔹【 Hysteria 2 主端口 (UDP) 】"
    local hy2_scan_port=${PORT_HY2:-8443}
    printf "    • %-4s ------------------------------ " "$hy2_scan_port"
    sleep 0.03
    if check_port_occupied "$hy2_scan_port" "udp"; then
        echo -e "[ ${red}❌ 占用${plain} ]"
    else
        echo -e "[ ${green}✅${plain} ]"
    fi
    echo

    echo -e "  🔹【 Hysteria 2  跳跃段 (UDP) 】"
    printf "    • 20000 ~ 50000 --------------------- "
    sleep 0.04
    local c1=0
    if command -v ss >/dev/null 2>&1; then
        c1=$(ss -uln 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' | awk '$1>=20000 && $1<=50000' | wc -l)
    fi
    if [[ "$c1" -eq 0 ]]; then
        echo -e "[ ${green}无冲突 (30001个)${plain} ]"
    else
        echo -e "[ ${yellow}有冲突 (${c1}个)${plain} ]"
    fi

    echo -e "${cyan}┌──────────────────────────────────────────────────────────────────────┐${plain}"
    echo -e "${cyan}│${plain} ${bold}${green}✅ [安全组/防火墙放行提示]${plain}                                           ${cyan}│${plain}"
    echo -e "${cyan}├──────────────────────────────────────────────────────────────────────┤${plain}"
    echo -e "${cyan}│${plain} 若部署在 AWS、Oracle、GCP、Hetzner、搬瓦工等云服务器，请务必在       ${cyan}│${plain}"
    echo -e "${cyan}│${plain} 【控制台防火墙】提前放行以下端口，否则影响正常使用：                 ${cyan}│${plain}"
    echo -e "${cyan}│                                                                      │${plain}"
    echo -e "${cyan}│${plain}   * ${green}80${plain}          : 域名证书申请专用端口                               ${cyan}│${plain}"
    echo -e "${cyan}│${plain}   * ${green}443${plain}         : VLESS-REALITY 默认端口                             ${cyan}│${plain}"
    echo -e "${cyan}│${plain}   * ${green}8443${plain}        : Hysteria 2 默认端口                                ${cyan}│${plain}"
    echo -e "${cyan}│${plain}   * ${green}2053${plain}        : VLESS-XHTTP 默认端口                               ${cyan}│${plain}"
    echo -e "${cyan}│${plain}   * ${green}20000-50000${plain} : Hysteria 2 UDP 端口跳跃范围                        ${cyan}│${plain}"
    echo -e "${cyan}│${plain}   * ${green}50001-60000${plain} : 订阅服务随机选择端口段                             ${cyan}│${plain}"
    echo -e "${cyan}│${plain}   * 或者自定义以上端口                                               ${cyan}│${plain}"
    echo -e "${cyan}│                                                                      │${plain}"
    echo -e "${cyan}│${plain} ${yellow}[i] 若系统内部开启了 UFW 或 Firewalld，请确保同步放行！${plain}              ${cyan}│${plain}"
    echo -e "${cyan}└──────────────────────────────────────────────────────────────────────┘${plain}"
}

configure_firewalls() {
    local reality_port=$1
    local hy2_port=$2
    local xhttp_port=$3
    local hop_ports=$4
    local sub_port=$5

    info "正在检测并配置系统防火墙放行必要服务端口..."

    for p in "$reality_port" "$xhttp_port" "$sub_port"; do
        [[ -n "$p" ]] || continue
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    if [[ -n "$hy2_port" ]]; then
        iptables -C INPUT -p udp --dport "$hy2_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$hy2_port" -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p udp --dport "$hy2_port" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$hy2_port" -j ACCEPT 2>/dev/null || true
    fi
    if [[ -n "$hop_ports" ]]; then
        local IFS=','
        read -ra HP_LIST <<< "$hop_ports"
        for hp in "${HP_LIST[@]}"; do
            hp=${hp/-/:}
            iptables -C INPUT -p udp --dport "$hp" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$hp" -j ACCEPT 2>/dev/null || true
            ip6tables -C INPUT -p udp --dport "$hp" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$hp" -j ACCEPT 2>/dev/null || true
        done
    fi

    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qw "active"; then
            info "检测到系统处于 UFW 激活状态，正在放行端口规则..."
            [[ -n "$reality_port" ]] && ufw allow "${reality_port}/tcp" >/dev/null 2>&1 || true
            [[ -n "$xhttp_port" ]] && ufw allow "${xhttp_port}/tcp" >/dev/null 2>&1 || true
            [[ -n "$sub_port" ]] && ufw allow "${sub_port}/tcp" >/dev/null 2>&1 || true
            [[ -n "$hy2_port" ]] && ufw allow "${hy2_port}/udp" >/dev/null 2>&1 || true
            if [[ -n "$hop_ports" ]]; then
                local IFS=','
                read -ra HP_LIST <<< "$hop_ports"
                for hp in "${HP_LIST[@]}"; do
                    hp=${hp/:/:}
                    ufw allow "${hp}/udp" >/dev/null 2>&1 || true
                done
            fi
        fi
    fi

    if command -v firewall-cmd >/dev/null 2>&1; then
        if firewall-cmd --state >/dev/null 2>&1; then
            info "检测到系统处于 firewalld 运行状态，正在放行端口规则..."
            [[ -n "$reality_port" ]] && firewall-cmd --permanent --add-port="${reality_port}/tcp" >/dev/null 2>&1 || true
            [[ -n "$xhttp_port" ]] && firewall-cmd --permanent --add-port="${xhttp_port}/tcp" >/dev/null 2>&1 || true
            [[ -n "$sub_port" ]] && firewall-cmd --permanent --add-port="${sub_port}/tcp" >/dev/null 2>&1 || true
            [[ -n "$hy2_port" ]] && firewall-cmd --permanent --add-port="${hy2_port}/udp" >/dev/null 2>&1 || true
            if [[ -n "$hop_ports" ]]; then
                local IFS=','
                read -ra HP_LIST <<< "$hop_ports"
                for hp in "${HP_LIST[@]}"; do
                    hp=${hp/:/-}
                    firewall-cmd --permanent --add-port="${hp}/udp" >/dev/null 2>&1 || true
                done
            fi
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi
    fi
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

find_free_sub_port() {
    local port
    for _ in {1..50}; do
        port=$(( 50001 + RANDOM % 10000 ))
        if ! check_port_occupied "$port" "tcp"; then
            echo "$port"
            return 0
        fi
    done
    for ((port=50001; port<=60000; port++)); do
        if ! check_port_occupied "$port" "tcp"; then
            echo "$port"
            return 0
        fi
    done
    echo "54328"
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

configure_hy2_hop_ports() {
    local def_range="20000-50000"
    local user_hop=""
    while true; do
        echo
        echo "Hy2 跳跃端口格式："
        echo "  1. 多个单端口（例：1369,2468,6688）"
        echo "  2. 端口范围（例：${def_range}）"
        echo "  3. 两者组合（例：2899,3800-8300,9968,11888-21986）"
        local hop_mode
        read -rp "请选择格式 [默认: 2]: " hop_mode
        hop_mode=${hop_mode:-2}
        case "$hop_mode" in
            1)
                read -rp "请输入多个单端口 [默认: 1369,2468,6688]: " user_hop
                user_hop=${user_hop:-"1369,2468,6688"}
                ;;
            2)
                read -rp "请输入端口范围 [默认: ${def_range}]: " user_hop
                user_hop=${user_hop:-"$def_range"}
                ;;
            3)
                read -rp "请输入端口组合 [默认: 2899,3800-8300,9968,11888-21986]: " user_hop
                user_hop=${user_hop:-"2899,3800-8300,9968,11888-21986"}
                ;;
            *) warn "请选择 1、2 或 3。"; continue ;;
        esac
        if ! validate_hop_ports "$user_hop"; then
            warn "格式或端口范围不正确。单端口用英文逗号，范围用连字符；端口须为 1025-65535，范围起点不能大于终点。"
            continue
        fi
        if ! check_hop_ports_available "$user_hop"; then continue; fi
        PORT_HOP_PORTS="$user_hop"
        break
    done
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
    local target_tag="$1"
    if [[ -z "$target_tag" ]]; then
        info "正在从 GitHub 获取 Xray-core 官方最新版本..."
        target_tag=$(curl -sSL --connect-timeout 8 --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null)
        if [[ ! "$target_tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            target_tag="$XRAY_STABLE_VERSION"
            warn "获取最新版本号失败（可能触发 GitHub 频率限制），安全保底安装: ${target_tag}"
        else
            info "成功获取最新版本号: ${target_tag}"
        fi
    else
        info "正在从 GitHub 获取 Xray-core (${target_tag})..."
    fi
    [[ -z "${ARCH}" ]] && check_arch

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${target_tag}/Xray-linux-${ARCH}.zip"
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
        cp -p "${XRAY_BIN}" "${CONFIG_DIR}/xray.original" || { error "无法备份已有的 ${XRAY_BIN}，为避免覆盖现有服务而中止。"; rm -rf "$tmp_dir"; return 1; }
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

get_domain_ip() {
    local domain=$1
    local res
    res=$(python3 -c "import socket, sys; print(socket.gethostbyname(sys.argv[1]))" "$domain" 2>/dev/null)
    if [[ -z "$res" ]] && command -v getent >/dev/null 2>&1; then
        res=$(getent ahosts "$domain" 2>/dev/null | awk '{print $1; exit}')
    fi
    echo "$res"
}

install_acme() {
    if ! command -v socat >/dev/null 2>&1; then
        info "正在安装 acme 依赖组件 (socat)..."
        if [[ "${PKG_MANAGER}" == "apt-get" ]]; then
            apt-get install -y socat >/dev/null 2>&1 || true
        elif [[ "${PKG_MANAGER}" == "yum" ]]; then
            yum install -y socat >/dev/null 2>&1 || true
        elif [[ "${PKG_MANAGER}" == "apk" ]]; then
            apk add --no-cache socat >/dev/null 2>&1 || true
        fi
    fi
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        return 0
    fi
    info "正在安装 acme.sh 证书申请工具..."
    local acme_installer
    acme_installer=$(mktemp) || { error "无法创建临时安装文件！"; return 1; }
    if curl -sSL --connect-timeout 10 --max-time 60 https://get.acme.sh -o "$acme_installer" 2>/dev/null ||        wget -qO "$acme_installer" --timeout=60 https://get.acme.sh 2>/dev/null; then
        if [[ -s "$acme_installer" ]]; then
            sh "$acme_installer" >/dev/null 2>&1
        fi
    fi
    rm -f "$acme_installer"
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1 || true
        success "acme.sh 安装就绪！"
        return 0
    fi
    error "acme.sh 安装失败，请检查网络连接！"
    return 1
}

extract_acme_error_reason() {
    local log_file=$1
    [[ -s "$log_file" ]] || { echo "未知验证异常"; return 0; }
    if grep -qi "too many certificates already issued" "$log_file"; then
        echo "触发官方防滥用风控：该域名在 7 天内申请已达 5 次上限！"
    elif grep -qi "too many failed authorizations" "$log_file"; then
        echo "1 小时内验证失败超过 5 次，触发官方防暴力验证风控（请稍后再试）"
    elif grep -qiE "Timeout during connect|Connection timed out" "$log_file"; then
        echo "连接 80 端口超时（请检查域名 AAAA/IPv6 解析或云厂商防火墙 80 端口放行）"
    elif grep -qi "Connection refused" "$log_file"; then
        echo "80 端口连接被拒绝（请检查 80 端口是否被其他进程占用）"
    elif grep -qi "CAA record" "$log_file"; then
        echo "域名的 CAA 记录限制了该机构的证书签发"
    elif grep -qiE "NXDOMAIN|SERVFAIL" "$log_file"; then
        echo "DNS 解析失败，未检测到该域名的公网 A/AAAA 记录"
    else
        local raw_err
        raw_err=$(grep -Ei 'error|failed|invalid' "$log_file" | tail -n 1 | tr -d '\r\n' | head -c 80)
        echo "${raw_err:-验证握手未通过}"
    fi
}

issue_ssl_certificate() {
    local domain=$1
    local cert_file=$2
    local key_file=$3
    local acme_bin="$HOME/.acme.sh/acme.sh"

    [[ -x "$acme_bin" ]] || return 1

    local existing_cert="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
    local existing_key="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
    if [[ ! -f "$existing_cert" ]]; then
        existing_cert="$HOME/.acme.sh/${domain}/fullchain.cer"
        existing_key="$HOME/.acme.sh/${domain}/${domain}.key"
    fi
    if [[ -f "$existing_cert" && -f "$existing_key" ]]; then
        if openssl x509 -checkend 86400 -noout -in "$existing_cert" >/dev/null 2>&1; then
            info "检测到本地已有该域名有效证书，正在直接复用安装..."
            mkdir -p "$(dirname "$cert_file")"
            cp -f "$existing_cert" "$cert_file"
            cp -f "$existing_key" "$key_file"
            chmod 644 "$cert_file"
            chmod 600 "$key_file"
            success "已成功复用本地有效 SSL 证书，无需重复申请！"
            return 0
        fi
    fi

    # 预检提示：探测域名是否存在 AAAA (IPv6) 解析但本地缺乏 IPv6 外网联通
    local dom_has_aaaa=0
    if python3 -c "import socket, sys; sys.exit(0 if socket.getaddrinfo('${domain}', None, socket.AF_INET6) else 1)" 2>/dev/null; then
        dom_has_aaaa=1
    fi
    if [[ $dom_has_aaaa -eq 1 ]]; then
        local local_has_v6=0
        if [[ "$IP" =~ : ]] || ip -6 route get 2001:4860:4860::8888 >/dev/null 2>&1; then
            local_has_v6=1
        fi
        if [[ $local_has_v6 -eq 0 ]]; then
            warn "【预检提示】检测到域名 [${domain}] 解析了 AAAA (IPv6) 地址，但当前 VPS 缺乏公网 IPv6 联通！"
            warn "Let's Encrypt 强制走 IPv6 可能会导致超时，若受阻脚本将自动无缝切换 ZeroSSL IPv4 签发。"
            sleep 1.2
        fi
    fi

    iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port=80/tcp >/dev/null 2>&1 || true
    fi

    if ss -tln 2>/dev/null | grep -qE '[: ]80 '; then
        local p80_occ_proc
        p80_occ_proc=$(ss -tlnp 2>/dev/null | grep -E '[: ]80[ \t]' | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        [[ -z "$p80_occ_proc" || "$p80_occ_proc" == *"("* ]] && p80_occ_proc=$(lsof -iTCP:80 -sTCP:LISTEN -t 2>/dev/null | head -n 1 | xargs -r ps -o comm= 2>/dev/null)
        warn "检测到 TCP 80 端口已被进程 [${p80_occ_proc:-未知}] 占用！"
        warn "申请证书需要临时独占 80 端口以完成 HTTP-01 验证。"
        local release_80
        read -rp "是否允许终止该占用进程以继续申请证书？[y/N]: " release_80
        case "${release_80:-n}" in
            [yY]|[yY][eE][sS])
                if command -v fuser >/dev/null 2>&1; then
                    fuser -k 80/tcp >/dev/null 2>&1 || true
                elif command -v lsof >/dev/null 2>&1; then
                    local p80_pids
                    p80_pids=$(lsof -ti:80 2>/dev/null)
                    [[ -n "$p80_pids" ]] && kill -9 $p80_pids 2>/dev/null || true
                fi
                sleep 1
                ;;
            *)
                error "用户已取消释放 80 端口，证书申请终止。"
                return 1
                ;;
        esac
    fi

    local acme_email="${ACME_EMAIL:-}"
    if [[ -z "$acme_email" ]]; then
        echo -e "\n${cyan}【SSL 证书管理员通知邮箱设置】${plain}"
        echo -e "说明: 邮箱仅用于 Let's Encrypt / ZeroSSL 发送证书到期预警与安全通告，不公开。"
        read -rp "请输入接收证书通知的邮箱 [直接回车默认: admin@${domain}]: " acme_email
        acme_email=$(echo "$acme_email" | tr -d '[:space:]')
        if [[ -z "$acme_email" || ! "$acme_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            acme_email="admin@${domain}"
            info "已采用合规的本域回退邮箱: ${acme_email}"
        fi
        ACME_EMAIL="$acme_email"
        save_env_data
    fi

    mkdir -p "$(dirname "$cert_file")"
    local issue_log
    issue_log=$(mktemp) || { error "无法创建临时日志文件！"; return 1; }
    trap 'rm -f "$issue_log"' RETURN

    local timeout_cmd=""
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd="timeout 90s"
    fi

    # 智能双向 CA 记忆与快速轮换
    local primary_ca="${ACME_PREFERRED_CA:-letsencrypt}"
    local backup_ca="zerossl"
    [[ "$primary_ca" == "zerossl" ]] && backup_ca="letsencrypt"

    info "正在通过 ${primary_ca} 申请 SSL 证书..."
    "$acme_bin" --register-account -m "$acme_email" --server "$primary_ca" >/dev/null 2>&1 || true
    if $timeout_cmd "$acme_bin" --issue -d "$domain" --standalone -k ec-256 --server "$primary_ca" --force >"$issue_log" 2>&1; then
        "$acme_bin" --install-cert -d "$domain" --ecc \
            --fullchain-file "$cert_file" \
            --key-file "$key_file" >/dev/null 2>&1
        rm -f "$issue_log"
        if [[ -s "$cert_file" && -s "$key_file" ]]; then
            chmod 644 "$cert_file"
            chmod 600 "$key_file"
            ACME_PREFERRED_CA="$primary_ca"
            save_env_data
            return 0
        fi
    fi

    # 提取首选 CA 失败原因并切换备用 CA
    local primary_fail_reason
    primary_fail_reason=$(extract_acme_error_reason "$issue_log")
    warn "${primary_ca} 申请未通过 [原因: ${primary_fail_reason}]"
    info "正在切换 ${backup_ca} 备用 CA 重新申请 (最多等待 90 秒)..."

    "$acme_bin" --register-account -m "$acme_email" --server "$backup_ca" >/dev/null 2>&1 || true
    if $timeout_cmd "$acme_bin" --issue -d "$domain" --standalone -k ec-256 --server "$backup_ca" --force >>"$issue_log" 2>&1; then
        "$acme_bin" --install-cert -d "$domain" --ecc \
            --fullchain-file "$cert_file" \
            --key-file "$key_file" >/dev/null 2>&1
        rm -f "$issue_log"
        if [[ -s "$cert_file" && -s "$key_file" ]]; then
            chmod 644 "$cert_file"
            chmod 600 "$key_file"
            ACME_PREFERRED_CA="$backup_ca"
            save_env_data
            return 0
        fi
    fi

    echo -e "${yellow}--- ACME 申请失败诊断输出 ---${plain}"
    tail -n 8 "$issue_log" 2>/dev/null
    echo -e "${yellow}----------------------------${plain}"
    rm -f "$issue_log"
    return 1
}

prompt_for_domain() {
    local prompt_msg=${1:-"请输入绑定的域名 (如 example.com，输入 0 返回): "}
    local dom confirm_dom
    while true; do
        read -rp "$prompt_msg" dom
        [[ "$dom" == "0" ]] && { echo "0"; return 0; }
        dom=${dom,,}
        if ! [[ "$dom" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
            warn "域名格式无效，请重新输入！" >&2
            continue
        fi
        local confirmed=false
        while true; do
            read -rp "您输入的域名是: ${dom}，确认是否正确？[Y/n]: " confirm_dom
            case "${confirm_dom:-y}" in
                [yY]|[yY][eE][sS]) confirmed=true; break ;;
                [nN]|[nN][oO]) confirmed=false; break ;;
                *) warn "输入无效，请输入 y 确认，或输入 n 取消并重新输入！" >&2 ;;
            esac
        done
        if [[ "$confirmed" == true ]]; then
            echo "$dom"
            return 0
        else
            warn "已取消，请重新输入！" >&2
        fi
    done
}

configure_hy2_manual_cert() {
    while true; do
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                   Hysteria 2 手动配置已拥有证书"
        echo -e "${cyan}========================================================================${plain}"
        echo -e "  ${green}1.${plain} 粘贴证书与私钥内容 (支持直接复制文本粘贴)"
        echo
        echo -e "  ${green}2.${plain} 指定 VPS 上的证书文件路径 (.crt / .key)"
        echo
        echo -e "  ${green}0.${plain} 返回上级选择"
        echo -e "${cyan}------------------------------------------------------------${plain}"
        local man_choice
        read -rp "请输入选项 [默认: 1]: " man_choice
        man_choice=${man_choice:-1}
        case "$man_choice" in
            1)
                local domain
                domain=$(prompt_for_domain "请输入该证书绑定的域名 (如 hy2.example.com，输入 0 返回): ")
                [[ "$domain" == "0" ]] && continue

                local temp_cert="${CONFIG_DIR}/certs/hy2.crt.tmp"
                local temp_key="${CONFIG_DIR}/certs/hy2.key.tmp"
                mkdir -p "${CONFIG_DIR}/certs"

                echo -e "${cyan}------------------------------------------------------------${plain}"
                echo -e "请复制本地证书内容 (含 -----BEGIN CERTIFICATE----- 及 -----END CERTIFICATE-----)"
                echo -e "在下方粘贴。粘贴完成后，请在${green}单独一行输入 EOF${plain} 并按回车 [Enter]："
                echo -e "${cyan}------------------------------------------------------------${plain}"
                > "$temp_cert"
                while IFS= read -r line; do
                    [[ "$line" == "EOF" || "$line" == "eof" ]] && break
                    printf '%s\n' "$line" >> "$temp_cert"
                done

                if ! openssl x509 -in "$temp_cert" -noout >/dev/null 2>&1; then
                    error "未能识别到有效的 X.509 证书内容！"
                    rm -f "$temp_cert"
                    echo -e "按任意键返回..."
                    read -n 1 -s -r
                    continue
                fi

                echo -e "${cyan}------------------------------------------------------------${plain}"
                echo -e "请复制私钥内容 (含 -----BEGIN PRIVATE KEY----- 等起始标记)"
                echo -e "在下方粘贴。粘贴完成后，请在${green}单独一行输入 EOF${plain} 并按回车 [Enter]："
                echo -e "${cyan}------------------------------------------------------------${plain}"
                > "$temp_key"
                while IFS= read -r line; do
                    [[ "$line" == "EOF" || "$line" == "eof" ]] && break
                    printf '%s\n' "$line" >> "$temp_key"
                done

                if ! (openssl pkey -in "$temp_key" -noout >/dev/null 2>&1 || openssl rsa -in "$temp_key" -noout >/dev/null 2>&1 || openssl ec -in "$temp_key" -noout >/dev/null 2>&1); then
                    error "未能识别到有效的私钥内容！"
                    rm -f "$temp_cert" "$temp_key"
                    echo -e "按任意键返回..."
                    read -n 1 -s -r
                    continue
                fi

                mv -f "$temp_cert" "${CONFIG_DIR}/certs/hy2.crt"
                mv -f "$temp_key" "${CONFIG_DIR}/certs/hy2.key"
                chmod 644 "${CONFIG_DIR}/certs/hy2.crt"
                chmod 600 "${CONFIG_DIR}/certs/hy2.key"

                HY2_MODE=2
                HY2_DOMAIN="$domain"
                HY2_PIN_SHA256=""
                success "自备证书与私钥已保存并就绪！已绑定域名: ${domain}"
                return 0
                ;;
            2)
                local domain
                domain=$(prompt_for_domain "请输入该证书绑定的域名 (如 hy2.example.com，输入 0 返回): ")
                [[ "$domain" == "0" ]] && continue

                local path_crt path_key
                while true; do
                    read -rp "请输入证书完整路径 (.crt/.pem，输入 0 返回): " path_crt
                    [[ "$path_crt" == "0" ]] && break
                    if [[ -f "$path_crt" ]]; then
                        if openssl x509 -in "$path_crt" -noout >/dev/null 2>&1; then
                            break
                        else
                            warn "指定的文件不是有效的 X.509 证书！"
                        fi
                    else
                        warn "文件不存在，请重新输入！"
                    fi
                done
                [[ "$path_crt" == "0" ]] && continue

                while true; do
                    read -rp "请输入私钥完整路径 (.key，输入 0 返回): " path_key
                    [[ "$path_key" == "0" ]] && break
                    if [[ -f "$path_key" ]]; then
                        if openssl pkey -in "$path_key" -noout >/dev/null 2>&1 || openssl rsa -in "$path_key" -noout >/dev/null 2>&1 || openssl ec -in "$path_key" -noout >/dev/null 2>&1; then
                            break
                        else
                            warn "指定的文件不是有效的私钥！"
                        fi
                    else
                        warn "文件不存在，请重新输入！"
                    fi
                done
                [[ "$path_key" == "0" ]] && continue

                local cert_file="${CONFIG_DIR}/certs/hy2.crt"
                local key_file="${CONFIG_DIR}/certs/hy2.key"
                mkdir -p "$(dirname "$cert_file")"
                cp -f "$path_crt" "$cert_file"
                cp -f "$path_key" "$key_file"
                chmod 644 "$cert_file"
                chmod 600 "$key_file"

                HY2_MODE=2
                HY2_DOMAIN="$domain"
                HY2_PIN_SHA256=""
                success "自备域名与证书已就绪！已绑定域名: ${domain}"
                return 0
                ;;
            0)
                return 1
                ;;
            *)
                warn "无效选项，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

configure_hy2_custom_cert() {
    while true; do
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                   Hysteria 2 自备域名与 SSL 证书配置"
        echo -e "${cyan}========================================================================${plain}"
        local record_type="A"
        [[ "${IP}" =~ : ]] && record_type="AAAA"
        echo -e "  ${green}1.${plain} 自动申请 ACME 免费证书 (需域名提前解析 ${record_type} 记录到: ${cyan}${IP:-本机公网IP}${plain})"
        echo
        echo -e "  ${green}2.${plain} 手动配置已拥有证书"
        echo
        echo -e "  ${green}0.${plain} 返回上级选择"
        echo -e "${cyan}------------------------------------------------------------${plain}"
        echo -e "✅ 提示：在 Cloudflare 域名解析中指定 A 记录后，不要打开橙色云，保持橙色云为关闭状态。"
        echo -e "${cyan}------------------------------------------------------------${plain}"
        local sub_choice
        read -rp "请输入选项 [默认: 1]: " sub_choice
        sub_choice=${sub_choice:-1}
        case "$sub_choice" in
            1)
                local domain confirm_domain
                while true; do
                    read -rp "请输入已解析到本 VPS 的域名 (输入 0 返回): " domain
                    [[ "$domain" == "0" ]] && break
                    domain=${domain,,}
                    if ! [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
                        warn "域名格式无效，请重新输入！"
                        continue
                    fi
                    local confirmed=false
                    while true; do
                        read -rp "您输入的域名是: ${domain}，确认是否正确？[Y/n]: " confirm_domain
                        case "${confirm_domain:-y}" in
                            [yY]|[yY][eE][sS]) confirmed=true; break ;;
                            [nN]|[nN][oO]) confirmed=false; break ;;
                            *) warn "输入无效，请输入 y 确认，或输入 n 取消并重新输入！" ;;
                        esac
                    done
                    if [[ "$confirmed" == true ]]; then
                        break
                    else
                        warn "已取消，请重新输入！"
                    fi
                done
                [[ "$domain" == "0" ]] && continue

                info "正在检测域名解析..."
                local resolved_ip
                resolved_ip=$(get_domain_ip "$domain")
                if [[ -z "$resolved_ip" ]]; then
                    warn "无法解析域名 ${domain} 的 IP 地址，请确认 DNS 解析已在域名服务商处生效！"
                    local force_acme
                    local proceed_acme=false
                    while true; do
                        read -rp "是否仍要尝试继续申请？[Y/n]: " force_acme
                        case "${force_acme:-y}" in
                            [yY]|[yY][eE][sS]) proceed_acme=true; break ;;
                            [nN]|[nN][oO]) proceed_acme=false; break ;;
                            *) warn "输入无效，请输入 y 继续尝试，或输入 n 取消！" ;;
                        esac
                    done
                    if [[ "$proceed_acme" != true ]]; then
                        continue
                    fi
                elif [[ "$resolved_ip" != "$IP" ]]; then
                    warn "域名解析 IP ($resolved_ip) 与本机公网 IP ($IP) 不一致！"
                    local force_acme
                    local proceed_acme=false
                    while true; do
                        read -rp "是否仍要尝试继续申请？[Y/n]: " force_acme
                        case "${force_acme:-y}" in
                            [yY]|[yY][eE][sS]) proceed_acme=true; break ;;
                            [nN]|[nN][oO]) proceed_acme=false; break ;;
                            *) warn "输入无效，请输入 y 继续尝试，或输入 n 取消！" ;;
                        esac
                    done
                    if [[ "$proceed_acme" != true ]]; then
                        continue
                    fi
                else
                    success "域名解析匹配成功！($resolved_ip)"
                fi

                install_acme || { error "acme.sh 准备失败！"; sleep 2; continue; }
                local cert_file="${CONFIG_DIR}/certs/hy2.crt"
                local key_file="${CONFIG_DIR}/certs/hy2.key"
                if issue_ssl_certificate "$domain" "$cert_file" "$key_file"; then
                    HY2_MODE=2
                    HY2_DOMAIN="$domain"
                    HY2_PIN_SHA256=""
                    success "SSL 证书申请成功！已绑定域名: ${domain}"
                    return 0
                else
                    warn "证书申请失败！请重点排查以下常见原因："
                    echo -e "  ${cyan}1.${plain} 【Cloudflare 橙色云】: 节点 2 (Hy2) 申请证书时必须【关闭橙色云 (灰云直连)】！若开启了橙色云将阻断 80 端口验证。"
                    echo -e "  ${cyan}2.${plain} 【域名解析生效】: 请确认在 Cloudflare 添加的 A 记录已生效并指向本机公网 IP (${IP:-当前VPS})。"
                    echo -e "  ${cyan}3.${plain} 【服务商安全组】: 请检查云服务商后台控制台（如 AWS/阿里云/腾讯云/甲骨文等）是否放行了 TCP 80 端口。"
                    echo -e "\n按任意键重试或返回..."
                    read -n 1 -s -r
                fi
                ;;
            2)
                if configure_hy2_manual_cert; then
                    return 0
                fi
                ;;
            0)
                return 1
                ;;
            *)
                warn "无效选项，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

configure_hy2_security() {
    while true; do
        echo -e "${cyan}------------------------------------------------------------${plain}"
        echo -e "请选择 Hysteria 2 安全与证书模式："
        echo -e "  1. 无域名模式（自签证书 + pinSHA-256）"
        echo -e "  2. 自备域名模式（ACME 证书或自有证书）"
        echo -e "${cyan}------------------------------------------------------------${plain}"
        echo -e "✅ 提示：自备域名模式的抗封锁能力/隐蔽性 远高于无域名模式，请尽量使用自备域名模式。"
        echo -e "${cyan}------------------------------------------------------------${plain}"
        local h_choice
        read -rp "请输入选项 [默认: 1]: " h_choice
        h_choice=${h_choice:-1}
        case "$h_choice" in
            1)
                HY2_MODE=1
                HY2_DOMAIN=""
                HY2_PIN_SHA256="$CERT_SHA256"
                break
                ;;
            2)
                HY2_MODE=2
                HY2_DOMAIN=""
                HY2_PIN_SHA256=""
                if configure_hy2_custom_cert; then
                    break
                fi
                ;;
            *)
                warn "输入无效，请输入 1 或 2！"
                ;;
        esac
    done
}

probe_best_sni() {
    info "正在多线程并发测速探测候选 REALITY 伪装域名 (SNI) 的真实握手延迟与可用性..."
    local sorted_list=()
    local display_lines=()
    local probe_output

    probe_output=$(python3 - "${DEFAULT_SNI_LIST[@]}" <<'PY_EOF' 2>/dev/null
import sys, socket, ssl, time, concurrent.futures

domains = [d.strip() for d in sys.argv[1:] if d.strip()]
if not domains:
    domains = [
        "itunes.apple.com", "gateway.icloud.com", "swdist.apple.com",
        "updates.cdn-apple.com", "samsung.com", "api.onedrive.com",
        "speedtest.net", "addons.mozilla.org", "download.docker.com", "amazon.com"
    ]

def check_sni(domain):
    t0 = time.time()
    try:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with socket.create_connection((domain, 443), timeout=2.0) as sock:
            with ctx.wrap_socket(sock, server_hostname=domain) as ssock:
                lat = int((time.time() - t0) * 1000)
                return domain, lat, True
    except Exception:
        return domain, 9999, False

with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
    results = list(executor.map(check_sni, domains))

results.sort(key=lambda x: x[1])
for dom, lat, ok in results:
    tag = f"{lat}ms" if ok else "超时"
    print(f"{dom}\t{tag}")
PY_EOF
)

    local idx=0
    if [[ -n "$probe_output" ]]; then
        while IFS=$'\t' read -r dom lat_str; do
            [[ -z "$dom" ]] && continue
            sorted_list+=("$dom")
            if [[ "$lat_str" == "超时" ]]; then
                display_lines+=("$(printf "  %2d. %-26s ${red}[超时/阻断]${plain}" "$((idx+1))" "$dom")")
            else
                local rec_tag=""
                [[ $idx -eq 0 ]] && rec_tag="${green} (推荐最优)${plain}"
                display_lines+=("$(printf "  %2d. %-26s ${green}[握手延迟: %s]${plain}%b" "$((idx+1))" "$dom" "$lat_str" "$rec_tag")")
            fi
            idx=$((idx+1))
        done <<< "$probe_output"
    fi

    if [[ ${#sorted_list[@]} -eq 0 ]]; then
        sorted_list=("${DEFAULT_SNI_LIST[@]}")
        for i in "${!DEFAULT_SNI_LIST[@]}"; do
            display_lines+=("$(printf "  %2d. %-26s" "$((i+1))" "${DEFAULT_SNI_LIST[$i]}")")
        done
    fi

    echo -e "${cyan}========================================================================${plain}"
    echo -e "                   REALITY 伪装域名 (SNI) 测速推荐排名列表"
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    for line in "${display_lines[@]}"; do
        echo -e "$line"
    done
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "✅ 提示：直接按 ${green}回车${plain} 智能默认选中第 1 个最优推荐域名 [${green}${sorted_list[0]}${plain}]"
    echo -e "✅ 输入序号 [1-${#sorted_list[@]}] 直接选用对应排名域名"
    echo -e "✅ 输入 ${yellow}m${plain} 可手动自定义输入任意其他域名"
    echo -e "${cyan}========================================================================${plain}"
    local choice sni
    read -rp "请输入选项 [默认: 1]: " choice
    choice=${choice:-1}
    if [[ "$choice" == "m" || "$choice" == "M" ]]; then
        while true; do
            read -rp "请输入 REALITY SNI 域名: " sni
            if [[ "$sni" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
                REALITY_SNI="${sni,,}"
                break
            else
                warn "域名格式无效，请重新输入（例如: itunes.apple.com）"
            fi
        done
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sorted_list[@]} )); then
        REALITY_SNI="${sorted_list[$((choice-1))]}"
    else
        warn "输入无效，默认选中第 1 项: ${sorted_list[0]}"
        REALITY_SNI="${sorted_list[0]}"
    fi
    TLS_SNI="${REALITY_SNI}"
    success "已选定 REALITY SNI：${REALITY_SNI}"
}

generate_credentials() {
    local mode=${1:-"custom"} uuid_mode user_uuid
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
        configure_hy2_security
    else
        HY2_MODE=1
        HY2_DOMAIN=""
        HY2_PIN_SHA256="$CERT_SHA256"
    fi
    success "凭证与证书生成完毕。"
}

setup_iptables_port_hopping() {
    info "正在配置 Hysteria 2 端口跳跃转发 (${PORT_HOP_PORTS} -> ${PORT_HY2})..."
    cat > "${IPTABLES_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
CONFIG_DIR="/etc/tofu"
DATA_FILE="${CONFIG_DIR}/node_info.env"

load_env_safe() {
    if [[ -f "$DATA_FILE" ]]; then
        PORT_HY2=$(grep -E '^[[:space:]]*PORT_HY2=' "$DATA_FILE" | head -n 1 | cut -d= -f2- | tr -d ' "\047')
        PORT_HOP_PORTS=$(grep -E '^[[:space:]]*PORT_HOP_PORTS=' "$DATA_FILE" | head -n 1 | cut -d= -f2- | tr -d ' "\047')
    fi
}

apply_redirect() {
    local tport=$1
    local plist=$2
    [[ -z "$tport" || -z "$plist" ]] && return 0
    local IFS=','
    local -a PORTS
    read -ra PORTS <<< "$plist"
    for PORT_SPEC in "${PORTS[@]}"; do
        PORT_SPEC=${PORT_SPEC/-/:}
        iptables -t nat -C PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || \
            iptables -t nat -A PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" || true
        iptables -C INPUT -p udp --dport "$PORT_SPEC" -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport "$PORT_SPEC" -j ACCEPT 2>/dev/null || true
        ip6tables -t nat -C PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || \
            ip6tables -t nat -A PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" || true
        ip6tables -C INPUT -p udp --dport "$PORT_SPEC" -j ACCEPT 2>/dev/null || \
            ip6tables -I INPUT -p udp --dport "$PORT_SPEC" -j ACCEPT 2>/dev/null || true
    done
    iptables -C INPUT -p udp --dport "$tport" -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p udp --dport "$tport" -j ACCEPT 2>/dev/null || true
    ip6tables -C INPUT -p udp --dport "$tport" -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -p udp --dport "$tport" -j ACCEPT 2>/dev/null || true
}

flush_redirect() {
    local tport=$1
    local plist=$2
    if [[ -n "$plist" && -n "$tport" ]]; then
        local IFS=','
        local -a PORTS
        read -ra PORTS <<< "$plist"
        for PORT_SPEC in "${PORTS[@]}"; do
            PORT_SPEC=${PORT_SPEC/-/:}
            iptables -t nat -D PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || true
            iptables -D INPUT -p udp --dport "$PORT_SPEC" -j ACCEPT 2>/dev/null || true
            ip6tables -t nat -D PREROUTING -p udp --dport "$PORT_SPEC" -j REDIRECT --to-ports "$tport" 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport "$PORT_SPEC" -j ACCEPT 2>/dev/null || true
        done
        iptables -D INPUT -p udp --dport "$tport" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$tport" -j ACCEPT 2>/dev/null || true
    fi
    while true; do
        local num
        num=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "REDIRECT" | head -n 1 | awk '{print $1}')
        [[ -n "$num" && "$num" =~ ^[0-9]+$ ]] || break
        iptables -t nat -D PREROUTING "$num" 2>/dev/null || break
    done
    while true; do
        local num6
        num6=$(ip6tables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "REDIRECT" | head -n 1 | awk '{print $1}')
        [[ -n "$num6" && "$num6" =~ ^[0-9]+$ ]] || break
        ip6tables -t nat -D PREROUTING "$num6" 2>/dev/null || break
    done
}

action="${1:-apply}"
tport="${2:-}"
plist="${3:-}"

case "$action" in
    apply|enable)
        if [[ -z "$tport" || -z "$plist" ]]; then
            load_env_safe
            tport="${tport:-$PORT_HY2}"
            plist="${plist:-$PORT_HOP_PORTS}"
        fi
        if [[ -n "$tport" && -n "$plist" ]]; then
            apply_redirect "$tport" "$plist"
        fi
        ;;
    flush|disable)
        if [[ -n "$tport" && -n "$plist" ]]; then
            flush_redirect "$tport" "$plist"
        else
            load_env_safe
            if [[ -n "$PORT_HY2" && -n "$PORT_HOP_PORTS" ]]; then
                flush_redirect "$PORT_HY2" "$PORT_HOP_PORTS"
            fi
        fi
        flush_redirect
        ;;
    *)
        echo "Usage: $0 {apply|enable|flush|disable} [target_port] [hop_port_range]"
        exit 1
        ;;
esac
EOF
    chmod +x "${IPTABLES_SCRIPT}"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1 || true
    /bin/bash "${IPTABLES_SCRIPT}" flush >/dev/null 2>&1 || true
    /bin/bash "${IPTABLES_SCRIPT}" apply "${PORT_HY2}" "${PORT_HOP_PORTS}"
    success "Hysteria 2 端口跳跃内核级 NAT 转发已就绪！"
}


get_routing_outbound() {
    if is_warp_egress_enabled; then
        echo "warp-socks"
    else
        echo "direct"
    fi
}

generate_server_config() {
    info "正在合成服务端主配置文件 (${CONFIG_FILE})..."
    local hy2_cert="${CONFIG_DIR}/certs/ecc.crt"
    local hy2_key="${CONFIG_DIR}/certs/ecc.key"
    if [[ "$HY2_MODE" == "2" && -f "${CONFIG_DIR}/certs/hy2.crt" && -f "${CONFIG_DIR}/certs/hy2.key" ]]; then
        hy2_cert="${CONFIG_DIR}/certs/hy2.crt"
        hy2_key="${CONFIG_DIR}/certs/hy2.key"
    fi
    local routing_outbound
    routing_outbound=$(get_routing_outbound)

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
          "minClientVer": "0.0.0",
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
    }
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
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "none"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "vless-xhttp"
        ],
        "outboundTag": "${routing_outbound}"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
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
        return 1
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

write_sub_server_script() {
    cat > "${SUB_SERVER_SCRIPT}" <<'EOF_PY'
#!/usr/bin/env python3
# ToFu Native Adaptive Subscription Server
import os, sys, json, base64, socket, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn

DATA_FILE = os.environ.get('TOFU_DATA_FILE', '/etc/tofu/node_info.env')

def load_env():
    env = {}
    if not os.path.exists(DATA_FILE):
        return env
    try:
        with open(DATA_FILE, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                env[k] = v
    except Exception:
        pass
    return env

def generate_links(env):
    ip = env.get('IP', '127.0.0.1')
    host_ip = f'[{ip}]' if ':' in ip else ip
    uuid = env.get('UUID', '')
    p_reality = env.get('PORT_REALITY', '443')
    p_hy2 = env.get('PORT_HY2', '8443')
    p_hop = env.get('PORT_HOP_PORTS', '20000-50000')
    p_xhttp = env.get('PORT_XHTTP', '2053')
    sni_reality = env.get('REALITY_SNI', 'itunes.apple.com')
    pbk_reality = env.get('REALITY_PUBLIC_KEY', '')
    sid_reality = env.get('REALITY_SHORT_ID', '')
    hy2_mode = env.get('HY2_MODE', '1')
    hy2_domain = env.get('HY2_DOMAIN', '')
    hy2_pin = env.get('HY2_PIN_SHA256', '')
    cert_sha = env.get('CERT_SHA256', '')
    tls_sni = env.get('TLS_SNI', sni_reality)

    frag_r = urllib.parse.quote('REALITY-VLESS+XTLS-Vision-（主力节点）', safe='-._~')
    frag_h = urllib.parse.quote('Hysteria 2-（UDP端口跳跃）', safe='-._~')
    frag_x = urllib.parse.quote('XHTTP-VLESS+TLS-(可套CDN+WARP)', safe='-._~')

    link_reality = f'vless://{uuid}@{host_ip}:{p_reality}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={sni_reality}&fp=chrome&pbk={pbk_reality}&sid={sid_reality}&type=tcp#{frag_r}'

    hop_esc = p_hop.replace(',', '%2C')
    if hy2_mode == '2' and hy2_domain:
        link_hy2 = f'hysteria2://{uuid}@{hy2_domain}:{p_hy2}?mport={hop_esc}&ports={hop_esc}&security=tls&alpn=h3&sni={hy2_domain}#{frag_h}'
    else:
        link_hy2 = f'hysteria2://{uuid}@{host_ip}:{p_hy2}?mport={hop_esc}&ports={hop_esc}&security=tls&alpn=h3&pinSHA256={hy2_pin}&sni={tls_sni}#{frag_h}'

    link_xhttp = f'vless://{uuid}@{host_ip}:{p_xhttp}?encryption=none&security=tls&sni={tls_sni}&type=xhttp&path=%2Fxraybox-{uuid}&mode=auto&pcs={cert_sha}&pinnedPeerCertSha256={cert_sha}&hpkp={cert_sha}#{frag_x}'

    cf_domain = env.get('CF_CDN_DOMAIN', '').strip()
    p_cdn = env.get('CF_CDN_PORT', '2053').strip()
    link_cdn = ""
    if cf_domain:
        frag_cdn = urllib.parse.quote('XHTTP-（CDN可换优选IP）', safe='-._~')
        link_cdn = f'vless://{uuid}@{cf_domain}:{p_cdn}?encryption=none&security=tls&sni={cf_domain}&host={cf_domain}&type=xhttp&path=%2Fxraybox-{uuid}&mode=auto#{frag_cdn}'

    return link_reality, link_hy2, link_xhttp, link_cdn

def generate_clash_yaml(env):
    ip = env.get('IP', '127.0.0.1')
    uuid = env.get('UUID', '')
    p_reality = env.get('PORT_REALITY', '443')
    p_hy2 = env.get('PORT_HY2', '8443')
    p_hop = env.get('PORT_HOP_PORTS', '20000-50000')
    p_xhttp = env.get('PORT_XHTTP', '2053')
    sni_reality = env.get('REALITY_SNI', 'itunes.apple.com')
    pbk_reality = env.get('REALITY_PUBLIC_KEY', '')
    sid_reality = env.get('REALITY_SHORT_ID', '')
    hy2_mode = env.get('HY2_MODE', '1')
    hy2_domain = env.get('HY2_DOMAIN', '')
    tls_sni = env.get('TLS_SNI', sni_reality)

    hy2_server = hy2_domain if (hy2_mode == '2' and hy2_domain) else ip
    hy2_sni = hy2_domain if (hy2_mode == '2' and hy2_domain) else tls_sni

    yaml_parts = [
        'port: 7890',
        'socks-port: 7891',
        'allow-lan: false',
        'mode: rule',
        'log-level: info',
        'unified-delay: true',
        '',
        'proxies:',
        '  - name: "REALITY-主力节点"',
        '    type: vless',
        f'    server: {ip}',
        f'    port: {p_reality}',
        f'    uuid: {uuid}',
        '    network: tcp',
        '    tls: true',
        '    udp: true',
        '    flow: xtls-rprx-vision',
        f'    servername: {sni_reality}',
        '    reality-opts:',
        f'      public-key: "{pbk_reality}"',
        f'      short-id: "{sid_reality}"',
        '      support-x25519mlkem768: true',
        '    client-fingerprint: chrome',
        '',
        '  - name: "Hy2-端口跳跃"',
        '    type: hysteria2',
        f'    server: {hy2_server}',
        f'    port: {p_hy2}',
        f'    ports: {p_hop}',
        f'    password: {uuid}',
        f'    sni: {hy2_sni}',
        '    skip-cert-verify: true',
        '',
        '  - name: "XHTTP-可套CDN"',
        '    type: vless',
        f'    server: {ip}',
        f'    port: {p_xhttp}',
        f'    uuid: {uuid}',
        '    network: xhttp',
        '    tls: true',
        '    udp: true',
        f'    servername: {tls_sni}',
        '    xhttp-opts:',
        f'      path: /xraybox-{uuid}',
        '      mode: auto',
        '    skip-cert-verify: true',
        ''
    ]

    cf_domain = env.get('CF_CDN_DOMAIN', '').strip()
    p_cdn = env.get('CF_CDN_PORT', '2053').strip()
    if cf_domain:
        yaml_parts.extend([
            '  - name: "XHTTP-CDN优选"',
            '    type: vless',
            f'    server: {cf_domain}',
            f'    port: {p_cdn}',
            f'    uuid: {uuid}',
            '    network: xhttp',
            '    tls: true',
            '    udp: true',
            f'    servername: {cf_domain}',
            '    xhttp-opts:',
            f'      path: /xraybox-{uuid}',
            '      mode: auto',
            ''
        ])

    pg_proxies = ['      - "自动选择"', '      - "REALITY-主力节点"', '      - "Hy2-端口跳跃"', '      - "XHTTP-可套CDN"']
    if cf_domain:
        pg_proxies.append('      - "XHTTP-CDN优选"')
    pg_proxies.append('      - "DIRECT"')

    auto_proxies = ['      - "REALITY-主力节点"', '      - "Hy2-端口跳跃"', '      - "XHTTP-可套CDN"']
    if cf_domain:
        auto_proxies.append('      - "XHTTP-CDN优选"')

    yaml_parts.extend([
        'proxy-groups:',
        '  - name: "节点选择"',
        '    type: select',
        '    proxies:'
    ] + pg_proxies + [
        '',
        '  - name: "自动选择"',
        '    type: url-test',
        '    url: http://www.gstatic.com/generate_204',
        '    interval: 300',
        '    tolerance: 50',
        '    proxies:'
    ] + auto_proxies + [
        '',
        'rules:',
        '  - GEOIP,LAN,DIRECT',
        '  - GEOIP,CN,DIRECT',
        '  - MATCH,节点选择',
        ''
    ])
    return '\n'.join(yaml_parts)

def generate_singbox_json(env):
    ip = env.get('IP', '127.0.0.1')
    uuid = env.get('UUID', '')
    p_reality = int(env.get('PORT_REALITY', '443'))
    p_hy2 = int(env.get('PORT_HY2', '8443'))
    p_hop = env.get('PORT_HOP_PORTS', '20000-50000')
    p_xhttp = int(env.get('PORT_XHTTP', '2053'))
    sni_reality = env.get('REALITY_SNI', 'itunes.apple.com')
    pbk_reality = env.get('REALITY_PUBLIC_KEY', '')
    sid_reality = env.get('REALITY_SHORT_ID', '')
    hy2_mode = env.get('HY2_MODE', '1')
    hy2_domain = env.get('HY2_DOMAIN', '')
    tls_sni = env.get('TLS_SNI', sni_reality)

    hy2_server = hy2_domain if (hy2_mode == '2' and hy2_domain) else ip
    hy2_sni = hy2_domain if (hy2_mode == '2' and hy2_domain) else tls_sni

    hop_list = [p.strip() for p in p_hop.split(',') if p.strip()]
    cf_domain = env.get('CF_CDN_DOMAIN', '').strip()
    p_cdn = int(env.get('CF_CDN_PORT', '2053')) if env.get('CF_CDN_PORT', '2053').isdigit() else 2053

    sel_outbounds = ['自动选择', 'REALITY-主力节点', 'Hy2-端口跳跃', 'XHTTP-可套CDN']
    test_outbounds = ['REALITY-主力节点', 'Hy2-端口跳跃', 'XHTTP-可套CDN']
    if cf_domain:
        sel_outbounds.append('XHTTP-CDN优选')
        test_outbounds.append('XHTTP-CDN优选')
    sel_outbounds.append('direct')

    outbounds = [
        {
            'type': 'selector',
            'tag': '节点选择',
            'outbounds': sel_outbounds
        },
        {
            'type': 'urltest',
            'tag': '自动选择',
            'outbounds': test_outbounds,
            'url': 'http://www.gstatic.com/generate_204',
            'interval': '3m'
        },
        {
            'type': 'vless',
            'tag': 'REALITY-主力节点',
            'server': ip,
            'server_port': p_reality,
            'uuid': uuid,
            'flow': 'xtls-rprx-vision',
            'tls': {
                'enabled': True,
                'server_name': sni_reality,
                'utls': {'enabled': True, 'fingerprint': 'chrome'},
                'reality': {
                    'enabled': True,
                    'public_key': pbk_reality,
                    'short_id': sid_reality
                }
            }
        },
        {
            'type': 'hysteria2',
            'tag': 'Hy2-端口跳跃',
            'server': hy2_server,
            'server_port': p_hy2,
            'hop_interval': '30s',
            'hop_ports': hop_list,
            'password': uuid,
            'tls': {
                'enabled': True,
                'server_name': hy2_sni,
                'insecure': True
            }
        },
        {
            'type': 'vless',
            'tag': 'XHTTP-可套CDN',
            'server': ip,
            'server_port': p_xhttp,
            'uuid': uuid,
            'transport': {
                'type': 'xhttp',
                'path': f'/xraybox-{uuid}',
                'mode': 'auto'
            },
            'tls': {
                'enabled': True,
                'server_name': tls_sni,
                'insecure': True
            }
        }
    ]

    if cf_domain:
        outbounds.append({
            'type': 'vless',
            'tag': 'XHTTP-CDN优选',
            'server': cf_domain,
            'server_port': p_cdn,
            'uuid': uuid,
            'transport': {
                'type': 'xhttp',
                'path': f'/xraybox-{uuid}',
                'mode': 'auto'
            },
            'tls': {
                'enabled': True,
                'server_name': cf_domain
            }
        })

    outbounds.extend([
        {'type': 'direct', 'tag': 'direct'},
        {'type': 'block', 'tag': 'block'}
    ])

    cfg = {
        'outbounds': outbounds,
        'route': {
            'final': '节点选择',
            'auto_detect_interface': True
        }
    }
    return json.dumps(cfg, indent=2, ensure_ascii=False)

class SubHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        env = load_env()
        token = env.get('SUB_TOKEN', '')
        enabled = env.get('SUB_ENABLED', '1')

        if enabled != '1' or not token:
            self.send_error(404, 'Subscription Disabled')
            return

        parsed = urllib.parse.urlparse(self.path)
        expected_path = f'/sub/{token}'
        if parsed.path != expected_path:
            self.send_error(404, 'Not Found')
            return

        query = urllib.parse.parse_qs(parsed.query)
        req_type = query.get('type', [''])[0].lower()
        ua = self.headers.get('User-Agent', '').lower()

        link_r, link_h, link_x, link_cdn = generate_links(env)

        if req_type == 'clash' or (not req_type and any(k in ua for k in ['clash', 'mihomo', 'stash', 'verge'])):
            content = generate_clash_yaml(env)
            self.send_response(200)
            self.send_header('Content-Type', 'text/yaml; charset=utf-8')
            self.send_header('Content-Disposition', 'attachment; filename="tofu_clash.yaml"')
            self.send_header('Subscription-Userinfo', 'upload=0; download=0; total=0')
            self.end_headers()
            self.wfile.write(content.encode('utf-8'))
            return

        if req_type in ['singbox', 'sing-box'] or (not req_type and any(k in ua for k in ['sing-box', 'singbox', 'nekobox'])):
            content = generate_singbox_json(env)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Disposition', 'attachment; filename="tofu_singbox.json"')
            self.end_headers()
            self.wfile.write(content.encode('utf-8'))
            return

        all_links = f'{link_r}\n{link_h}\n{link_x}\n'
        if link_cdn:
            all_links += f'{link_cdn}\n'
        b64_data = base64.b64encode(all_links.encode('utf-8')).decode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Subscription-Userinfo', 'upload=0; download=0; total=0')
        self.end_headers()
        self.wfile.write(b64_data.encode('utf-8'))

def main():
    env = load_env()
    port = int(env.get('SUB_PORT', '54328'))
    try:
        class DualStackServer(ThreadingMixIn, HTTPServer):
            daemon_threads = True
            address_family = socket.AF_INET6
            def server_bind(self):
                try:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                except (AttributeError, OSError):
                    pass
                super().server_bind()
        server = DualStackServer(('::', port), SubHandler)
    except Exception:
        class FallbackThreadedServer(ThreadingMixIn, HTTPServer):
            daemon_threads = True
        server = FallbackThreadedServer(('0.0.0.0', port), SubHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()

if __name__ == '__main__':
    main()
EOF_PY
    chmod 700 "${SUB_SERVER_SCRIPT}"
}

setup_sub_system_service() {
    write_sub_server_script
    info "正在配置自适应节点订阅服务守护进程..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        cat > "${SUB_SERVICE_FILE}" <<EOF
[Unit]
Description=ToFu Subscription Service
Documentation=https://github.com/YGGYDW/ToFu
After=network.target tofu.service
PartOf=tofu.service

[Service]
Type=simple
User=root
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes
ExecStart=/usr/bin/python3 ${SUB_SERVER_SCRIPT}
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable tofu-sub >/dev/null 2>&1
        systemctl restart tofu-sub
    else
        start_sub_fallback_service
    fi
    success "ToFu 订阅服务启动成功（端口: ${SUB_PORT}）！"
}

start_sub_service() {
    if [[ "$SUB_ENABLED" != "1" ]]; then
        info "订阅服务已被手动禁用，跳过启动。"
        return 0
    fi
    info "正在启动 ToFu 订阅服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl start tofu-sub >/dev/null 2>&1
    else
        start_sub_fallback_service
    fi
}

stop_sub_service() {
    info "正在停止 ToFu 订阅服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu-sub >/dev/null 2>&1
    fi
    stop_sub_fallback_service
}

restart_sub_service() {
    if [[ "$SUB_ENABLED" != "1" ]]; then
        stop_sub_service
        return 0
    fi
    info "正在重启 ToFu 订阅服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl restart tofu-sub >/dev/null 2>&1
    else
        stop_sub_fallback_service
        start_sub_fallback_service
    fi
}

start_sub_fallback_service() {
    stop_sub_fallback_service
    nohup /usr/bin/python3 "${SUB_SERVER_SCRIPT}" >/dev/null 2>&1 &
    echo $! > "${SUB_FALLBACK_PID_FILE}"
}

stop_sub_fallback_service() {
    if [[ -f "${SUB_FALLBACK_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${SUB_FALLBACK_PID_FILE}" 2>/dev/null)
        if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 0.5
            kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "${SUB_FALLBACK_PID_FILE}"
    fi
    pkill -f "${SUB_SERVER_SCRIPT}" >/dev/null 2>&1 || true
}

is_sub_service_running() {
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl is-active --quiet tofu-sub 2>/dev/null && return 0
    fi
    if [[ -f "${SUB_FALLBACK_PID_FILE}" ]]; then
        local pid
        pid=$(cat "${SUB_FALLBACK_PID_FILE}" 2>/dev/null)
        if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    pgrep -f "${SUB_SERVER_SCRIPT}" >/dev/null 2>&1 && return 0
    if [[ -n "$SUB_PORT" ]]; then
        check_port_occupied "$SUB_PORT" "tcp" && return 0
    fi
    return 1
}


save_env_data() {
    cat > "${DATA_FILE}" <<EOF
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
SUB_PORT=${SUB_PORT:-54328}
SUB_TOKEN="${SUB_TOKEN}"
SUB_ENABLED=${SUB_ENABLED:-1}
CF_CDN_DOMAIN="${CF_CDN_DOMAIN}"
CF_CDN_PORT="${CF_CDN_PORT}"
ACME_EMAIL="${ACME_EMAIL:-}"
ACME_PREFERRED_CA="${ACME_PREFERRED_CA:-letsencrypt}"
EOF
    chmod 600 "$DATA_FILE"
}

load_env_data() {
    local env_file="$DATA_FILE" line key value
    PORT_REALITY=${PORT_REALITY:-$DEFAULT_REALITY_PORT}
    PORT_HY2=${PORT_HY2:-$DEFAULT_HY2_PORT}
    PORT_XHTTP=${PORT_XHTTP:-$DEFAULT_XHTTP_PORT}
    PORT_HOP_PORTS=${PORT_HOP_PORTS:-$DEFAULT_HOP_PORTS}
    SUB_PORT=${SUB_PORT:-}
    SUB_TOKEN=${SUB_TOKEN:-}
    SUB_ENABLED=${SUB_ENABLED:-1}
    CF_CDN_DOMAIN=${CF_CDN_DOMAIN:-}
    CF_CDN_PORT=${CF_CDN_PORT:-}
    ACME_EMAIL=${ACME_EMAIL:-}
    ACME_PREFERRED_CA=${ACME_PREFERRED_CA:-letsencrypt}
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
            IP) [[ "$value" =~ ^[A-Fa-f0-9:.]+$ ]] && IP=$value ;;
            UUID) [[ "$value" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] && printf -v "$key" '%s' "${value,,}" ;;
            PORT_REALITY|PORT_HY2|PORT_XHTTP|SUB_PORT)
                if [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( value >= 1 && value <= 65535 )); then printf -v "$key" '%s' "$value"; fi
                ;;
            PORT_HOP_PORTS) [[ "$value" =~ ^[0-9,-]+$ ]] && printf -v "$key" '%s' "$value" ;;
            REALITY_SNI|TLS_SNI|HY2_DOMAIN)
                if [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then printf -v "$key" '%s' "${value,,}"; fi
                ;;
            REALITY_PUBLIC_KEY|REALITY_PRIVATE_KEY)
                [[ "$value" =~ ^[A-Za-z0-9_+/=-]+$ ]] && printf -v "$key" '%s' "$value"
                ;;
            REALITY_SHORT_ID)
                [[ "$value" =~ ^[[:xdigit:]]{8,16}$ ]] && printf -v "$key" '%s' "$value"
                ;;
            CERT_SHA256|HY2_PIN_SHA256)
                [[ "$value" =~ ^[[:xdigit:]]{64}$ ]] && printf -v "$key" '%s' "${value,,}"
                ;;
            HY2_MODE)
                [[ "$value" =~ ^[123]$ ]] && printf -v "$key" '%s' "$value"
                ;;
            SUB_TOKEN)
                [[ "$value" =~ ^[[:alnum:]_-]+$ ]] && printf -v "$key" '%s' "$value"
                ;;
            SUB_ENABLED)
                [[ "$value" =~ ^[01]$ ]] && printf -v "$key" '%s' "$value"
                ;;
            CF_CDN_DOMAIN)
                if [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then printf -v "$key" '%s' "${value,,}"; fi
                ;;
            CF_CDN_PORT)
                if [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( value >= 1 && value <= 65535 )); then printf -v "$key" '%s' "$value"; fi
                ;;
            ACME_EMAIL)
                [[ "$value" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] && printf -v "$key" '%s' "$value"
                ;;
            ACME_PREFERRED_CA)
                [[ "$value" =~ ^(letsencrypt|zerossl)$ ]] && printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$env_file"
    if [[ -z "$SUB_PORT" ]]; then
        SUB_PORT=$(find_free_sub_port)
    fi
    if [[ -z "$SUB_TOKEN" ]]; then
        SUB_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n')
    fi
}

generate_client_links() {
    local host_ip="${IP}"
    if [[ "${IP}" =~ : ]]; then
        host_ip="[${IP}]"
    fi

    local fragment_reality="REALITY-VLESS%2BXTLS-Vision-%EF%BC%88%E4%B8%BB%E5%8A%9B%E8%8A%82%E7%82%B9%EF%BC%89"
    local fragment_hy2="Hysteria%202-%EF%BC%88UDP%E7%AB%AF%E5%8F%A3%E8%B7%B3%E8%B7%83%EF%BC%89"
    local fragment_xhttp="XHTTP-VLESS%2BTLS-%28%E5%8F%AF%E5%A5%97CDN%2BWARP%29"
    LINK_REALITY="vless://${UUID}@${host_ip}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#${fragment_reality}"

    if [[ "$HY2_MODE" == "2" && -n "$HY2_DOMAIN" ]]; then
        LINK_HY2="hysteria2://${UUID}@${HY2_DOMAIN}:${PORT_HY2}?mport=${PORT_HOP_PORTS//,/%2C}&ports=${PORT_HOP_PORTS//,/%2C}&security=tls&alpn=h3&sni=${HY2_DOMAIN}#${fragment_hy2}"
    else
        LINK_HY2="hysteria2://${UUID}@${host_ip}:${PORT_HY2}?mport=${PORT_HOP_PORTS//,/%2C}&ports=${PORT_HOP_PORTS//,/%2C}&security=tls&alpn=h3&pinSHA256=${HY2_PIN_SHA256}&sni=${TLS_SNI}#${fragment_hy2}"
    fi

    LINK_XHTTP="vless://${UUID}@${host_ip}:${PORT_XHTTP}?encryption=none&security=tls&sni=${TLS_SNI}&type=xhttp&path=%2Fxraybox-${UUID}&mode=auto&pcs=${CERT_SHA256}&pinnedPeerCertSha256=${CERT_SHA256}&hpkp=${CERT_SHA256}#${fragment_xhttp}"

    LINK_CDN=""
    if [[ -n "$CF_CDN_DOMAIN" ]]; then
        local p_cdn="${CF_CDN_PORT:-2053}"
        local fragment_cdn="XHTTP-%EF%BC%88CDN%E5%8F%AF%E6%8D%A2%E4%BC%98%E9%80%89IP%EF%BC%89"
        LINK_CDN="vless://${UUID}@${CF_CDN_DOMAIN}:${p_cdn}?encryption=none&security=tls&sni=${CF_CDN_DOMAIN}&host=${CF_CDN_DOMAIN}&type=xhttp&path=%2Fxraybox-${UUID}&mode=auto#${fragment_cdn}"
    fi

    local sub_url="http://${host_ip}:${SUB_PORT:-54328}/sub/${SUB_TOKEN}"
    cat > "${NODES_TXT}" <<EOF
========================================================================
                      ToFu 节点配置直连与备份
========================================================================
【通用自适应订阅链接】
${sub_url}
────────────────────────────────────────────────────────────────────────
【节点1】REALITY-VLESS+XTLS-Vision-（主力节点）
${LINK_REALITY}
────────────────────────────────────────────────────────────────────────
【节点2】Hysteria 2-（UDP端口跳跃）
${LINK_HY2}
────────────────────────────────────────────────────────────────────────
【节点3】XHTTP-VLESS+TLS-(可套CDN+WARP)
${LINK_XHTTP}
EOF
    if [[ -n "$LINK_CDN" ]]; then
        cat >> "${NODES_TXT}" <<EOF
────────────────────────────────────────────────────────────────────────
【节点4】XHTTP-（CDN可换优选IP）
${LINK_CDN}
EOF
    fi
    echo "========================================================================" >> "${NODES_TXT}"
    chmod 600 "${NODES_TXT}"
}

show_node_info() {
    load_env_data
    if [[ ! -f "${CONFIG_FILE}" || ! -f "${DATA_FILE}" ]]; then
        error "未检测到 ToFu 节点配置，请先运行安装！"
        return 1
    fi

    generate_client_links

    local host_ip="${IP}"
    if [[ "${IP}" =~ : ]]; then
        host_ip="[${IP}]"
    fi
    local sub_url="http://${host_ip}:${SUB_PORT}/sub/${SUB_TOKEN}"

    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    if [[ "$1" == "installed" ]]; then
        echo -e "              ${bold}${green}ToFu 节点部署完成！${plain}"
        echo -e "${cyan}========================================================================${plain}"
    fi
    echo -e "                         ${bold}${yellow}ToFu 节点订阅信息${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "【全平台通用订阅链接】(一键导入全部节点，自动适配各客户端格式)\n"
    echo -e "  ${bold}${green}${sub_url}${plain}\n"
    echo -e "【各系统推荐客户端】"
    echo -e "  ├─ Windows : v2rayN、Clash Verge Rev、Karing"
    echo -e "  ├─ macOS   : Clash Verge Rev、Karing"
    echo -e "  ├─ iOS     : Shadowrocket、Karing、V2box、Clash Mi"
    echo -e "  └─ Android : v2rayNG、Karing"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "【备用：单节点原始链接】(如客户端不支持订阅时使用)"
    echo -e "  ▸ 节点 1 (REALITY 主力节点):"
    echo -e "    ${cyan}${LINK_REALITY}${plain}\n"
    echo -e "  ▸ 节点 2 (Hysteria 2 端口跳跃):"
    echo -e "    ${cyan}${LINK_HY2}${plain}\n"
    echo -e "  ▸ 节点 3 (XHTTP 可套CDN+WARP):"
    echo -e "    ${cyan}${LINK_XHTTP}${plain}"
    if [[ -n "$LINK_CDN" ]]; then
        echo -e "\n  ▸ 节点 4 (XHTTP CDN 可换优选IP):"
        echo -e "    ${cyan}${LINK_CDN}${plain}"
    fi
    echo -e "${cyan}========================================================================${plain}"
    echo -e "请选择二维码或订阅操作："
    echo
    echo -e "    ${green}1.${plain} 显示【通用订阅】二维码 (一次导入所有节点)"
    echo
    local qr_label="显示 3 个单节点的二维码"
    [[ -n "$LINK_CDN" ]] && qr_label="显示 4 个单节点的二维码"
    echo -e "    ${green}2.${plain} ${qr_label}"
    echo
    echo -e "    ${green}3.${plain} 订阅管理设置"
    echo
    echo -e "    ${green}0.${plain} 返回管理菜单"
    echo -e "${cyan}========================================================================${plain}"
    while true; do
        read -rp "请输入选项 [默认: 1]: " qr_choice
        qr_choice=${qr_choice:-1}
        case "$qr_choice" in
            1)
                show_qr "通用节点自适应订阅" "${sub_url}"
                echo -e "\n按任意键返回管理菜单..."
                read -n 1 -s -r
                return 0
                ;;
            2)
                show_qr "REALITY-VLESS+XTLS-Vision-（主力节点）" "${LINK_REALITY}"
                show_qr "Hysteria 2-（UDP端口跳跃）" "${LINK_HY2}"
                show_qr "XHTTP-VLESS+TLS-(可套CDN+WARP)" "${LINK_XHTTP}"
                if [[ -n "$LINK_CDN" ]]; then
                    show_qr "XHTTP-（CDN可换优选IP）" "${LINK_CDN}"
                fi
                echo -e "\n按任意键返回管理菜单..."
                read -n 1 -s -r
                return 0
                ;;
            3)
                subscription_management_menu
                return 0
                ;;
            0)
                return 0
                ;;
            *)
                warn "输入错误，请输入 0-3 之间的数字！"
                ;;
        esac
    done
}

subscription_management_menu() {
    load_env_data
    local host_ip="${IP}"
    if [[ "${IP}" =~ : ]]; then
        host_ip="[${IP}]"
    fi

    while true; do
        local sub_base="http://${host_ip}:${SUB_PORT}/sub/${SUB_TOKEN}"
        local is_run="未运行"
        local status_color="${red}"
        if is_sub_service_running; then
            is_run="运行中"
            status_color="${green}"
        fi

        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                         ${bold}${yellow}ToFu 订阅管理设置${plain}"
        echo -e "${cyan}========================================================================${plain}"
        echo -e "  当前订阅状态 : ${status_color}● ${is_run}${plain}"
        echo -e "  当前监听端口 : ${cyan}${SUB_PORT}${plain}"
        local masked_token="${SUB_TOKEN}"
        if [[ ${#SUB_TOKEN} -ge 8 ]]; then
            masked_token="${SUB_TOKEN:0:4}****${SUB_TOKEN: -4}"
        fi
        echo -e "  当前安全密钥 : ${cyan}${masked_token}${plain}"
        echo -e "  完整订阅地址 : ${bold}${green}${sub_base}${plain}"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo
        echo -e "    ${green}1.${plain} 一键重置订阅密钥 Token"
        echo -e "        (如订阅泄露给他人，重置后旧链接立即作废)"
        echo
        echo -e "    ${green}2.${plain} 修改订阅服务监听端口"
        echo -e "        (支持在 50001-60000 间重新随机或自定义)"
        echo
        local toggle_action="停止"
        [[ "$SUB_ENABLED" != "1" ]] && toggle_action="开启"
        echo -e "    ${green}3.${plain} ${toggle_action}订阅服务"
        echo
        echo -e "    ${green}0.${plain} 返回上级菜单"
        echo -e "${cyan}========================================================================${plain}"
        read -rp "请输入操作序号 [0-3]: " sub_opt
        case "$sub_opt" in
            1) reset_sub_token ;;
            2) change_sub_port ;;
            3) toggle_sub_service ;;
            0)
                return 0
                ;;
            *)
                warn "输入错误，请输入 0-3 之间的操作序号！"
                sleep 1
                ;;
        esac
    done
}

reset_sub_token() {
    local confirm
    while true; do
        read -rp "确认重新生成订阅密钥 Token？旧链接将立即失效！[Y/n]: " confirm
        case "$confirm" in
            ""|[yY]|[yY][eE][sS])
                SUB_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n')
                save_env_data
                restart_sub_service
                success "订阅密钥 Token 已重置为: ${SUB_TOKEN}"
                echo -e "\n按任意键返回订阅设置..."
                read -n 1 -s -r
                return 0
                ;;
            [nN]|[nN][oO])
                info "已取消重置。"
                sleep 1
                return 0
                ;;
            *)
                warn "输入无效，请输入 y 确认重置，或输入 n 取消！"
                ;;
        esac
    done
}

change_sub_port() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                       ${bold}${yellow}修改订阅服务监听端口${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "当前订阅端口 : ${cyan}${SUB_PORT}${plain}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "    ${green}1.${plain} 重新随机生成高位端口 (50001-60000)"
    echo
    echo -e "    ${green}2.${plain} 手动自定义输入端口 (1024-65535)"
    echo
    echo -e "    ${green}0.${plain} 取消返回"
    echo -e "${cyan}========================================================================${plain}"
    local p_choice new_sub_port=""
    while true; do
        read -rp "请选择模式 [默认: 1]: " p_choice
        p_choice=${p_choice:-1}
        case "$p_choice" in
            1)
                new_sub_port=$(find_free_sub_port)
                info "已随机选定可用端口: ${new_sub_port}"
                break
                ;;
            2)
                while true; do
                    read -rp "请输入自定义订阅端口 (1024-65535): " custom_p
                    if [[ "$custom_p" =~ ^[0-9]+$ ]] && (( custom_p >= 1024 && custom_p <= 65535 )); then
                        if (( custom_p == SUB_PORT )); then
                            info "输入的端口与当前端口相同，无需修改。"
                            return 0
                        fi
                        if check_port_occupied "$custom_p" "tcp"; then
                            warn "端口 ${custom_p} 已被系统其他进程占用，请换用其他端口！"
                        else
                            new_sub_port="$custom_p"
                            break
                        fi
                    else
                        warn "端口无效，请输入 1024-65535 之间的有效端口！"
                    fi
                done
                break
                ;;
            0)
                return 0
                ;;
            *)
                warn "输入错误，请输入 0-2 之间的选项！"
                ;;
        esac
    done

    if [[ -n "$new_sub_port" ]]; then
        info "正在更新防火墙规则..."
        iptables -D INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || true
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
            ufw delete allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-port="${SUB_PORT}/tcp" >/dev/null 2>&1 || true
        fi

        iptables -I INPUT -p tcp --dport "$new_sub_port" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT -p tcp --dport "$new_sub_port" -j ACCEPT 2>/dev/null || true
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
            ufw allow "${new_sub_port}/tcp" >/dev/null 2>&1 || true
        fi
        if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
            firewall-cmd --permanent --add-port="${new_sub_port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
        fi

        SUB_PORT="$new_sub_port"
        save_env_data
        restart_sub_service
        success "订阅监听端口已成功修改为: ${SUB_PORT}"
        echo -e "\n按任意键返回订阅设置..."
        read -n 1 -s -r
    fi
}

toggle_sub_service() {
    local confirm
    if [[ "$SUB_ENABLED" == "1" ]]; then
        while true; do
            read -rp "确认停止订阅服务？客户端将无法获取节点更新！[Y/n]: " confirm
            case "$confirm" in
                ""|[yY]|[yY][eE][sS])
                    SUB_ENABLED=0
                    save_env_data
                    stop_sub_service
                    success "订阅服务已成功停止。"
                    sleep 1.5
                    return 0
                    ;;
                [nN]|[nN][oO])
                    info "操作已取消。"
                    sleep 1
                    return 0
                    ;;
                *)
                    warn "输入无效，请输入 y 确认停止，或输入 n 取消！"
                    ;;
            esac
        done
    else
        while true; do
            read -rp "确认开启订阅服务？[Y/n]: " confirm
            case "$confirm" in
                ""|[yY]|[yY][eE][sS])
                    SUB_ENABLED=1
                    save_env_data
                    start_sub_service
                    success "订阅服务已成功开启！"
                    sleep 1.5
                    return 0
                    ;;
                [nN]|[nN][oO])
                    info "操作已取消。"
                    sleep 1
                    return 0
                    ;;
                *)
                    warn "输入无效，请输入 y 确认开启，或输入 n 取消！"
                    ;;
            esac
        done
    fi
}

show_cdn_tutorial() {
    local return_target=${1:-"info"}
    clear
    echo -e "${cyan}========================================================================${plain}"
    echo -e "              为节点 3【VLESS + XHTTP + TLS】套 Cloudflare CDN 设置"
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
    echo -e "     - 代理状态 (Proxy): 开启【橙色云 (已代理状态)】"
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
    echo -e "${cyan}------------------------------------------------------------------------${plain}"
    echo -e "教程阅读完毕，按回车 [Enter] 返回..."
    read -r
    if [[ "$return_target" == "info" ]]; then
        show_node_info
    fi
    return 0
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
    echo -e "   ├─ 端口分配: 主端口 8443 │ 动态跳跃段 20000-50000"
    echo -e "   ├─ 核心定位: 【暴力带宽】"
    echo -e "   ├─ 特点属性: 面向 UDP 网络与高延迟/丢包场景，不可套 CDN，两种证书方式可选"
    echo -e "   └─ 调度内核: 客户端调度 ${green}Xray / sing-box${plain} 内核\n"

    echo -e "✅ ${bold}${yellow}节点 3【XHTTP】：${plain}"
    echo -e "   ${bold}VLESS + XHTTP + TLS (可套CDN+WARP)${plain}"
    echo -e "   ├─ 协议架构: 应用层 VLESS │ 传输层 XHTTP │ 安全层 TLS │ 分流扩展 Cloudflare WARP 出口"
    echo -e "   ├─ 端口分配: 端口 2053 (TCP)"
    echo -e "   ├─ 核心定位: 【多样化DIY】"
    echo -e "   ├─ 特点属性: 可直连或经 Cloudflare CDN 回源；源站地址仍可能因 DNS 或旁路访问暴露"
    echo -e "   └─ 调度内核: 客户端调度 ${green}Xray${plain} 内核\n"

    echo -e "${cyan}============================ 请选择部署模式 ============================${plain}"
    echo -e "  ${green}1.${plain} 小白模式 (回车即可)"
    echo
    echo -e "  ${green}2.${plain} 自定义高级模式"
    echo
    echo -e "  ${green}0.${plain} 取消安装并返回"
    echo -e "${cyan}========================================================================${plain}"
    local mode_choice
    while true; do
        read -rp "请输入模式编号 [默认: 1]: " mode_choice
        mode_choice=${mode_choice:-1}
        case "$mode_choice" in
            0)
                info "已取消安装。"
                return 0
                ;;
            1|2)
                break
                ;;
            *)
                warn "输入无效，请输入 1、2 或 0！"
                ;;
        esac
    done

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

        configure_hy2_hop_ports

        while true; do
            read -rp "请输入 XHTTP 端口 [默认: 2053]: " user_xhttp_port
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

    [[ -z "$TLS_SNI" ]] && TLS_SNI="${REALITY_SNI}"
    SUB_PORT=$(find_free_sub_port)
    SUB_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(16))" 2>/dev/null || od -vN 16 -An -tx1 /dev/urandom | tr -d ' \n')
    SUB_ENABLED=1

    echo -e "\n${cyan}========================================================================${plain}"
    info "选定端口: REALITY: ${PORT_REALITY}, Hysteria2 主端口: ${PORT_HY2}，跳跃端口: ${PORT_HOP_PORTS}, XHTTP: ${PORT_XHTTP}, 订阅: ${SUB_PORT}"

    configure_firewalls "${PORT_REALITY}" "${PORT_HY2}" "${PORT_XHTTP}" "${PORT_HOP_PORTS}" "${SUB_PORT}"
    install_xray_core || { error "Xray 核心安装失败，停止部署。"; return 1; }
    if [[ "$mode_choice" == "2" ]]; then generate_credentials "custom"; else generate_credentials "auto"; fi
    save_env_data
    setup_iptables_port_hopping
    generate_server_config
    setup_system_service
    setup_sub_system_service

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

    show_node_info "installed"
}

uninstall_all() {
    clear
    show_logo
    echo -e "${yellow}此操作将完整彻底卸载 ToFu：停止服务、删除程序核心、清理证书工具、撤销系统防火墙与内核规则，恢复纯净系统。${plain}"
    local delete_confirm
    while true; do
        read -rp "确认完整卸载 ToFu？[Y/n]: " delete_confirm
        case "$delete_confirm" in
            ""|[yY]|[yY][eE][sS]) break ;;
            [nN]|[nN][oO])
                info "已取消卸载。"
                return 0
                ;;
            *)
                warn "输入无效，请输入 y 确认卸载，或输入 n 取消！"
                ;;
        esac
    done
    local install_source_path=""
    [[ -f "${CONFIG_DIR}/install_source_path" ]] && IFS= read -r install_source_path < "${CONFIG_DIR}/install_source_path"
    load_env_data

    info "正在停止 ToFu 服务及相关进程..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu >/dev/null 2>&1
        systemctl disable tofu >/dev/null 2>&1
        rm -f "${SYSTEMD_FILE}"
        systemctl stop tofu-sub >/dev/null 2>&1
        systemctl disable tofu-sub >/dev/null 2>&1
        rm -f "${SUB_SERVICE_FILE}"
        systemctl daemon-reload
    elif command -v rc-service >/dev/null 2>&1 || [[ -f "${OPENRC_FILE}" ]]; then
        rc-service tofu stop >/dev/null 2>&1
        rc-update del tofu default >/dev/null 2>&1
        rm -f "${OPENRC_FILE}"
    fi
    stop_fallback_service
    stop_sub_fallback_service
    pkill -9 -f /usr/local/bin/xray >/dev/null 2>&1 || true
    pkill -9 -f "${SUB_SERVER_SCRIPT}" >/dev/null 2>&1 || true
    rm -f "$FALLBACK_PID_FILE" "$SUB_FALLBACK_PID_FILE"

    info "正在清理内核 iptables/ip6tables 端口转发与放行规则..."
    if [[ -f "${IPTABLES_SCRIPT}" ]]; then
        /bin/bash "$IPTABLES_SCRIPT" flush >/dev/null 2>&1 || true
    fi
    while true; do
        local num
        num=$(iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "REDIRECT" | head -n 1 | awk '{print $1}')
        [[ -n "$num" && "$num" =~ ^[0-9]+$ ]] || break
        iptables -t nat -D PREROUTING "$num" 2>/dev/null || break
    done
    while true; do
        local num6
        num6=$(ip6tables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "REDIRECT" | head -n 1 | awk '{print $1}')
        [[ -n "$num6" && "$num6" =~ ^[0-9]+$ ]] || break
        ip6tables -t nat -D PREROUTING "$num6" 2>/dev/null || break
    done

    info "正在清理系统防火墙放行规则..."
    local all_known_ports=(443 8443 2053 10443 18443 12053 80)
    [[ -n "$SUB_PORT" ]] && all_known_ports+=("$SUB_PORT")
    for p in "${all_known_ports[@]}"; do
        iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    for r in 20000:50000 20000:35000 35001:50000; do
        iptables -D INPUT -p udp --dport "$r" -j ACCEPT 2>/dev/null || true
        ip6tables -D INPUT -p udp --dport "$r" -j ACCEPT 2>/dev/null || true
    done

    if command -v ufw >/dev/null 2>&1; then
        for p in "${all_known_ports[@]}"; do
            ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true
            ufw delete allow "${p}/udp" >/dev/null 2>&1 || true
        done
        ufw delete allow 20000:50000/udp >/dev/null 2>&1 || true
        ufw delete allow 20000:35000/udp >/dev/null 2>&1 || true
        ufw delete allow 35001:50000/udp >/dev/null 2>&1 || true
    fi

    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for p in "${all_known_ports[@]}"; do
            firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --permanent --remove-port="${p}/udp" >/dev/null 2>&1 || true
        done
        firewall-cmd --permanent --remove-port="20000-50000/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port="20000-35000/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port="35001-50000/udp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if [[ -d "$HOME/.acme.sh" ]]; then
        local has_certs=0
        if ls "$HOME/.acme.sh"/*/*.cer >/dev/null 2>&1 || ls "$HOME/.acme.sh"/*_ecc/*.cer >/dev/null 2>&1; then
            has_certs=1
        fi
        if [[ $has_certs -eq 1 ]]; then
            local keep_certs="y"
            while true; do
                read -rp "检测到历史申请的有效 SSL 证书，是否保留？保留后重新部署同域名可 0 秒免申复用，防止消耗每周额度 [Y/n]: " keep_certs
                case "${keep_certs:-y}" in
                    [yY]|[yY][eE][sS])
                        info "已为您保留历史 SSL 证书环境，下次部署同域名将直接 0 秒复用。"
                        break
                        ;;
                    [nN]|[nN][oO])
                        info "正在彻底清理 acme.sh 证书工具及历史证书..."
                        "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1 || true
                        (crontab -l 2>/dev/null | grep -v "acme.sh" | crontab -) >/dev/null 2>&1 || true
                        rm -rf "$HOME/.acme.sh"
                        break
                        ;;
                    *)
                        warn "输入无效，请按回车或输入 y 确认保留，或输入 n 彻底清理！"
                        ;;
                esac
            done
        else
            "$HOME/.acme.sh/acme.sh" --uninstall >/dev/null 2>&1 || true
            (crontab -l 2>/dev/null | grep -v "acme.sh" | crontab -) >/dev/null 2>&1 || true
            rm -rf "$HOME/.acme.sh"
        fi
    fi

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
    success "ToFu 全部组件已彻底干净卸载！"
    echo -e "✅ 系统环境、端口防火墙已恢复纯净。\n"
    exit 0
}

start_service() {
    info "正在启动 ToFu 服务..."
    local start_ok=false
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        if systemctl start tofu >/dev/null 2>&1; then
            start_ok=true
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service tofu start >/dev/null 2>&1; then
            start_ok=true
        fi
    else
        if start_fallback_service; then
            start_ok=true
        fi
    fi

    sleep 1
    if [[ "$start_ok" == true ]] && ( pgrep -f "${XRAY_BIN}" >/dev/null 2>&1 || ( [[ -d /run/systemd/system ]] && systemctl is-active --quiet tofu 2>/dev/null ) ); then
        success "ToFu 服务已成功启动！"
    else
        error "ToFu 服务启动失败！请检查配置文件 /etc/tofu/config.json 或运行 'journalctl -u tofu -n 30' 查看错误日志。"
        return 1
    fi
    start_sub_service
}

stop_service() {
    info "正在停止 ToFu 服务..."
    if [[ -d /run/systemd/system ]] || pidof systemd >/dev/null 2>&1; then
        systemctl stop tofu >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service tofu stop >/dev/null 2>&1
    fi
    stop_fallback_service
    stop_sub_service
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
    restart_sub_service
}

switch_to_specific_xray_version() {
    local target_tag="$1"
    local display_name="$2"
    check_arch
    check_os
    local current_ver
    current_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    [[ -n "$current_ver" && "$current_ver" != v* ]] && current_ver="v${current_ver}"

    info "当前运行版本: ${current_ver:-未知} ➔ 目标版本: ${target_tag}"
    if [[ "${current_ver}" == "${target_tag}" ]]; then
        success "当前内核已是 ${display_name} (${current_ver})，无需重复切换！"
        local force_switch
        while true; do
            read -rp "是否强制重新拉取覆盖？[Y/n]: " force_switch
            case "${force_switch:-y}" in
                [yY]|[yY][eE][sS]) break ;;
                [nN]|[nN][oO])
                    read -n 1 -s -r -p "按任意键返回菜单..."
                    return 0
                    ;;
                *) warn "输入无效，请输入 y 强制拉取，或输入 n 取消！" ;;
            esac
        done
    fi

    local backup_bin="${CONFIG_DIR}/xray.upgrade-backup"
    if [[ -x "$XRAY_BIN" ]]; then cp -p "$XRAY_BIN" "$backup_bin" || { error "无法备份当前 Xray，已停止操作。"; return 1; }; fi

    if ! install_xray_core "$target_tag"; then
        rm -f "$backup_bin"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi

    if [[ -f "$CONFIG_FILE" ]] && ! "$XRAY_BIN" -test -config "$CONFIG_FILE"; then
        error "新核心配置检查失败，正在恢复原核心。"
        [[ -f "$backup_bin" ]] && mv -f "$backup_bin" "$XRAY_BIN"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi

    if ! restart_service; then
        error "新核心启动失败，正在恢复原核心。"
        [[ -f "$backup_bin" ]] && mv -f "$backup_bin" "$XRAY_BIN"
        restart_service || true
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi

    rm -f "$backup_bin"
    success "Xray-core 已成功切换至 ${display_name}！"
    read -n 1 -s -r -p "按任意键返回菜单..."
}

upgrade_xray_core() {
    info "正在检测 Xray-core 官方最新版本..."
    check_arch
    check_os
    local release_api
    release_api=$(mktemp) || return 1
    trap 'rm -f "$release_api"' RETURN
    if ! curl -fLsS --connect-timeout 10 --max-time 60 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" -o "$release_api"; then
        error "获取 GitHub 最新版本失败，请检查网络！"
        rm -f "$release_api"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    local latest_tag
    latest_tag=$(jq -er '.tag_name | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$release_api" 2>/dev/null) || latest_tag=""
    rm -f "$release_api"
    if [[ -z "$latest_tag" ]]; then
        error "官方版本号缺失或格式异常，已停止升级。"
        read -n 1 -s -r -p "按任意键返回菜单..."
        return 1
    fi
    switch_to_specific_xray_version "$latest_tag" "官方最新版 ${latest_tag}"
}

xray_kernel_management_menu() {
    while true; do
        clear
        show_logo
        local current_ver
        current_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
        [[ -n "$current_ver" && "$current_ver" != v* ]] && current_ver="v${current_ver}"
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                         ${bold}Xray 内核管理与切换${plain}                    "
        echo -e "   当前内核版本 : ${green}${bold}${current_ver:-未知}${plain}"
        echo -e "${cyan}========================================================================${plain}"
        echo
        local update_flag
        update_flag=$(check_xray_update_status)
        if [[ "$update_flag" == "1" ]]; then
            echo -e "  ${green}1.${plain} 升级 Xray-core 至最新版 ${yellow}【有更新】${plain}"
        else
            echo -e "  ${green}1.${plain} 升级 Xray-core 至最新版"
        fi
        echo
        echo -e "  ${green}2.${plain} Xray v26.6.27（黄金稳定版）"
        echo
        echo -e "  ${green}0.${plain} 返回主菜单"
        echo
        echo -e "${cyan}------------------------------------------------------------------------${plain}"
        read -rp "请输入操作序号 [0-2]: " choice
        case "$choice" in
            1) upgrade_xray_core ;;
            2) switch_to_specific_xray_version "v26.6.27" "Xray v26.6.27 (黄金稳定版)" ;;
            0) return 0 ;;
            *) error "输入错误，请重新选择！"; sleep 1 ;;
        esac
    done
}

show_domain_notice() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                         涉及域名的注意事项"
    echo -e "${cyan}========================================================================${plain}"
    echo
    echo -e "【域名适用范围】"
    echo -e "  ├─ 域名层级 : 一级主域名 (aaa.com)、二级 (bbb.aaa.com)、三级子域名均可使用"
    echo -e "  ├─ 节点 2 (Hy2)   : 用于申请 SSL 证书"
    echo -e "  └─ 节点 3 (XHTTP) : 用于配置 Cloudflare CDN 代理"
    echo
    echo -e "【核心注意事项】"
    echo -e "  ├─ 节点 2 (Hy2)   : 走纯 UDP 协议 ➔ 需【关闭橙色云】"
    echo -e "  ├─ 节点 3 (XHTTP) : 走标准 TCP 协议，套 CDN ➔ 需【开启橙色云】"
    echo -e "  └─ 核心原则       : 同一域名的云朵不能又开又关，共用主域名时必须使用【不同子域名】！"
    echo
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo
    echo -e "【正确示范】(在 Cloudflare 为两个节点解析不同子域名到 A 记录)"
    echo -e "  ${green}✅${plain} 节点 2 (Hy2)   : 解析 hy2.bbb.aaa.com  ➔ 【${green}关闭橙色云${plain}】"
    echo -e "  ${green}✅${plain} 节点 3 (XHTTP) : 解析 ccc.bbb.aaa.com  ➔ 【${green}开启橙色云${plain}】"
    echo
    echo -e "【错误示范】"
    echo -e "  ${red}❌${plain} 节点 2 (Hy2)   : 解析 ccc.bbb.aaa.com  ➔ 【${green}开启橙色云${plain}】"
    echo -e "  ${red}❌${plain} 节点 3 (XHTTP) : 解析 ccc.bbb.aaa.com  ➔ 【${green}关闭橙色云${plain}】"
    echo -e "  ${yellow}‼️${plain} 错误点 : 两个节点共用了同一个子域名 ccc 。"
    echo -e "  ${yellow}‼️${plain} 错误点 : 不同节点错误的使用了橙色云状态。"
    echo
    echo -e "${cyan}========================================================================${plain}"
    read -n 1 -s -r -p "按任意键返回管理菜单..."
    return 0
}

check_xray_update_status() {
    local cache_file="${CONFIG_DIR}/.xray_update_check"
    local now
    now=$(date +%s)
    local last_ts=0 cached_ver="" has_update=0 current_ver
    current_ver=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    current_ver=${current_ver#v}

    if [[ -f "$cache_file" ]]; then
        last_ts=$(awk -F= '$1=="LAST_CHECK_TS"{print $2}' "$cache_file" 2>/dev/null || echo 0)
        cached_ver=$(awk -F= '$1=="LATEST_VER"{print $2}' "$cache_file" 2>/dev/null || echo "")
        has_update=$(awk -F= '$1=="HAS_UPDATE"{print $2}' "$cache_file" 2>/dev/null || echo 0)
    fi

    if (( now - last_ts > 86400 || last_ts == 0 )); then
        local latest_tag
        latest_tag=$(curl -sL --connect-timeout 3 --max-time 5 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null)
        if [[ "$latest_tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            cached_ver=${latest_tag#v}
            last_ts=$now
        fi
    fi

    if [[ -n "$cached_ver" && -n "$current_ver" && "$cached_ver" != "$current_ver" ]]; then
        has_update=1
    else
        has_update=0
    fi

    mkdir -p "$CONFIG_DIR" 2>/dev/null || true
    cat > "$cache_file" 2>/dev/null <<EOF
LAST_CHECK_TS=${last_ts}
LATEST_VER=${cached_ver}
HAS_UPDATE=${has_update}
EOF
    echo "$has_update"
}

get_cf_egress_banner() {
    local title color frame
    if is_warp_egress_enabled; then
        title="● Cloudflare WARP 出口"
        color=$green
    else
        title="○ 原生 VPS 直连"
        color=$yellow
    fi
    frame=$(python3 - "$title" <<'PY'
import sys, unicodedata, re

def visible_width(s):
    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', s)
    w = 0
    for ch in clean:
        if unicodedata.category(ch) in ('Mn', 'Cf'):
            continue
        ea = unicodedata.east_asian_width(ch)
        if ea in ('W', 'F'):
            w += 2
        else:
            w += 1
    return w

title = sys.argv[1]
content = "   " + title + "   "
w = visible_width(content)
print("╭" + "─" * (w + 2) + "╮")
print("│ " + content + " │")
print("╰" + "─" * (w + 2) + "╯")
PY
)
    echo -e "${color}${frame}${plain}"
}

show_dashboard_panel() {
    local pid
    pid=$(pgrep -f "${XRAY_BIN}" | head -n 1)
    local mem_mb="0.0"
    local cpu_usage="0.0"
    if [[ -n "$pid" ]]; then
        local mem_kb
        mem_kb=$(grep -i VmRSS /proc/${pid}/status 2>/dev/null | awk '{print $2}')
        if [[ -n "$mem_kb" ]]; then
            mem_mb=$(awk -v k="$mem_kb" 'BEGIN {printf "%.1f", k/1024}')
        fi
        cpu_usage=$(ps -p "${pid}" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0.1")
        [[ -z "$cpu_usage" ]] && cpu_usage="0.1"
    fi

    local bbr_flag=0
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        bbr_flag=1
    fi

    local os_pretty=""
    if [[ -f /etc/os-release ]]; then
        os_pretty=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    fi
    [[ -z "$os_pretty" ]] && os_pretty="${OS_TYPE} (${ARCH_NAME})"

    local xray_raw xray_ver ver_date ver_display
    xray_raw=$("${XRAY_BIN}" version 2>/dev/null | head -n 1 | awk '{print $2}')
    xray_ver=${xray_raw#v}
    if [[ "$xray_ver" =~ ^([0-9]{2})\.([0-9]{1,2})\.([0-9]{1,2})$ ]]; then
        ver_date="20${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        ver_display="Xray-core v${xray_ver} (${ver_date})"
    elif [[ -n "$xray_ver" ]]; then
        ver_display="Xray-core v${xray_ver}"
    else
        ver_display="Xray-core v26"
    fi

    local ipv4="无" ipv6="无"
    local ip_cache="/tmp/tofu_ip_cache"
    if [[ -f "$ip_cache" ]]; then
        local cache_v4 cache_v6
        cache_v4=$(grep -E '^IPV4=' "$ip_cache" 2>/dev/null | cut -d= -f2-)
        cache_v6=$(grep -E '^IPV6=' "$ip_cache" 2>/dev/null | cut -d= -f2-)
        [[ -n "$cache_v4" ]] && ipv4="$cache_v4"
        [[ -n "$cache_v6" ]] && ipv6="$cache_v6"
    else
        if [[ "$IP" =~ : ]]; then
            ipv6="$IP"
            local v4
            v4=$(curl -s4m2 "https://api.ipify.org" 2>/dev/null || curl -s4m2 "https://icanhazip.com" 2>/dev/null || echo "")
            [[ -n "$v4" ]] && ipv4="$v4"
        else
            [[ -n "$IP" ]] && ipv4="$IP"
            local v6
            v6=$(curl -s6m2 "https://api64.ipify.org" 2>/dev/null || echo "")
            [[ -n "$v6" ]] && ipv6="$v6"
        fi
        echo "IPV4=${ipv4}" > "$ip_cache" 2>/dev/null || true
        echo "IPV6=${ipv6}" >> "$ip_cache" 2>/dev/null || true
    fi

    local warp_flag=0
    if is_warp_egress_enabled; then
        warp_flag=1
    fi

    local p_reality="${PORT_REALITY:-443}"
    local p_hy2="${PORT_HY2:-8443}"
    local p_hop="${PORT_HOP_PORTS:-20000-50000}"
    local p_xhttp="${PORT_XHTTP:-2053}"
    local p_sub="${SUB_PORT:-54328}"
    local cdn_domain="${CF_CDN_DOMAIN:-}"
    local cdn_port="${CF_CDN_PORT:-2053}"

    local p_reality_listen=0 p_reality_proc=""
    local p_hy2_listen=0 p_hy2_proc=""
    local p_xhttp_listen=0 p_xhttp_proc=""
    local p_sub_listen=0 p_sub_proc=""
    local p_80_listen=0 p_80_proc=""

    local ss_tln ss_tlnp ss_uln ss_ulnp
    ss_tln=$(ss -tln 2>/dev/null)
    ss_tlnp=$(ss -tlnp 2>/dev/null)
    ss_uln=$(ss -uln 2>/dev/null)
    ss_ulnp=$(ss -ulnp 2>/dev/null)

    if [[ -n "$pid" ]]; then
        grep -qE "[: ]${p_reality} " <<< "$ss_tln" && p_reality_listen=1
        grep -qE "[: ]${p_hy2} " <<< "$ss_uln" && p_hy2_listen=1
        grep -qE "[: ]${p_xhttp} " <<< "$ss_tln" && p_xhttp_listen=1
    fi
    if is_sub_service_running; then
        p_sub_listen=1
    fi

    if [[ "$p_reality_listen" -eq 0 ]] && grep -qE "[: ]${p_reality} " <<< "$ss_tln"; then
        p_reality_proc=$(grep -E "[: ]${p_reality}[ \t]" <<< "$ss_tlnp" | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        [[ -z "$p_reality_proc" || "$p_reality_proc" == *"("* ]] && p_reality_proc=$(lsof -iTCP:${p_reality} -sTCP:LISTEN -t 2>/dev/null | head -n 1 | xargs -r ps -o comm= 2>/dev/null)
    fi
    if [[ "$p_hy2_listen" -eq 0 ]] && grep -qE "[: ]${p_hy2} " <<< "$ss_uln"; then
        p_hy2_proc=$(grep -E "[: ]${p_hy2}[ \t]" <<< "$ss_ulnp" | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        [[ -z "$p_hy2_proc" || "$p_hy2_proc" == *"("* ]] && p_hy2_proc=$(lsof -iUDP:${p_hy2} -t 2>/dev/null | head -n 1 | xargs -r ps -o comm= 2>/dev/null)
    fi
    if [[ "$p_xhttp_listen" -eq 0 ]] && grep -qE "[: ]${p_xhttp} " <<< "$ss_tln"; then
        p_xhttp_proc=$(grep -E "[: ]${p_xhttp}[ \t]" <<< "$ss_tlnp" | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        [[ -z "$p_xhttp_proc" || "$p_xhttp_proc" == *"("* ]] && p_xhttp_proc=$(lsof -iTCP:${p_xhttp} -sTCP:LISTEN -t 2>/dev/null | head -n 1 | xargs -r ps -o comm= 2>/dev/null)
    fi
    if [[ "$p_sub_listen" -eq 0 ]] && grep -qE "[: ]${p_sub} " <<< "$ss_tln"; then
        p_sub_proc=$(grep -E "[: ]${p_sub}[ \t]" <<< "$ss_tlnp" | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        [[ -z "$p_sub_proc" || "$p_sub_proc" == *"("* ]] && p_sub_proc=$(lsof -iTCP:${p_sub} -sTCP:LISTEN -t 2>/dev/null | head -n 1 | xargs -r ps -o comm= 2>/dev/null)
    fi
    if grep -qE '[: ]80 ' <<< "$ss_tln"; then
        p_80_listen=1
        p_80_proc=$(grep -E '[: ]80[ \t]' <<< "$ss_tlnp" | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        [[ -z "$p_80_proc" || "$p_80_proc" == *"("* ]] && p_80_proc=$(lsof -iTCP:80 -sTCP:LISTEN -t 2>/dev/null | head -n 1 | xargs -r ps -o comm= 2>/dev/null)
    fi

    python3 - "$pid" "$mem_mb" "$cpu_usage" "$bbr_flag" "$os_pretty" "$ver_display" "$ipv4" "$ipv6" "$warp_flag" \
        "$p_reality" "$p_reality_listen" "$p_reality_proc" \
        "$p_hy2" "$p_hy2_listen" "$p_hy2_proc" "$p_hop" \
        "$p_xhttp" "$p_xhttp_listen" "$p_xhttp_proc" \
        "$p_sub" "$p_sub_listen" "$p_sub_proc" \
        "$cdn_domain" "$cdn_port" "$p_80_listen" "$p_80_proc" <<'PY'
import sys, re, unicodedata

(
    pid, mem_mb, cpu_usage, bbr_flag,
    os_pretty, ver_display, ipv4, ipv6, warp_flag,
    p_reality, p_reality_listen, p_reality_proc,
    p_hy2, p_hy2_listen, p_hy2_proc, p_hop,
    p_xhttp, p_xhttp_listen, p_xhttp_proc,
    p_sub, p_sub_listen, p_sub_proc,
    cdn_domain, cdn_port,
    p_80_listen, p_80_proc
) = sys.argv[1:27]

C_RESET  = '\x1b[0m'
C_RED    = '\x1b[0;31m'
C_GREEN  = '\x1b[0;32m'
C_YELLOW = '\x1b[0;33m'
C_CYAN   = '\x1b[0;36m'
C_WHITE  = '\x1b[0;37m'

def visible_width(s):
    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', s)
    w = 0
    for ch in clean:
        if unicodedata.category(ch) in ('Mn', 'Cf'):
            continue
        ea = unicodedata.east_asian_width(ch)
        if ea in ('W', 'F'):
            w += 2
        else:
            w += 1
    return w

is_running = bool(pid.strip())
status_text = f"{C_GREEN}[ 运行中 ]{C_RESET}" if is_running else f"{C_RED}[ 未运行 ]{C_RESET}"
bbr_status = f"{C_GREEN}BBR 已开启{C_RESET}" if bbr_flag == "1" else f"{C_YELLOW}BBR 未开启{C_RESET}"

if is_running:
    proc_info = f"PID {C_CYAN}{pid}{C_RESET}  |  内存 {C_GREEN}{mem_mb}MB{C_RESET}  |  CPU {C_CYAN}{cpu_usage}%{C_RESET}  |  {bbr_status}"
else:
    proc_info = f"PID {C_WHITE}-{C_RESET}  |  内存 {C_WHITE}0.0MB{C_RESET}  |  CPU {C_WHITE}0.0%{C_RESET}  |  {bbr_status}"

os_str = f"{C_YELLOW}{os_pretty}{C_RESET}"
ver_str = f"{C_CYAN}{ver_display}{C_RESET}"
ipv4_str = f"{C_CYAN}{ipv4}{C_RESET}" if ipv4 != "无" else "无"
ipv6_str = f"{C_CYAN}{ipv6}{C_RESET}" if ipv6 != "无" else "无"
warp_status = f"{C_GREEN}● 已配置 [ Cloudflare WARP ]{C_RESET}" if warp_flag == "1" else f"{C_YELLOW}[ 原生 VPS 直连 ]{C_RESET}"
cdn_status = f"{C_GREEN}● 已配置 [ {cdn_domain}:{cdn_port} ]{C_RESET}" if cdn_domain else f"{C_YELLOW}○ 未配置{C_RESET}"

def format_port_status(port_str, is_listening, occupant_proc):
    if is_listening == "1":
        return f"{C_GREEN}{port_str}{C_RESET}"
    if occupant_proc:
        return f"{C_RED}{port_str} [已占用: {occupant_proc}]{C_RESET}"
    return f"{C_RED}{port_str} [未运行]{C_RESET}"

r_port = format_port_status(p_reality, p_reality_listen, p_reality_proc)
h_port = format_port_status(p_hy2, p_hy2_listen, p_hy2_proc)
if p_hy2_listen == "1":
    hop_str = f"{C_GREEN}{p_hop}{C_RESET}"
else:
    hop_str = f"{C_RED}{p_hop}{C_RESET}"

x_port = format_port_status(p_xhttp, p_xhttp_listen, p_xhttp_proc)
s_port = format_port_status(p_sub, p_sub_listen, p_sub_proc)

if p_80_listen == "1":
    proc_desc = f": {p_80_proc}" if p_80_proc else ""
    c_port = f"{C_RED}80 [已占用{proc_desc}]{C_RESET}"
else:
    c_port = f"{C_GREEN}80 [空闲待用]{C_RESET}"

raw_rows = [
    "运行状态  : " + status_text,
    "进程信息  : " + proc_info,
    "系统环境  : " + os_str,
    "核心版本  : " + ver_str,
    "---sep---",
    "IPv4 地址 : " + ipv4_str,
    "IPv6 地址 : " + ipv6_str,
    "CDN 入站  : " + cdn_status,
    "XHTTP出站 : " + warp_status,
    "---sep---",
    "监听端口  :",
    " - 1. REALITY : " + r_port,
    f" - 2. Hy2     : {h_port} (端口跳跃: {hop_str})",
    " - 3. XHTTP   : " + x_port,
    " - 4. 订阅端口 : " + s_port,
    " - 5. 证书端口 : " + c_port,
]

max_content_w = max(visible_width(r) for r in raw_rows if r != "---sep---")
W = max(72, max_content_w + 6)

def row(content):
    pad = W - 6 - visible_width(content)
    if pad < 0:
        pad = 0
    return '|  ' + content + ' ' * pad + '  |'

line = '+-' + '-' * (W - 4) + '-+'
title = "ToFu 节点部署管理"
t_w = visible_width(title)
left_space = (W - 2 - t_w) // 2
right_space = W - 2 - left_space - t_w
title_row = '|' + ' ' * left_space + title + ' ' * right_space + '|'

print(line)
print(title_row)
print(line)
for r in raw_rows:
    if r == "---sep---":
        print(line)
    else:
        print(row(r))
print(line)
PY
}

show_warp_success_card() {
    local frame
    frame=$(python3 <<'PY'
import sys, re, unicodedata
lines = ["节点 3 XHTTP-VLESS+TLS 节点", "✅已成功配置 WARP 出站✅"]
def visible_width(s):
    clean = re.sub(r'\x1b\[[0-9;]*[a-zA-Z]', '', s)
    return sum(0 if unicodedata.category(c) in ("Mn", "Cf") else 2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in clean)
w = max(visible_width(s) for s in lines)
def row(s):
    padding = w - visible_width(s)
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
    while true; do
        read -r -p "确认切换吗？[Y/n]: " answer
        case "$answer" in
            ""|[yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO])
                info "已取消切换。"
                read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."
                return 1
                ;;
            *)
                warn "输入无效，请输入 y 确认切换，或输入 n 取消！"
                ;;
        esac
    done
}

toggle_cf_egress() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                         切换节点 3 出口分流模式"
    echo -e "${cyan}========================================================================${plain}"

    local is_cf_on=false
    if is_warp_egress_enabled; then
        is_cf_on=true
    fi

    if [[ "$is_cf_on" == true ]]; then
        echo -e "当前状态: ${green}【● Cloudflare WARP 出口模式】${plain}"
        echo -e "即将切换为: ${yellow}【○ 原生 VPS 直连出口模式】${plain}\n"
        confirm_warp_toggle || return 0

        info "正在更新 Xray 路由规则至原生直连..."
        set_xhttp_warp_egress off || { read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."; return 1; }
        success "已成功切换为【○ 原生 VPS 直连出口模式】！"
        echo -e "✅ 此时为 VPS 原生出站。\n"
        read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."
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
                read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."
                return 1
            fi
        else
            error "安装 Cloudflare 官方客户端失败，请检查 VPS 外网连接！"
            read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."
            return 1
        fi

        info "正在更新 Xray 路由规则至 Cloudflare 出口..."
        set_xhttp_warp_egress on || { read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."; return 1; }
        success "已成功切换为【● Cloudflare】出口模式！"
        
        success "WARP 代理出口验证成功，出口 IP: ${test_ip}"
        echo
        show_warp_success_card
        echo
        read -n 1 -s -r -p "按任意键返回 Cloudflare CDN + WARP..."
    fi
}

cf_inbound_cdn_menu() {
    load_env_data
    while true; do
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                         ${bold}${yellow}Cloudflare 入站 CDN 设置${plain}"
        echo -e "${cyan}========================================================================${plain}"
        if [[ -n "$CF_CDN_DOMAIN" ]]; then
            echo -e "  当前入站 CDN 状态 : ${green}● 已配置 [ ${CF_CDN_DOMAIN}:${CF_CDN_PORT:-2053} ]${plain}"
        else
            echo -e "  当前入站 CDN 状态 : ${yellow}○ 未配置${plain}"
        fi
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo
        echo -e "    ${green}1.${plain} Cloudflare CDN 设置说明"
        echo
        echo -e "    ${green}2.${plain} 入站 CDN 设置"
        if [[ -n "$CF_CDN_DOMAIN" ]]; then
            echo
            echo -e "    ${green}3.${plain} 清除入站 CDN 节点配置"
        fi
        echo
        echo -e "    ${green}9.${plain} 返回上级菜单"
        echo
        echo -e "    ${green}0.${plain} 返回主菜单"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        read -rp "请输入操作序号 [默认: 2]: " sub_choice
        sub_choice=${sub_choice:-2}
        case "$sub_choice" in
            1)
                show_cdn_tutorial "cf_inbound"
                ;;
            2)
                setup_cf_inbound_cdn
                return 0
                ;;
            3)
                if [[ -n "$CF_CDN_DOMAIN" ]]; then
                    clear_cf_inbound_cdn
                else
                    warn "输入错误，请重新选择！"
                    sleep 1
                fi
                ;;
            9)
                return 0
                ;;
            0)
                return 99
                ;;
            *)
                warn "输入错误，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

render_cf_port_status() {
    local cf_ports=("443" "2053" "2083" "2087" "2096" "8443")
    local status_bar=""
    local best_def=""
    local first_avail=""

    for p in "${cf_ports[@]}"; do
        local is_occ=0
        if [[ "$p" == "$PORT_REALITY" || "$p" == "$PORT_HY2" || "$p" == "$PORT_XHTTP" || "$p" == "$SUB_PORT" ]]; then
            is_occ=1
        elif check_port_occupied "$p" "tcp"; then
            is_occ=1
        fi

        local item=""
        if [[ $is_occ -eq 0 ]]; then
            item="${green}✅${p}${plain}"
            if [[ -z "$first_avail" ]]; then first_avail="$p"; fi
            if [[ "$p" == "2053" ]]; then best_def="2053"; fi
        else
            item="${red}❌${p}${plain}"
        fi

        if [[ -z "$status_bar" ]]; then
            status_bar="$item"
        else
            status_bar="${status_bar}  |  ${item}"
        fi
    done

    if [[ -z "$best_def" ]]; then
        best_def="${first_avail:-2053}"
    fi

    CF_PORT_STATUS_BAR="$status_bar"
    CF_PORT_RECOMMENDED_DEF="$best_def"
}

setup_cf_inbound_cdn() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                       ${bold}${yellow}配置 Cloudflare 入站 CDN${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "说明：此域名对应客户端的【连接地址】、【伪装域名 (Host)】与【SNI】。"
    echo -e "      须已在 Cloudflare 解析并开启【橙色云 (已代理)】。"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"

    local input_domain=""
    while true; do
        read -rp "你在Cloudflare添加的域名: " input_domain
        input_domain=$(echo "$input_domain" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        if [[ -z "$input_domain" ]]; then
            warn "域名不能为空，请重新输入！"
            continue
        fi
        if ! [[ "$input_domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; then
            warn "域名格式不正确，请输入有效域名（如: cdn.example.com）！"
            continue
        fi

        local confirm_domain
        while true; do
            read -rp "请再次确认域名 [ ${input_domain} ]？[Y/n]: " confirm_domain
            case "$confirm_domain" in
                ""|[yY]|[yY][eE][sS])
                    break 2
                    ;;
                [nN]|[nN][oO])
                    info "请重新输入域名..."
                    break
                    ;;
                *)
                    warn "输入无效，请按回车或输入 y 确认，或输入 n 重新输入！"
                    ;;
            esac
        done
    done

    local input_port=""
    local valid_cf_ports=("443" "2053" "2083" "2087" "2096" "8443")
    while true; do
        echo -e "\n${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        render_cf_port_status
        echo -e "当前端口池状态 :  ${CF_PORT_STATUS_BAR}"
        read -rp "请输入节点 4 代理端口 [默认: ${CF_PORT_RECOMMENDED_DEF}]: " input_port
        input_port=${input_port:-$CF_PORT_RECOMMENDED_DEF}
        input_port=$(echo "$input_port" | tr -d ' ')
        
        local port_valid=0
        for p in "${valid_cf_ports[@]}"; do
            if [[ "$p" == "$input_port" ]]; then
                port_valid=1
                break
            fi
        done
        if [[ "$port_valid" -ne 1 ]]; then
            warn "端口无效！Cloudflare 官方 HTTPS 代理仅支持：443、2053、2083、2087、2096、8443"
            continue
        fi

        local is_occ=0
        if [[ "$input_port" == "$PORT_REALITY" || "$input_port" == "$PORT_HY2" || "$input_port" == "$PORT_XHTTP" || "$input_port" == "$SUB_PORT" ]]; then
            is_occ=1
        elif check_port_occupied "$input_port" "tcp"; then
            is_occ=1
        fi
        if [[ $is_occ -eq 1 ]]; then
            warn "端口 ${input_port} 处于已被占用状态 (❌)，请在标有 ✅ 的可用端口中选择！"
            continue
        fi

        local confirm_port
        while true; do
            read -rp "确认端口: ${input_port}？[Y/n]: " confirm_port
            case "$confirm_port" in
                ""|[yY]|[yY][eE][sS])
                    break 2
                    ;;
                [nN]|[nN][oO])
                    info "请重新输入端口..."
                    break
                    ;;
                *)
                    warn "输入无效，请按回车或输入 y 确认，或输入 n 重新输入！"
                    ;;
            esac
        done
    done

    CF_CDN_DOMAIN="$input_domain"
    CF_CDN_PORT="$input_port"
    save_env_data
    restart_sub_service
    success "入站 CDN 节点配置完成！已新增【节点 4（XHTTP CDN 可换优选IP）】。"
    sleep 1.2
    show_node_info
}

clear_cf_inbound_cdn() {
    if [[ -z "$CF_CDN_DOMAIN" ]]; then
        info "当前未配置入站 CDN 节点，无需清除。"
        sleep 1
        return 0
    fi
    local confirm_clear
    while true; do
        read -rp "确认清除入站 CDN 节点配置？[Y/n]: " confirm_clear
        case "$confirm_clear" in
            ""|[yY]|[yY][eE][sS])
                CF_CDN_DOMAIN=""
                CF_CDN_PORT=""
                save_env_data
                restart_sub_service
                success "已清除入站 CDN 节点配置。"
                sleep 1
                return 0
                ;;
            [nN]|[nN][oO])
                info "操作已取消。"
                sleep 1
                return 0
                ;;
            *)
                warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！"
                ;;
        esac
    done
}

cloudflare_cdn_menu() {
    local return_target=${1:-"main"}
    while true; do
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                      Cloudflare CDN + WARP 设置            "
        echo -e "${cyan}========================================================================${plain}"
        echo -e "【当前节点 3 出口状态】:"
        get_cf_egress_banner
        echo -e " ✅ 提示: 入站 CDN 、出站 WARP 设置，仅对节点 3 【VLESS + XHTTP + TLS】 生效。"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo
        echo -e "  ${green}1.${plain} 入站 CDN"
        echo
        local toggle_label="出站 切换为【● Cloudflare WARP 出口】"
        if is_warp_egress_enabled; then
            toggle_label="出站 切换为【○ 原生 VPS 直连出口】"
        fi
        echo -e "  ${green}2.${plain} ${toggle_label}"
        echo
        echo -e "  ${green}0.${plain} 返回管理菜单"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        read -rp "请输入操作序号 [0-2]: " cf_choice
        case "$cf_choice" in
            1)
                cf_inbound_cdn_menu
                if [[ $? -eq 99 ]]; then
                    if [[ "$return_target" == "info" ]]; then
                        show_node_info
                    fi
                    return 0
                fi
                ;;
            2)
                toggle_cf_egress
                ;;
            0)
                if [[ "$return_target" == "info" ]]; then
                    show_node_info
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
    pkill -9 -x xray >/dev/null 2>&1 || true
    pkill -9 -f "^${XRAY_BIN}" >/dev/null 2>&1 || true
    if [[ -f "${IPTABLES_SCRIPT}" ]]; then
        /bin/bash "${IPTABLES_SCRIPT}" flush >/dev/null 2>&1 || true
    fi
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp >/dev/null 2>&1 || true; fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --add-port=80/tcp >/dev/null 2>&1 || true
    fi
    rm -f "${CONFIG_FILE}" "${DATA_FILE}" "${NODES_TXT}"
    CF_CDN_DOMAIN=""
    CF_CDN_PORT=""
    success "历史服务已停止，端口与转发规则已全部释放。"
}

validate_node_port_input() {
    local port="$1"
    local proto="${2:-tcp}"
    local cur_port="$3"
    local node_name="$4"

    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        warn "端口无效！请输入 1-65535 之间的有效端口号！"
        return 1
    fi

    if (( port == 80 )); then
        warn "【安全拦截】80 端口已被 ToFu 脚本严格保留用于 ACME Standalone 证书申请与自动化静默续签！"
        echo -e "${yellow}为确保 SSL 证书签发与自动续期不受阻断，请勿将代理节点绑定至 80 端口。${plain}\n"
        return 1
    fi

    if [[ -n "$cur_port" ]] && (( port == cur_port )); then
        info "输入端口与当前【${node_name}】端口相同 (${cur_port})，无需修改。"
        return 2
    fi

    local conflict_node=""
    if [[ "$node_name" != *"Reality"* && -n "$PORT_REALITY" && "$port" == "$PORT_REALITY" ]]; then
        conflict_node="节点 1 (REALITY)"
    elif [[ "$node_name" != *"Hysteria"* && -n "$PORT_HY2" && "$port" == "$PORT_HY2" ]]; then
        conflict_node="节点 2 (Hysteria 2)"
    elif [[ "$node_name" != *"XHTTP"* && -n "$PORT_XHTTP" && "$port" == "$PORT_XHTTP" ]]; then
        conflict_node="节点 3 (XHTTP)"
    elif [[ "$node_name" != *"订阅"* && -n "$SUB_PORT" && "$port" == "$SUB_PORT" ]]; then
        conflict_node="订阅 Web 服务"
    fi

    if [[ -n "$conflict_node" ]]; then
        warn "端口冲突！端口 ${port} 已被当前 ToFu 系统内的【${conflict_node}】占用！请更换其他端口。"
        return 1
    fi

    if check_port_occupied "$port" "$proto"; then
        warn "端口 ${port} (${proto^^}) 已被系统其他运行中的进程占用！请更换其他可用端口。"
        return 1
    fi

    return 0
}

is_port_in_hop_range() {
    local target_p="$1"
    local hop_list="$2"
    [[ -z "$target_p" || -z "$hop_list" ]] && return 1
    local IFS=','
    local -a parts
    read -ra parts <<< "$hop_list"
    for token in "${parts[@]}"; do
        if [[ "$token" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
            local s=$((10#${BASH_REMATCH[1]}))
            local e=$((10#${BASH_REMATCH[2]}))
            if (( target_p >= s && target_p <= e )); then
                return 0
            fi
        elif [[ "$token" =~ ^[0-9]{1,5}$ ]]; then
            if (( target_p == 10#$token )); then
                return 0
            fi
        fi
    done
    return 1
}

modify_node_reality_port() {
    load_env_data
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                   ${bold}${yellow}修改 节点 1 (VLESS-Reality) 端口${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "当前 节点 1 监听端口 : ${cyan}${PORT_REALITY}${plain} / TCP"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"

    local new_port=""
    while true; do
        read -rp "请输入新的 节点 1 端口 (1-65535) [按 0 取消]: " new_port
        new_port=$(echo "$new_port" | tr -d ' ')
        [[ "$new_port" == "0" ]] && { info "已取消修改。"; return 0; }
        [[ -z "$new_port" ]] && continue

        local val_res
        validate_node_port_input "$new_port" "tcp" "$PORT_REALITY" "节点 1 (REALITY)"
        val_res=$?
        if [[ $val_res -eq 2 ]]; then
            return 0
        elif [[ $val_res -eq 0 ]]; then
            break
        fi
    done

    local confirm
    while true; do
        read -rp "确认将 节点 1 端口由 ${PORT_REALITY} 修改为 ${new_port}？[Y/n]: " confirm
        case "$confirm" in
            ""|[yY]|[yY][eE][sS]) break ;;
            [nN]|[nN][oO]) info "操作已取消。"; return 0 ;;
            *) warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！" ;;
        esac
    done

    info "正在更新服务端配置并验证新端口..."
    local old_port="$PORT_REALITY"
    local config_bak="${CONFIG_FILE}.port_bak"
    cp -p "$CONFIG_FILE" "$config_bak" || { error "无法备份现有配置文件，操作已终止。"; return 1; }

    PORT_REALITY="$new_port"
    generate_server_config

    if ! "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        error "新端口配置语法或绑定校验失败，正在回滚旧配置！"
        mv -f "$config_bak" "$CONFIG_FILE"
        PORT_REALITY="$old_port"
        sleep 2
        return 1
    fi

    if ! restart_service; then
        error "Xray 服务在新端口启动失败，正在回滚旧配置！"
        mv -f "$config_bak" "$CONFIG_FILE"
        PORT_REALITY="$old_port"
        generate_server_config
        restart_service || true
        sleep 2
        return 1
    fi

    rm -f "$config_bak"
    info "正在更新系统防火墙规则..."
    iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
    ip6tables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
    fi

    iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        ufw allow "${new_port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    save_env_data
    generate_client_links
    restart_sub_service
    success "节点 1 (REALITY) 端口已成功修改为: ${PORT_REALITY}！"
    echo -e "${yellow}⚠️ 提示：如您的 VPS 开启了云厂商安全组（阿里云、腾讯云、AWS、甲骨文等），请务必在云控制台放行 TCP 端口 ${PORT_REALITY}！${plain}"
    echo -e "\n按回车 [Enter] 返回端口管理菜单..."
    read -r
}

modify_node_hy2_port() {
    load_env_data
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                   ${bold}${yellow}修改 节点 2 (Hysteria 2) 端口${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "当前 Hysteria 2 主端口   : ${cyan}${PORT_HY2}${plain} / UDP"
    echo -e "当前 Hysteria 2 跳跃端口 : ${cyan}${PORT_HOP_PORTS}${plain} / UDP"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
    echo -e "    ${green}1.${plain} 修改主端口 (当前: ${PORT_HY2})"
    echo
    echo -e "    ${green}2.${plain} 修改端口跳跃范围 (当前: ${PORT_HOP_PORTS})"
    echo
    echo -e "    ${green}3.${plain} 同时修改主端口与跳跃范围"
    echo
    echo -e "    ${green}0.${plain} 返回上级菜单"
    echo -e "${cyan}========================================================================${plain}"

    local hy_choice
    read -rp "请选择操作序号 [0-3]: " hy_choice
    case "$hy_choice" in
        1)
            local new_main=""
            while true; do
                read -rp "请输入新的 Hysteria 2 主端口 (1-65535) [按 0 取消]: " new_main
                new_main=$(echo "$new_main" | tr -d ' ')
                [[ "$new_main" == "0" ]] && { info "已取消修改。"; return 0; }
                [[ -z "$new_main" ]] && continue

                local val_res
                validate_node_port_input "$new_main" "udp" "$PORT_HY2" "节点 2 (Hysteria 2)"
                val_res=$?
                if [[ $val_res -eq 2 ]]; then
                    return 0
                elif [[ $val_res -ne 0 ]]; then
                    continue
                fi

                if is_port_in_hop_range "$new_main" "$PORT_HOP_PORTS"; then
                    warn "警告：新主端口 ${new_main} 位于当前跳跃范围 (${PORT_HOP_PORTS}) 内！主端口不能与自身跳跃端口重叠。请更换其他端口或选择选项 3 同时调整跳跃范围。"
                    continue
                fi
                break
            done

            local confirm
            while true; do
                read -rp "确认将 Hysteria 2 主端口由 ${PORT_HY2} 修改为 ${new_main}？[Y/n]: " confirm
                case "$confirm" in
                    ""|[yY]|[yY][eE][sS]) break ;;
                    [nN]|[nN][oO]) info "操作已取消。"; return 0 ;;
                    *) warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！" ;;
                esac
            done

            info "正在更新 Hysteria 2 服务配置..."
            local old_main="$PORT_HY2"
            local old_hop="$PORT_HOP_PORTS"
            local config_bak="${CONFIG_FILE}.port_bak"
            cp -p "$CONFIG_FILE" "$config_bak" || { error "无法备份现有配置文件，操作已终止。"; return 1; }

            if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                /bin/bash "${IPTABLES_SCRIPT}" flush "$old_main" "$old_hop" >/dev/null 2>&1 || true
            fi

            PORT_HY2="$new_main"
            generate_server_config

            if ! "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
                error "新端口配置语法或绑定校验失败，正在回滚旧配置！"
                mv -f "$config_bak" "$CONFIG_FILE"
                PORT_HY2="$old_main"
                if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                    /bin/bash "${IPTABLES_SCRIPT}" apply "$old_main" "$old_hop" >/dev/null 2>&1 || true
                fi
                sleep 2
                return 1
            fi

            if ! restart_service; then
                error "Xray 服务在新主端口启动失败，正在回滚旧配置！"
                mv -f "$config_bak" "$CONFIG_FILE"
                PORT_HY2="$old_main"
                generate_server_config
                restart_service || true
                if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                    /bin/bash "${IPTABLES_SCRIPT}" apply "$old_main" "$old_hop" >/dev/null 2>&1 || true
                fi
                sleep 2
                return 1
            fi

            rm -f "$config_bak"
            if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                /bin/bash "${IPTABLES_SCRIPT}" apply "${PORT_HY2}" "${PORT_HOP_PORTS}" >/dev/null 2>&1 || true
            fi

            info "正在更新防火墙规则..."
            iptables -D INPUT -p udp --dport "$old_main" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport "$old_main" -j ACCEPT 2>/dev/null || true
            if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
                ufw delete allow "${old_main}/udp" >/dev/null 2>&1 || true
            fi
            if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
                firewall-cmd --permanent --remove-port="${old_main}/udp" >/dev/null 2>&1 || true
            fi

            iptables -I INPUT -p udp --dport "$new_main" -j ACCEPT 2>/dev/null || true
            ip6tables -I INPUT -p udp --dport "$new_main" -j ACCEPT 2>/dev/null || true
            if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
                ufw allow "${new_main}/udp" >/dev/null 2>&1 || true
            fi
            if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
                firewall-cmd --permanent --add-port="${new_main}/udp" >/dev/null 2>&1 || true
                firewall-cmd --reload >/dev/null 2>&1 || true
            fi

            save_env_data
            generate_client_links
            restart_sub_service
            success "节点 2 (Hysteria 2) 主端口已成功修改为: ${PORT_HY2}！"
            echo -e "${yellow}⚠️ 提示：如您的 VPS 开启了云厂商安全组，请务必在云控制台放行 UDP 端口 ${PORT_HY2}！${plain}"
            echo -e "\n按回车 [Enter] 返回端口管理菜单..."
            read -r
            ;;
        2)
            local new_hop=""
            while true; do
                echo
                echo "Hysteria 2 跳跃端口格式："
                echo "  1. 固定离散端口（例如：1369,2468,6688）"
                echo "  2. 连续端口范围（例如：20000-50000）"
                echo "  3. 混合格式（例如：2899,3800-8300,9968,11888-21986）"
                local hmode
                read -rp "请选择跳跃端口输入模式 [默认: 2, 按 0 取消]: " hmode
                hmode=${hmode:-2}
                [[ "$hmode" == "0" ]] && { info "已取消修改。"; return 0; }
                case "$hmode" in
                    1)
                        read -rp "请输入离散端口 [例如: 1369,2468,6688]: " new_hop
                        ;;
                    2)
                        read -rp "请输入连续端口范围 [例如: 20000-50000]: " new_hop
                        ;;
                    3)
                        read -rp "请输入混合端口 [例如: 2899,3800-8300,9968]: " new_hop
                        ;;
                    *) warn "请输入 1、2 或 3！"; continue ;;
                esac
                new_hop=$(echo "$new_hop" | tr -d ' ')
                [[ -z "$new_hop" ]] && continue
                if ! validate_hop_ports "$new_hop"; then
                    warn "格式或端口范围错误！必须为 1025-65535 之间，且范围起点不能大于终点。"
                    continue
                fi
                if is_port_in_hop_range "$PORT_HY2" "$new_hop"; then
                    warn "警告：当前主端口 (${PORT_HY2}) 位于您输入的跳跃范围 (${new_hop}) 内！跳跃端口不能包含主端口。"
                    continue
                fi
                if ! check_hop_ports_available "$new_hop"; then
                    continue
                fi
                break
            done

            local confirm
            while true; do
                read -rp "确认将 Hysteria 2 跳跃端口修改为 ${new_hop}？[Y/n]: " confirm
                case "$confirm" in
                    ""|[yY]|[yY][eE][sS]) break ;;
                    [nN]|[nN][oO]) info "操作已取消。"; return 0 ;;
                    *) warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！" ;;
                esac
            done

            info "正在更新 Hysteria 2 端口跳跃转发规则..."
            local old_hop="$PORT_HOP_PORTS"
            if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                /bin/bash "${IPTABLES_SCRIPT}" flush "$PORT_HY2" "$old_hop" >/dev/null 2>&1 || true
            fi

            local IFS=','
            local -a old_hps
            read -ra old_hps <<< "$old_hop"
            for ohp in "${old_hps[@]}"; do
                ohp=${ohp/-/:}
                iptables -D INPUT -p udp --dport "$ohp" -j ACCEPT 2>/dev/null || true
                ip6tables -D INPUT -p udp --dport "$ohp" -j ACCEPT 2>/dev/null || true
                if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
                    ufw delete allow "${ohp}/udp" >/dev/null 2>&1 || true
                fi
            done

            PORT_HOP_PORTS="$new_hop"
            if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                /bin/bash "${IPTABLES_SCRIPT}" apply "${PORT_HY2}" "${PORT_HOP_PORTS}" >/dev/null 2>&1 || true
            fi

            configure_firewalls "$PORT_REALITY" "$PORT_HY2" "$PORT_XHTTP" "$PORT_HOP_PORTS" "$SUB_PORT"

            save_env_data
            generate_client_links
            restart_sub_service
            success "节点 2 (Hysteria 2) 端口跳跃范围已成功修改为: ${PORT_HOP_PORTS}！"
            echo -e "${yellow}⚠️ 提示：如您的 VPS 开启了云厂商安全组，请务必在云控制台放行 UDP 跳跃范围: ${PORT_HOP_PORTS}！${plain}"
            echo -e "\n按回车 [Enter] 返回端口管理菜单..."
            read -r
            ;;
        3)
            local new_main=""
            while true; do
                read -rp "请输入新的 Hysteria 2 主端口 (1-65535) [按 0 取消]: " new_main
                new_main=$(echo "$new_main" | tr -d ' ')
                [[ "$new_main" == "0" ]] && { info "已取消修改。"; return 0; }
                [[ -z "$new_main" ]] && continue
                local val_res
                validate_node_port_input "$new_main" "udp" "" "节点 2 (Hysteria 2)"
                val_res=$?
                if [[ $val_res -ne 0 && $val_res -ne 2 ]]; then
                    continue
                fi
                break
            done

            local new_hop=""
            while true; do
                echo
                echo "Hysteria 2 跳跃端口格式："
                echo "  1. 固定离散端口（例如：1369,2468,6688）"
                echo "  2. 连续端口范围（例如：20000-50000）"
                echo "  3. 混合格式（例如：2899,3800-8300,9968,11888-21986）"
                local hmode
                read -rp "请选择跳跃端口输入模式 [默认: 2, 按 0 取消]: " hmode
                hmode=${hmode:-2}
                [[ "$hmode" == "0" ]] && { info "已取消修改。"; return 0; }
                case "$hmode" in
                    1) read -rp "请输入离散端口 [例如: 1369,2468,6688]: " new_hop ;;
                    2) read -rp "请输入连续端口范围 [例如: 20000-50000]: " new_hop ;;
                    3) read -rp "请输入混合端口 [例如: 2899,3800-8300,9968]: " new_hop ;;
                    *) warn "请输入 1、2 或 3！"; continue ;;
                esac
                new_hop=$(echo "$new_hop" | tr -d ' ')
                [[ -z "$new_hop" ]] && continue
                if ! validate_hop_ports "$new_hop"; then
                    warn "格式或端口范围错误！必须为 1025-65535 之间，且范围起点不能大于终点。"
                    continue
                fi
                if is_port_in_hop_range "$new_main" "$new_hop"; then
                    warn "警告：新主端口 (${new_main}) 位于您输入的跳跃范围 (${new_hop}) 内！主端口不能与自身跳跃端口重叠。"
                    continue
                fi
                if ! check_hop_ports_available "$new_hop"; then
                    continue
                fi
                break
            done

            local confirm
            while true; do
                read -rp "确认将 Hysteria 2 主端口设为 ${new_main}，跳跃设为 ${new_hop}？[Y/n]: " confirm
                case "$confirm" in
                    ""|[yY]|[yY][eE][sS]) break ;;
                    [nN]|[nN][oO]) info "操作已取消。"; return 0 ;;
                    *) warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！" ;;
                esac
            done

            info "正在更新 Hysteria 2 服务与跳跃配置..."
            local old_main="$PORT_HY2"
            local old_hop="$PORT_HOP_PORTS"
            local config_bak="${CONFIG_FILE}.port_bak"
            cp -p "$CONFIG_FILE" "$config_bak" || { error "无法备份现有配置文件，操作已终止。"; return 1; }

            if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                /bin/bash "${IPTABLES_SCRIPT}" flush "$old_main" "$old_hop" >/dev/null 2>&1 || true
            fi

            PORT_HY2="$new_main"
            PORT_HOP_PORTS="$new_hop"
            generate_server_config

            if ! "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
                error "新端口配置语法或绑定校验失败，正在回滚旧配置！"
                mv -f "$config_bak" "$CONFIG_FILE"
                PORT_HY2="$old_main"
                PORT_HOP_PORTS="$old_hop"
                if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                    /bin/bash "${IPTABLES_SCRIPT}" apply "$old_main" "$old_hop" >/dev/null 2>&1 || true
                fi
                sleep 2
                return 1
            fi

            if ! restart_service; then
                error "Xray 服务在新主端口启动失败，正在回滚旧配置！"
                mv -f "$config_bak" "$CONFIG_FILE"
                PORT_HY2="$old_main"
                PORT_HOP_PORTS="$old_hop"
                generate_server_config
                restart_service || true
                if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                    /bin/bash "${IPTABLES_SCRIPT}" apply "$old_main" "$old_hop" >/dev/null 2>&1 || true
                fi
                sleep 2
                return 1
            fi

            rm -f "$config_bak"
            if [[ -f "${IPTABLES_SCRIPT}" ]]; then
                /bin/bash "${IPTABLES_SCRIPT}" apply "${PORT_HY2}" "${PORT_HOP_PORTS}" >/dev/null 2>&1 || true
            fi

            iptables -D INPUT -p udp --dport "$old_main" -j ACCEPT 2>/dev/null || true
            ip6tables -D INPUT -p udp --dport "$old_main" -j ACCEPT 2>/dev/null || true
            if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
                ufw delete allow "${old_main}/udp" >/dev/null 2>&1 || true
            fi
            local IFS=','
            local -a old_hps
            read -ra old_hps <<< "$old_hop"
            for ohp in "${old_hps[@]}"; do
                ohp=${ohp/-/:}
                iptables -D INPUT -p udp --dport "$ohp" -j ACCEPT 2>/dev/null || true
                ip6tables -D INPUT -p udp --dport "$ohp" -j ACCEPT 2>/dev/null || true
                if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
                    ufw delete allow "${ohp}/udp" >/dev/null 2>&1 || true
                fi
            done

            configure_firewalls "$PORT_REALITY" "$PORT_HY2" "$PORT_XHTTP" "$PORT_HOP_PORTS" "$SUB_PORT"

            save_env_data
            generate_client_links
            restart_sub_service
            success "节点 2 (Hysteria 2) 主端口与跳跃范围已全部更新成功！"
            echo -e "${yellow}⚠️ 提示：如您的 VPS 开启了云厂商安全组，请务必在云控制台放行 UDP 主端口 ${PORT_HY2} 及跳跃范围 ${PORT_HOP_PORTS}！${plain}"
            echo -e "\n按回车 [Enter] 返回端口管理菜单..."
            read -r
            ;;
        0) return 0 ;;
        *) warn "输入错误，请重新选择！"; sleep 1 ;;
    esac
}

modify_node_xhttp_port() {
    load_env_data
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                   ${bold}${yellow}修改 节点 3 (VLESS-XHTTP) 端口${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "当前 节点 3 本地监听端口 : ${cyan}${PORT_XHTTP}${plain} / TCP"
    if [[ -n "$CF_CDN_DOMAIN" ]]; then
        echo -e "${yellow}注：节点 3 本地监听端口独立于 节点 4 CDN 边缘端口 (${CF_CDN_PORT:-2053})。${plain}"
        echo -e "${yellow}如您已配置 Cloudflare Origin Rules 源服务器端口重写，修改此处后请同步在 Cloudflare 规则中将目标重写端口更新为新端口！${plain}"
    fi
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"

    local new_port=""
    while true; do
        read -rp "请输入新的 节点 3 端口 (1-65535) [按 0 取消]: " new_port
        new_port=$(echo "$new_port" | tr -d ' ')
        [[ "$new_port" == "0" ]] && { info "已取消修改。"; return 0; }
        [[ -z "$new_port" ]] && continue

        local val_res
        validate_node_port_input "$new_port" "tcp" "$PORT_XHTTP" "节点 3 (XHTTP)"
        val_res=$?
        if [[ $val_res -eq 2 ]]; then
            return 0
        elif [[ $val_res -eq 0 ]]; then
            break
        fi
    done

    local confirm
    while true; do
        read -rp "确认将 节点 3 端口由 ${PORT_XHTTP} 修改为 ${new_port}？[Y/n]: " confirm
        case "$confirm" in
            ""|[yY]|[yY][eE][sS]) break ;;
            [nN]|[nN][oO]) info "操作已取消。"; return 0 ;;
            *) warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！" ;;
        esac
    done

    info "正在更新服务端配置并验证新端口..."
    local old_port="$PORT_XHTTP"
    local config_bak="${CONFIG_FILE}.port_bak"
    cp -p "$CONFIG_FILE" "$config_bak" || { error "无法备份现有配置文件，操作已终止。"; return 1; }

    PORT_XHTTP="$new_port"
    generate_server_config

    if ! "$XRAY_BIN" -test -config "$CONFIG_FILE" >/dev/null 2>&1; then
        error "新端口配置语法或绑定校验失败，正在回滚旧配置！"
        mv -f "$config_bak" "$CONFIG_FILE"
        PORT_XHTTP="$old_port"
        sleep 2
        return 1
    fi

    if ! restart_service; then
        error "Xray 服务在新端口启动失败，正在回滚旧配置！"
        mv -f "$config_bak" "$CONFIG_FILE"
        PORT_XHTTP="$old_port"
        generate_server_config
        restart_service || true
        sleep 2
        return 1
    fi

    rm -f "$config_bak"
    info "正在更新系统防火墙规则..."
    iptables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
    ip6tables -D INPUT -p tcp --dport "$old_port" -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${old_port}/tcp" >/dev/null 2>&1 || true
    fi

    iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
    ip6tables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || true
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
        ufw allow "${new_port}/tcp" >/dev/null 2>&1 || true
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    save_env_data
    generate_client_links
    restart_sub_service
    success "节点 3 (VLESS-XHTTP) 端口已成功修改为: ${PORT_XHTTP}！"
    echo -e "${yellow}⚠️ 提示：如您的 VPS 开启了云厂商安全组，请务必在云控制台放行 TCP 端口 ${PORT_XHTTP}！${plain}"
    if [[ -n "$CF_CDN_DOMAIN" ]]; then
        echo -e "${cyan}提示：如果您在 Cloudflare 配置了 Origin Rules 规则，请记得将源端口同步更新为 ${PORT_XHTTP}。${plain}"
    fi
    echo -e "\n按回车 [Enter] 返回端口管理菜单..."
    read -r
}

modify_node_cdn_port() {
    load_env_data
    if [[ -z "$CF_CDN_DOMAIN" ]]; then
        warn "当前尚未配置 节点 4 (Cloudflare 入站 CDN)，无需修改端口！"
        sleep 1.5
        return 0
    fi

    echo -e "${cyan}========================================================================${plain}"
    echo -e "                 ${bold}${yellow}修改 节点 4 (CF-CDN-XHTTP) 边缘代理端口${plain}"
    echo -e "${cyan}========================================================================${plain}"
    echo -e "当前 节点 4 边缘端口 : ${cyan}${CF_CDN_PORT:-2053}${plain} / TCP"
    echo -e "绑定 CDN 域名        : ${green}${CF_CDN_DOMAIN}${plain}"
    echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"

    local input_port=""
    local valid_cf_ports=("443" "2053" "2083" "2087" "2096" "8443")
    while true; do
        render_cf_port_status
        echo -e "当前端口池状态 :  ${CF_PORT_STATUS_BAR}"
        read -rp "请输入节点 4 代理端口 [默认: ${CF_PORT_RECOMMENDED_DEF}, 按 0 取消]: " input_port
        input_port=${input_port:-$CF_PORT_RECOMMENDED_DEF}
        input_port=$(echo "$input_port" | tr -d ' ')
        [[ "$input_port" == "0" ]] && { info "已取消修改。"; return 0; }
        
        local port_valid=0
        for p in "${valid_cf_ports[@]}"; do
            if [[ "$p" == "$input_port" ]]; then
                port_valid=1
                break
            fi
        done
        if [[ "$port_valid" -ne 1 ]]; then
            warn "端口无效！Cloudflare 官方 HTTPS 代理仅支持：443、2053、2083、2087、2096、8443"
            continue
        fi

        if [[ "$input_port" == "$CF_CDN_PORT" ]]; then
            info "输入端口与当前节点 4 端口相同 (${CF_CDN_PORT})，无需修改。"
            return 0
        fi

        local is_occ=0
        if [[ "$input_port" == "$PORT_REALITY" || "$input_port" == "$PORT_HY2" || "$input_port" == "$PORT_XHTTP" || "$input_port" == "$SUB_PORT" ]]; then
            is_occ=1
        elif check_port_occupied "$input_port" "tcp"; then
            is_occ=1
        fi
        if [[ $is_occ -eq 1 ]]; then
            warn "端口 ${input_port} 处于已被占用状态 (❌)，请在标有 ✅ 的可用端口中选择！"
            continue
        fi
        break
    done

    local confirm
    while true; do
        read -rp "确认将 节点 4 边缘代理端口由 ${CF_CDN_PORT:-2053} 修改为 ${input_port}？[Y/n]: " confirm
        case "$confirm" in
            ""|[yY]|[yY][eE][sS]) break ;;
            [nN]|[nN][oO]) info "操作已取消。"; return 0 ;;
            *) warn "输入无效，请按回车或输入 y 确认，或输入 n 取消！" ;;
        esac
    done

    CF_CDN_PORT="$input_port"
    save_env_data
    generate_client_links
    restart_sub_service
    success "节点 4 (CF-CDN-XHTTP) 边缘代理端口已成功修改为: ${CF_CDN_PORT}！"
    echo -e "\n按回车 [Enter] 返回端口管理菜单..."
    read -r
}

node_port_management_menu() {
    while true; do
        load_env_data
        clear
        show_logo
        echo -e "${cyan}========================================================================${plain}"
        echo -e "                         ${bold}${yellow}ToFu 节点端口修改 ${plain}"
        echo -e "${cyan}========================================================================${plain}"
        echo -e "  当前监听与端口状态:"
        echo -e "  ├─ 节点 1 (VLESS-Reality) : ${green}${PORT_REALITY:-443}${plain} / TCP"
        echo -e "  ├─ 节点 2 (Hysteria 2)    : ${green}${PORT_HY2:-8443}${plain} / UDP (跳跃: ${green}${PORT_HOP_PORTS:-20000-50000}${plain})"
        echo -e "  ├─ 节点 3 (VLESS-XHTTP)   : ${green}${PORT_XHTTP:-2053}${plain} / TCP"
        local has_node4=0
        if [[ -n "$CF_CDN_DOMAIN" ]]; then
            has_node4=1
            echo -e "  ├─ 节点 4 (CF-CDN-XHTTP)  : ${green}${CF_CDN_PORT:-2053}${plain} / TCP (Cloudflare CDN 边缘端口)"
        fi
        echo -e "  ├─ 订阅 Web 服务          : ${green}${SUB_PORT:-54328}${plain} / TCP"
        echo -e "  └─ ACME 证书申请保留端口  : ${green}80${plain} / TCP ${red}(严禁占用)${plain}"
        echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
        echo
        echo -e "    ${green}1.${plain} 修改 节点 1 (VLESS-Reality) 端口"
        echo
        echo -e "    ${green}2.${plain} 修改 节点 2 (Hysteria 2) 端口 (包含主端口与端口跳跃)"
        echo
        echo -e "    ${green}3.${plain} 修改 节点 3 (VLESS-XHTTP) 端口"
        echo
        if [[ $has_node4 -eq 1 ]]; then
            echo -e "    ${green}4.${plain} 修改 节点 4 (CF-CDN-XHTTP) 端口"
            echo
            echo -e "    ${green}5.${plain} 修改 订阅服务 端口"
            echo
            echo -e "    ${green}0.${plain} 返回主菜单"
            echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
            read -rp "请输入操作序号 [0-5]: " p_choice
            case "$p_choice" in
                1) modify_node_reality_port ;;
                2) modify_node_hy2_port ;;
                3) modify_node_xhttp_port ;;
                4) modify_node_cdn_port ;;
                5) change_sub_port ;;
                0) return 0 ;;
                *) error "输入错误，请重新选择！"; sleep 1 ;;
            esac
        else
            echo -e "    ${green}4.${plain} 修改 订阅服务 端口"
            echo
            echo -e "    ${green}0.${plain} 返回主菜单"
            echo -e "${cyan}────────────────────────────────────────────────────────────────────────${plain}"
            read -rp "请输入操作序号 [0-4]: " p_choice
            case "$p_choice" in
                1) modify_node_reality_port ;;
                2) modify_node_hy2_port ;;
                3) modify_node_xhttp_port ;;
                4) change_sub_port ;;
                0) return 0 ;;
                *) error "输入错误，请重新选择！"; sleep 1 ;;
            esac
        fi
    done
}

run_tofu_doctor() {
    clear
    show_logo
    echo -e "${cyan}========================================================================${plain}"
    echo -e "                 ${bold}${yellow}ToFu 系统 | 节点 | 订阅 | 证书 状态查询${plain}"
    echo -e "${cyan}========================================================================${plain}"
    load_env_data
    if [[ ! -f "${CONFIG_FILE}" || ! -f "${DATA_FILE}" ]]; then
        error "未检测到 ToFu 节点配置，请先运行部署！"
        return 1
    fi

    echo -e "${bold}【1. 核心进程运行状态】${plain}"
    local xray_pid
    xray_pid=$(pgrep -f "${XRAY_BIN}" | head -n 1)
    if [[ -n "$xray_pid" ]]; then
        local mem_kb
        mem_kb=$(grep -i VmRSS /proc/${xray_pid}/status 2>/dev/null | awk '{print $2}')
        local mem_mb="0.0"
        [[ -n "$mem_kb" ]] && mem_mb=$(awk -v k="$mem_kb" 'BEGIN {printf "%.1f", k/1024}')
        local cpu_usage
        cpu_usage=$(ps -p "${xray_pid}" -o %cpu --no-headers 2>/dev/null | tr -d ' ' || echo "0.1")
        echo -e "  ├─ Xray-core 守护进程 : ${green}● 正常运行${plain} (PID: ${xray_pid}, 内存: ${mem_mb}MB, CPU: ${cpu_usage}%)"
    else
        echo -e "  ├─ Xray-core 守护进程 : ${red}❌ 未运行${plain} (请尝试选择主菜单 5 重启服务)"
    fi

    if is_sub_service_running; then
        echo -e "  └─ 订阅 Web 服务      : ${green}● 正常运行${plain} (端口: ${SUB_PORT:-54328})"
    else
        echo -e "  └─ 订阅 Web 服务      : ${yellow}○ 未运行 / 已停用${plain}"
    fi

    echo -e "\n${bold}【2. 节点监听端口与网络联通】${plain}"
    local cur_tcp cur_udp
    cur_tcp=$(ss -tln 2>/dev/null)
    cur_udp=$(ss -uln 2>/dev/null)

    if grep -qE "[: ]${PORT_REALITY:-443} " <<< "$cur_tcp"; then
        echo -e "  ├─ 节点 1 REALITY (${PORT_REALITY:-443}/TCP)  : ${green}✅ 监听正常${plain}"
    else
        echo -e "  ├─ 节点 1 REALITY (${PORT_REALITY:-443}/TCP)  : ${red}❌ 未监听${plain}"
    fi

    if grep -qE "[: ]${PORT_HY2:-8443} " <<< "$cur_udp"; then
        echo -e "  ├─ 节点 2 Hysteria 2 (${PORT_HY2:-8443}/UDP) : ${green}✅ 监听正常${plain}"
    else
        echo -e "  ├─ 节点 2 Hysteria 2 (${PORT_HY2:-8443}/UDP) : ${red}❌ 未监听${plain}"
    fi

    local hop_rule_count
    hop_rule_count=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -c "REDIRECT" || echo 0)
    if [[ "$hop_rule_count" -gt 0 ]]; then
        echo -e "  ├─ Hy2 UDP 端口跳跃转发规则     : ${green}✅ 内核 NAT 已生效${plain} (活跃规则数: ${hop_rule_count})"
    else
        echo -e "  ├─ Hy2 UDP 端口跳跃转发规则     : ${yellow}⚠️ 未检测到活跃 NAT 转发规则${plain}"
    fi

    if grep -qE "[: ]${PORT_XHTTP:-2053} " <<< "$cur_tcp"; then
        echo -e "  ├─ 节点 3 XHTTP (${PORT_XHTTP:-2053}/TCP)    : ${green}✅ 监听正常${plain}"
    else
        echo -e "  ├─ 节点 3 XHTTP (${PORT_XHTTP:-2053}/TCP)    : ${red}❌ 未监听${plain}"
    fi

    if grep -qE "[: ]80 " <<< "$cur_tcp"; then
        local p80_name
        p80_name=$(ss -tlnp 2>/dev/null | grep -E '[: ]80[ \t]' | head -n 1 | sed -E 's/.*users:\(\("([^"]+).*/\1/' 2>/dev/null)
        echo -e "  └─ 证书验证专用端口 (80/TCP)     : ${red}⚠️ 已被外部进程 [${p80_name:-占用}] 占用${plain}"
    else
        echo -e "  └─ 证书验证专用端口 (80/TCP)     : ${green}✅ 空闲待命 (随时支持证书签发与续期)${plain}"
    fi

    echo -e "\n${bold}【3. 系统加速与内核环境】${plain}"
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
        echo -e "  ├─ TCP BBR 拥塞控制算法        : ${green}✅ 已启用并生效${plain}"
    else
        echo -e "  ├─ TCP BBR 拥塞控制算法        : ${yellow}○ 未开启${plain}"
    fi

    if is_warp_egress_enabled; then
        echo -e "  ├─ 节点 3 WARP 出站扩展         : ${green}● 已开启并接管 XHTTP 出站${plain}"
    else
        echo -e "  ├─ 节点 3 WARP 出站扩展         : [ 原生 VPS 直连出站 ]"
    fi

    if [[ -n "$CF_CDN_DOMAIN" ]]; then
        echo -e "  └─ 节点 4 Cloudflare CDN 入站   : ${green}● 已绑定 [ ${CF_CDN_DOMAIN}:${CF_CDN_PORT:-2053} ]${plain}"
    else
        echo -e "  └─ 节点 4 Cloudflare CDN 入站   : ○ 未配置"
    fi

    echo -e "\n${bold}【4. 证书与有效期检测】${plain}"
    local hy2_crt="${CONFIG_DIR}/certs/hy2.crt"
    local ecc_crt="${CONFIG_DIR}/certs/ecc.crt"
    if [[ -f "$hy2_crt" ]]; then
        local expire_date end_ts now_ts left_days
        expire_date=$(openssl x509 -enddate -noout -in "$hy2_crt" 2>/dev/null | cut -d= -f2)
        if [[ -n "$expire_date" ]]; then
            end_ts=$(date -d "$expire_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expire_date" +%s 2>/dev/null || echo 0)
            now_ts=$(date +%s)
            left_days=$(( (end_ts - now_ts) / 86400 ))
            if (( left_days > 15 )); then
                echo -e "  ├─ Hysteria 2 SSL 证书 (${HY2_DOMAIN:-自签}) : ${green}✅ 正常${plain} (剩余有效期: ${left_days} 天)"
            elif (( left_days > 0 )); then
                echo -e "  ├─ Hysteria 2 SSL 证书 (${HY2_DOMAIN:-自签}) : ${yellow}⚠️ 即将到期${plain} (剩余有效期: ${left_days} 天)"
            else
                echo -e "  ├─ Hysteria 2 SSL 证书 (${HY2_DOMAIN:-自签}) : ${red}❌ 已过期${plain}"
            fi
        fi
    elif [[ "$HY2_MODE" == "1" ]]; then
        echo -e "  ├─ Hysteria 2 证书模式          : ${green}✅ 自签证书 SHA256 指纹认证模式${plain}"
    fi

    if [[ -f "$ecc_crt" ]]; then
        echo -e "  └─ XHTTP 自签 TLS 证书          : ${green}✅ 就绪${plain} (SHA256: ${CERT_SHA256:0:16}...)"
    fi

    echo -e "${cyan}========================================================================${plain}"
    echo -e "查询完成！按回车 [Enter] 返回管理菜单..."
    read -r
}

main_menu() {
    while true; do
        load_env_data
        clear
        show_logo
        show_dashboard_panel
        echo -e " ✅ 随时在终端输入 ${green}tofu${plain} 即可唤醒本管理菜单"
        echo -e "${cyan}------------------------------------------------------------------------${plain}"
        echo
        echo -e "    ${green}1.${plain} 查看所有节点信息与二维码"
        echo
        echo -e "    ${green}2.${plain} Cloudflare CDN + WARP"
        echo
        echo -e "    ${green}3.${plain} 节点端口修改"
        echo
        echo -e "    ${green}4.${plain} 系统 | 节点 | 订阅 | 证书 状态查询"
        echo
        local update_flag
        update_flag=$(check_xray_update_status)
        if [[ "$update_flag" == "1" ]]; then
            echo -e "    ${green}5.${plain} 升级 Xray 或更换 Xray 内核版本 ${yellow}【有更新】${plain}"
        else
            echo -e "    ${green}5.${plain} 升级 Xray 或更换 Xray 内核版本"
        fi
        echo
        echo -e "    ${green}6.${plain} 重启 ToFu 服务"
        echo
        echo -e "    ${green}7.${plain} 停止 ToFu 服务"
        echo
        echo -e "    ${green}8.${plain} 重新部署节点"
        echo
        echo -e "    ${green}9.${plain} 完整卸载 ToFu 组件"
        echo
        echo -e "    ${green}10.${plain} 涉及域名的注意事项"
        echo
        echo -e "    ${green}0.${plain} 退出菜单"
        echo
        echo -e "${cyan}------------------------------------------------------------------------${plain}"
        read -rp "请输入操作序号 [0-10]: " choice
        case "$choice" in
            1) show_node_info ;;
            2) cloudflare_cdn_menu "main" ;;
            3) node_port_management_menu ;;
            4) run_tofu_doctor ;;
            5)
                xray_kernel_management_menu
                ;;
            6)
                restart_service
                sleep 1
                ;;
            7)
                stop_service
                sleep 1
                ;;
            8)
                local confirm_reinstall
                while true; do
                    read -rp "确定要清空现有配置并重新部署节点吗？[Y/n]: " confirm_reinstall
                    case "${confirm_reinstall:-y}" in
                        [yY]|[yY][eE][sS])
                            clean_wipe_for_reinstall
                            install_all
                            break
                            ;;
                        [nN]|[nN][oO])
                            info "已取消重新部署。"
                            sleep 1
                            break
                            ;;
                        *)
                            warn "输入无效，请输入 y 确认重新部署，或输入 n 取消！"
                            ;;
                    esac
                done
                ;;
            9) uninstall_all ;;
            10) show_domain_notice ;;
            0)
                echo -e "\n✅ 感谢使用 ToFu！随时在终端输入 ${green}tofu${plain} 即可再次唤出管理菜单。\n"
                exit 0
                ;;
            *)
                error "输入错误，请重新选择！"
                sleep 1
                ;;
        esac
    done
}

check_arch
check_os

case "$1" in
    install)
        install_all
        main_menu
        ;;
    uninstall)      uninstall_all ;;
    info)
        show_node_info
        main_menu
        ;;
    sub)
        subscription_management_menu
        main_menu
        ;;
    restart)        restart_service ;;
    start)          start_service ;;
    stop)           stop_service ;;
    cdn)
        cloudflare_cdn_menu "main"
        main_menu
        ;;
    domain|dns)
        show_domain_notice
        main_menu
        ;;
    port|ports)
        node_port_management_menu
        main_menu
        ;;
    update|upgrade|kernel)
        xray_kernel_management_menu
        main_menu
        ;;
    doctor|check|status)
        run_tofu_doctor
        main_menu
        ;;
    *)
        if [[ -f "${DATA_FILE}" || -f "${CONFIG_FILE}" ]]; then
            main_menu
        else
            install_all
            main_menu
        fi
        ;;
esac

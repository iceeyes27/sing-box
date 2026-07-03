# ─── 安装组件 ────────────────────────────────────────────────
get_meminfo_kb() {
    local key="$1" name value unit
    [[ -r /proc/meminfo ]] || return 1
    while read -r name value unit; do
        if [[ "$name" == "${key}:" && "$value" =~ ^[0-9]+$ ]]; then
            echo "$value"
            return 0
        fi
    done < /proc/meminfo
    return 1
}

get_resource_profile() {
    local mem_total swap_total
    mem_total=$(get_meminfo_kb MemTotal 2>/dev/null || echo 0)
    swap_total=$(get_meminfo_kb SwapTotal 2>/dev/null || echo 0)

    if (( mem_total <= 0 )); then
        echo "unknown"
    elif (( mem_total < 786432 && swap_total < 131072 )); then
        echo "low-noswap"
    elif (( mem_total < 786432 )); then
        echo "low-swap"
    elif (( mem_total < 1572864 )); then
        echo "standard"
    else
        echo "high"
    fi
}

get_cpu_count() {
    local cpu_count
    if command -v nproc &>/dev/null; then
        cpu_count=$(nproc 2>/dev/null || echo 1)
    elif command -v getconf &>/dev/null; then
        cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    elif [[ -r /proc/cpuinfo ]]; then
        cpu_count=$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo 2>/dev/null || echo 1)
    else
        cpu_count=1
    fi
    [[ "$cpu_count" =~ ^[0-9]+$ && "$cpu_count" -gt 0 ]] || cpu_count=1
    echo "$cpu_count"
}

get_cpu_profile() {
    local cpu_count
    cpu_count=$(get_cpu_count)
    if (( cpu_count <= 1 )); then
        echo "low"
    elif (( cpu_count <= 2 )); then
        echo "standard"
    else
        echo "high"
    fi
}

resource_profile_label() {
    case "$(get_resource_profile)" in
        low-noswap) echo "低内存 / 无可用 swap" ;;
        low-swap)   echo "低内存 / 有可用 swap" ;;
        standard)   echo "标准内存" ;;
        high)       echo "高内存" ;;
        *)          echo "未知内存状态" ;;
    esac
}

cpu_profile_label() {
    case "$(get_cpu_profile)" in
        low)      echo "低 CPU ($(get_cpu_count) 核)" ;;
        standard) echo "标准 CPU ($(get_cpu_count) 核)" ;;
        high)     echo "高 CPU ($(get_cpu_count) 核)" ;;
        *)        echo "未知 CPU 状态" ;;
    esac
}

cleanup_low_memory_swap() {
    [[ "$LOW_MEMORY_SWAP_CREATED" == "true" ]] || return 0
    swapoff "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
    rm -f "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
    LOW_MEMORY_SWAP_CREATED=false
}

prepare_low_memory_swap() {
    local available_mb

    [[ "$(get_resource_profile)" == "low-noswap" ]] || return 0
    command -v mkswap &>/dev/null && command -v swapon &>/dev/null || return 0

    if [[ -e "$LOW_MEMORY_SWAP_FILE" ]]; then
        warn "检测到低内存，但 ${LOW_MEMORY_SWAP_FILE} 已存在，跳过临时 swap 创建"
        return 0
    fi

    available_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
    [[ "$available_mb" =~ ^[0-9]+$ ]] || available_mb=0
    if (( available_mb < 640 )); then
        warn "检测到低内存且磁盘可用空间不足，继续使用分批安装"
        return 0
    fi

    info "检测到低内存且无可用 swap，临时启用 512MB swap 支撑安装..."
    if command -v fallocate &>/dev/null; then
        fallocate -l 512M "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || \
            dd if=/dev/zero of="$LOW_MEMORY_SWAP_FILE" bs=1M count=512 status=none >/dev/null 2>&1 || true
    else
        dd if=/dev/zero of="$LOW_MEMORY_SWAP_FILE" bs=1M count=512 status=none >/dev/null 2>&1 || true
    fi

    if [[ ! -s "$LOW_MEMORY_SWAP_FILE" ]]; then
        rm -f "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
        warn "临时 swap 文件创建失败，继续使用分批安装"
        return 0
    fi

    chmod 600 "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
    if mkswap "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 && swapon "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1; then
        LOW_MEMORY_SWAP_CREATED=true
        trap cleanup_low_memory_swap EXIT
        success "临时 swap 已启用"
    else
        rm -f "$LOW_MEMORY_SWAP_FILE" >/dev/null 2>&1 || true
        warn "当前 VPS 不允许启用临时 swap，继续使用分批安装"
    fi
}

is_low_memory_without_swap() {
    [[ "$(get_resource_profile)" == "low-noswap" && "$LOW_MEMORY_SWAP_CREATED" != "true" ]]
}

run_low_resource() {
    if command -v ionice &>/dev/null; then
        ionice -c 3 nice -n 19 "$@"
    else
        nice -n 19 "$@"
    fi
}

package_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v apk &>/dev/null; then
        echo "apk"
    else
        echo "none"
    fi
}

singbox_binary_available() {
    command -v sing-box &>/dev/null
}

is_apt_package_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

install_apt_packages_low_resource() {
    local pkg
    export DEBIAN_FRONTEND=noninteractive
    run_low_resource apt-get update -qq -o Acquire::Languages=none 2>/dev/null || return 1
    apt-get clean >/dev/null 2>&1 || true

    for pkg in "$@"; do
        if is_apt_package_installed "$pkg"; then
            continue
        fi
        info "安装依赖: ${pkg}"
        if ! run_low_resource apt-get install -y -qq --no-install-recommends \
            -o Dpkg::Use-Pty=0 \
            -o APT::Install-Recommends=false \
            -o APT::Install-Suggests=false \
            "$pkg" > /dev/null 2>&1; then
            warn "依赖安装失败: ${pkg}"
            return 1
        fi
        apt-get clean >/dev/null 2>&1 || true
    done
}

install_yum_packages_low_resource() {
    local manager="$1" pkg
    shift
    for pkg in "$@"; do
        if command -v rpm &>/dev/null && rpm -q "$pkg" >/dev/null 2>&1; then
            continue
        fi
        info "安装依赖: ${pkg}"
        if ! run_low_resource "$manager" install -y -q "$pkg" > /dev/null 2>&1; then
            warn "依赖安装失败: ${pkg}"
            return 1
        fi
    done
}

install_apk_packages_low_resource() {
    local pkg
    for pkg in "$@"; do
        if apk info -e "$pkg" >/dev/null 2>&1; then
            continue
        fi
        info "安装依赖: ${pkg}"
        if ! run_low_resource apk add --no-cache "$pkg" > /dev/null 2>&1; then
            warn "依赖安装失败: ${pkg}"
            return 1
        fi
    done
}

install_packages_low_resource() {
    case "$(package_manager)" in
        apt) install_apt_packages_low_resource "$@" ;;
        dnf) install_yum_packages_low_resource dnf "$@" ;;
        yum) install_yum_packages_low_resource yum "$@" ;;
        apk) install_apk_packages_low_resource "$@" ;;
        *)   return 1 ;;
    esac
}

install_missing_required_deps() {
    local missing=()

    command -v curl &>/dev/null || missing+=(curl)
    command -v openssl &>/dev/null || missing+=(openssl)
    [[ ${#missing[@]} -eq 0 ]] && return 0

    warn "缺少关键依赖: ${missing[*]}"
    install_packages_low_resource "${missing[@]}"
}

install_optional_deps() {
    local optional=()
    local cpu_profile profile

    profile=$(get_resource_profile)
    cpu_profile=$(get_cpu_profile)
    case "$profile" in
        low-noswap)
            if is_low_memory_without_swap; then
                warn "检测到低内存且无可用 swap，跳过可选依赖安装"
                return 0
            fi
            ;;
        low-swap)
            info "低内存但已有可用 swap，将分批安装缺失的可选依赖"
            ;;
        standard|high)
            info "当前资源状态允许安装缺失的可选依赖"
            ;;
        *)
            info "内存状态未知，按保守策略分批安装缺失的可选依赖"
            ;;
    esac

    if [[ "$cpu_profile" == "low" ]]; then
        info "检测到低 CPU，缺失依赖将使用低优先级串行安装"
    fi

    command -v wget &>/dev/null || optional+=(wget)
    command -v jq &>/dev/null || optional+=(jq)
    command -v python3 &>/dev/null || optional+=(python3)
    command -v ip &>/dev/null || optional+=(iproute2)
    command -v lsof &>/dev/null || optional+=(lsof)
    [[ -f /etc/ssl/certs/ca-certificates.crt ]] || optional+=(ca-certificates)

    [[ ${#optional[@]} -gt 0 ]] || return 0
    info "安装可选依赖: ${optional[*]}"
    if ! install_packages_low_resource "${optional[@]}"; then
        warn "部分可选依赖安装失败，继续核心部署；订阅服务或端口检测能力可能受限"
    fi
}

get_singbox_release_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7) echo "armv7" ;;
        i386|i686|x86) echo "386" ;;
        *) return 1 ;;
    esac
}

get_latest_singbox_version() {
    local version latest_url

    version=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
        | awk -F'"' '/"tag_name"/ { gsub(/^v/, "", $4); print $4; exit }' || true)

    if [[ -z "$version" ]]; then
        latest_url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
            "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null || true)
        version="${latest_url##*/v}"
    fi

    [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
    echo "$version"
}

install_singbox_from_official_tarball() {
    local version arch tmp_dir archive url bin_path

    arch=$(get_singbox_release_arch) || return 1
    version=$(get_latest_singbox_version) || return 1
    tmp_dir=$(mktemp -d)
    archive="${tmp_dir}/sing-box.tar.gz"
    url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}-musl.tar.gz"

    info "下载 sing-box 官方二进制: v${version} (${arch}-musl)"
    if ! curl -fL --retry 3 --connect-timeout 15 -o "$archive" "$url"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        return 1
    fi

    bin_path=$(find "$tmp_dir" -type f -name sing-box | head -n 1 || true)
    if [[ -z "$bin_path" || ! -f "$bin_path" ]]; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if command -v install &>/dev/null; then
        install -m 0755 "$bin_path" /usr/local/bin/sing-box
    else
        cp "$bin_path" /usr/local/bin/sing-box
        chmod 755 /usr/local/bin/sing-box
    fi

    hash -r 2>/dev/null || true
    if ! singbox_binary_available && [[ -x /usr/local/bin/sing-box ]]; then
        ln -sf /usr/local/bin/sing-box /usr/bin/sing-box 2>/dev/null || true
        hash -r 2>/dev/null || true
    fi

    rm -rf "$tmp_dir"
    singbox_binary_available
}

install_or_upgrade_singbox_package() {
    local upgrade="${1:-false}"
    local apk_args=(add --no-cache)

    if [[ "$(package_manager)" == "apk" ]]; then
        [[ "$upgrade" == "true" ]] && apk_args+=(--upgrade)
        if ! run_low_resource apk "${apk_args[@]}" sing-box > /dev/null 2>&1 || ! singbox_binary_available; then
            warn "Alpine 软件源安装 sing-box 失败，改用官方 musl 二进制"
            install_singbox_from_official_tarball || return 1
        fi
    else
        curl -fsSL https://sing-box.app/install.sh | sh || return 1
    fi

    singbox_binary_available
}

install_deps() {
    info "安装基础依赖..."
    info "资源检测: $(resource_profile_label), $(cpu_profile_label)"
    prepare_low_memory_swap
    install_missing_required_deps || error "关键依赖安装失败: curl openssl。请检查系统内存、磁盘空间或软件源"
    install_optional_deps
    success "关键依赖就绪"
}

parse_rtc_utc_epoch() {
    local rtc_raw="$1"
    local rtc_input rtc_epoch rtc_tz
    [[ -n "$rtc_raw" ]] || return 1

    if [[ "$rtc_raw" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?[[:space:]]*([+-][0-9]{2}:?[0-9]{2}|UTC|Z)? ]]; then
        rtc_tz="${BASH_REMATCH[4]:-UTC}"
        [[ "$rtc_tz" == "Z" ]] && rtc_tz="UTC"
        rtc_input="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${rtc_tz}"
    elif [[ "$rtc_raw" =~ [A-Z][a-z]{2}[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        rtc_input="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} UTC"
    elif [[ "$rtc_raw" =~ [A-Z][a-z]{2}[[:space:]]+([A-Z][a-z]{2})[[:space:]]+([0-9]{1,2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]]+([0-9]{4}) ]]; then
        rtc_input="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} UTC"
    else
        return 1
    fi

    rtc_epoch=$(LC_ALL=C date -u -d "$rtc_input" +%s 2>/dev/null || return 1)
    [[ "$rtc_epoch" =~ ^[0-9]+$ ]] || return 1
    (( rtc_epoch >= 946684800 )) || return 1
    echo "$rtc_epoch"
}

get_rtc_utc_epoch() {
    local rtc_raw

    if command -v hwclock &>/dev/null; then
        rtc_raw=$(LC_ALL=C hwclock --utc --show 2>/dev/null || true)
        parse_rtc_utc_epoch "$rtc_raw" && return 0
    fi

    if command -v timedatectl &>/dev/null; then
        rtc_raw=$(LC_ALL=C timedatectl 2>/dev/null | awk -F': ' '/RTC time:/ {print $2; exit}' || true)
        parse_rtc_utc_epoch "$rtc_raw" && return 0
    fi

    return 1
}

get_time_skew_seconds() {
    local system_epoch rtc_epoch diff
    system_epoch=$(date -u +%s 2>/dev/null || return 1)
    rtc_epoch=$(get_rtc_utc_epoch 2>/dev/null || return 1)
    diff=$((system_epoch - rtc_epoch))
    (( diff < 0 )) && diff=$(( -diff ))
    echo "$diff"
}

is_time_synchronized() {
    if command -v timedatectl &>/dev/null; then
        [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]
    elif command -v chronyc &>/dev/null; then
        chronyc tracking 2>/dev/null | grep -Eq 'Leap status[[:space:]]*:[[:space:]]*Normal'
    else
        return 1
    fi
}

# 是否存在能查询 NTP 同步状态的工具。
# busybox ntpd 等环境查不到状态，此时「无法验证」不能当作「未同步」，
# 否则每次调用都会触发一轮无意义的同步修复。
time_sync_status_verifiable() {
    command -v timedatectl &>/dev/null || command -v chronyc &>/dev/null
}

# 通过 HTTPS 响应头的 Date 字段获取网络 UTC 时间。
# 用于在 RTC 读数可疑时仲裁系统时间是否真的有问题：
# 部分虚拟化平台(NAT VPS/容器)的 RTC 是冻结或乱值，偏差可达数十年，
# 这种情况下 NTP 永远「修不好」RTC，但系统时间本身是准的。
get_http_date_epoch() {
    local url raw day mon year hms mon_num epoch

    for url in https://www.cloudflare.com https://www.apple.com; do
        raw=$(curl -sI --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '\r' | \
              awk 'tolower($1) == "date:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
        # RFC 7231 格式: Thu, 03 Jul 2026 04:35:43 GMT
        [[ "$raw" =~ ([0-9]{1,2})[[:space:]]+([A-Z][a-z]{2})[[:space:]]+([0-9]{4})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}) ]] || continue
        day="${BASH_REMATCH[1]}"
        mon="${BASH_REMATCH[2]}"
        year="${BASH_REMATCH[3]}"
        hms="${BASH_REMATCH[4]}"
        case "$mon" in
            Jan) mon_num=01 ;; Feb) mon_num=02 ;; Mar) mon_num=03 ;; Apr) mon_num=04 ;;
            May) mon_num=05 ;; Jun) mon_num=06 ;; Jul) mon_num=07 ;; Aug) mon_num=08 ;;
            Sep) mon_num=09 ;; Oct) mon_num=10 ;; Nov) mon_num=11 ;; Dec) mon_num=12 ;;
            *) continue ;;
        esac
        [[ ${#day} -eq 1 ]] && day="0${day}"
        # 转成 "YYYY-MM-DD HH:MM:SS"，GNU date 和 busybox date 都能解析
        epoch=$(LC_ALL=C date -u -d "${year}-${mon_num}-${day} ${hms}" +%s 2>/dev/null) || continue
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        (( epoch >= 946684800 )) || continue
        echo "$epoch"
        return 0
    done
    return 1
}

get_network_time_skew_seconds() {
    local system_epoch net_epoch diff
    net_epoch=$(get_http_date_epoch) || return 1
    system_epoch=$(date -u +%s 2>/dev/null) || return 1
    diff=$((system_epoch - net_epoch))
    (( diff < 0 )) && diff=$(( -diff ))
    echo "$diff"
}

existing_time_sync_service() {
    local svc
    for svc in systemd-timesyncd chrony chronyd ntp ntpd openntpd; do
        if service_exists "$svc"; then
            echo "$svc"
            return 0
        fi
    done
    if command -v chronyc &>/dev/null; then
        echo "chrony"
        return 0
    fi
    if command -v ntpq &>/dev/null || command -v ntpd &>/dev/null; then
        echo "ntp"
        return 0
    fi
    return 1
}

start_time_sync_service() {
    local svc
    for svc in systemd-timesyncd chrony chronyd ntp ntpd openntpd; do
        service_exists "$svc" || continue
        service_enable_now "$svc" 2>/dev/null || true
    done
}

step_system_time_with_ntp() {
    command -v ntpd &>/dev/null || return 1
    ntpd -d -n -q -p time.cloudflare.com >/dev/null 2>&1
}

install_time_sync_service() {
    local existing_svc

    if existing_svc=$(existing_time_sync_service 2>/dev/null); then
        info "检测到已有时间同步服务: ${existing_svc}，不安装新的时间同步服务"
        return 0
    fi

    case "$(package_manager)" in
        apt)
            info "安装时间同步服务 systemd-timesyncd..."
            if install_apt_packages_low_resource systemd-timesyncd; then
                return 0
            fi
            info "systemd-timesyncd 安装失败，回退安装 chrony..."
            install_apt_packages_low_resource chrony || return 1
            ;;
        dnf)
            info "安装时间同步服务 chrony..."
            install_yum_packages_low_resource dnf chrony || return 1
            ;;
        yum)
            info "安装时间同步服务 chrony..."
            install_yum_packages_low_resource yum chrony || return 1
            ;;
        apk)
            info "安装时间同步服务 chrony..."
            install_apk_packages_low_resource chrony || return 1
            ;;
        *) return 1 ;;
    esac
    return 0
}

attempt_time_sync() {
    if command -v timedatectl &>/dev/null; then
        timedatectl set-ntp true 2>/dev/null || true
    fi
    start_time_sync_service
    sleep 2
    if command -v chronyc &>/dev/null; then
        chronyc -a makestep >/dev/null 2>&1 || true
        sleep 2
    elif command -v ntpd &>/dev/null; then
        step_system_time_with_ntp || true
        sleep 2
    fi
}

ensure_time_sync() {
    local skew="" net_skew=""
    local need_sync=false

    # 检测+修复流程不便宜(多次探测、重启服务)，同一进程内只完整执行一次，
    # 避免菜单里每选一个操作都重复触发。
    if [[ "${TIME_SYNC_CHECKED:-false}" == "true" ]]; then
        return 0
    fi
    TIME_SYNC_CHECKED=true

    if skew=$(get_time_skew_seconds 2>/dev/null); then
        if (( skew > TIME_SKEW_THRESHOLD )); then
            # RTC 偏差过大时先用网络时间仲裁：虚拟化平台的 RTC 可能本身就是
            # 冻结/乱值(偏差可达数十年)，若系统时间与网络时间一致则无需修复。
            if net_skew=$(get_network_time_skew_seconds 2>/dev/null) && (( net_skew <= TIME_SKEW_THRESHOLD )); then
                info "系统时间与网络时间一致 (误差 ${net_skew}s)，RTC 偏差 ${skew}s 判定为宿主机 RTC 异常，已忽略"
                skew="$net_skew"
            else
                need_sync=true
            fi
        fi
    fi

    # 只有在存在可查询同步状态的工具(timedatectl/chronyc)且明确报告未同步时
    # 才触发修复；busybox ntpd 等无法验证的环境不把「查不到」当「未同步」。
    if time_sync_status_verifiable && ! is_time_synchronized; then
        need_sync=true
    fi

    if [[ "$need_sync" != "true" ]]; then
        success "系统时间同步正常"
        return 0
    fi

    if [[ -n "$skew" ]]; then
        warn "检测到系统时间与 RTC 相差 ${skew}s，开始同步修复..."
    else
        warn "检测到系统时间未同步，开始同步修复..."
    fi

    attempt_time_sync

    if time_sync_status_verifiable && ! is_time_synchronized; then
        install_time_sync_service && attempt_time_sync
    fi

    # 修复后复查：网络时间优先于 RTC，RTC 只在拿不到网络时间时兜底
    if net_skew=$(get_network_time_skew_seconds 2>/dev/null); then
        if (( net_skew <= TIME_SKEW_THRESHOLD )); then
            success "系统时间已同步，与网络时间误差 ${net_skew}s"
            return 0
        fi
        warn "时间同步后系统时间与网络时间仍相差 ${net_skew}s，请手动检查 NTP 服务"
        return 1
    fi

    if skew=$(get_time_skew_seconds 2>/dev/null); then
        if (( skew <= TIME_SKEW_THRESHOLD )); then
            success "系统时间已同步，当前与 RTC 误差 ${skew}s"
            return 0
        fi
        warn "时间同步后系统时间与 RTC 仍相差 ${skew}s，请检查宿主机/虚拟化平台时间源"
        return 1
    fi

    if is_time_synchronized; then
        success "系统时间已同步"
        return 0
    fi

    warn "自动时间同步失败，请手动检查 NTP 服务"
    return 1
}

install_singbox() {
    if command -v sing-box &>/dev/null; then
        local ver
        ver=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        info "sing-box 已安装: $ver"
    else
        info "安装 sing-box..."
        install_or_upgrade_singbox_package false || error "sing-box 安装失败。请检查网络、磁盘空间或 GitHub 访问"
        success "sing-box 安装完成"
    fi
    mkdir -p "$CONFIG_DIR"
}

install_cloudflared_from_apk() {
    [[ "$(package_manager)" == "apk" ]] || return 1
    run_low_resource apk add --no-cache cloudflared >/dev/null 2>&1 || return 1
    command -v cloudflared >/dev/null 2>&1 || return 1
    cloudflared --version >/dev/null 2>&1
}

install_cloudflared_binary() {
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH_CF}"
    local tmp_file

    tmp_file=$(mktemp) || return 1
    if ! curl -fsSL --retry 3 --connect-timeout 15 "$url" -o "$tmp_file"; then
        rm -f "$tmp_file"
        return 1
    fi
    chmod 755 "$tmp_file"
    if ! "$tmp_file" --version >/dev/null 2>&1; then
        rm -f "$tmp_file"
        return 1
    fi
    if command -v install >/dev/null 2>&1; then
        install -m 0755 "$tmp_file" /usr/local/bin/cloudflared
    else
        cp "$tmp_file" /usr/local/bin/cloudflared
        chmod 755 /usr/local/bin/cloudflared
    fi
    rm -f "$tmp_file"
    cloudflared --version >/dev/null 2>&1
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        info "cloudflared 已安装"
        return
    fi
    info "安装 cloudflared..."
    if [[ "$(package_manager)" == "apk" ]]; then
        install_cloudflared_from_apk && { success "cloudflared 安装完成"; return; }
        warn "Alpine 软件源安装 cloudflared 失败，改用官方二进制"
    fi
    install_cloudflared_binary || error "cloudflared 安装失败。请检查网络、磁盘空间、系统架构或 GitHub 访问"
    success "cloudflared 安装完成"
}

write_singbox_service() {
    [[ "$(service_manager)" == "openrc" ]] || return 0

    local singbox_bin
    singbox_bin=$(command -v sing-box 2>/dev/null || echo "/usr/bin/sing-box")

    cat > "$SINGBOX_OPENRC_SERVICE" << EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="${singbox_bin}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
}
EOF
    chmod 755 "$SINGBOX_OPENRC_SERVICE"
}


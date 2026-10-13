#!/usr/bin/env bash

case "$(uname -s)" in
    Linux*)               PLATFORM=linux ;;
    Darwin*)              PLATFORM=macos ;;
    MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
    *)
        echo "peek: unsupported OS ($(uname -s))" >&2
        exit 1
        ;;
esac

# --no-color can appear anywhere in the args, strip it out before anything
# else looks at $1/$2 so it doesn't collide w subcommand/-x/count parsing

NO_COLOR_FLAG=false
args=()

for arg in "$@"; do
    if [ "$arg" = "--no-color" ]; then
        NO_COLOR_FLAG=true
    else
        args+=("$arg")
    fi
done
set -- "${args[@]}"


if [ -n "$NO_COLOR" ] || $NO_COLOR_FLAG; then
    BOLD=''
    RESET=''
    GREEN=''
    YELLOW=''
    RED=''
else
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
fi


case "$1" in
    -h|--help|help)
        cat <<EOF

${BOLD}Usage${RESET}:
  peek [command] [options]

${BOLD}Commands${RESET}:
  sys            system info (OS, hostname, uptime)
  mem            memory usage and top processes
  net            network info (IP, gateway, up/down speed)
  disk           free/used space per fixed drive
  git            git status for the current repo
  (none)         show everything above

${BOLD}Options${RESET}:
  -x             show extra detail (mem only)
  <number>       set an exact process-list count (mem only)
  --no-color     disable colored output (also respects the NO_COLOR env var)
  -h, --help     show this help message

EOF
        exit 0
        ;;
esac

cat <<'EOF'

          '||'''|,               '||
           ||   ||                ||
           ||...|' .|''|, .|''|,  || //`  .|''|, '||''|
┌───────── ||      ||..|| ||..||  ||<<    ||..||  || ─────────┐
          .||      `|...  `|...  .|| \\.  `|...  .||.


EOF

barLength=20

# internal border width for the git status output
lineWidth=55

# -x anywhere as second arg means "extra", show more detail/output for the command
# a plain number as the second arg sets an exact count instaed
EXTRA=false
[ "$2" = "-x" ] && EXTRA=true

procLimit=10
if [[ "$2" =~ ^[0-9]+$ ]]; then
    procLimit=$2
elif $EXTRA; then
    procLimit=20
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

fetch_mem() {
    case "$PLATFORM" in
        windows)
            powershell -NoProfile -Command '
$os = Get-CimInstance Win32_OperatingSystem
"{0}|{1}" -f $os.TotalVisibleMemorySize, $os.FreePhysicalMemory
' | tr -d '\r'
            ;;
        linux)
            awk '
                /^MemTotal:/     { total = $2 }
                /^MemAvailable:/ { avail = $2 }
                END              { print total "|" avail }
            ' /proc/meminfo
            ;;
        macos)
            local pageSize totalBytes totalKb freePages inactivePages freeKb
            pageSize=$(sysctl -n hw.pagesize)
            totalBytes=$(sysctl -n hw.memsize)
            totalKb=$((totalBytes / 1024))
            freePages=$(vm_stat | awk '/Pages free/ {gsub(/\./, "", $3); print $3}')
            inactivePages=$(vm_stat | awk '/Pages inactive/ {gsub(/\./, "", $3); print $3}')
            freeKb=$(( (freePages + inactivePages) * pageSize / 1024 ))
            echo "${totalKb}|${freeKb}"
            ;;
    esac
}

fetch_sys() {
    case "$PLATFORM" in
        windows)
            powershell -NoProfile -Command '
$os = Get-CimInstance Win32_OperatingSystem
$u = (Get-Date) - $os.LastBootUpTime
$caption = $os.Caption -replace "Microsoft ", ""
"{0}|{1}d {2}h {3}m" -f $caption, $u.Days, $u.Hours, $u.Minutes
' | tr -d '\r'
            ;;
        linux)
            local caption uptimeSec days hours mins
            caption=$(awk -F= '/^PRETTY_NAME=/ { gsub(/"/, "", $2); print $2 }' /etc/os-release)
            uptimeSec=$(awk '{print int($1)}' /proc/uptime)
            days=$((uptimeSec / 86400))
            hours=$(((uptimeSec % 86400) / 3600))
            mins=$(((uptimeSec % 3600) / 60))
            echo "${caption}|${days}d ${hours}h ${mins}m"
            ;;
        macos)
            local caption bootEpoch nowEpoch uptimeSec days hours mins
            caption="macOS $(sw_vers -productVersion)"
            bootEpoch=$(sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/')
            nowEpoch=$(date +%s)
            uptimeSec=$((nowEpoch - bootEpoch))
            days=$((uptimeSec / 86400))
            hours=$(((uptimeSec % 86400) / 3600))
            mins=$(((uptimeSec % 3600) / 60))
            echo "${caption}|${days}d ${hours}h ${mins}m"
            ;;
    esac
}

fetch_net() {
    case "$PLATFORM" in
        windows)
            powershell -NoProfile -Command '

    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike "169.254*" -and $_.InterfaceAlias -notmatch "Loopback" } |
            Select-Object -First 1 -ExpandProperty IPAddress)

    $gw = (Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty NextHop)

    $rx = (Get-Counter "\Network Interface(*)\Bytes Received/sec").CounterSamples |
           Where-Object { $_.InstanceName -notmatch "Loopback|isatap" } |
           Measure-Object -Property CookedValue -Sum | Select-Object -ExpandProperty Sum

    $tx = (Get-Counter "\Network Interface(*)\Bytes Sent/sec").CounterSamples |
           Where-Object { $_.InstanceName -notmatch "Loopback|isatap" } |
           Measure-Object -Property CookedValue -Sum |
           Select-Object -ExpandProperty Sum

    "$ip|$gw|$rx|$tx"

    '   | tr -d '\r'
            ;;
        linux)
            local iface ip gw rx1 tx1 rx2 tx2 rx=0 tx=0
            iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
            ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
            gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
            if [ -n "$iface" ]; then
                read -r rx1 tx1 < <(awk -v i="${iface}:" '$1==i {print $2, $10}' /proc/net/dev)
                sleep 1
                read -r rx2 tx2 < <(awk -v i="${iface}:" '$1==i {print $2, $10}' /proc/net/dev)
                rx=$(( rx2 - rx1 ))
                tx=$(( tx2 - tx1 ))
            fi
            echo "${ip}|${gw}|${rx}|${tx}"
            ;;
        macos)
            local iface ip gw rx1 tx1 rx2 tx2 rx=0 tx=0
            iface=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')
            if [ -n "$iface" ]; then
                ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
                gw=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}')
                read -r rx1 tx1 < <(netstat -ibn 2>/dev/null | awk -v i="$iface" '$1==i {print $7, $10; exit}')
                sleep 1
                read -r rx2 tx2 < <(netstat -ibn 2>/dev/null | awk -v i="$iface" '$1==i {print $7, $10; exit}')
                rx=$(( rx2 - rx1 ))
                tx=$(( tx2 - tx1 ))
            fi
            echo "${ip}|${gw}|${rx}|${tx}"
            ;;
    esac
}

fetch_processes() {
    case "$PLATFORM" in
        windows)
            MSYS_NO_PATHCONV=1 tasklist /FO CSV /NH |
                sed 's/\([0-9]\),\([0-9]\)/\1\2/g' |
                awk -F',' '{ gsub(/"/, "", $1); gsub(/[^0-9]/, "", $5); print $1 "|" $5 }'
            ;;
        linux|macos)
            ps -eo comm=,rss= | awk '{ rss = $NF; $NF = ""; name = $0; gsub(/^ +| +$/, "", name); print name "|" rss }'
            ;;
    esac
}

fetch_disk() {
    case "$PLATFORM" in
        windows)
            powershell -NoProfile -Command '
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    "{0}|{1}|{2}" -f $_.DeviceID, $_.Size, $_.FreeSpace
}
' | tr -d '\r'
            ;;
        linux|macos)
            df -k 2>/dev/null | awk 'NR>1 && $1 ~ /^\/dev\// { print $6 "|" ($2*1024) "|" ($4*1024) }'
            ;;
    esac
}

# only kick off the data gathering a given view actually needs, and run it
# all concurrently instead of waiting on each powershell call one at a time
need_sys=false
need_mem=false
need_net=false
need_disk=false

case "$1" in
    sys) need_sys=true ;;
    mem) need_mem=true ;;
    net) need_net=true ;;
    disk) need_disk=true ;;
    git) : ;;
    *) need_sys=true; need_mem=true; need_net=true; need_disk=true ;;
esac

pids=()
$need_mem && { fetch_mem > "$WORKDIR/mem" & pids+=($!); fetch_processes > "$WORKDIR/proc" & pids+=($!); }
$need_sys && { fetch_sys > "$WORKDIR/sys" & pids+=($!); }
$need_net && { fetch_net > "$WORKDIR/net" & pids+=($!); }
$need_disk && { fetch_disk > "$WORKDIR/disk" & pids+=($!); }

[ ${#pids[@]} -gt 0 ] && wait "${pids[@]}" 2>/dev/null

if $need_mem; then
    IFS='|' read -r totalKb freeKb < "$WORKDIR/mem"
    usedKb=$((totalKb - freeKb))

    # keep KB precision for the percentage, only round for display below
    percentage=$((usedKb * 100 / totalKb))

    total=$(awk -v v="$totalKb" 'BEGIN{printf "%.1f", v/1048576}')
    free=$(awk -v v="$freeKb" 'BEGIN{printf "%.1f", v/1048576}')
    used=$(awk -v v="$usedKb" 'BEGIN{printf "%.1f", v/1048576}')

    filled=$((barLength * percentage / 100))
    empty=$((barLength - filled))

    barColor=$GREEN
    [ "$percentage" -ge 60 ] && barColor=$YELLOW
    [ "$percentage" -ge 85 ] && barColor=$RED

    # group by process name and sum memory across all instances of that name
    # (fetch_processes already normalizes each platform's output to name|memKB)
    memUsage=$(awk -F'|' '{
            mem[$1] += $2 / 1024
            count[$1]++
        }
        END {
            for (name in mem) printf "%.1f|%s|%d\n", mem[name], name, count[name]
        }' "$WORKDIR/proc" |
        sort -t'|' -k1 -nr |
        head -n "$procLimit" |
        awk -F'|' '{printf "%-43s %8.1f MB\n", $2" ("$3")", $1}')
fi

if $need_sys; then
    IFS='|' read -r osCaption uptime < "$WORKDIR/sys"
fi

if $need_net; then
    IFS='|' read -r netIp netGw netRx netTx < "$WORKDIR/net"
fi

if $need_disk; then
    diskInfo=$(cat "$WORKDIR/disk")
fi

sys() {
    echo "${BOLD}SYSTEM${RESET}"
    echo "Computer: $(hostname)"
    echo "OS: $osCaption"
    echo "Uptime: $uptime"
}

mem() {
    echo "${BOLD}MEMORY${RESET}"
    echo "Total memory: $total GB"
    echo "Free memory: $free GB"
    echo "Memory usage: $percentage%"
    printf '%s' "$barColor"
    printf '%*s' $filled '' | tr ' ' '#'
    printf '%*s' $empty '' | tr ' ' '-'
    printf '%s' "$RESET"
    echo ""
    echo ""
    echo "${BOLD}TOP PROCESSES${RESET}"
    echo "$memUsage"
}

network() {
    echo "${BOLD}NETWORK${RESET}"
    local rxKb txKb
    rxKb=$(awk -v v="${netRx:-0}" 'BEGIN{printf "%.1f", v/1024}')
    txKb=$(awk -v v="${netTx:-0}" 'BEGIN{printf "%.1f", v/1024}')
    echo "IP: ${netIp:-N/A}"
    echo "Gateway: ${netGw:-N/A}"
    echo "Down: ${rxKb} KB/s   Up: ${txKb} KB/s"
}

disk() {
    echo "${BOLD}DISK${RESET}"
    while IFS='|' read -r letter totalBytes freeBytes; do
        [ -z "$letter" ] && continue
        usedBytes=$((totalBytes - freeBytes))
        pct=$((usedBytes * 100 / totalBytes))

        totalGb=$(awk -v v="$totalBytes" 'BEGIN{printf "%.1f", v/1073741824}')
        freeGb=$(awk -v v="$freeBytes" 'BEGIN{printf "%.1f", v/1073741824}')
        usedGb=$(awk -v v="$usedBytes" 'BEGIN{printf "%.1f", v/1073741824}')

        diskColor=$GREEN
        [ "$pct" -ge 60 ] && diskColor=$YELLOW
        [ "$pct" -ge 85 ] && diskColor=$RED

        diskFilled=$((barLength * pct / 100))
        diskEmpty=$((barLength - diskFilled))

        echo "${letter} ${usedGb}/${totalGb} GB used (${pct}%)"
        printf '%s' "$diskColor"
        printf '%*s' $diskFilled '' | tr ' ' '#'
        printf '%*s' $diskEmpty '' | tr ' ' '-'
        printf '%s' "$RESET"
        echo ""
    done <<< "$diskInfo"
}

gitstatus() {
    echo "${BOLD}GIT${RESET}"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Not a git repository"
        return
    fi
    local branch staged unstaged untracked statusWord statusColor last
    branch=$(git branch --show-current)
    [ -z "$branch" ] && branch="detached"
    staged=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    unstaged=$(git diff --name-only 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    if [ $((staged + unstaged + untracked)) -eq 0 ]; then
        statusWord="CLEAN"
        statusColor=$GREEN
    else
        statusWord="DIRTY"
        statusColor=$YELLOW
    fi
    echo "Branch: $branch"
    echo "Status: ${statusColor}${statusWord}${RESET} (staged: $staged, unstaged: $unstaged, untracked: $untracked)"
    last=$(git log -1 --format='%h %s (%cr)' 2>/dev/null)
    if [ -n "$last" ]; then
        local prefix="Last commit: " maxLen
        maxLen=$((lineWidth - ${#prefix}))

        if [ "${#last}" -gt "$maxLen" ]; then
            last="${last:0:$((maxLen - 3))}..."
        fi

        echo "${prefix}${last}"
    fi
}

case "$1" in
    sys)
        sys | sed 's/^/    /'
        ;;
    mem)
        mem | sed 's/^/    /'
        ;;

    net)
        network | sed 's/^/    /'
        ;;
    disk)
        disk | sed 's/^/    /'
        ;;
    git)
        gitstatus | sed 's/^/    /'
        ;;

    "" | *)
        sys | sed 's/^/    /'
        echo ""
        mem | sed 's/^/    /'
        echo ""
        network | sed 's/^/    /'
        echo ""
        disk | sed 's/^/    /'
        echo ""
        gitstatus | sed 's/^/    /'
        ;;
esac

cat <<'EOF'


└─────────                                           ─────────┘
EOF

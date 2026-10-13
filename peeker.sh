#!/usr/bin/env bash

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


                                                      `-.
                                                        .`
                                                     _.`.`
                                                 _.-` .`
                                         ___.---` _.-`
                                 __..---`___..---`
                        _...--.-`   _.--`
                    _.-`.-`.-`  _.-`
                 .-` .`  .`   .`
      .         /   /   /    /                    .
      \`-.._    |  |    \    `.              _..-`/
     .'-.._ ``--.._\     `. -- `.      _..-``  _..-`.
     `_    _       `-. .`        `. .-`      _    _`
       `.``           .            \          ``.`
        `-.-'    _   .              :   _   `-.-`
          `..-..'    ;       .` `.  '    `..-..`
              /      .      : .-. : :        \
              `._     \     ;( O ) /      _.`
                 `-._.'`.    .`-'.' `._.-'
                         `-....-`



EOF

barLength=20

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
    powershell -NoProfile -Command '
$os = Get-CimInstance Win32_OperatingSystem
"{0}|{1}" -f $os.TotalVisibleMemorySize, $os.FreePhysicalMemory
' | tr -d '\r'
}

fetch_sys() {
    powershell -NoProfile -Command '
$os = Get-CimInstance Win32_OperatingSystem
$u = (Get-Date) - $os.LastBootUpTime
$caption = $os.Caption -replace "Microsoft ", ""
"{0}|{1}d {2}h {3}m" -f $caption, $u.Days, $u.Hours, $u.Minutes
' | tr -d '\r'
}

fetch_net() {
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
}

fetch_processes() {
    MSYS_NO_PATHCONV=1 tasklist /FO CSV /NH | sed 's/\([0-9]\),\([0-9]\)/\1\2/g'
}

fetch_disk() {
    powershell -NoProfile -Command '
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    "{0}|{1}|{2}" -f $_.DeviceID, $_.Size, $_.FreeSpace
}
' | tr -d '\r'
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
    memUsage=$(awk -F',' '{
            gsub(/"/, "", $1); gsub(/[^0-9]/, "", $5)
            mem[$1] += $5 / 1024
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
    [ -n "$last" ] && echo "Last commit: $last"
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

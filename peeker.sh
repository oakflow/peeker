#!/usr/bin/env bash

BOLD=$'\033[1m'
RESET=$'\033[0m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

case "$1" in
    -h|--help|help)
        cat <<EOF
Usage: peek [command] [options]

Commands:
  sys            system info (OS, hostname, uptime)
  mem            memory usage and top processes
  net            network info (IP, gateway, up/down speed)
  git            git status for the current repo
  (none)         show everything above

Options:
  -x             show extra detail (mem only)
  <number>       set an exact process-list count (mem only)
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

# only kick off the data gathering a given view actually needs, and run it
# all concurrently instead of waiting on each powershell call one at a time
need_sys=false
need_mem=false
need_net=false

case "$1" in
    sys) need_sys=true ;;
    mem) need_mem=true ;;
    net) need_net=true ;;
    git) : ;;
    *) need_sys=true; need_mem=true; need_net=true ;;
esac

pids=()
$need_mem && { fetch_mem > "$WORKDIR/mem" & pids+=($!); fetch_processes > "$WORKDIR/proc" & pids+=($!); }
$need_sys && { fetch_sys > "$WORKDIR/sys" & pids+=($!); }
$need_net && { fetch_net > "$WORKDIR/net" & pids+=($!); }

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

gitstatus() {
    echo "${BOLD}GIT${RESET}"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Not a git repository"
        return
    fi
    local branch staged unstaged untracked statusWord statusColor last
    branch=$(git branch --show-current)
    [ -z "$branch" ] && branch="detached"
    staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
    unstaged=$(git diff --name-only | wc -l | tr -d ' ')
    untracked=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')
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
        gitstatus | sed 's/^/    /'
        ;;
esac

cat <<'EOF'


└─────────                                           ─────────┘
EOF

# peeker

A lightweight CLI for at-a-glance system info: memory, CPU/process usage, network, disk, and git status. No dependencies, just bash.

```
$ peek

          '||'''|,               '||
           ||   ||                ||
           ||...|' .|''|, .|''|,  || //`  .|''|, '||''|
┌───────── ||      ||..|| ||..||  ||<<    ||..||  || ─────────┐
          .||      `|...  `|...  .|| \\.  `|...  .||.


    SYSTEM
    Computer: my-machine
    OS: Windows 11 Pro
    Uptime: 2d 4h 17m

    MEMORY
    Total memory: 15.9 GB
    Free memory: 6.2 GB
    Memory usage: 61%
    ############--------

    TOP PROCESSES
    chrome.exe (24)                              1842.3 MB
    ...

    NETWORK
    IP: 192.168.1.42
    Gateway: 192.168.1.1
    Down: 128.4 KB/s   Up: 12.1 KB/s

    DISK
    C: 412.0/953.9 GB used (43%)
    ########------------

    GIT
    Branch: unix-support
    Status: CLEAN (staged: 0, unstaged: 0, untracked: 0)
    Last commit: 384182e add disk command, --no-color s...     


└─────────                                           ─────────┘
```

## Install

```bash
git clone https://github.com/oakflow/peeker.git
./peeker/install.sh
```

This symlinks `peek` into `~/.local/bin` and tells you if that directory needs to be added to your `PATH`.

On Windows, run this from Git Bash, `peek` works the same way there once the symlink is on `PATH`.

## Usage

```
peek [command] [options]

Commands:
  sys            system info (OS, hostname, uptime)
  mem            memory usage and top processes
  net            network info (IP, gateway, up/down speed)
  disk           free/used space per fixed drive
  git            git status for the current repo
  update         pull the latest version of peek
  (none)         show everything above

Options:
  -x             show extra detail (mem only)
  <number>       set an exact process-list count (mem only)
  --no-color     disable colored output (also respects the NO_COLOR env var)
  -h, --help     show this help message
```

## Platform support

- **Windows** (Git Bash): fully supported.
- **Linux**: fully supported.
- **macOS**: implemented but not yet tested on real hardware. Worst case a value falls back to blank/`N/A` rather than crashing, but treat it as unverified for now.
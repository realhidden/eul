# eul for Linux

The command line variant of [eul](../README.md) — a calm system monitor for
the terminal, made for Debian, Ubuntu and the Raspberry Pi. One static-ish
C99 binary, no dependencies beyond libc, built with `make`.

```
· eul web-server  · Debian GNU/Linux 12 (bookworm)  · Linux 6.1.0-18-amd64  · up 41d 3h 12m
 cpu    8% [████████░░░░░░░░░░░░░░░░░░░░░░]  load 0.42 0.51 0.49  52°C  2.4 GHz
   0 [████████░░░░░░░░] 16%   1 [██████░░░░░░░░░░░░] 11%
 mem   38% [██████████░░░░░░░░░░░░░░░░░░░░]  1.5 GB of 3.9 GB
      swap  2%    21 MB of 1.0 GB
 disk /             [████░░░░░░░░░░░░░░░]  24.3%  14.6 GB of 62.7 GB
 net  ↓ 12 KB/s   ↑ 3.1 KB/s   eth0 192.168.1.10
 top cpu              top mem
  12.0% postgres        512 MB postgres
 peers web-server sharing via broker.emqx.io
   MacBook Pro  cpu 12%  mem 45%  52°C  ↓12 KB/s ↑3 KB/s
```

## Metrics

Same numbers the Mac app shows, read from `/proc`, `/sys`, `statvfs` and
`getifaddrs` — syscalls and file reads, no shelled-out tools:

- **cpu** — total usage (user+nice+system+irq+softirq+steal), per-core bars,
  load averages, SoC/package temperature (`coretemp`, `k10temp`, `zenpower`,
  `cpu_thermal`, …) and mean core frequency
- **gpu** — busy % for AMD (amdgpu's `gpu_busy_percent`) and NVIDIA (NVML,
  loaded at runtime from the driver — no build dependency). Intel iGPUs and
  the Raspberry Pi expose no utilisation counter, so no row there
- **mem** — used as *total − available* (what `htop` calls used), swap
- **disk** — real filesystems from `/proc/self/mounts` (ext4, xfs, btrfs,
  zfs, vfat, …), used/free like `df`. A mount tints amber below 10% free or
  15 GB free, red below 3% or 4 GB — the same thresholds as the Mac health
  engine (§2.4)
- **net** — total and per-interface rates, addresses per adapter
- **top** — processes by CPU and by resident memory
- **battery** — when `/sys/class/power_supply` has one

Colors follow the Mac app's health language: everything monochrome while
fine, amber at elevated thresholds, red at critical. `NO_COLOR` and
non-TTY output disable colors entirely.

## Install

Every [release](https://github.com/realhidden/eul/releases/latest) carries
`eul-linux-x86_64`, `eul-linux-arm64` and `eul-linux-armv7` (Raspberry Pi
32-bit) tarballs, built against glibc 2.31 — Debian 11+, Ubuntu 20.04+,
Raspberry Pi OS bullseye+:

```bash
curl -L https://github.com/realhidden/eul/releases/latest/download/eul-linux-arm64.tar.gz | tar xz
sudo install eul-linux-arm64/eul /usr/local/bin/
```

## Build

```bash
cd linux
make            # needs only a C compiler and make
sudo make install PREFIX=/usr/local   # optional
```

Works with glibc and musl, x86_64, arm64 and armv7 — a Pi Zero is enough.
For a fully static binary: `make CC=musl-gcc static`.

## Peers: see your Linux boxes in the Mac app

With a shared secret, eul finds other machines running eul — including Macs
running the menu bar app — over the internet through public MQTT brokers.
Snapshots are sealed (ChaChaPoly, key derived from the secret) before they
leave the machine, so neither the network nor the broker sees the stats.

On the Mac, set the secret in eul's settings. On Linux:

```bash
eul --generate-secret                    # once; give it to every device
EUL_SHARE_SECRET=xryfj-qcrb4-vrckj-r7p8d eul --peers
```

`--peers` shows discovered machines in the dashboard; `--headless` runs the
sharer without a dashboard, for servers (see `eul-cli.service`). In the Mac
app a Linux box shows up in Settings and in the panel's machine picker,
with its CPU (per core), memory, GPU, network, disk and uptime.

eul joins all three brokers at once, like the Mac app, so peers still meet
when one broker is down. The Linux side connects over plain-TCP MQTT (port
1883) to stay dependency-free: the payload is sealed and authenticated
either way, and Macs listening on the same brokers over TLS receive it just
the same. What a network observer can see is the topic name and message
sizes, as on the broker itself. There is no LAN (Bonjour) path on Linux;
Macs next to a Linux box see it through the brokers.

Secrets are 4 groups of 5 from a look-alike-free alphabet (~99 bits). Use
the same secret on every device you want to see each other; peers expire
after ~16 s of silence.

## Options

```
-i, --interval SECONDS  refresh interval, fractions ok (default 2)
-1, --once              print one frame and exit
-j, --json              print one JSON snapshot and exit
    --no-color          plain text, no ANSI colors
    --ascii             # bars instead of unicode blocks
    --no-top            hide the top processes table
-s, --share SECRET      join the eul peer network (EUL_SHARE_SECRET env)
-p, --peers             show discovered peers in the dashboard
    --name NAME         name advertised to peers (default: hostname)
    --broker HOST:PORT  replace the default broker list (comma separated)
    --headless          no dashboard; share only (for systemd)
    --generate-secret   print a fresh shareable secret and exit
```

`--json` is stable and script-friendly: cpu/mem/disk/net/top/battery/peers
with byte counts and rates in bytes per second.

## systemd

```bash
sudo cp eul-cli.service /etc/systemd/system/
sudoedit /etc/default/eul        # EUL_SHARE_SECRET=your-secret
sudo systemctl enable --now eul-cli
```

## Tests

```bash
make test        # RFC vectors for the crypto, JSON/peer decode checks
make compat      # macOS only: cross-checks against the Swift/CryptoKit
                 # implementation the eul app ships, in both directions
```

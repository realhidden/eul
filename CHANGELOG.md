# Changelog

What this fork ([realhidden/eul](https://github.com/realhidden/eul)) built on
top of the eul lineage. Newest first. Earlier history is summarised at the
bottom.

## 2.3.0 — 2026-09-25

### Peers in the panel
- **Machine picker** in the panel footer, between "Updated every…" and
  "eul is using…". It lists this Mac and every peer sharing your secret, and
  only appears while at least one peer is connected.
- **Remote view:** pick a peer and the tiles show its numbers instead of
  yours: CPU with the per-core grid, memory with its app / wired /
  compressed breakdown, network, GPU and disk. Each has a history chart built
  from the peer's snapshots. The header shows the peer's name, uptime and
  path (LAN or Internet).
- **Always opens local:** the panel resets to this Mac whenever it closes,
  and falls back to it if the picked peer disappears.
- **No remote processes:** a Mac only samples processes while its own panel
  is open, to save energy, so there are none to send.

### Sharing
- **Explicit switch:** "Share stats with other Macs" in Settings · General.
  A secret alone no longer turns sharing on. Macs that already had a secret
  on 2.2 stay switched on after the update.
- **All brokers at once:** eul joins all three brokers side by side instead
  of failing over. Two peers that each landed on a different broker used to
  never meet. The copy of a snapshot that arrives through a second broker,
  or over LAN as well, is dropped by its sender timestamp.
- **Richer snapshots:** they now carry per-core usage, the memory breakdown,
  disk free/total and uptime. The new fields are optional, so 2.2 and 2.3
  peers still understand each other in both directions.
- **Settings card:** the secret's caption is shorter and sits under the
  field instead of wrapping beside it.

### eul for Linux (new)
- **What it is:** a terminal monitor for Debian, Ubuntu and the Raspberry
  Pi, as one dependency-free C99 binary. It builds with glibc or musl for
  x86_64, arm64 and armv7. See [`linux/README.md`](linux/README.md).
- **Metrics:**
  - CPU total and per core, load, temperature, frequency
  - memory and swap
  - GPU: AMD via sysfs, NVIDIA via NVML loaded at runtime
  - disks, network, top processes by CPU and memory, battery
- **Output:** a live dashboard, `--once`, or `--json`.
- **Peers:** it speaks the Mac app's peer protocol byte for byte. Linux boxes
  appear in the Mac panel's picker, and Macs in the Linux dashboard.
  `--headless` runs only the sharer, with a systemd unit included.
- **Tests:**
  - RFC test vectors for the crypto
  - Mac 2.3 snapshot decoding
  - MQTT framing: split, batched and oversized packets
  - a cross-check against CryptoKit in both directions (`make compat`)
- **CI and releases:** CI builds with `-Werror` and runs the tests under
  ASan/UBSan. Releases attach glibc 2.31 tarballs for all three
  architectures, which run on Debian 11+, Ubuntu 20.04+ and Raspberry Pi OS.

### Release pipeline
- **Publishing:** releases are published with the `gh` CLI instead of
  `action-gh-release`, which raced itself into a duplicate draft on v2.3.0
  and lost two tarballs. The job now fails if any expected asset is
  missing.

## 2.2.0 — 2026-09-25

### Nearby Macs (new)
- **Discovery:** Macs running eul with the same shared secret find each
  other and exchange a small stats snapshot every 5 s: CPU, memory, GPU,
  temperature and network rates.
- **Two paths:**
  - **LAN:** Bonjour `_eul-peer._udp`, snapshots sent straight between Macs.
  - **Internet:** public MQTT brokers over TLS (`broker.emqx.io`,
    `broker.hivemq.com`, `test.mosquitto.org`). There is nothing to deploy
    and no account.
- **End-to-end encryption:** the secret is stretched with PBKDF2-SHA256
  (200k rounds) and split with HKDF into the Bonjour token, the broker topic
  and a ChaChaPoly key. The network and the brokers see neither the secret
  nor the stats. Echoes of our own snapshots and anything older than 60 s
  are dropped.
- **MQTT client:** a minimal MQTT 3.1.1 client (QoS 0, keepalive, reconnect)
  written on Network.framework, so there are no new dependencies.
- **Secret generator:** Generate makes a strong secret that's still easy to
  type on the other Mac: four groups of five characters, without look-alikes
  like 0/o or 1/l, about 99 bits. A typed secret under 12 characters gets a
  warning, and surrounding whitespace is ignored.
- **Languages:** Settings · General has a Nearby Macs card listing peers with
  their stats, translated into all 23 languages.

## 2.1.0 — 2026-09-18

### Menu bar and panel
- **Slot styles:** a three-way picker (Full, Value only and a new Smart
  style) previewed live in Settings against real data. Smart swaps the caps
  label for the component glyph and puts a history histogram under each
  value.
- **One chart language:** the same histogram draws in the bar, the panel and
  the widgets. Charts are zero-based, so an idle GPU no longer looks busy,
  and percentages are capped at 100.
- **Panel tiles:**
  - the per-core grid is always visible
  - memory and GPU gained history charts
  - the CPU tile takes the full row
  - process rows show their PID
- **Addresses:** the network tile lists every adapter's addresses in your
  service order, and one click copies an address.
- **Glyphs:** component icons use SF Symbols, with a bitmap fallback where
  no symbol exists.
- **Widgets:** CPU, Memory and Network widgets were rebuilt around the hero
  number and a history chart. The chart uses the same samples the panel
  draws, so the two never disagree.
- **Status items:** a hidden status item can be forced to show.

### Fixes
- **Ad-hoc signed builds:** fixed a launch crash outside Xcode caused by
  hardened runtime.
- **Width governor:** it no longer collapses a perfectly visible status
  item.
- **Preferences shortcut:** the Preferences menu item (⌘,) was never
  connected and did nothing; it works now.
- **Network watchdog:** its message is clearer.

### Releases
- **Architectures:** releases are now a universal Release build (x86_64 +
  arm64), not an arm64-only Debug build. The workflow fails if a slice is
  missing, or if the ad-hoc signed app carries hardened runtime, the
  combination that can't launch.
- **Repository:** 569 MB of committed build output is no longer tracked, and
  repo links point to this fork.

### Removed
- **Clean Mode:** the screen blackout and keyboard lock for wiping.

## Before this fork

- **2.0.0:** the redesign by [chrsomle](https://github.com/chrsomle/eul):
  - one menu bar entry point with a width governor
  - the investigation panel and the health engine
  - fan control through a privileged helper
  - honest widgets, and native sampling
- **1.7.0:** [miaoweiwei](https://github.com/miaoweiwei) made it build with
  modern Xcode and fixed Apple Silicon CPU/GPU/memory temperatures.
- **1.6.3:** macOS compatibility fixes (network stats on newer macOS, disk
  usage) and an SMC struct size assertion, merged from the
  [sclarkca](https://github.com/sclarkca/eul) and
  [StoneOlo](https://github.com/StoneOlo/eul) forks.
- **1.0–1.6.2:** the original eul by [gao-sun](https://github.com/gao-sun/eul)
  and its localisation community.

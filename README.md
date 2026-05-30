# statusbar-rtkernel

Reproducible PREEMPT_RT kernel builds for Raspberry Pi 5, packaged as
Debian `.deb`s. Built in a Debian Trixie container via Podman, designed
to be driven from per-variant config snapshots that you commit and pin
to a kernel SHA.

> Portions of this repository were developed with assistance from Claude,
> an AI model by Anthropic. The kernel itself is upstream Linux under its
> own license; this repository contains my own build, packaging, and
> deployment tooling around it, with Claude assisting in refactoring the
> scripts and in validating the realtime and CPU isolation configuration.
> All architectural decisions, final implementations, and engineering
> judgments are my own, and any errors are mine alone.

> Works on arm64 hosts (Apple Silicon Macs, arm64 Linux) and x86_64
> Debian hosts. `build.sh` picks the container path automatically from
> `uname -m`: arm64 builds natively, x86_64 cross-compiles to arm64.
> Both paths produce the same arm64 `.deb`s. Details and the qemu-user
> fallback are in [`docs/X86_HOSTS.md`](docs/X86_HOSTS.md).

## What it builds

A kernel variant is a directory under `variants/`:

```
variants/<name>/
  build.conf   # kernel branch + pinned SHA + .deb version
  config       # full kernel .config
  cmdline.txt  # /boot/firmware/cmdline.txt (PARTUUID as __PARTUUID__)
  README.md    # what this variant is and why
```

`build.sh <name>` reads the variant, builds the kernel + headers `.deb`s,
and drops them in `variants/<name>/out/`. `deploy.sh <name> user@host`
copies them to a Pi, installs, and replaces the cmdline (preserving the
Pi's `PARTUUID`).

## Prereqs

- Build host: Apple Silicon Mac (Podman Machine — arm64 VM by default),
  arm64 Linux (Debian, Ubuntu, Fedora Asahi, …), or x86_64 Debian/Ubuntu
  (cross-compiles via `Containerfile.cross`).
- Podman ≥ 4. `brew install podman && podman machine init --now` on
  macOS; `dnf install podman` or `apt install podman` on Linux.
- An SSH-reachable Pi 5 running Raspberry Pi OS (Trixie-based).

## Quick start

Build and deploy the pinned 6.12.70 variant:

    ./build.sh  6.12.70-nohzfull-rt+
    ./deploy.sh 6.12.70-nohzfull-rt+ pi@raspberrypi
    ssh pi@raspberrypi sudo reboot
    ssh pi@raspberrypi 'bash -s' < verify.sh

First build takes ~15–25 minutes on M-series Macs or comparable x86_64
Debian hosts (clone + image build + kernel compile). Subsequent builds
reuse a kernel source clone cached in a Podman volume —
`statusbar-rtkernel-src-native` on arm64 hosts,
`statusbar-rtkernel-src-cross` on x86_64.

Inspect or wipe the source cache (substitute `-cross` on x86_64 hosts):

    podman volume inspect statusbar-rtkernel-src-native
    podman volume rm      statusbar-rtkernel-src-native   # next build re-clones

## Variants

Three are shipped:

| Variant | Pin | Notes |
| --- | --- | --- |
| `6.12.70-nohzfull-rt+` | commit `88969c95` (2026-02-11) | The kernel running on jdk01A. |
| `6.12.90-nohzfull-rt+` | commit `998e6404` on `rpi-6.12.y` | Pinned to the merge that bumps the branch to Linux 6.12.90. |
| `6.18-nohzfull-rt+` | branch `rpi-6.18.y` (auto-pinned per build) | Series tracker — accepts any 6.18.x point release. |

All apply: `PREEMPT_RT`, `HZ=1000`, `NO_HZ_FULL`, `RCU_NOCB_CPU`,
`IRQ_FORCED_THREADING`, ftrace + osnoise + hwlat tracers, BPF + perf.
All isolate `cpu2-3` via cmdline (`isolcpus=2-3 nohz_full=2-3
rcu_nocbs=2-3 irqaffinity=0-1`) leaving `cpu0-1` for housekeeping.

### Variant naming: X.Y vs X.Y.Z

The kernel version prefix in the variant name determines how strictly
`build.sh`'s post-build assertion checks what was actually built:

- **`X.Y.Z-…`** — pin a specific point release (e.g. `6.12.70-…`).
  `build.sh` refuses if the produced kernel's `X.Y.Z` doesn't match.
  Use this when you care about a known-good point release and want
  rebuilds to fail loudly if the pin drifts.
- **`X.Y-…`** — track the whole rpi-X.Y.y series (e.g. `6.18-…`).
  Any point release on the series is accepted; the post-build assertion
  only fails if the major.minor changes (e.g. branch jumps to 6.19).
  Use this when you want to track upstream stable updates as they roll
  in and don't care which specific patch level you get.

In both modes, `KERNEL_REF` is auto-written-back on first build for
reproducibility. To roll a series-tracking variant forward, blank
`KERNEL_REF` again before the next build.

### Make a new variant

    ./new-variant.sh 6.13.5-nohzfull-rt+ rpi-6.13.y    # pin a point release
    ./new-variant.sh 6.13-nohzfull-rt+   rpi-6.13.y    # track the series

Clones the kernel (cached), applies the RT/perf base on top of
`bcm2712_defconfig`, drops you into `menuconfig` for tweaks, then
snapshots the resulting `.config` + a starter `build.conf` and
`cmdline.txt` into `variants/<name>/`. Commit those four files.

## Reproducibility

`build.sh` sets:

- `KBUILD_BUILD_USER=statusbar`
- `KBUILD_BUILD_HOST=rtkernel-builder`
- `KBUILD_BUILD_TIMESTAMP=<commit's author date>`

Override via env vars to change them. When a variant's `KERNEL_REF` is
empty, `build.sh` resolves the branch tip, builds it, and writes the
resolved SHA back into `build.conf`.

## Layout

```
.
├── build.sh                       # ./build.sh <variant>
├── deploy.sh                      # ./deploy.sh <variant> user@host
├── new-variant.sh                 # ./new-variant.sh <name> <branch>
├── verify.sh                      # run on the Pi (or pipe via ssh)
├── podman/Containerfile.trixie    # arm64 host → native arm64 build
├── podman/Containerfile.cross     # x86_64 host → arm64 cross-build
├── docs/X86_HOSTS.md
└── variants/<name>/{build.conf, config, cmdline.txt, README.md}
```

## Reverting

The Pi's stock kernel `.deb` and original `cmdline.txt` / `config.txt` are
all kept:

- `dpkg -i /var/cache/apt/archives/linux-image-*.deb` to reinstall the
  stock kernel.
- `sudo cp /boot/firmware/cmdline.txt.pre-rtkernel /boot/firmware/cmdline.txt`
  to restore the original cmdline.
- `sudo cp /boot/firmware/config.txt.pre-rtkernel /boot/firmware/config.txt`
  to drop the `kernel=vmlinuz-…` / `initramfs …` block `deploy.sh` appended
  (otherwise the bootloader will keep loading the RT kernel even after a
  stock `linux-image-rpi` reinstall).

These leave the RT kernel installed alongside; if you only want to pick a
different kernel at boot without a full revert, edit the managed block in
`/boot/firmware/config.txt` instead.

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

> **arm64-only.** This is for Apple Silicon Macs or arm64 Linux hosts
> (the build container is native arm64). For x86_64 hosts see
> [`docs/X86_HOSTS.md`](docs/X86_HOSTS.md).

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

- arm64 host: Apple Silicon Mac (Podman Machine — arm64 VM by default)
  or arm64 Linux (Debian, Ubuntu, Fedora Asahi, …).
- Podman ≥ 4. `brew install podman && podman machine init --now` on
  macOS; `dnf install podman` or `apt install podman` on Linux.
- An SSH-reachable Pi 5 running Raspberry Pi OS (Trixie-based).

## Quick start

Build and deploy the pinned 6.12.70 variant:

    ./build.sh  6.12.70-nohzfull-rt+
    ./deploy.sh 6.12.70-nohzfull-rt+ pi@raspberrypi
    ssh pi@raspberrypi sudo reboot
    ssh pi@raspberrypi 'bash -s' < verify.sh

First build takes ~15–25 minutes on M-series Macs (clone + image
build + kernel compile). Subsequent builds reuse a kernel source clone
cached in the Podman volume `statusbar-rtkernel-src`.

### Why a volume instead of a host directory?

The Linux kernel tree contains pairs of files that differ only in case
(e.g. `xt_CONNMARK.h` vs `xt_connmark.h`). macOS APFS is case-insensitive
by default, so a host-side clone silently loses ~25 source files and
the build fails later. Keeping the source in a Podman volume puts it
on the VM's case-sensitive ext4 filesystem. On Linux hosts the volume
is equally fine — same code path everywhere.

Inspect or wipe the source cache:

    podman volume inspect statusbar-rtkernel-src
    podman volume rm      statusbar-rtkernel-src   # next build re-clones

## Variants

Two are shipped:

| Variant | Pin | Notes |
| --- | --- | --- |
| `6.12.70-nohzfull-rt+` | commit `88969c95` (2026-02-11) | The kernel running on jdk01A. |
| `6.12.90-nohzfull-rt+` | commit `998e6404` on `rpi-6.12.y` | Pinned to the merge that bumps the branch to Linux 6.12.90. |

Both apply: `PREEMPT_RT`, `HZ=1000`, `NO_HZ_FULL`, `RCU_NOCB_CPU`,
`IRQ_FORCED_THREADING`, ftrace + osnoise + hwlat tracers, BPF + perf.
Both isolate `cpu2-3` via cmdline (`isolcpus=2-3 nohz_full=2-3
rcu_nocbs=2-3 irqaffinity=0-1`) leaving `cpu0-1` for housekeeping.

### Make a new variant

    ./new-variant.sh 6.13.5-nohzfull-rt+ rpi-6.13.y

Clones the kernel (cached), applies the RT/perf base on top of
`bcm2712_defconfig`, drops you into `menuconfig` for tweaks, then
snapshots the resulting `.config` + a starter `build.conf` and
`cmdline.txt` into `variants/6.13.5-nohzfull-rt+/`. Commit those four
files.

## Reproducibility

`build.sh` sets:

- `KBUILD_BUILD_USER=statusbar`
- `KBUILD_BUILD_HOST=rtkernel-builder`
- `KBUILD_BUILD_TIMESTAMP=<commit's author date>`

so the kernel's version string is determined entirely by the variant
files + the pinned SHA. Override via env vars if you want different
values. When a variant's `KERNEL_REF` is empty, `build.sh` resolves
the branch tip, builds it, and writes the resolved SHA back into
`build.conf` — so the first "branch tip" build becomes a pinned build
after the fact.

## Layout

```
.
├── build.sh                       # ./build.sh <variant>
├── deploy.sh                      # ./deploy.sh <variant> user@host
├── new-variant.sh                 # ./new-variant.sh <name> <branch>
├── verify.sh                      # run on the Pi (or pipe via ssh)
├── podman/Containerfile.trixie    # native arm64 build env
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

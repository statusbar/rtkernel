# Building on x86_64 hosts

This repo is **arm64-only** by design — the build container is
`arm64v8/debian:trixie` and the produced `.deb`s are arm64 only.
On an arm64 host (Apple Silicon Mac via Podman Machine, or arm64
Linux) the container runs natively and a full build takes ~15–25 min.

There are two ways to use this on an x86_64 host. Neither is supported
or fast.

## 1. qemu-user emulation

Install `qemu-user-static` on the host so Podman can run arm64
containers:

    # Debian/Ubuntu
    sudo apt install qemu-user-static binfmt-support
    # Fedora
    sudo dnf install qemu-user-static

Then everything in this repo works as documented — `./build.sh
<variant>` will pull the `arm64v8` image and run it under emulation.
Expect a **10–30× slowdown** (a 20-minute native build becomes 4–10
hours). Acceptable for one-off CI runs, painful for iteration.

You may need to explicitly request the arm64 platform if your Podman
default differs:

    podman pull --arch=arm64 arm64v8/debian:trixie

## 2. Cross-compile from x86_64 (not provided here)

The original `docs/kernelbuild-rpi5-cross-from-fedora/` scripts in the
statusbar repo use `gcc-aarch64-linux-gnu` to cross-compile from a
Fedora x86_64 host directly, no container needed. That's faster than
emulation but requires a different build path (different toolchain
package, `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`, no
container indirection). This repo intentionally doesn't carry that
variant — keeping a single arm64-native code path is the whole point.

If you have a frequent x86_64-host workflow, fork and add a
`Containerfile.cross` that installs the GNU cross-toolchain on top of
`debian:trixie` (host arch) and have `build.sh` switch on
`uname -m`.

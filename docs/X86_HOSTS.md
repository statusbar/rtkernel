# Building on x86_64 hosts

The arm64 `.deb`s this repo produces can be built on x86_64 Debian hosts
two ways. **Cross-compile is the recommended path** — it's native amd64
inside the container, so the build runs as fast as it would on an arm64
host. qemu-user emulation remains as a fallback for anyone who wants the
exact arm64 image used on native hosts.

## 1. Cross-compile (recommended)

`build.sh` detects `uname -m == x86_64` and switches automatically to a
parallel container path:

- Image: `statusbar-rtkernel:trixie-cross-amd64`, built from
  [`podman/Containerfile.cross`](../podman/Containerfile.cross) — native
  amd64 `debian:trixie` plus `crossbuild-essential-arm64` and the
  `:arm64` dev headers `bindeb-pkg` needs.
- Source volume: `statusbar-rtkernel-src-cross` (separate from the
  arm64 native volume so the two paths don't trample each other).
- In-container `make` invocation: `ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu- … KBUILD_DEBARCH=arm64 bindeb-pkg`.

`KBUILD_DEBARCH=arm64` is the non-obvious knob. Without it `bindeb-pkg`
stamps the resulting `.deb`'s `Architecture:` field with the build host's
arch (`amd64`), and `apt install` on the Pi refuses it with a confusing
error. If a build succeeds but `dpkg-deb -I` reports `amd64`, that flag
didn't take effect — that's the first thing to check.

Run:

    ./build.sh 6.18.29-nohzfull-rt+

Verify the output is actually arm64:

    dpkg-deb -I variants/6.18.29-nohzfull-rt+/out/linux-image-*.deb \
      | grep Architecture
    # Architecture: arm64

Then `./deploy.sh <variant> pi@<host>` as usual.

## 2. qemu-user emulation (fallback)

If you want the exact same arm64v8 image used on native arm64 hosts,
install qemu-user-static so podman can run arm64 containers under
emulation:

    # Debian/Ubuntu
    sudo apt install qemu-user-static binfmt-support
    # Fedora
    sudo dnf install qemu-user-static

You then have to force `build.sh` down the arm64 path — easiest is to
edit the `uname -m` switch locally and pick the arm64v8 image, or run
the equivalent `podman` commands by hand:

    podman build --platform=linux/arm64 \
      -t statusbar-rtkernel:trixie-arm64 \
      -f podman/Containerfile.trixie podman/

Expect a **10–30× slowdown** vs the cross path (a 20-minute build
becomes 4–10 hours). Useful for one-off CI runs where bit-for-bit parity
with the arm64 native image matters; painful for iteration.

## Reproducibility across paths

The `.deb`s aren't bit-identical across paths — the `FROM debian:trixie`
lines aren't pinned to image digests. Pin both to `@sha256:...` and
`sha256sum`-compare in CI if you need strict parity.

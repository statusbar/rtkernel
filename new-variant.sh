#!/usr/bin/env bash
# Scaffold a new kernel variant.
#
# Usage:  ./new-variant.sh <variant-name> <kernel-branch>
# Example: ./new-variant.sh 6.13.5-nohzfull-rt+ rpi-6.13.y
#
# Clones the kernel (in a named Podman volume — see build.sh for why),
# applies our RT/perf base on top of bcm2712_defconfig, drops you into
# menuconfig to review/tweak, then snapshots the resulting .config plus
# a starter build.conf, cmdline.txt, and README.md into variants/<name>/.

set -euo pipefail

usage() { echo "Usage: $0 <variant-name> <kernel-branch>"; exit 1; }
[ $# -eq 2 ] || usage

name="$1"
branch="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
variant_dir="$script_dir/variants/$name"

[ -e "$variant_dir" ] && { echo "$variant_dir already exists"; exit 1; }

image="statusbar-rtkernel:trixie-arm64"
src_vol="statusbar-rtkernel-src"
remote="${KERNEL_REMOTE:-https://github.com/raspberrypi/linux.git}"

echo "==> Building container image $image"
podman build --quiet -t "$image" \
  -f "$script_dir/podman/Containerfile.trixie" "$script_dir/podman" >/dev/null

if ! podman volume inspect "$src_vol" >/dev/null 2>&1; then
  echo "==> Creating volume $src_vol"
  podman volume create "$src_vol" >/dev/null
fi

cid=""
cleanup() {
  [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting container"
cid=$(podman run -d --rm \
  -v "$src_vol":/work \
  -e KERNEL_REMOTE="$remote" \
  -e KERNEL_BRANCH="$branch" \
  "$image" \
  sleep infinity)

podman exec "$cid" mkdir -p /out

# Prepare source. Doing this non-interactively before menuconfig.
echo "==> Cloning/updating kernel source in volume"
podman exec -i "$cid" bash <<'PREP'
set -euo pipefail
cd /work
if [ ! -d linux/.git ]; then
  git clone --filter=blob:none "$KERNEL_REMOTE" linux
fi
cd linux
git fetch --quiet origin "$KERNEL_BRANCH"
git checkout --quiet --detach "origin/$KERNEL_BRANCH"
git clean -qfdx

make ARCH=arm64 bcm2712_defconfig
scripts/config --enable  PREEMPT_RT
scripts/config --disable PREEMPT_VOLUNTARY
scripts/config --disable PREEMPT_NONE
scripts/config --set-val HZ 1000
scripts/config --enable  HZ_1000
scripts/config --enable  NO_HZ_FULL
scripts/config --enable  RCU_NOCB_CPU
scripts/config --enable  IRQ_FORCED_THREADING
scripts/config --enable  FUNCTION_TRACER FUNCTION_GRAPH_TRACER DYNAMIC_FTRACE \
                         FTRACE_SYSCALLS IRQSOFF_TRACER PREEMPT_TRACER \
                         SCHED_TRACER OSNOISE_TRACER TRACE_CLOCK HWLAT_TRACER
scripts/config --enable  BPF_SYSCALL BPF_JIT PERF_EVENTS
scripts/config --set-str LOCALVERSION "-nohzfull-rt"
make ARCH=arm64 olddefconfig

# Capture the branch tip SHA for the README.
git rev-parse HEAD > /out/.sha
PREP

# Interactive menuconfig (save+exit to keep defaults).
echo "==> Running menuconfig — save+exit to keep defaults"
podman exec -it "$cid" bash -c 'cd /work/linux && make ARCH=arm64 menuconfig'

# Snapshot the resulting config.
podman exec "$cid" cp /work/linux/.config /out/config
sha=$(podman exec "$cid" cat /out/.sha)

mkdir -p "$variant_dir"
podman cp "$cid:/out/config" "$variant_dir/config"

cat >"$variant_dir/build.conf" <<EOF
# Variant: $name
# Scaffolded $(date -u +%Y-%m-%d) from $branch @ $sha

KERNEL_REMOTE=$remote
KERNEL_BRANCH=$branch

# Pinned commit. Empty = use branch tip; build.sh will write the resolved
# SHA back here after a successful build.
KERNEL_REF=

# Trailing suffix kbuild's setlocalversion writes to .scmversion. The "+"
# matches the convention captured from jdk01A. Set empty to suppress.
SCMVERSION_SUFFIX=+

KDEB_PKGVERSION=1.0-1
EOF

cat >"$variant_dir/cmdline.txt" <<'EOF'
console=serial0,115200 console=tty1 root=PARTUUID=__PARTUUID__ rootfstype=ext4 fsck.repair=yes rootwait isolcpus=2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1
EOF

cat >"$variant_dir/README.md" <<EOF
# $name

Scaffolded from \`$branch\` @ \`$sha\`.

Edit \`config\` (re-run \`./new-variant.sh\` then move the file, or use
\`scripts/config\` inside the container) and \`cmdline.txt\` as needed, then:

    ./build.sh $name
    ./deploy.sh $name pi@raspberrypi
EOF

echo
echo "==> Scaffolded $variant_dir"
echo "==> Review, then: ./build.sh $name"

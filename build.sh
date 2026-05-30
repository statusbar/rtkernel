#!/usr/bin/env bash
# Build a kernel variant. Produces .deb packages in variants/<variant>/out/.
#
# Usage:  ./build.sh <variant>
# Example: ./build.sh 6.12.90-nohzfull-rt+
#
# The kernel source is kept in a named Podman volume (statusbar-rtkernel-src)
# so it lives in the container engine's case-sensitive ext4 filesystem.
# This is required on macOS (APFS is case-insensitive by default and would
# silently destroy ~25 kernel source files on clone). Variant inputs and
# build outputs are shuttled in and out via `podman cp` — no host bind
# mounts — so the script works regardless of which host paths the Podman
# Machine VM shares.

set -euo pipefail

usage() {
  echo "Usage: $0 <variant>"
  echo
  echo "Available variants:"
  ls -1 "$(dirname "$0")/variants" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  exit 1
}

[ $# -eq 1 ] || usage
variant="$1"

script_dir="$(cd "$(dirname "$0")" && pwd)"
variant_dir="$script_dir/variants/$variant"
[ -d "$variant_dir" ] || { echo "no such variant: $variant_dir"; usage; }
[ -f "$variant_dir/build.conf" ] || { echo "missing $variant_dir/build.conf"; exit 1; }
[ -f "$variant_dir/config" ] || { echo "missing $variant_dir/config"; exit 1; }

KERNEL_REMOTE=""
KERNEL_BRANCH=""
KERNEL_REF=""
SCMVERSION_SUFFIX=""
KDEB_PKGVERSION="1.0-1"
# shellcheck disable=SC1090
. "$variant_dir/build.conf"

: "${KERNEL_REMOTE:=https://github.com/raspberrypi/linux.git}"
[ -n "$KERNEL_BRANCH" ] || { echo "KERNEL_BRANCH must be set in build.conf"; exit 1; }

build_user="${KBUILD_BUILD_USER:-statusbar}"
build_host="${KBUILD_BUILD_HOST:-rtkernel-builder}"
# Empty default — container fills in from commit author date if unset.
build_ts="${KBUILD_BUILD_TIMESTAMP:-}"

out_dir="$variant_dir/out"
mkdir -p "$out_dir"

# A previous run may have produced .debs for a different kernel version
# (e.g. when the pinned SHA rolled forward). Clear them so the only thing
# in out/ after this build is what this build produced.
rm -f "$out_dir"/linux-*.deb "$out_dir"/.resolved-ref

# Extract the version prefix (X.Y.Z) from the variant name. The build
# must produce a kernel whose version starts with this, otherwise we've
# silently drifted off the requested version.
expected_ver=$(echo "$variant" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
[ -n "$expected_ver" ] || {
  echo "ERROR: variant name '$variant' does not start with a kernel version (X.Y.Z) — refusing to build"
  exit 1
}

image="statusbar-rtkernel:trixie-arm64"
src_vol="statusbar-rtkernel-src"

echo "==> Building container image $image"
podman build --quiet -t "$image" \
  -f "$script_dir/podman/Containerfile.trixie" "$script_dir/podman" >/dev/null

if ! podman volume inspect "$src_vol" >/dev/null 2>&1; then
  echo "==> Creating volume $src_vol (kernel source cache)"
  podman volume create "$src_vol" >/dev/null
fi

cid=""
cleanup() {
  [ -n "$cid" ] && podman rm -f "$cid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> Starting build container"
cid=$(podman run -d --rm \
  -v "$src_vol":/work \
  -e KERNEL_REMOTE="$KERNEL_REMOTE" \
  -e KERNEL_BRANCH="$KERNEL_BRANCH" \
  -e KERNEL_REF="$KERNEL_REF" \
  -e SCMVERSION_SUFFIX="$SCMVERSION_SUFFIX" \
  -e KDEB_PKGVERSION="$KDEB_PKGVERSION" \
  -e KBUILD_BUILD_USER="$build_user" \
  -e KBUILD_BUILD_HOST="$build_host" \
  -e KBUILD_BUILD_TIMESTAMP="$build_ts" \
  "$image" \
  sleep infinity)

podman exec "$cid" mkdir -p /variant /out
echo "==> Staging variant into container"
podman cp "$variant_dir/build.conf" "$cid:/variant/"
podman cp "$variant_dir/config" "$cid:/variant/"

echo "==> Compiling — this is the long part"
podman exec -i "$cid" bash <<'BUILD'
set -euo pipefail

cd /work
# bindeb-pkg drops its artifacts alongside /work/linux/ (i.e. in /work),
# and the final step here copies /work/linux-*.deb to /out. Without
# clearing leftovers, a previous variant's .debs would be re-exported and
# trip the post-build version assertion (or worse, sneak past it).
rm -f /work/linux-*.deb /work/linux-*.buildinfo /work/linux-*.changes
if [ ! -d linux/.git ]; then
  echo "==> [container] Cloning $KERNEL_REMOTE (partial clone)"
  git clone --filter=blob:none "$KERNEL_REMOTE" linux
fi
cd linux

echo "==> [container] Fetching $KERNEL_BRANCH"
git fetch --quiet origin "$KERNEL_BRANCH"

if [ -z "${KERNEL_REF:-}" ]; then
  KERNEL_REF=$(git rev-parse "origin/$KERNEL_BRANCH")
  echo "==> [container] Resolved $KERNEL_BRANCH → $KERNEL_REF"
  echo "$KERNEL_REF" > /out/.resolved-ref
fi

echo "==> [container] Checking out $KERNEL_REF"
git checkout --quiet --detach "$KERNEL_REF"
git clean -qfdx

if [ -z "${KBUILD_BUILD_TIMESTAMP:-}" ]; then
  export KBUILD_BUILD_TIMESTAMP=$(git show -s --format=%cI "$KERNEL_REF")
fi
echo "==> [container] KBUILD_BUILD_USER=$KBUILD_BUILD_USER HOST=$KBUILD_BUILD_HOST TS=$KBUILD_BUILD_TIMESTAMP"

cp /variant/config .config
if [ -n "${SCMVERSION_SUFFIX:-}" ]; then
  printf "%s" "$SCMVERSION_SUFFIX" > .scmversion
fi

make ARCH=arm64 olddefconfig
make ARCH=arm64 -j"$(nproc)" bindeb-pkg KDEB_PKGVERSION="$KDEB_PKGVERSION"

cp /work/linux-*.deb /out/
ls -lh /out/
BUILD

echo "==> Extracting .debs from container"
podman cp "$cid:/out/." "$out_dir/"

# Write back resolved SHA if KERNEL_REF was empty and the container recorded one.
marker="$out_dir/.resolved-ref"
if [ -z "$KERNEL_REF" ] && [ -s "$marker" ]; then
  resolved=$(cat "$marker")
  rm "$marker"
  conf="$variant_dir/build.conf"
  if grep -qE '^KERNEL_REF=' "$conf"; then
    sed -i.bak -E "s|^KERNEL_REF=.*$|KERNEL_REF=$resolved|" "$conf"
    rm "$conf.bak"
  else
    printf '\nKERNEL_REF=%s\n' "$resolved" >> "$conf"
  fi
  echo "==> Wrote resolved KERNEL_REF=$resolved back to $conf"
fi

# Verify the built kernel version matches the variant name. If it doesn't,
# the SHA in build.conf no longer points to the version the variant claims
# to be — either the branch tip rolled forward before pinning, or someone
# pinned the wrong SHA. Fail loudly so the operator can rename the variant
# or re-pin KERNEL_REF, rather than silently deploying a different kernel.
built_image=$(ls -1 "$out_dir"/linux-image-*.deb 2>/dev/null | head -1)
[ -n "$built_image" ] || { echo "ERROR: no linux-image .deb produced"; exit 1; }
built_kver=$(basename "$built_image" | sed -E 's/^linux-image-(.+)_[^_]+_[^_]+\.deb$/\1/')
actual_ver=$(echo "$built_kver" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)

if [ "$expected_ver" != "$actual_ver" ]; then
  echo
  echo "ERROR: variant '$variant' expects kernel $expected_ver, but build produced $actual_ver"
  echo "       (full kernel version: $built_kver)"
  echo
  echo "       Fix one of:"
  echo "         a) Rename variants/$variant/ to start with $actual_ver"
  echo "         b) Pin KERNEL_REF in variants/$variant/build.conf to a SHA that builds $expected_ver"
  echo
  echo "       The stale .debs in $out_dir have NOT been deleted, but deploy.sh will refuse"
  echo "       to ship them while the variant name doesn't match. Inspect with:"
  echo "         ls $out_dir/"
  exit 1
fi

echo
echo "==> Build complete — produced kernel $built_kver"
ls -lh "$out_dir"/linux-*.deb
echo
echo "==> Next: ./deploy.sh $variant <user@host>"

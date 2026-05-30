#!/usr/bin/env bash
# Deploy a built variant to a Raspberry Pi over SSH.
#
# Usage:  ./deploy.sh <variant> <user@host>
# Example: ./deploy.sh 6.12.90-nohzfull-rt+ pi@raspberrypi
#
# Installs the kernel + headers .debs; plants the kernel image, initrd,
# Pi 5 DTBs, and overlays into /boot/firmware/ (the only filesystem the Pi
# bootloader can read); points config.txt at the new kernel via a managed
# block; and replaces cmdline.txt with the variant's (substituting the Pi's
# existing PARTUUID). One-time backups of cmdline.txt and config.txt are
# kept as /boot/firmware/{cmdline,config}.txt.pre-rtkernel.

set -euo pipefail

usage() { echo "Usage: $0 <variant> <user@host>"; exit 1; }
[ $# -eq 2 ] || usage

variant="$1"
target="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
variant_dir="$script_dir/variants/$variant"
out_dir="$variant_dir/out"

[ -d "$variant_dir" ] || { echo "no such variant: $variant_dir"; exit 1; }
[ -f "$variant_dir/cmdline.txt" ] || { echo "missing $variant_dir/cmdline.txt"; exit 1; }

# Variant directories are named after the kernel version they ship
# (e.g. 6.12.90-nohzfull-rt+). Extract the X.Y.Z prefix; the .deb we
# pick up must match this, otherwise we're about to deploy something
# the operator didn't ask for.
expected_ver=$(echo "$variant" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
[ -n "$expected_ver" ] || {
  echo "ERROR: variant name '$variant' does not start with a kernel version (X.Y.Z) — refusing to deploy"
  exit 1
}

# Refuse to silently pick when more than one image deb is present — that's
# how the 6.12.70-vs-6.12.90 bricking happened: an old .deb sorted first
# and got shipped.
# Portable to bash 3.2 (macOS): no mapfile. Glob with null-match guard.
image_debs=()
for f in "$out_dir"/linux-image-*.deb; do
  [ -e "$f" ] && image_debs+=("$f")
done
headers_debs=()
for f in "$out_dir"/linux-headers-*.deb; do
  [ -e "$f" ] && headers_debs+=("$f")
done

if [ "${#image_debs[@]}" -eq 0 ]; then
  echo "ERROR: no linux-image .deb in $out_dir — run ./build.sh $variant first"
  exit 1
fi
if [ "${#image_debs[@]}" -gt 1 ]; then
  echo "ERROR: multiple linux-image .debs in $out_dir — refusing to guess:"
  printf '  %s\n' "${image_debs[@]}"
  echo "Delete the stale ones (build.sh now clears out/ on each run) and try again."
  exit 1
fi
if [ "${#headers_debs[@]}" -gt 1 ]; then
  echo "ERROR: multiple linux-headers .debs in $out_dir — refusing to guess:"
  printf '  %s\n' "${headers_debs[@]}"
  exit 1
fi

image_deb="${image_debs[0]}"
headers_deb="${headers_debs[0]:-}"

# Belt-and-suspenders: confirm the deb's kernel version matches the
# variant name before we ship it.
deb_kver=$(basename "$image_deb" | sed -E 's/^linux-image-(.+)_[^_]+_[^_]+\.deb$/\1/')
deb_ver=$(echo "$deb_kver" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)
if [ "$expected_ver" != "$deb_ver" ]; then
  echo "ERROR: variant '$variant' expects kernel $expected_ver, but $image_deb is $deb_ver ($deb_kver)"
  echo "       Re-run ./build.sh $variant — it will catch this and tell you how to fix it."
  exit 1
fi

echo "==> Copying packages to $target"
scp "$image_deb" "$target:/tmp/"
[ -n "$headers_deb" ] && scp "$headers_deb" "$target:/tmp/"
scp "$variant_dir/cmdline.txt" "$target:/tmp/rtkernel-cmdline.txt.tmpl"

image_name=$(basename "$image_deb")
headers_name=""
[ -n "$headers_deb" ] && headers_name=$(basename "$headers_deb")

echo "==> Installing on $target"
ssh "$target" 'bash -s' "$image_name" "$headers_name" <<'REMOTE'
set -euo pipefail

image_name="$1"
headers_name="${2:-}"

sudo dpkg -i "/tmp/$image_name"
if [ -n "$headers_name" ] && [ -f "/tmp/$headers_name" ]; then
  sudo dpkg -i "/tmp/$headers_name" || echo "headers install failed (non-fatal)"
fi

# Derive the actual installed kernel version from the .deb filename — the
# variant directory's name and the built version can differ (e.g. when
# pinning a branch tip whose Makefile has rolled forward).
KVER=$(echo "$image_name" | sed -E 's/^linux-image-(.+)_[^_]+_[^_]+\.deb$/\1/')
echo "==> Installed kernel version: $KVER"

[ -f "/boot/vmlinuz-$KVER" ]        || { echo "ERROR: /boot/vmlinuz-$KVER missing after install"; exit 1; }
[ -d "/usr/lib/linux-image-$KVER" ] || { echo "ERROR: /usr/lib/linux-image-$KVER missing after install"; exit 1; }

FW=/boot/firmware

# The Pi bootloader can't read ext4, so a Debian linux-image .deb (which
# lands in /boot/) is invisible to it until we copy the kernel, initrd,
# DTBs, and overlays onto the FAT firmware partition.
echo "==> Planting kernel and initrd into $FW/"
sudo cp "/boot/vmlinuz-$KVER"    "$FW/vmlinuz-$KVER"
sudo cp "/boot/initrd.img-$KVER" "$FW/initrd.img-$KVER"

dtb_src=$(find "/usr/lib/linux-image-$KVER" -name 'bcm2712-rpi-5-b.dtb' -print -quit)
[ -n "$dtb_src" ] || { echo "ERROR: bcm2712-rpi-5-b.dtb not found in linux-image-$KVER"; exit 1; }
echo "==> Planting bcm2712-*.dtb from $(dirname "$dtb_src")"
sudo cp "$(dirname "$dtb_src")"/bcm2712-*.dtb "$FW/"

ovl_src=$(find "/usr/lib/linux-image-$KVER" -type d -name overlays -print -quit)
if [ -n "$ovl_src" ]; then
  echo "==> Planting overlays from $ovl_src"
  sudo mkdir -p "$FW/overlays"
  sudo cp "$ovl_src"/*.dtbo "$FW/overlays/"
fi

# Point config.txt at the new kernel via a managed block, backed up once
# and rewritten on every deploy.
CONFIG_FILE=$FW/config.txt
[ -f "${CONFIG_FILE}.pre-rtkernel" ] || sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.pre-rtkernel"
sudo sed -i '/^# >>> statusbar-rtkernel >>>$/,/^# <<< statusbar-rtkernel <<<$/d' "$CONFIG_FILE"
sudo tee -a "$CONFIG_FILE" >/dev/null <<EOF
# >>> statusbar-rtkernel >>>
[all]
kernel=vmlinuz-$KVER
initramfs initrd.img-$KVER followkernel
# <<< statusbar-rtkernel <<<
EOF
echo "==> config.txt now boots vmlinuz-$KVER"

CMDLINE_FILE=$FW/cmdline.txt
TMPL=/tmp/rtkernel-cmdline.txt.tmpl

live_partuuid=$(grep -oE 'PARTUUID=[A-Fa-f0-9-]+' "$CMDLINE_FILE" | head -1 | cut -d= -f2)
if [ -z "$live_partuuid" ]; then
  echo "ERROR: could not read PARTUUID from $CMDLINE_FILE — aborting cmdline replace"
  exit 1
fi

# One-time backup, never overwritten.
[ -f "${CMDLINE_FILE}.pre-rtkernel" ] || sudo cp "$CMDLINE_FILE" "${CMDLINE_FILE}.pre-rtkernel"

sed "s/__PARTUUID__/$live_partuuid/g" "$TMPL" | sudo tee "$CMDLINE_FILE" >/dev/null
echo "==> New cmdline:"
cat "$CMDLINE_FILE"
REMOTE

echo
echo "==> Deployed. Reboot:  ssh $target sudo reboot"
echo "==> Then verify:       ssh $target 'bash -s' < $script_dir/verify.sh"

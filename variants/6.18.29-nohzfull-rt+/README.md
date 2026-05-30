# 6.18.29-nohzfull-rt+

Branch-tip variant against `rpi-6.18.y`, targeting the kernel line the
Raspberry Pi distro currently ships as `6.18.29+rpt-rpi-v8`. `KERNEL_REF`
in `build.conf` starts empty; the first `./build.sh` writes the resolved
SHA back so subsequent rebuilds are reproducible.

CPU topology + isolation are the same as `6.12.70-nohzfull-rt+`
(`isolcpus=2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1`).

## ⚠️ `config` is a 6.12.85 seed, not a 6.18 baseline

This variant was scaffolded by hand from an x86_64 host without running
`new-variant.sh`, so `config` is a verbatim copy of the
`6.12.85-nohzfull-rt+` `.config`. It is **not** a real 6.18 defconfig.

Before relying on a build:

1. Run `./new-variant.sh 6.18.29-nohzfull-rt+-regen rpi-6.18.y` on an
   arm64 host (or this x86 host with `qemu-user-static`), and replace
   this directory's `config` with the regenerated one.
2. Or, on first build, accept that `make olddefconfig` against the 6.18
   tree will leave new symbols at their kernel defaults — review the
   diff in `.config` after the build and decide whether to commit it back.

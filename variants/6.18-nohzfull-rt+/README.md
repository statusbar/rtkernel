# 6.18-nohzfull-rt+

Series-tracking variant against `rpi-6.18.y`: accepts any 6.18.x point
release the branch tip currently produces. `build.sh`'s post-build
assertion checks at X.Y precision only (a `6.19.x` build would still be
flagged so you can decide whether to follow the series bump).

`KERNEL_REF` in `build.conf` records the SHA of the last build for
reproducibility. To roll forward to a newer 6.18.x, blank `KERNEL_REF`
and rerun `./build.sh`; the script resolves the current branch tip and
writes the new SHA back.

CPU topology + isolation are the same as `6.12.70-nohzfull-rt+`
(`isolcpus=2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1`).

## ⚠️ `config` is a 6.12.85 seed, not a 6.18 baseline

This variant was scaffolded by hand from an x86_64 host without running
`new-variant.sh`, so `config` is a verbatim copy of the
`6.12.85-nohzfull-rt+` `.config`. It is **not** a real 6.18 defconfig.

Before relying on a build:

1. Run `./new-variant.sh 6.18-nohzfull-rt+-regen rpi-6.18.y` on an
   arm64 host (or this x86 host — the cross path handles it), and
   replace this directory's `config` with the regenerated one.
2. Or, on first build, accept that `make olddefconfig` against the 6.18
   tree will leave new symbols at their kernel defaults — review the
   diff in `.config` after the build and decide whether to commit it back.

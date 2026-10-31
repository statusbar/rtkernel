# 6.12.90-nohzfull-rt+

Pinned variant on `rpi-6.12.y`. `KERNEL_REF` in `build.conf` points at the
SHA that produces Linux 6.12.90; `build.sh` and `deploy.sh` both refuse to
proceed unless the produced kernel version matches the variant name.

The 6.12.90 merge commit is the first SHA in this 6.12.y window that ships
the full Raspberry Pi DTB set (Pi 5, Pi 500, CM5, CM5L, PCIe, IOMMU). The
"Linux 6.12.85" merge point on the same branch is upstream-only and ships
a stub `bcm2712-rpi-5-b.dts`, so it does not boot the Pi 5 cleanly.

CPU topology + isolation are the same as `6.12.70-nohzfull-rt+`.

## 1.0-2: AF_XDP and the TSN qdiscs

`CONFIG_XDP_SOCKETS=y` (with `CONFIG_XDP_SOCKETS_DIAG=m`): 1.0-1 had it off,
so every `socket(AF_XDP)` failed with EAFNOSUPPORT and statusbar's XDP
transport, and its root integration tests, could not run on the node.
`CONFIG_NET_SCH_CBS`, `_ETF` and `_TAPRIO` as modules alongside the
`mqprio` that was already there: the credit-based shaper is what
statusbar's tc client installs for an AVB talker, and ETF/TAPRIO are the
other two 802.1Q TSN qdiscs, cheap to have on hand.

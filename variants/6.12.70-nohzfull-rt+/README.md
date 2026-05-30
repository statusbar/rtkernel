# 6.12.70-nohzfull-rt+

Pinned to commit `88969c95` of `rpi-6.12.y` (the "Linux 6.12.70" merge,
2026-02-11). This is the kernel running on jdk01A.

CPU topology assumption (RPi5: four Cortex-A76 @ 2.4 GHz, homogeneous):

- `cpu0-1` housekeeping: desktop, IRQs, kernel threads
- `cpu2-3` isolated for RT workload (`isolcpus=2-3 nohz_full=2-3 rcu_nocbs=2-3 irqaffinity=0-1`)

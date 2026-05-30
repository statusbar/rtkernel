#!/usr/bin/env bash
# Run ON the Raspberry Pi after booting into the new kernel to confirm
# PREEMPT_RT, isolation, and tracers are active.
#
# Usage on the Pi:  bash verify.sh
# Or remotely:      ssh pi@host 'bash -s' < verify.sh

set -uo pipefail

pass=0
fail=0
check() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q -- "$expected"; then
    echo "  [PASS] $desc"
    pass=$((pass + 1))
  else
    echo "  [FAIL] $desc"
    echo "         expected: $expected"
    echo "         got:      $actual"
    fail=$((fail + 1))
  fi
}

echo "================================="
echo " RT Kernel Verification — $(date)"
echo "================================="

echo
echo "── Kernel"
kver=$(uname -r)
echo "   uname -r: $kver"

# Pull CONFIG_LOCALVERSION from the running kernel — use it to assert that
# uname -r contains the variant suffix (cheap sanity check that we booted
# into the right build).
running_config=/boot/config-$(uname -r)
config_src=""
if [ -r "$running_config" ]; then
  config_src=$running_config
elif [ -r /proc/config.gz ]; then
  config_src=/proc/config.gz
fi

cfg_get() {
  local key="$1"
  if [ -z "$config_src" ]; then echo ""; return; fi
  if [[ "$config_src" == *.gz ]]; then
    zcat "$config_src" | grep "^$key=" || true
  else
    grep "^$key=" "$config_src" || true
  fi
}

local_ver=$(cfg_get CONFIG_LOCALVERSION | sed -E 's/^CONFIG_LOCALVERSION=//; s/^"//; s/"$//')
if [ -n "$local_ver" ]; then
  echo "   CONFIG_LOCALVERSION: $local_ver"
  check "uname -r ends with $local_ver" "$local_ver" "$kver"
fi

echo
echo "── PREEMPT_RT"
preempt_rt=$(cfg_get CONFIG_PREEMPT_RT)
check "CONFIG_PREEMPT_RT=y" "CONFIG_PREEMPT_RT=y" "$preempt_rt"

echo
echo "── Cmdline"
cmdline=$(cat /proc/cmdline)
echo "   $cmdline"
for token in isolcpus= nohz_full= rcu_nocbs= irqaffinity=; do
  check "$token present" "$token" "$cmdline"
done

echo
echo "── CPU isolation"
isolated=$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "")
nohz_full=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null || echo "")
echo "   isolated:  $isolated"
echo "   nohz_full: $nohz_full"
[ -n "$isolated" ]  && check "isolated cpus non-empty"  "[0-9]" "$isolated"
[ -n "$nohz_full" ] && check "nohz_full cpus non-empty" "[0-9]" "$nohz_full"

echo
echo "── Tracers"
tracers=$(cat /sys/kernel/debug/tracing/available_tracers 2>/dev/null \
       || sudo cat /sys/kernel/debug/tracing/available_tracers 2>/dev/null \
       || echo "not accessible")
echo "   $tracers"
for t in function function_graph irqsoff preemptoff timerlat osnoise; do
  check "tracer: $t" "$t" "$tracers"
done

echo
echo "── Timer"
hz=$(cfg_get CONFIG_HZ)
echo "   $hz"
check "HZ=1000" "1000" "$hz"

echo
echo "── Threads on isolated cores (should be only kthread placeholders)"
if [ -n "$isolated" ]; then
  isolated_list=$(echo "$isolated" | tr ',' '\n' | awk -F- '{ if (NF==2) for (i=$1;i<=$2;i++) print i; else print $1 }' | tr '\n' '|' | sed 's/|$//')
  ps -eo psr,pid,comm | awk -v re="^($isolated_list)\$" '$1 ~ re' | head -20
fi

echo
echo "── Hardware"
if [ -f /proc/device-tree/model ]; then
  model=$(tr -d '\0' </proc/device-tree/model)
  echo "   Model: $model"
fi

echo
echo "── RT tools (optional, apt install rt-tests trace-cmd)"
for tool in rtla trace-cmd cyclictest; do
  if command -v "$tool" >/dev/null 2>&1; then
    echo "  [ OK ] $tool: $(command -v "$tool")"
  else
    echo "  [WARN] $tool not installed"
  fi
done

echo
echo "================================="
echo " Results: $pass passed, $fail failed"
echo "================================="
[ "$fail" -eq 0 ]

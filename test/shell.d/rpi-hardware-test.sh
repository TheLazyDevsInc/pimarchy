#!/bin/bash

# The Raspberry Pi's hardware and user setup leaves, run against the real
# platform detector on fixture machines. Each must leave x86 and other ARM
# machines alone.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The leaves follow the real predicates on fixture machines, and root reads only
# the live hardware.
require_platform_fixtures "the Raspberry Pi hardware leaves"

hardware_all="$ROOT/install/hardware/all.sh"
user_all="$ROOT/install/user/all.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

# Fixture machines: a Pi 400, a Pi 4, a plain ARM VM and an x86 PC.
fake_platform "$scratch/hw/pi400" aarch64-rpi
fake_platform "$scratch/hw/pi4" aarch64-rpi
printf '%s\0' raspberrypi,4-model-b brcm,bcm2711 >"$scratch/hw/pi4/proc/device-tree/compatible"
fake_platform "$scratch/hw/arm" aarch64
fake_platform "$scratch/hw/x86" x86

export CALL_LOG="$scratch/calls.log"
run() {
  local machine=$1
  shift
  : >"$CALL_LOG"
  PATH="$scratch/hw/$machine/bin:$scratch/bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_PROC_ROOT="$scratch/hw/$machine/proc" "$@"
}

# A sourced leaf has valid syntax, never exits, and runs from its all.sh.
check_leaf() {
  local leaf=$1 all=$2

  bash -n "$ROOT/install/$leaf" || fail "$leaf has valid syntax"
  ! grep -Eq '^[[:space:]]*(exit|return)\b' "$ROOT/install/$leaf" || fail "$leaf is a sourced leaf and never exits"
  grep -qx "run_logged \"\$OMARCHY_INSTALL/$leaf\"" "$all" || fail "$(basename "$(dirname "$all")") setup runs $leaf"
}

# Sleep: every Pi, nothing else.
sleep_setup="$ROOT/install/hardware/rpi/sleep.sh"
check_leaf hardware/rpi/sleep.sh "$hardware_all"
[[ $(grep -n 'hardware/rpi/sleep.sh' "$hardware_all" | cut -d: -f1) == $(( $(grep -n 'hardware/gb10/sleep.sh' "$hardware_all" | cut -d: -f1) + 1 )) ]] ||
  fail "the Pi sleep setting runs beside the GB10 one"
run_sleep() {
  local machine=$1
  shift
  OMARCHY_SLEEP_CONFIG_DIR="$scratch/sleep/$machine" run "$machine" "$@"
}
for machine in pi400 pi4; do
  run_sleep "$machine" bash "$sleep_setup"
  config="$scratch/sleep/$machine/omarchy-sleep-disabled.conf"
  [[ $(head -n 1 "$config") == "[Sleep]" ]] || fail "the $machine's sleep settings are in the [Sleep] section"
  for setting in AllowSuspend AllowHibernation AllowSuspendThenHibernate AllowHybridSleep; do
    grep -Fxq "$setting=no" "$config" || fail "a $machine disallows $setting"
  done
  run_sleep "$machine" omarchy-sleep-disabled || fail "sleep reads as disabled on a $machine"
done
before=$(sha256sum "$scratch/sleep/pi400/omarchy-sleep-disabled.conf")
run_sleep pi400 bash "$sleep_setup"
[[ $(sha256sum "$scratch/sleep/pi400/omarchy-sleep-disabled.conf") == "$before" ]] ||
  fail "rerunning the sleep setting leaves it unchanged"
for machine in arm x86; do
  run_sleep "$machine" bash "$sleep_setup"
  [[ ! -e $scratch/sleep/$machine ]] || fail "the $machine machine keeps system sleep"
done
pass "every Pi disallows each sleep operation, and other machines keep sleep"

cat >"$scratch/bin/omarchy-toggle-enabled" <<'SH'
#!/bin/bash
exit 1
SH
cat >"$scratch/bin/omarchy-hibernation-available" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$scratch/bin"/*
guard() {
  grep -F "\"$1\"" "$ROOT/default/omarchy/omarchy-menu.jsonc" | sed -E 's/.*"when":"([^"]*)".*/\1/'
}
for item in system.suspend system.hibernate; do
  run_sleep pi400 bash -c "$(guard "$item")" && fail "the $item row is hidden on a Pi"
  run_sleep x86 bash -c "$(guard "$item")" || fail "the $item row stays on an x86 PC"
done
pass "the menu hides Suspend and Hibernate on a Pi"

# Vulkan: the Pi's GPU never shows in lspci, so its family installs the driver.
vulkan_setup="$ROOT/install/hardware/vulkan.sh"
cat >"$scratch/bin/omarchy-pkg-add" <<'SH'
#!/bin/bash
printf 'omarchy-pkg-add %s\n' "$*" >>"$CALL_LOG"
SH
cat >"$scratch/bin/lspci" <<'SH'
#!/bin/bash
[[ -z ${TEST_LSPCI:-} ]] || printf '%s\n' "$TEST_LSPCI"
SH
chmod +x "$scratch/bin"/*
for machine in pi400 pi4; do
  run "$machine" bash "$vulkan_setup"
  [[ $(<"$CALL_LOG") == "omarchy-pkg-add vulkan-broadcom" ]] || fail "a $machine gets the Broadcom Vulkan driver" "$(<"$CALL_LOG")"
done
run arm bash "$vulkan_setup"
[[ ! -s $CALL_LOG ]] || fail "a plain ARM machine installs no Vulkan driver" "$(<"$CALL_LOG")"
TEST_LSPCI='00:02.0 VGA compatible controller: Intel Corporation Device 7d55' run x86 bash "$vulkan_setup"
[[ $(<"$CALL_LOG") == "omarchy-pkg-add vulkan-intel" ]] || fail "an x86 PC still gets its lspci-matched driver alone" "$(<"$CALL_LOG")"
grep -Fxq vulkan-broadcom <(sed -e 's/[[:space:]]*#.*$//' "$ROOT/install/omarchy-aarch64-rpi.packages") ||
  fail "the Pi package list carries vulkan-broadcom, so an image's first boot installs nothing"
pass "a Pi installs vulkan-broadcom, and other machines keep their drivers"

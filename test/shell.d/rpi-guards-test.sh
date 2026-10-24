#!/bin/bash

# Commands that assume a Limine and UEFI machine, or a CPU a Raspberry Pi does
# not have, step aside on a Pi and keep their behaviour everywhere else.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The guards follow the real predicates on fixture machines, and root reads only
# the live hardware.
require_platform_fixtures "the Raspberry Pi command guards"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
stub_bin="$scratch/bin"
mkdir -p "$stub_bin"

fake_platform "$scratch/hw/pi400" aarch64-rpi
fake_platform "$scratch/hw/arm" aarch64
fake_platform "$scratch/hw/mac" aarch64-apple
fake_platform "$scratch/hw/x86" x86

# Stubs record their calls. sudo runs only the stubs, so nothing here can reach
# this machine's boot files or firmware.
record_stub() {
  cat >"$stub_bin/$1" <<'SH'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$CALL_LOG"
SH
  chmod +x "$stub_bin/$1"
}
cat >"$stub_bin/sudo" <<SH
#!/bin/bash
printf 'sudo %s\n' "\$*" >>"\$CALL_LOG"
if [[ -x $stub_bin/\$1 ]]; then
  exec "\$@"
fi
SH
# Only the stubs count as installed, so this machine's own tools never decide
# which path a command takes. A test moves a stub away to uninstall it.
cat >"$stub_bin/omarchy-cmd-missing" <<SH
#!/bin/bash
for command in "\$@"; do
  [[ -x $stub_bin/\$command ]] || exit 0
done
exit 1
SH
chmod +x "$stub_bin"/*

export CALL_LOG="$scratch/calls.log"
run() {
  local machine=$1
  shift
  : >"$CALL_LOG"
  PATH="$scratch/hw/$machine/bin:$stub_bin:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" \
    OMARCHY_PROC_ROOT="$scratch/hw/$machine/proc" "$@"
}

# omarchy-refresh-limine: nothing to refresh without Limine, unchanged with it.
record_stub limine-update
record_stub limine-snapper-sync
mv "$stub_bin/limine-update" "$scratch/limine-update.off"
output=$(run pi400 "$ROOT/bin/omarchy-refresh-limine" </dev/null) || fail "refresh-limine succeeds without Limine"
[[ $output == *"does not boot with Limine"* ]] || fail "refresh-limine says why it did nothing" "$output"
[[ ! -s $CALL_LOG ]] || fail "refresh-limine touches no boot file without Limine" "$(<"$CALL_LOG")"
mv "$scratch/limine-update.off" "$stub_bin/limine-update"
run x86 "$ROOT/bin/omarchy-refresh-limine" </dev/null >/dev/null 2>&1 || true
for call in "sudo mv /boot/limine.conf /boot/limine.conf.bak" "sudo cp $ROOT/default/limine/limine.conf /boot/limine.conf" \
  "limine-update " "limine-snapper-sync "; do
  grep -Fxq "$call" "$CALL_LOG" || fail "refresh-limine still resets and rebuilds Limine where it is installed: $call" "$(<"$CALL_LOG")"
done
pass "refresh-limine steps aside without Limine and resets Limine where it is installed"

# Direct Boot: a Pi has no UEFI to boot a UKI directly. The DGX Spark's marker
# is pointed at a scratch path, so this machine's own file decides nothing.
direct_boot=$(grep -F '"setup.direct-boot"' "$ROOT/default/omarchy/omarchy-menu.jsonc" |
  sed -E 's/.*"when":"([^"]*)".*/\1/' | sed "s|/etc/limine-entry-tool.d/|$scratch/limine-entry-tool.d/|")
[[ $direct_boot == *"omarchy-hw-aarch64-rpi"* ]] || fail "the Direct Boot entry asks the Pi predicate" "$direct_boot"
for machine in pi400 mac; do
  run "$machine" bash -c "$direct_boot" && fail "Direct Boot is hidden on the $machine"
done
for machine in x86 arm; do
  run "$machine" bash -c "$direct_boot" || fail "Direct Boot stays on the $machine machine"
done
pass "the menu hides Direct Boot on a Pi and keeps it on x86 and other ARM machines"

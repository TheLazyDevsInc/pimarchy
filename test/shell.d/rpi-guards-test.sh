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

# omarchy-update-firmware: the bootloader EEPROM on a Pi, fwupd elsewhere.
# rpi-eeprom-update reports, exiting 1 when an update is available, and stages
# the update with -a. It records its stdin, since with a terminal there it
# would ask before installing.
record_stub fwupdmgr
record_stub omarchy-pkg-add
record_stub omarchy-state
cat >"$stub_bin/rpi-eeprom-update" <<'SH'
#!/bin/bash
stdin=$(readlink /proc/$$/fd/0)
printf 'rpi-eeprom-update %s stdin=%s\n' "$*" "$stdin" >>"$CALL_LOG"
if [[ $* == "-a" ]]; then
  echo "*** PREPARING EEPROM UPDATES ***"
  exit 0
fi
echo "BOOTLOADER: status"
exit "${TEST_EEPROM_STATUS:-0}"
SH
chmod +x "$stub_bin/rpi-eeprom-update"

output=$(TEST_EEPROM_STATUS=0 run pi400 "$ROOT/bin/omarchy-update-firmware") || fail "an up-to-date Pi bootloader is a success"
[[ $(grep -c '^rpi-eeprom-update' "$CALL_LOG") == 1 ]] || fail "an up-to-date Pi only checks its bootloader" "$(<"$CALL_LOG")"
grep -Fxq 'rpi-eeprom-update  stdin=/dev/null' "$CALL_LOG" || fail "the check runs with no terminal, so it never asks" "$(<"$CALL_LOG")"
[[ $output == *"BOOTLOADER: status"* ]] || fail "the Pi shows its bootloader status" "$output"
! grep -Eq '^(fwupdmgr|omarchy-pkg-add|omarchy-state) ' "$CALL_LOG" || fail "a Pi never reaches fwupd or asks for a reboot" "$(<"$CALL_LOG")"

output=$(TEST_EEPROM_STATUS=1 run pi400 "$ROOT/bin/omarchy-update-firmware") || fail "a Pi with a bootloader update applies it"
grep -Fxq 'sudo rpi-eeprom-update -a' "$CALL_LOG" || fail "an available update is staged with -a" "$(<"$CALL_LOG")"
grep -Fxq 'omarchy-state set reboot-required' "$CALL_LOG" || fail "a staged update asks for a reboot"
[[ $output == *"Restart the computer to apply it."* ]] || fail "the Pi is told a reboot applies the update" "$output"
! grep -q '^fwupdmgr ' "$CALL_LOG" || fail "a Pi never reaches fwupd"

if TEST_EEPROM_STATUS=2 run pi400 "$ROOT/bin/omarchy-update-firmware" >/dev/null; then
  fail "a failed bootloader check fails the update"
fi
! grep -Fq 'rpi-eeprom-update -a' "$CALL_LOG" || fail "a failed check stages nothing"
pass "a Pi updates its bootloader EEPROM with rpi-eeprom-update"

for machine in x86 arm; do
  run "$machine" "$ROOT/bin/omarchy-update-firmware" >/dev/null || fail "the $machine machine updates firmware through fwupd"
  grep -Fxq 'fwupdmgr refresh --force' "$CALL_LOG" || fail "the $machine machine refreshes fwupd metadata" "$(<"$CALL_LOG")"
  grep -Fxq 'sudo fwupdmgr update' "$CALL_LOG" || fail "the $machine machine applies fwupd updates" "$(<"$CALL_LOG")"
  ! grep -q '^rpi-eeprom-update' "$CALL_LOG" || fail "the $machine machine never runs the Pi updater"
done
mv "$stub_bin/fwupdmgr" "$scratch/fwupdmgr.off"
run x86 "$ROOT/bin/omarchy-update-firmware" >/dev/null 2>&1 || true
grep -Fxq 'omarchy-pkg-add fwupd' "$CALL_LOG" || fail "fwupd is still installed when it is missing" "$(<"$CALL_LOG")"
mv "$scratch/fwupdmgr.off" "$stub_bin/fwupdmgr"
pass "other machines update firmware through fwupd as before"

# omarchy-install-docker-dbs: SQL Server on x86 only, MongoDB everywhere but the
# Pi. gum records the choices it was offered and picks none.
export OFFERED="$scratch/offered"
cat >"$stub_bin/gum" <<'SH'
#!/bin/bash
cat >"$OFFERED"
SH
cat >"$stub_bin/docker" <<'SH'
#!/bin/bash
printf 'docker %s\n' "${*: -1}" >>"$CALL_LOG"
SH
chmod +x "$stub_bin/gum" "$stub_bin/docker"
offered() {
  run "$1" "$ROOT/bin/omarchy-install-docker-dbs" >/dev/null
  paste -sd ' ' "$OFFERED"
}
[[ $(offered x86) == "MySQL PostgreSQL Redis MongoDB MariaDB MSSQL" ]] || fail "x86 offers every database, in order" "$(offered x86)"
[[ $(offered arm) == "MySQL PostgreSQL Redis MongoDB MariaDB" ]] || fail "ARM offers no SQL Server, which has no ARM image" "$(offered arm)"
[[ $(offered pi400) == "MySQL PostgreSQL Redis MariaDB" ]] || fail "a Pi offers neither SQL Server nor MongoDB" "$(offered pi400)"

output=$(run pi400 "$ROOT/bin/omarchy-install-docker-dbs" MongoDB MSSQL Redis)
[[ $(<"$CALL_LOG") == $'sudo docker run -d --restart unless-stopped -p 127.0.0.1:6379:6379 --name=redis redis:7\ndocker redis:7' ]] ||
  fail "a Pi asked for MongoDB and SQL Server by name starts only the databases it can run" "$(<"$CALL_LOG")"
[[ $output == *"Skipping MongoDB"* && $output == *"Skipping MSSQL"* ]] || fail "a Pi says why it skipped them" "$output"
run x86 "$ROOT/bin/omarchy-install-docker-dbs" MongoDB MSSQL >/dev/null
grep -Fxq 'docker mongo:noble' "$CALL_LOG" && grep -Fxq 'docker mcr.microsoft.com/mssql/server:2022-CU12-ubuntu-22.04' "$CALL_LOG" ||
  fail "x86 still starts MongoDB and SQL Server" "$(<"$CALL_LOG")"
pass "Docker databases are offered only where their images run"

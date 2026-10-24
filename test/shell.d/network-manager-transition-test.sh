#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

dns="$ROOT/bin/omarchy-dns"
hardware_network="$ROOT/install/hardware/network.sh"

! grep -F 'systemd-networkd' "$dns" >/dev/null || fail "omarchy-dns no longer restarts systemd-networkd"
grep -F 'NetworkManager/conf.d/20-omarchy-dns.conf' "$dns" >/dev/null
grep -F '[global-dns-domain-*]' "$dns" >/dev/null
grep -F 'ipv4.ignore-auto-dns yes' "$dns" >/dev/null
grep -F 'ipv4.ignore-auto-dns no' "$dns" >/dev/null
grep -F 'nmcli device reapply' "$dns" >/dev/null
grep -F 'nmcli general reload conf' "$dns" >/dev/null
grep -F 'nmcli general reload dns-full' "$dns" >/dev/null
if grep -F 'nmcli general reload conf,dns-full' "$dns" >/dev/null; then
  fail "omarchy-dns must not push DNS before reapplying active profiles"
fi
pass "omarchy-dns configures DNS through NetworkManager"

grep -F 'systemd-networkd.service' "$hardware_network" >/dev/null
grep -F 'systemd-networkd.socket' "$hardware_network" >/dev/null
grep -F '20-wlan.network' "$hardware_network" >/dev/null
grep -F 'omarchy-networkd-retired' "$hardware_network" >/dev/null
pass "hardware setup retires archinstall networkd state"

# Run the leaf against a fixture networkd directory, with systemctl recorded.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/network"
cat >"$scratch/bin/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$CALL_LOG"
[[ $1 != "is-active" ]]
SH
chmod +x "$scratch/bin/systemctl"
export CALL_LOG="$scratch/calls.log"
run_network_setup() {
  PATH="$scratch/bin:$PATH" OMARCHY_NETWORKD_DIR="$scratch/network" bash -eE -c 'source "$1"' bash "$hardware_network"
}
retired() {
  compgen -G "$scratch/network/omarchy-networkd-retired-*/$1" >/dev/null
}

# Arch Linux ARM's root filesystem ships these two, CRLF line endings and all.
printf '[Match]\r\nName=en*\r\n\r\n[Network]\r\nDHCP=yes\r\nDNSSEC=no\n' >"$scratch/network/en.network"
printf '[Match]\r\nName=eth*\r\n\r\n[Network]\r\nDHCP=yes\r\nDNSSEC=no\n' >"$scratch/network/eth.network"
printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' >"$scratch/network/20-ethernet.network"
printf '[Match]\nName=wl*\n\n[Network]\nAddress=10.0.0.2/24\n' >"$scratch/network/25-mine.network"
run_network_setup
for file in en.network eth.network 20-ethernet.network; do
  [[ ! -e $scratch/network/$file ]] || fail "hardware setup retires the stock $file"
  retired "$file" || fail "the retired $file is kept in a backup directory"
done
[[ -f $scratch/network/25-mine.network ]] || fail "hardware setup keeps an administrator's own .network file"
grep -Fxq 'systemctl disable systemd-networkd.service' "$CALL_LOG" || fail "hardware setup disables systemd-networkd"
pass "hardware setup retires Arch Linux ARM's stock networkd files"

# Files under the same names that someone changed stay where they are, and a
# stock file with plain LF line endings still counts as stock.
rm -rf "$scratch/network"/*
printf '[Match]\r\nName=en*\r\n\r\n[Network]\r\nDHCP=yes\r\nDNSSEC=no\r\nAddress=192.168.1.5/24\n' >"$scratch/network/en.network"
printf '[Match]\nName=eth0\n\n[Network]\nDHCP=yes\nDNSSEC=no\n' >"$scratch/network/eth.network"
run_network_setup
[[ -f $scratch/network/en.network && -f $scratch/network/eth.network ]] ||
  fail "hardware setup keeps en.network and eth.network that differ from Arch Linux ARM's"
! compgen -G "$scratch/network/omarchy-networkd-retired-*" >/dev/null || fail "nothing is retired when no stock file is left"
printf '[Match]\nName=eth*\n\n[Network]\nDHCP=yes\nDNSSEC=no\n' >"$scratch/network/eth.network"
run_network_setup
retired eth.network || fail "a stock file with LF line endings is retired too"
[[ -f $scratch/network/en.network ]] || fail "the changed en.network still stays"
pass "hardware setup keeps changed en.network and eth.network files"

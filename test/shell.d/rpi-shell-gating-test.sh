#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Pi 400 has no battery and no power-profiles-daemon support (no
# /sys/class/power_supply, no platform_profile, no intel_pstate/amd_pstate).
# These assertions pin the gating that stops the battery service's two
# background timers from polling that hardware forever.

run_node_test <<'JS'
const battery = requireFromRoot('shell/plugins/services/battery/BatteryModel.js')

assertEqual(battery.batteryPercentage(null), -1, 'battery percentage reports -1 with no UPower device (e.g. a Pi with no battery)')

assertDeepEqual(
  battery.shouldWarnLowBattery(null, false, 1, 10, false),
  { level: -1, notify: false, notifiedLowBattery: false },
  'low-battery check never notifies with no UPower device'
)
JS

service_qml="$ROOT/shell/plugins/services/battery/Service.qml"

if grep -q 'running: true' "$service_qml"; then
  fail "battery service timers no longer hardcode running: true"
fi
pass "battery service timers no longer hardcode running: true"

rg -F 'running: root.batteryPresent' "$service_qml" >/dev/null ||
  fail "battery check timer gates on battery presence"
pass "battery check timer gates on battery presence"

rg -F 'running: root.powerProfilesAvailable' "$service_qml" >/dev/null ||
  fail "power profile poll gates on power-profiles-daemon availability"
pass "power profile poll gates on power-profiles-daemon availability"

# Regression guard: nobody "simplifies" the daemon read back to
# `powerprofilesctl get`, which is the PyGObject script that caused the daily
# SIGSEGV crashes this file's comment explains.
rg -F 'command: ["busctl", "--json=short", "get-property", "net.hadess.PowerProfiles"' "$service_qml" >/dev/null ||
  fail "power profile read still goes through busctl, not powerprofilesctl get"
pass "power profile read still goes through busctl, not powerprofilesctl get"

rg -F 'python/cpython#124619' "$service_qml" >/dev/null ||
  fail "busctl rationale comment (CPython shutdown race) is preserved"
pass "busctl rationale comment (CPython shutdown race) is preserved"

rg -F 'SIGSEGV' "$service_qml" >/dev/null ||
  fail "busctl rationale comment still explains the SIGSEGV crashes it avoids"
pass "busctl rationale comment still explains the SIGSEGV crashes it avoids"

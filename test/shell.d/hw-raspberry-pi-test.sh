#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

# --- omarchy-hw-raspberry-pi / omarchy-hw-raspberry-pi-400 ---

# /proc/device-tree/model is NUL-terminated; write fixtures the same way so
# the tr -d '\0' handling is actually exercised.
write_model() {
  printf '%s\0' "$1" >"$tmp_dir/model"
}

remove_model() {
  rm -f "$tmp_dir/model"
}

hw_raspberry_pi() {
  OMARCHY_DT_MODEL_PATH="$tmp_dir/model" "$ROOT/bin/omarchy-hw-raspberry-pi"
}

hw_raspberry_pi_400() {
  OMARCHY_DT_MODEL_PATH="$tmp_dir/model" "$ROOT/bin/omarchy-hw-raspberry-pi-400"
}

assert_model() {
  local description="$1" generic_expected="$2" pi400_expected="$3"

  local generic_actual=no
  hw_raspberry_pi && generic_actual=yes
  [[ $generic_actual == "$generic_expected" ]] ||
    fail "$description" "omarchy-hw-raspberry-pi: expected $generic_expected, got $generic_actual"

  local pi400_actual=no
  hw_raspberry_pi_400 && pi400_actual=yes
  [[ $pi400_actual == "$pi400_expected" ]] ||
    fail "$description" "omarchy-hw-raspberry-pi-400: expected $pi400_expected, got $pi400_actual"

  pass "$description"
}

write_model "Raspberry Pi 400"
assert_model "a Raspberry Pi 400 model string matches both detectors" yes yes

write_model "Raspberry Pi 4 Model B Rev 1.4"
assert_model "a Raspberry Pi 4 Model B matches the generic detector but not the 400 detector" yes no

write_model "Raspberry Pi 5 Model B"
assert_model "a Raspberry Pi 5 matches the generic detector but not the 400 detector" yes no

remove_model
assert_model "a missing device-tree model file (the x86 case) matches neither detector" no no

remove_model
generic_stderr=$(OMARCHY_DT_MODEL_PATH="$tmp_dir/model" "$ROOT/bin/omarchy-hw-raspberry-pi" 2>&1 >/dev/null || true)
[[ -z $generic_stderr ]] || fail "a missing model file produces no stderr noise (generic)" "$generic_stderr"
pi400_stderr=$(OMARCHY_DT_MODEL_PATH="$tmp_dir/model" "$ROOT/bin/omarchy-hw-raspberry-pi-400" 2>&1 >/dev/null || true)
[[ -z $pi400_stderr ]] || fail "a missing model file produces no stderr noise (400)" "$pi400_stderr"
pass "a missing model file produces no stderr noise"

# --- omarchy-hw-broadcom-vc4 ---

setup_drm_dir() {
  rm -rf "$tmp_dir/drm"
  mkdir -p "$tmp_dir/drm"
}

# Args: card name, then any number of NUL-separated compatible strings.
write_card_compatible() {
  local card="$1"
  shift

  mkdir -p "$tmp_dir/drm/$card/device/of_node"
  local compatible_file="$tmp_dir/drm/$card/device/of_node/compatible"
  : >"$compatible_file"

  local value
  for value in "$@"; do
    printf '%s\0' "$value" >>"$compatible_file"
  done
}

hw_broadcom_vc4() {
  OMARCHY_DRM_PATH="$tmp_dir/drm" "$ROOT/bin/omarchy-hw-broadcom-vc4"
}

setup_drm_dir
write_card_compatible card0 "brcm,bcm2711-vc5" "brcm,bcm2711"
hw_broadcom_vc4 || fail "a vc5 compatible string is detected as Broadcom VideoCore"
pass "a vc5 compatible string is detected as Broadcom VideoCore"

setup_drm_dir
write_card_compatible card1 "brcm,2711-v3d"
hw_broadcom_vc4 || fail "a v3d compatible string is detected as Broadcom VideoCore"
pass "a v3d compatible string is detected as Broadcom VideoCore"

setup_drm_dir
write_card_compatible card0 "brcm,bcm2835-vc4"
hw_broadcom_vc4 || fail "an older vc4 compatible string is detected as Broadcom VideoCore"
pass "an older vc4 compatible string is detected as Broadcom VideoCore"

setup_drm_dir
mkdir -p "$tmp_dir/drm/card0/device"
if hw_broadcom_vc4; then
  fail "a card with no device-tree node is not Broadcom VideoCore"
fi
pass "a card with no device-tree node is not Broadcom VideoCore"

setup_drm_dir
if hw_broadcom_vc4; then
  fail "an empty DRM directory is not Broadcom VideoCore"
fi
pass "an empty DRM directory is not Broadcom VideoCore"

# --- omarchy-hw-drm-primary ---

setup_drm_dir_and_by_path() {
  rm -rf "$tmp_dir/drm" "$tmp_dir/by-path"
  mkdir -p "$tmp_dir/drm" "$tmp_dir/by-path"
}

# Args: card name, then any number of connector suffixes.
add_card() {
  local card="$1"
  shift

  mkdir -p "$tmp_dir/drm/$card"

  local connector
  for connector in "$@"; do
    mkdir -p "$tmp_dir/drm/$card-$connector"
  done
}

hw_drm_primary() {
  OMARCHY_DRM_PATH="$tmp_dir/drm" OMARCHY_DRI_BY_PATH="$tmp_dir/by-path" "$ROOT/bin/omarchy-hw-drm-primary"
}

setup_drm_dir_and_by_path
add_card card0 HDMI-A-1
output=""
if output=$(hw_drm_primary); then
  fail "a single DRM card prints nothing and fails" "unexpected output: $output"
fi
[[ -z $output ]] || fail "a single DRM card prints nothing and fails" "unexpected output: $output"
pass "a single DRM card prints nothing and fails"

setup_drm_dir_and_by_path
output=""
if output=$(hw_drm_primary); then
  fail "no DRM cards prints nothing and fails" "unexpected output: $output"
fi
[[ -z $output ]] || fail "no DRM cards prints nothing and fails" "unexpected output: $output"
pass "no DRM cards prints nothing and fails"

setup_drm_dir_and_by_path
add_card card0
add_card card1 HDMI-A-1 HDMI-A-2
ln -s ../card1 "$tmp_dir/by-path/platform-fe004000.hdmi-card"
ln -s ../renderD128 "$tmp_dir/by-path/platform-fe004000.hdmi-render"
result=$(hw_drm_primary) || fail "the scanout card is resolved through /dev/dri/by-path"
[[ $result == "$tmp_dir/by-path/platform-fe004000.hdmi-card" ]] ||
  fail "the scanout card is resolved through /dev/dri/by-path" "actual: $result"
pass "the scanout card is resolved through /dev/dri/by-path"

setup_drm_dir_and_by_path
add_card card0
add_card card1 HDMI-A-1
result=$(hw_drm_primary) || fail "the scanout card falls back to /dev/dri/cardN with no by-path match"
[[ $result == "/dev/dri/card1" ]] ||
  fail "the scanout card falls back to /dev/dri/cardN with no by-path match" "actual: $result"
pass "the scanout card falls back to /dev/dri/cardN with no by-path match"

SNAPPER_CONFIG_PATH="${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}"
SNAPPER_CONF_PATH="${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}"
template="${OMARCHY_SNAPPER_TEMPLATE:-${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root}"

# Snapshots need snapper and a btrfs root. Platforms whose image ships neither
# (a Raspberry Pi boots an ext4 root) skip this rather than fail system setup,
# and omarchy-snapshot already treats a missing snapper as no snapshots. This
# leaf is sourced by run_logged and run as a script by migrations, so it skips
# with if/else rather than return or exit.
root_fstype=$(findmnt -no FSTYPE / 2>/dev/null || true)

if omarchy-cmd-missing snapper; then
  echo "Skipping Snapper snapshot retention: snapper is not installed"
elif [[ $root_fstype != "btrfs" ]]; then
  echo "Skipping Snapper snapshot retention: the root filesystem is ${root_fstype:-unknown}, not btrfs"
else
  echo "Configuring Omarchy Snapper snapshot retention"

  if [[ ! -f $SNAPPER_CONFIG_PATH ]]; then
    mkdir -p "$(dirname "$SNAPPER_CONFIG_PATH")"

    if [[ ${OMARCHY_SNAPPER_CONFIGURE_TEST:-0} == "1" ]]; then
      : >"$SNAPPER_CONFIG_PATH"
    else
      snapper --no-dbus -c root create-config / >/dev/null 2>&1 || snapper -c root create-config / >/dev/null
    fi
  fi

  install -m 0644 "$template" "$SNAPPER_CONFIG_PATH"

  mkdir -p "$(dirname "$SNAPPER_CONF_PATH")"
  printf '%s\n' 'SNAPPER_CONFIGS="root"' >"$SNAPPER_CONF_PATH"
  chmod 0644 "$SNAPPER_CONF_PATH"

  systemctl disable --now snapper-timeline.timer >/dev/null 2>&1 || true
  systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service >/dev/null 2>&1 || true
fi

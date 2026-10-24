# A Pi cannot sleep: linux-rpi is built without suspend or hibernation support
# (CONFIG_SUSPEND and CONFIG_HIBERNATION are off), and the BCM2711's cores start
# by spin-table, with no PSCI firmware to suspend them. Say so to systemd, which
# also hides Suspend in the menu (omarchy-sleep-disabled), rather than offer a
# state the board cannot enter.
sleep_config_dir=${OMARCHY_SLEEP_CONFIG_DIR:-/etc/systemd/sleep.conf.d}

if omarchy-hw-aarch64-rpi; then
  mkdir -p "$sleep_config_dir"
  cat >"$sleep_config_dir/omarchy-sleep-disabled.conf" <<'CONF'
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
CONF
fi

# NetworkManager enablement is centralized in enable-services.sh.
systemctl disable iwd.service 2>/dev/null || true

# Fresh Omarchy uses NetworkManager. Archinstall's legacy "copy ISO network"
# mode enabled systemd-networkd and dropped DHCP .network files that compete
# with NetworkManager, so retire that state whenever hardware setup runs.
for unit in \
  systemd-networkd.service \
  systemd-networkd.socket \
  systemd-networkd-varlink.socket \
  systemd-networkd-varlink-metrics.socket \
  systemd-networkd-resolve-hook.socket; do
  systemctl disable "$unit" 2>/dev/null || true
done

# Prevent systemd-networkd-wait-online timeout on boot.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service 2>/dev/null || true

networkd_dir=${OMARCHY_NETWORKD_DIR:-/etc/systemd/network}

stock_networkd_file() {
  local file="$1"

  [[ -f $file ]] || return 1
  case "$(basename "$file")" in
    20-ethernet.network|20-wlan.network|20-wwan.network) ;;
    *) return 1 ;;
  esac

  grep -Eq '^[[:space:]]*DHCP=yes[[:space:]]*$' "$file" || return 1
  grep -Eq '^[[:space:]]*Name=(en\*|eth\*|wl\*|ww\*)[[:space:]]*$' "$file" || return 1
}

# Arch Linux ARM's root filesystem, which a Raspberry Pi install starts from,
# enables systemd-networkd with DHCP on every wired interface through
# en.network (Name=en*) and eth.network (Name=eth*). Retire them only while
# they still hold that stock content, apart from the CRLF line endings ALARM
# ships, so an administrator's own files of the same name stay.
alarm_networkd_file() {
  local file="$1" name

  [[ -f $file ]] || return 1
  name=$(basename "$file" .network)
  [[ $(tr -d '\r' <"$file") == $'[Match]\nName='"$name"$'*\n\n[Network]\nDHCP=yes\nDNSSEC=no' ]]
}

backup_dir="$networkd_dir/omarchy-networkd-retired-$(date +%Y%m%d%H%M%S)"
for file in "$networkd_dir/20-ethernet.network" "$networkd_dir/20-wlan.network" "$networkd_dir/20-wwan.network"; do
  if stock_networkd_file "$file"; then
    install -d -m 0755 "$backup_dir"
    mv "$file" "$backup_dir/"
  fi
done
for file in "$networkd_dir/en.network" "$networkd_dir/eth.network"; do
  if alarm_networkd_file "$file"; then
    install -d -m 0755 "$backup_dir"
    mv "$file" "$backup_dir/"
  fi
done

if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
  systemctl stop systemd-networkd.service 2>/dev/null || true
fi

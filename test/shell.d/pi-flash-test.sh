#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# pi/flash, sourced with its tools stubbed: the release's manifest as
# pi/release-manifest writes it, the disks lsblk and diskutil report, the
# questions answered on a stand-in terminal, and the image streamed from a
# stand-in for GitHub onto a file standing in for the card.

FLASH=$ROOT/pi/flash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
stubs=$tmp/stubs
mkdir -p "$stubs"

output=$(bash -c 'source "$1"; echo sourced' bash "$FLASH" 2>&1) || fail "sourcing pi/flash runs nothing" "$output"
[[ $output == "sourced" ]] || fail "sourcing pi/flash runs nothing" "$output"
pass "sourcing pi/flash runs nothing"

# macOS runs it with Bash 3.2, which this host can't: nothing 3.2 lacks may
# appear in it, outside comments.
if grep -v '^[[:space:]]*#' "$FLASH" |
  grep -nE 'declare -[AnlucL]|local -[Anlu]|mapfile|readarray|\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(,,|\^\^|,|\^|@[QEPAKa])\}|\[\[ -v |\|&|&>>|;;&|coproc|EPOCH(SECONDS|REALTIME)|inherit_errexit|globstar|\$\{![A-Za-z_]+[@*]\}'; then
  fail "pi/flash uses nothing Bash 3.2 lacks"
fi
pass "pi/flash uses nothing Bash 3.2 lacks"

# ── The release ──────────────────────────────────────────────────────────────

release=$tmp/release
mkdir -p "$release"
head -c 200000 /dev/urandom >"$release/card.img"
xz -T1 -k "$release/card.img"
split -b 70000 -d -a 1 "$release/card.img.xz" "$release/card.img.xz.part"
"$ROOT/pi/release-manifest" "$release/card.img.xz" "$release"/card.img.xz.part? >"$release/pimarchy.json"

flash() {
  PATH="$stubs:$PATH" bash -c 'source "$1"; shift; eval "$1"' bash "$FLASH" "$@"
}

output=$(flash 'read_manifest "$2"; printf "%s|" "$image" "$image_bytes" "$image_sha256" "$unpacked_bytes" "${parts[@]}" "${part_bytes[@]}"' \
  "$release/pimarchy.json")
expected="card.img.xz|$(stat -c %s "$release/card.img.xz")|$(sha256sum "$release/card.img.xz" | cut -d' ' -f1)|200000|"
for part in "$release"/card.img.xz.part?; do
  expected+="${part##*/}|"
done
for part in "$release"/card.img.xz.part?; do
  expected+="$(stat -c %s "$part")|"
done
[[ $output == "$expected" ]] || fail "pi/flash reads the manifest pi/release-manifest writes" "$output"
pass "pi/flash reads the manifest pi/release-manifest writes"

sed 's/"size": 70000}/"size": 70001}/' "$release/pimarchy.json" >"$tmp/broken.json"
status=0
output=$(flash 'read_manifest "$2"' "$tmp/broken.json" 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"the release's parts don't make up its image"* ]] ||
  fail "pi/flash refuses a manifest whose parts don't make up the image" "$output"
pass "pi/flash refuses a manifest whose parts don't make up the image"

# ── The card ─────────────────────────────────────────────────────────────────

# lsblk as it reports a laptop's disk, an SD card in a USB reader with its boot
# partition automounted, a USB disk Linux runs from, the laptop's SD slot, an
# eMMC boot area, an empty reader, a read-only card and a USB disk under LVM.
cat >"$stubs/lsblk" <<'SH'
#!/bin/bash
if [[ $* == "-dnpbP -o NAME,SIZE,RM,HOTPLUG,TRAN,TYPE,RO,MODEL" ]]; then
  cat <<'OUT'
NAME="/dev/sda" SIZE="512110190592" RM="0" HOTPLUG="0" TRAN="sata" TYPE="disk" RO="0" MODEL="Samsung SSD 860"
NAME="/dev/sdb" SIZE="31914983424" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="SD Card Reader"
NAME="/dev/sdc" SIZE="256060514304" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Portable SSD"
NAME="/dev/mmcblk0" SIZE="63864569856" RM="0" HOTPLUG="0" TRAN="" TYPE="disk" RO="0" MODEL=""
NAME="/dev/mmcblk1boot0" SIZE="4194304" RM="0" HOTPLUG="0" TRAN="" TYPE="disk" RO="0" MODEL=""
NAME="/dev/sdd" SIZE="0" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Empty Reader"
NAME="/dev/sde" SIZE="15931539456" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="1" MODEL="Locked Card"
NAME="/dev/sdf" SIZE="1000204886016" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Backup Disk"
OUT
  exit 0
fi
disk=${!#}
case $disk in
  /dev/sdb) printf '%s\n' 'NAME="/dev/sdb" TYPE="disk" MOUNTPOINT=""' 'NAME="/dev/sdb1" TYPE="part" MOUNTPOINT="/media/ada/BOOT"' ;;
  /dev/sdc) printf '%s\n' 'NAME="/dev/sdc" TYPE="disk" MOUNTPOINT=""' 'NAME="/dev/sdc1" TYPE="part" MOUNTPOINT="/boot/efi"' 'NAME="/dev/sdc2" TYPE="part" MOUNTPOINT="/"' ;;
  /dev/sdf) printf '%s\n' 'NAME="/dev/sdf" TYPE="disk" MOUNTPOINT=""' 'NAME="/dev/sdf1" TYPE="part" MOUNTPOINT=""' 'NAME="/dev/mapper/vg-data" TYPE="lvm" MOUNTPOINT="/srv/data"' ;;
  *) printf 'NAME="%s" TYPE="disk" MOUNTPOINT=""\n' "$disk" ;;
esac
SH
chmod +x "$stubs/lsblk"
output=$(flash 'linux_disks')
[[ $output == $'/dev/sdb 31914983424 SD Card Reader\n/dev/mmcblk0 63864569856 disk' ]] ||
  fail "Linux offers the card reader and the SD slot, and no disk it runs from, is empty, read-only or in use" "$output"
pass "Linux offers removable disks with media, and none it runs from, read-only or in a volume"

# diskutil as macOS reports its own disk, an SD card in a USB reader, a card
# in the built-in SD slot (which macOS lists as internal), an external disk
# macOS starts from, a fixed internal disk, an external disk holding another
# macOS, and an attached disk image.
mkdir -p "$tmp/diskutil"
cat >"$tmp/diskutil/list" <<'OUT'
/dev/disk0 (internal, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.3 GB   disk0
   1:             Apple_APFS_ISC Container disk1         524.3 MB   disk0s1
   2:                 Apple_APFS Container disk3         494.4 GB   disk0s2

/dev/disk4 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *31.9 GB    disk4
   1:             Windows_FAT_32 BOOT                    536.9 MB   disk4s1

/dev/disk5 (internal, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *63.9 GB    disk5

/dev/disk6 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *1.0 TB     disk6

/dev/disk7 (internal, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *2.0 TB     disk7

/dev/disk8 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:      GUID_partition_scheme                        *500.1 GB   disk8
   1:                        EFI EFI                     209.7 MB   disk8s1
   2:                 Apple_APFS Container disk9         499.9 GB   disk8s2

/dev/disk10 (external, physical):
   #:                       TYPE NAME                    SIZE       IDENTIFIER
   0:     FDisk_partition_scheme                        *8.6 GB     disk10
OUT
# As macOS 26 prints it: Media Read-Only, and a disk image external and
# removable but with the Disk Image protocol.
info() {
  printf '   Device Identifier:         %s\n   Device / Media Name:       %s\n   Protocol:                  %s\n   Disk Size:                 %s (%s Bytes) (exactly %s 512-Byte-Units)\n   Media Read-Only:           %s\n   Device Location:           %s\n   Removable Media:           %s\n   Virtual:                   %s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(( $5 / 512 ))" "$6" "$7" "$8" "$9" >"$tmp/diskutil/$1"
}
info disk0 "APPLE SSD AP0512Q" "Apple Fabric" "500.3 GB" 500277792768 No Internal Fixed No
info disk4 "SD Card Reader" USB "31.9 GB" 31914983424 No External Removable No
info disk5 "Built In SDXC Reader" "Secure Digital" "63.9 GB" 63864569856 No Internal Removable No
info disk6 "Portable SSD" USB "1.0 TB" 1000204886016 No External Fixed No
info disk7 "Internal HDD" SATA "2.0 TB" 2000398934016 No Internal Fixed No
info disk8 "Backup SSD" USB "500.1 GB" 500107862016 No External Fixed No
info disk10 "Disk Image" "Disk Image" "8.6 GB" 8589934592 No External Removable Yes
printf '   Volume Name:               Macintosh HD\n   APFS Physical Store:       disk6s2\n' >"$tmp/diskutil/root"
cat >"$stubs/diskutil" <<SH
#!/bin/bash
case "\$*" in
  "list physical") cat "$tmp/diskutil/list" ;;
  "info /") cat "$tmp/diskutil/root" ;;
  "info disk"*) cat "$tmp/diskutil/\$2" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$stubs/diskutil"
output=$(flash 'macos_disks')
[[ $output == $'/dev/disk4 31914983424 SD Card Reader\n/dev/disk5 63864569856 Built In SDXC Reader' ]] ||
  fail "macOS offers a card in a USB reader and one in the built-in slot, and not the disk it starts from" "$output"
pass "macOS offers external disks and cards in the built-in slot, and no disk it starts from, holding macOS, or an image"

# A card whose lock switch is on is read-only, and not offered.
sed -i 's/Media Read-Only:           No/Media Read-Only:           Yes/' "$tmp/diskutil/disk4"
output=$(flash 'macos_disks')
[[ $output == "/dev/disk5 63864569856 Built In SDXC Reader" ]] || fail "macOS doesn't offer a locked card" "$output"
pass "macOS doesn't offer a card whose lock switch is on"

# Picking a disk: by number on the terminal, or by --disk, which must be one on offer.
printf '2\n' >"$tmp/answers"
output=$(flash 'OS=linux wanted_disk=""; exec 3<"$2"; choose_disk 2>/dev/null; echo "$disk $disk_bytes $disk_name"' "$tmp/answers")
[[ $output == "/dev/mmcblk0 63864569856 disk" ]] || fail "the owner picks a disk by its number" "$output"
status=0
output=$(flash 'OS=linux wanted_disk=/dev/sda; choose_disk' 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"/dev/sda is not a removable disk this can write"* ]] ||
  fail "--disk can't name a disk that isn't on offer" "$output"
pass "a disk is picked from the ones on offer, by number or by --disk"

printf 'sdc\n' >"$tmp/answers"
status=0
output=$(flash 'disk=/dev/sdb disk_bytes=31914983424 disk_name=Reader; exec 3<"$2"; confirm_disk' "$tmp/answers" 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"nothing was written"* ]] || fail "a disk is written only when its name is typed back" "$output"
pass "a disk is written only when its name is typed back"

# ── The settings ─────────────────────────────────────────────────────────────

# Answers as typed: a Wi-Fi network and its password with a trailing space, the
# default country, a username, mismatched passwords then matching ones, git's
# name and email, a hostname, the default timezone and keyboard, and the key.
home=$tmp/home
mkdir -p "$home/.ssh"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA ada@laptop" >"$home/.ssh/id_ed25519.pub"
printf '%s\n' 'Home net' 'correct horse ' '' 'ada' 'pass one' 'pass two' 'pass word' 'pass word' 'Ada Lovelace' 'ada@example.com' \
  'pi400' '' '' 'yes' >"$tmp/answers"
cp "$ROOT/pi/rpi-boot/pimarchy.txt" "$tmp/pimarchy.txt"
cat >"$stubs/openssl" <<'SH'
#!/bin/bash
[[ $* == "passwd -6 -stdin" ]] || exit 1
read -r password
printf '$6$salt$%s\n' "$(printf '%s' "$password" | sha256sum | cut -c1-20)"
SH
chmod +x "$stubs/openssl"
output=$(HOME=$home LANG=en_GB.UTF-8 flash 'local_timezone() { printf Europe/London; }
  exec 3<"$2"; ask_settings 2>/dev/null; fill_settings "$3"; printf "%s\n" "${settings[@]}"' "$tmp/answers" "$tmp/pimarchy.txt")
hash="\$6\$salt\$$(printf 'pass word' | sha256sum | cut -c1-20)"
for line in 'WIFI_SSID=Home net' 'WIFI_PASSWORD="correct horse "' 'WIFI_COUNTRY=GB' 'USERNAME=ada' "PASSWORD_HASH=$hash" \
  'FULL_NAME=Ada Lovelace' 'EMAIL=ada@example.com' 'HOSTNAME=pi400' 'TIMEZONE=Europe/London' 'KEYBOARD=us' \
  'SSH_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA ada@laptop' 'PASSWORD=' 'WIFI_HIDDEN=no' 'SSH_PASSWORD_LOGIN=no'; do
  grep -qxF -- "$line" "$tmp/pimarchy.txt" || fail "pimarchy.txt gets $line" "$(grep -v '^#' "$tmp/pimarchy.txt")"
done
(( $(grep -c '^[A-Z_]*=' "$tmp/pimarchy.txt") == $(grep -c '^[A-Z_]*=' "$ROOT/pi/rpi-boot/pimarchy.txt") )) ||
  fail "each answer fills the template's own line, and adds none"
grep -q 'pass word' "$tmp/pimarchy.txt" && fail "the account's password itself stays off the card"
pass "the answers fill pimarchy.txt's own lines, a value with spaces at its end quoted, and the password only as its hash"

# macOS's openssl (LibreSSL) makes no SHA-512 crypt, so Perl makes it: the
# same hash as OpenSSL's for the same salt, long and non-ASCII passwords too.
if openssl passwd -6 -salt check x >/dev/null 2>&1 && command -v perl >/dev/null; then
  for password in 'pass word' "$(printf 'x%.0s' {1..70})" 'pässwörd ü'; do
    ours=$(printf '%s\n' "$password" | bash -c 'source "$1"; perl -e "$SHA512_CRYPT" Ab3./xyz12345678' bash "$FLASH")
    theirs=$(printf '%s\n' "$password" | openssl passwd -6 -salt Ab3./xyz12345678 -stdin)
    [[ $ours == "$theirs" ]] || fail "Perl's SHA-512 crypt matches OpenSSL's for \"$password\"" "$ours vs $theirs"
  done
  pass "Perl's SHA-512 crypt, for a macOS without one in openssl, matches OpenSSL's"
else
  skip "Perl's SHA-512 crypt against OpenSSL's (this host has no openssl passwd -6 or perl)"
fi

# Without either, the Pi gets the password, which it blanks once used.
printf '#!/bin/bash\nexit 1\n' >"$stubs/openssl"
printf '#!/bin/bash\nexit 1\n' >"$stubs/perl"
chmod +x "$stubs/perl"
printf '%s\n' '' 'ada' 'pass word' 'pass word' '' '' 'pi400' '' '' 'no' >"$tmp/answers"
output=$(HOME=$home flash 'exec 3<"$2"; ask_settings 2>/dev/null; printf "%s\n" "${settings[@]}"' "$tmp/answers")
[[ $output == *$'\nPASSWORD=pass word\n'* && $output != *WIFI* && $output != *SSH_KEY* ]] ||
  fail "without SHA-512 crypt the password goes as it is, and no Wi-Fi or key goes when none is given" "$output"
rm -f "$stubs/perl"
pass "without SHA-512 crypt in openssl or Perl, the Pi gets the password, and Ethernet needs no Wi-Fi"

# ── Writing ──────────────────────────────────────────────────────────────────

# curl as GitHub's release downloads answer it: each URL's file in turn.
cat >"$stubs/curl" <<SH
#!/bin/bash
for arg; do
  case \$arg in
    https://github.com/*/releases/download/*) cat "$release/\${arg##*/}" || exit 22 ;;
  esac
done
SH
chmod +x "$stubs/curl"
card=$tmp/card
: >"$card"
output=$(flash 'OS=linux; tmp=$3; disk=$2; tag=v1; as_root() { "$@"; }; read_manifest "$4"; write_image 2>&1' \
  "$card" "$tmp" "$release/pimarchy.json") || fail "pi/flash writes the image" "$output"
cmp -s "$card" "$release/card.img" || fail "the card holds the image, its parts joined and unpacked"
pass "the image's parts are streamed, joined and unpacked onto the card"

rm -f "$tmp/sum.fifo"
sed "s/\"sha256\": \"[0-9a-f]*\"/\"sha256\": \"$(printf '0%.0s' {1..64})\"/" "$release/pimarchy.json" >"$tmp/other.json"
status=0
output=$(flash 'OS=linux; tmp=$3; disk=$2; tag=v1; as_root() { "$@"; }; read_manifest "$4"; write_image' \
  "$card" "$tmp" "$tmp/other.json" 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"doesn't match the release's checksum"* ]] ||
  fail "a download that doesn't match the image's checksum fails" "$output"
pass "a download that doesn't match the image's checksum fails, and says the card won't boot"

rm -f "$tmp/sum.fifo"
mv "$release/card.img.xz.part2" "$tmp/part2"
status=0
output=$(flash 'OS=linux; tmp=$3; disk=$2; tag=v1; as_root() { "$@"; }; read_manifest "$4"; write_image' \
  "$card" "$tmp" "$release/pimarchy.json" 2>&1) || status=$?
mv "$tmp/part2" "$release/card.img.xz.part2"
(( status == 1 )) && [[ $output == *"writing the card failed"* ]] || fail "a part that won't download fails the write" "$output"
pass "a part that won't download fails the write"

#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# pi/flash, sourced with its tools stubbed: the release's manifest as
# pi/release-manifest writes it, the disks lsblk, the kernel's tables and
# diskutil report, the questions answered on a stand-in terminal, and the image
# streamed from a stand-in for GitHub onto a file standing in for the card.

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

# The Pi's own rules, copied so nothing is typed here that the Pi then refuses.
output=$(bash -c '
  source "$1"
  flash_reserved=$RESERVED_USERNAMES flash_keymaps=$KEYMAPS
  OMARCHY_FORM_DEFAULTS=/nonexistent source "$2"
  [[ $flash_reserved == "$OMARCHY_RESERVED_USERNAMES" ]] || echo "reserved usernames differ"
  form_keymaps=" $(printf "%s\n" "$OMARCHY_KEYBOARD_LAYOUTS" | cut -d"|" -f2 | awk "!seen[\$0]++" | tr "\n" " ")"
  [[ $flash_keymaps == "$form_keymaps" ]] || echo "keymaps differ: $form_keymaps"
' bash "$FLASH" "$ROOT/install/provisioning/setup-form.sh")
[[ -z $output ]] || fail "pi/flash checks usernames and layouts as the Pi's owner form does" "$output"
pass "pi/flash checks usernames and keyboard layouts as the Pi's owner form does"

# ── The release ──────────────────────────────────────────────────────────────

release=$tmp/release
mkdir -p "$release"
head -c 200000 /dev/urandom >"$release/card.img"
xz -T1 -k "$release/card.img"
split -b 70000 -d -a 1 "$release/card.img.xz" "$release/card.img.xz.part"
"$ROOT/pi/release-manifest" "$release/card.img.xz" "$release"/card.img.xz.part? >"$release/pimarchy.json"
base=https://github.com/TheLazyDevsInc/pimarchy
printf '<feed><link href="%s/releases/tag/%s"/></feed>\n' "$base" building "$base" v1 >"$release/releases.atom"

# Runs shell code with pi/flash's functions, its stubs first on PATH.
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

# curl as GitHub answers it: the releases feed, and each release download in
# turn, failing one it hasn't. As the real one does, it goes on past a failed
# download and reports only the last unless --fail-early is given.
cat >"$stubs/curl" <<SH
#!/bin/bash
fail_early=0 status=0 out=""
args=("\$@")
for i in "\${!args[@]}"; do
  case \${args[i]} in
    --fail-early) fail_early=1 ;;
    -o) out=\${args[i + 1]} ;;
  esac
done
[[ " \$* " == *" -f"* ]] || { echo "curl stub: pi/flash must pass -f" >&2; exit 2; }
for arg; do
  case \$arg in
    $base/releases.atom) file=$release/releases.atom ;;
    $base/releases/download/v1/*) file=$release/\${arg##*/} ;;
    https://*) file=/nonexistent ;;
    *) continue ;;
  esac
  if [[ -f \$file ]]; then
    if [[ -n \$out ]]; then cat "\$file" >"\$out"; else cat "\$file"; fi
    status=0
  else
    status=22
    (( fail_early )) && exit 22
  fi
done
exit \$status
SH
chmod +x "$stubs/curl"
output=$(flash 'tag=$(latest_tag "$2/manifest.json"); echo "$tag $(sed -n "s/.*\"image\": \"\(.*\)\".*/\1/p" "$2/manifest.json")"' "$tmp")
[[ $output == "v1 card.img.xz" ]] || fail "the newest release with a manifest is found through the releases feed" "$output"
pass "the newest release with a manifest is found through the releases feed, not GitHub's API"

# ── The card on Linux ────────────────────────────────────────────────────────

# lsblk as util-linux 2.39 answers, which refuses --list with --pairs, for a
# laptop's disk, an SD card in a USB reader with its boot partition
# automounted, a USB disk with /srv on it (from an lsblk naming the device
# numbers MAJ_MIN), the card Raspberry Pi OS runs from, a card in the laptop's
# slot, eMMC on the board, an empty reader, a read-only card, and USB disks
# under LVM, holding swap, under device-mapper, and with btrfs at /home.
cat >"$stubs/lsblk" <<SH
#!/bin/bash
for arg; do
  if [[ \$arg == -*l*P* || \$arg == -*P*l* ]]; then
    echo "lsblk: mutually exclusive arguments: --pairs --tree --list --raw" >&2
    exit 1
  fi
done
if [[ \$* == "-dnpbP -o NAME,SIZE,RM,HOTPLUG,TRAN,TYPE,RO,MODEL" ]]; then
  cat "\${LSBLK_DISKS:-$tmp/disks}"
  exit 0
fi
[[ \$* == "-npP -o NAME,TYPE,MAJ:MIN "* ]] || { echo "lsblk stub: unexpected \$*" >&2; exit 64; }
grep "^\${!#} " "$tmp/trees" | cut -d' ' -f2- | tr '|' '\n'
SH
chmod +x "$stubs/lsblk"
cat >"$tmp/disks" <<'OUT'
NAME="/dev/sda" SIZE="512110190592" RM="0" HOTPLUG="0" TRAN="sata" TYPE="disk" RO="0" MODEL="Samsung SSD 860"
NAME="/dev/sdb" SIZE="31914983424" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="SD Card Reader"
NAME="/dev/sdc" SIZE="256060514304" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Portable SSD"
NAME="/dev/mmcblk0" SIZE="63864569856" RM="0" HOTPLUG="0" TRAN="" TYPE="disk" RO="0" MODEL=""
NAME="/dev/mmcblk1" SIZE="31914983424" RM="0" HOTPLUG="0" TRAN="" TYPE="disk" RO="0" MODEL=""
NAME="/dev/mmcblk2" SIZE="62537072640" RM="0" HOTPLUG="0" TRAN="" TYPE="disk" RO="0" MODEL=""
NAME="/dev/sdd" SIZE="0" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Empty Reader"
NAME="/dev/sde" SIZE="15931539456" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="1" MODEL="Locked Card"
NAME="/dev/sdf" SIZE="1000204886016" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Backup Disk"
NAME="/dev/sdg" SIZE="64023257088" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Swap Stick"
NAME="/dev/sdh" SIZE="128035676160" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Encrypted Disk"
NAME="/dev/sdi" SIZE="500107862016" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Home Disk"
OUT
cat >"$tmp/trees" <<'OUT'
/dev/sdb NAME="/dev/sdb" TYPE="disk" MAJ:MIN="8:16"|NAME="/dev/sdb1" TYPE="part" MAJ:MIN="8:17"|NAME="/dev/sdb2" TYPE="part" MAJ:MIN="8:18"
/dev/sdc NAME="/dev/sdc" TYPE="disk" MAJ_MIN="8:32"|NAME="/dev/sdc1" TYPE="part" MAJ_MIN="8:33"|NAME="/dev/sdc2" TYPE="part" MAJ_MIN="8:34"
/dev/mmcblk0 NAME="/dev/mmcblk0" TYPE="disk" MAJ:MIN="179:0"|NAME="/dev/mmcblk0p1" TYPE="part" MAJ:MIN="179:1"|NAME="/dev/mmcblk0p2" TYPE="part" MAJ:MIN="179:2"
/dev/mmcblk1 NAME="/dev/mmcblk1" TYPE="disk" MAJ:MIN="179:32"|NAME="/dev/mmcblk1p1" TYPE="part" MAJ:MIN="179:33"
/dev/sdf NAME="/dev/sdf" TYPE="disk" MAJ:MIN="8:80"|NAME="/dev/sdf1" TYPE="part" MAJ:MIN="8:81"|NAME="/dev/mapper/vg-data" TYPE="lvm" MAJ:MIN="254:0"
/dev/sdg NAME="/dev/sdg" TYPE="disk" MAJ:MIN="8:96"|NAME="/dev/sdg1" TYPE="part" MAJ:MIN="8:97"|NAME="/dev/sdg2" TYPE="part" MAJ:MIN="8:98"
/dev/sdh NAME="/dev/sdh" TYPE="disk" MAJ:MIN="8:112"|NAME="/dev/sdh1" TYPE="part" MAJ:MIN="8:113"
/dev/sdi NAME="/dev/sdi" TYPE="disk" MAJ:MIN="8:128"|NAME="/dev/sdi1" TYPE="part" MAJ:MIN="8:129"
OUT
cat >"$tmp/mountinfo" <<'OUT'
22 1 179:2 / / rw,noatime shared:1 - ext4 /dev/root rw
23 22 179:1 / /boot/firmware rw,relatime shared:2 - vfat /dev/mmcblk0p1 rw
30 22 8:34 / /srv rw,relatime shared:9 - ext4 /dev/sdc2 rw
31 22 8:17 / /media/ada/BOOT rw,nosuid,nodev shared:10 - vfat /dev/sdb1 rw,uid=1000
32 22 0:45 /@home /home rw,relatime shared:11 - btrfs /dev/sdi1 rw,space_cache=v2
OUT
printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/dev/sdg2\tpartition\t1048572\t0\t-2\n' >"$tmp/swaps"
mkdir -p "$tmp/sysfs"/{mmcblk0,mmcblk1,mmcblk2}/device "$tmp/sysfs/sdh1/holders/dm-3"
echo SD >"$tmp/sysfs/mmcblk0/device/type"
echo SD >"$tmp/sysfs/mmcblk1/device/type"
echo MMC >"$tmp/sysfs/mmcblk2/device/type"
export PIMARCHY_FLASH_MOUNTINFO=$tmp/mountinfo PIMARCHY_FLASH_SWAPS=$tmp/swaps PIMARCHY_FLASH_SYSFS_BLOCK=$tmp/sysfs

output=$(flash 'linux_disks' 2>"$tmp/left-out")
[[ $output == $'/dev/sdb 31914983424 SD Card Reader\n/dev/mmcblk1 31914983424 SD card' ]] ||
  fail "Linux offers the card in the USB reader and the one in the slot" "$output"
for reason in "/dev/sdc (256.1 GB, Portable SSD): it is mounted at /srv" "/dev/mmcblk0 (63.9 GB, SD card): it is mounted at /" \
  "/dev/sdf (1000.2 GB, Backup Disk): a lvm volume is on it" "/dev/sdg (64.0 GB, Swap Stick): it holds swap" \
  "/dev/sdh (128.0 GB, Encrypted Disk): dm-3 is built on sdh1" "/dev/sdi (500.1 GB, Home Disk): it is mounted at /home"; do
  grep -qF "Leaving out $reason." "$tmp/left-out" || fail "Linux says it leaves out $reason" "$(cat "$tmp/left-out")"
done
pass "Linux offers removable disks nothing uses, and says why it leaves out the ones in use, the card Raspberry Pi OS runs from too"

# Before writing, everything on the card is unmounted, and a mount that stays
# stops the write.
cat >"$stubs/sudo" <<SH
#!/bin/bash
echo "sudo \$*" >>"$tmp/sudo.log"
if [[ \$1 == umount && ! -e $tmp/stuck ]]; then
  sed -i "\\| \$2 |d" "$tmp/mountinfo"
fi
SH
chmod +x "$stubs/sudo"
output=$(flash 'OS=linux disk=/dev/sdb; unmount_disk' 2>&1) || fail "the card's automounted partition is unmounted" "$output"
grep -qx 'sudo umount /dev/sdb1' "$tmp/sudo.log" && ! grep -q 'BOOT' "$tmp/mountinfo" || fail "the card's automounted partition is unmounted"
echo '31 22 8:17 / /media/ada/BOOT rw,nosuid,nodev shared:10 - vfat /dev/sdb1 rw,uid=1000' >>"$tmp/mountinfo"
touch "$tmp/stuck"
status=0
output=$(flash 'OS=linux disk=/dev/sdb; unmount_disk' 2>&1) || status=$?
rm "$tmp/stuck"
(( status == 1 )) && [[ $output == *"/dev/sdb stays mounted at /media/ada/BOOT so nothing was written"* ]] ||
  fail "a mount that won't go stops the write" "$output"
sed -i '/BOOT/d' "$tmp/mountinfo"
pass "everything on the card is unmounted before it is written, and a mount that stays stops the write"

# Picking a disk: by number on the terminal, or by --disk, which must be one on offer.
printf '2\n' >"$tmp/answers"
output=$(flash 'OS=linux wanted_disk=""; exec 3<"$2"; choose_disk 2>/dev/null; echo "$disk $disk_bytes $disk_name"' "$tmp/answers")
[[ $output == "/dev/mmcblk1 31914983424 SD card" ]] || fail "the owner picks a disk by its number" "$output"
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

# Just before writing, the disk is looked up again: another disk that has
# taken the card's name since is not written.
sed 's/SIZE="31914983424" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="SD Card Reader"/SIZE="2000398934016" RM="0" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="Backup Drive"/' \
  "$tmp/disks" >"$tmp/disks-later"
status=0
output=$(LSBLK_DISKS=$tmp/disks-later flash 'OS=linux disk=/dev/sdb disk_bytes=31914983424 disk_name="SD Card Reader"; recheck_disk' 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"/dev/sdb is no longer the 31.9 GB SD Card Reader chosen, so nothing was written"* ]] ||
  fail "a disk that has changed since it was chosen is not written" "$output"
flash 'OS=linux disk=/dev/sdb disk_bytes=31914983424 disk_name="SD Card Reader"; recheck_disk' 2>/dev/null ||
  fail "the disk chosen, unchanged, passes the check"
pass "the disk is looked up again just before it is written, and one that changed is not written"

# ── The card on macOS ────────────────────────────────────────────────────────

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

# ── The settings ─────────────────────────────────────────────────────────────

# Answers as typed: a Wi-Fi network and its password with a trailing space, a
# country in lower case, a reserved username then a good one, mismatched
# passwords then matching ones, a name with a colon then without, an email, a
# hostname, the default timezone, "gb" for the UK layout, and the key, saved on
# Windows.
home=$tmp/home
mkdir -p "$home/.ssh"
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA ada@laptop\r\n' >"$home/.ssh/id_ed25519.pub"
printf '%s\n' 'Home net' 'correct horse ' 'gb' 'git' 'ada' 'pass one' 'pass two' 'pass word' 'pass word' 'Ada: Lovelace' \
  'Ada Lovelace' 'ada@example.com' 'pi400' '' 'gb' 'yes' >"$tmp/answers"
cp "$ROOT/pi/rpi-boot/pimarchy.txt" "$tmp/pimarchy.txt"
cat >"$stubs/openssl" <<'SH'
#!/bin/bash
[[ $* == "passwd -6 -stdin" ]] || exit 1
read -r password
printf '$6$salt$%s\n' "$(printf '%s' "$password" | sha256sum | cut -c1-20)"
SH
chmod +x "$stubs/openssl"
output=$(HOME=$home LC_ALL= LANG=en_GB.UTF-8 flash 'local_timezone() { printf Europe/London; }
  exec 3<"$2"; ask_settings 2>/dev/null; fill_settings "$3"; printf "%s\n" "${settings[@]}"' "$tmp/answers" "$tmp/pimarchy.txt") ||
  fail "the questions are answered" "$output"
hash="\$6\$salt\$$(printf 'pass word' | sha256sum | cut -c1-20)"
for line in 'WIFI_SSID=Home net' 'WIFI_PASSWORD="correct horse "' 'WIFI_COUNTRY=GB' 'USERNAME=ada' "PASSWORD_HASH=$hash" \
  'FULL_NAME=Ada Lovelace' 'EMAIL=ada@example.com' 'HOSTNAME=pi400' 'TIMEZONE=Europe/London' 'KEYBOARD=uk' \
  'SSH_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA ada@laptop' 'PASSWORD=' 'WIFI_HIDDEN=no' 'SSH_PASSWORD_LOGIN=no'; do
  grep -qxF -- "$line" "$tmp/pimarchy.txt" || fail "pimarchy.txt gets $line" "$(grep -v '^#' "$tmp/pimarchy.txt" | cat -A)"
done
(( $(grep -c '^[A-Z_]*=' "$tmp/pimarchy.txt") == $(grep -c '^[A-Z_]*=' "$ROOT/pi/rpi-boot/pimarchy.txt") )) ||
  fail "each answer fills the template's own line, and adds none"
grep -q 'pass word' "$tmp/pimarchy.txt" && fail "the account's password itself stays off the card"
pass "the answers fill pimarchy.txt's own lines as the Pi's rules take them, and the password only as its hash"

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

card=$tmp/card
: >"$card"
write() {
  flash 'OS=linux; tmp=$3; disk=$2; tag=v1; is_device() { true; }; as_root() { "$@"; }; read_manifest "$4"; write_image' \
    "$card" "$tmp" "$1"
}
output=$(write "$release/pimarchy.json" 2>&1) || fail "pi/flash writes the image" "$output"
cmp -s "$card" "$release/card.img" || fail "the card holds the image, its parts joined and unpacked"
pass "the image's parts are streamed, joined and unpacked onto the card"

rm -f "$tmp/sum.fifo"
sed "s/\"sha256\": \"[0-9a-f]*\"/\"sha256\": \"$(printf '0%.0s' {1..64})\"/" "$release/pimarchy.json" >"$tmp/other.json"
status=0
output=$(write "$tmp/other.json" 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"doesn't match the release's checksum"* ]] ||
  fail "a download that doesn't match the image's checksum fails" "$output"
pass "a download that doesn't match the image's checksum fails, and says the card won't boot"

# A part missing from the middle: curl would go on to the last and report it
# fine, so only --fail-early stops the write there.
rm -f "$tmp/sum.fifo"
mv "$release/card.img.xz.part1" "$tmp/part1"
status=0
output=$(write "$release/pimarchy.json" 2>&1) || status=$?
mv "$tmp/part1" "$release/card.img.xz.part1"
(( status == 1 )) && [[ $output == *"writing the card failed"* ]] || fail "a part that won't download fails the write" "$output"
pass "a part that won't download fails the write"

rm -f "$tmp/sum.fifo"
status=0
output=$(flash 'OS=linux; tmp=$3; disk=$2; tag=v1; read_manifest "$4"; write_image' "$tmp/no-such-device" "$tmp" "$release/pimarchy.json" 2>&1) ||
  status=$?
(( status == 1 )) && [[ $output == *"is gone, so nothing was written"* && ! -e $tmp/no-such-device ]] ||
  fail "a card that went away is not recreated as a file" "$output"
pass "a card that went away since it was chosen is not written, nor made as a file"

# ── All of it ────────────────────────────────────────────────────────────────

# main, end to end, with the card a file lsblk offers: the questions, the list,
# the warning and the outcome reach the terminal, the card holds the image,
# and its pimarchy.txt the answers.
rm -f "$tmp/sum.fifo" "$tmp/sudo.log"
: >"$card"
printf 'NAME="%s" SIZE="31914983424" RM="1" HOTPLUG="1" TRAN="usb" TYPE="disk" RO="0" MODEL="SD Card Reader"\n' "$card" >"$tmp/disks-main"
printf '%s NAME="%s" TYPE="disk" MAJ:MIN="8:16"\n' "$card" "$card" >>"$tmp/trees"
cat >"$stubs/sudo" <<SH
#!/bin/bash
echo "sudo \$*" >>"$tmp/sudo.log"
[[ \$1 == -v ]] || exec "\$@"
SH
chmod +x "$stubs/sudo"
mkdir -p "$tmp/boot"
cp "$ROOT/pi/rpi-boot/pimarchy.txt" "$tmp/boot/pimarchy.txt"
printf '%s\n' '' 'ada' 'pass word' 'pass word' '' '' 'pi400' '' '' 'no' '' 'card' >"$tmp/answers"
status=0
LSBLK_DISKS=$tmp/disks-main PIMARCHY_FLASH_TTY=$tmp/answers HOME=$home flash '
  boot=$2
  is_device() { true; }
  mount_boot() { printf "%s" "$boot"; }
  main --release v1' "$tmp/boot" >"$tmp/main.out" 2>"$tmp/main.err" || status=$?
(( status == 0 )) || fail "main runs to its end" "$(cat "$tmp/main.err")"
for text in "Pimarchy release v1: card.img.xz" "Username on the Pi" "1) $card  31.9 GB  SD Card Reader" \
  "Everything on $card (31.9 GB, SD Card Reader) will be erased." "Type card to write Pimarchy to it" \
  "Done. Put the card in the Pi" "ssh ada@pi400.local"; do
  grep -qF -- "$text" "$tmp/main.err" || fail "the terminal shows: $text" "$(cat "$tmp/main.err")"
done
cmp -s "$card" "$release/card.img" && grep -qx 'USERNAME=ada' "$tmp/boot/pimarchy.txt" && grep -qx 'sudo -v' "$tmp/sudo.log" ||
  fail "main writes the card and fills in its pimarchy.txt"
pass "main asks, shows the disks and the warning, writes the card and fills in pimarchy.txt, all on the terminal"

status=0
PIMARCHY_FLASH_TTY=$tmp/answers flash 'main --release v2' >/dev/null 2>"$tmp/main.err" || status=$?
(( status == 1 )) && grep -qF "flash: release v2 has no pimarchy.json manifest" "$tmp/main.err" ||
  fail "main's errors reach the terminal" "$(cat "$tmp/main.err")"
pass "main's errors reach the terminal"

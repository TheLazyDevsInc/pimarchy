#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# The Raspberry Pi boot package's scripts (pi/rpi-boot): setup-boot and
# update-verify, which omarchy-lifecycle-dispatch runs on aarch64-rpi, and
# grow-root and headless, which its first-boot units run. Each runs against a fixture root
# whose /boot holds ALARM's own cmdline.txt and config.txt from linux-rpi
# 6.18.57-1 (fixtures/rpi-boot), with stubs for the tools that read or change
# the machine.

require_platform_fixtures "the Raspberry Pi boot scripts"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

scripts=$ROOT/pi/rpi-boot
alarm=$SHELL_TEST_DIR/fixtures/rpi-boot
root=$tmp/root
state=$tmp/state
calls=$tmp/calls
stubs=$tmp/stubs
kversion=6.18.57-1-rpi
partuuid=6c586e13-02

for platform in aarch64-rpi x86; do
  fake_platform "$tmp/$platform" "$platform"
done

# Each stub logs its command line to $calls and answers from $state.
mkdir -p "$stubs"
cat >"$stubs/findmnt" <<SH
#!/bin/bash
echo "findmnt \$*" >>"$calls"
case "\$*" in
  "-no PARTUUID /") cat "$state/partuuid" ;;
  "-nvo SOURCE /") cat "$state/source" ;;
  "-no FSTYPE /") cat "$state/fstype" ;;
  *) echo "findmnt: unexpected \$*" >&2; exit 64 ;;
esac
SH
cat >"$stubs/findfs" <<SH
#!/bin/bash
echo "findfs \$*" >>"$calls"
while read -r spec device; do
  if [[ \$spec == "\$1" ]]; then
    echo "\$device"
    exit 0
  fi
done <"$state/devices"
echo "findfs: unable to resolve '\$1'" >&2
exit 1
SH
# blkid -t lists every device that carries the tag.
cat >"$stubs/blkid" <<SH
#!/bin/bash
echo "blkid \$*" >>"$calls"
[[ \$1 == "-c" && \$2 == "/dev/null" && \$3 == "-o" && \$4 == "device" && \$5 == "-t" ]] || exit 4
status=2
while read -r spec device; do
  if [[ \$spec == "\$6" ]]; then
    echo "\$device"
    status=0
  fi
done <"$state/devices"
exit \$status
SH
cat >"$stubs/mkinitcpio" <<SH
#!/bin/bash
echo "mkinitcpio \$*" >>"$calls"
[[ ! -e $state/mkinitcpio-fails ]] || exit 1
touch "$root/boot/initramfs-linux.img"
SH
cat >"$stubs/lsinitcpio" <<SH
#!/bin/bash
echo "lsinitcpio \$*" >>"$calls"
[[ \$1 == "-l" && \$2 == "$root/boot/initramfs-linux.img" ]] || exit 64
cat "$state/listing"
SH
# lsblk pads its columns. It answers PARTN and PTTYPE from udev's database,
# which is empty in early boot until udev has processed the disk again, so the
# stub leaves them empty, as lsblk does then.
cat >"$stubs/lsblk" <<SH
#!/bin/bash
echo "lsblk \$*" >>"$calls"
case "\$*" in
  "-no KNAME,PKNAME /dev/mmcblk0p2") printf 'mmcblk0p2 %s  \n' "\$(cat "$state/pkname")" ;;
  "-no PARTN /dev/mmcblk0p2" | "-dno PTTYPE /dev/mmcblk0") echo ;;
  "-bdno SIZE /dev/mmcblk0") printf ' %s\n' "\$(cat "$state/disk-bytes")" ;;
  *) echo "lsblk: unexpected \$*" >&2; exit 64 ;;
esac
SH
cat >"$stubs/sfdisk" <<SH
#!/bin/bash
echo "sfdisk \$*" >>"$calls"
if [[ \$1 == "--dump" ]]; then
  cat "$state/dump"
else
  cat >"$state/sfdisk-input"
  [[ ! -e $state/sfdisk-fails ]] || exit 1
fi
SH
for tool in partx resize2fs systemctl ufw set-wireless-regdom; do
  cat >"$stubs/$tool" <<SH
#!/bin/bash
echo "$tool \$*" >>"$calls"
[[ ! -e $state/$tool-fails ]] || exit 1
SH
done
# ssh-keygen takes the one key form the tests use.
cat >"$stubs/ssh-keygen" <<SH
#!/bin/bash
echo "ssh-keygen \$*" >>"$calls"
[[ \$(cat) == "ssh-ed25519 AAAA"* ]]
SH
chmod +x "$stubs"/*

# A Pi as ALARM and Omarchy leave it: linux-rpi's own boot files, Omarchy's
# kernel parameters, an initramfs built for the installed kernel after its
# configuration last changed, the image's grow-root marker, and the root
# partition (partition 2 of an 8 GiB image's MBR on a 32 GB card) mounted at /.
reset_root() {
  rm -rf "$root" "$state"
  : >"$calls"
  mkdir -p "$state" "$root/boot" "$root/dev" "$root/etc/limine-entry-tool.d" "$root/etc/mkinitcpio.conf.d" \
    "$root/sys/class/block/mmcblk0p2" "$root/usr/lib/modules/$kversion" "$root/var/lib/omarchy/image" "$root/var/lib/pimarchy"
  cp "$alarm/cmdline.txt" "$alarm/config.txt" "$root/boot/"
  cp "$ROOT/etc/limine-entry-tool.d/omarchy-defaults.conf" "$root/etc/limine-entry-tool.d/"
  echo "HOOKS=(base udev)" >"$root/etc/mkinitcpio.conf"
  echo "HOOKS=(base udev plymouth)" >"$root/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf"
  touch -d @1700000000 "$root/etc/mkinitcpio.conf" "$root/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf"
  echo linux-rpi >"$root/usr/lib/modules/$kversion/pkgbase"
  printf 'kernel' >"$root/boot/kernel8.img"
  printf 'initramfs' >"$root/boot/initramfs-linux.img"
  touch "$root/dev/mmcblk0p1" "$root/dev/mmcblk0p2" "$root/dev/sda1" "$root/var/lib/pimarchy/grow-root-pending"
  echo 2 >"$root/sys/class/block/mmcblk0p2/partition"
  chmod -R go-w "$root"

  echo "$partuuid" >"$state/partuuid"
  echo /dev/mmcblk0p2 >"$state/source"
  echo ext4 >"$state/fstype"
  printf '%s\n' "PARTUUID=$partuuid /dev/mmcblk0p2" "PARTUUID=6c586e13-01 /dev/mmcblk0p1" "LABEL=data /dev/sda1" >"$state/devices"
  printf '%s\n' usr/bin/busybox "usr/lib/modules/$kversion" "usr/lib/modules/$kversion/modules.dep" \
    "usr/lib/modules/$kversion/kernel/drivers/gpu/drm/vc4/vc4.ko.zst" >"$state/listing"
  echo mmcblk0 >"$state/pkname"
  echo 31914983424 >"$state/disk-bytes"
  cat >"$state/dump" <<'DUMP'
label: dos
label-id: 0x6c586e13
device: /dev/mmcblk0
unit: sectors
sector-size: 512

/dev/mmcblk0p1 : start=        2048, size=     1048576, type=c, bootable
/dev/mmcblk0p2 : start=     1050624, size=    15728640, type=83
DUMP
}

# Runs a Pi boot script on a platform fixture, against the fixture root.
on() {
  local platform=$1 script=$2
  shift 2
  OMARCHY_PROC_ROOT="$tmp/$platform/proc" OMARCHY_RPI_BOOT_ROOT="$root" PATH="$stubs:$tmp/$platform/bin:$ROOT/bin:$PATH" \
    "$scripts/$script" "$@"
}

# Every file in the fixture root and its content.
fingerprint() {
  (cd "$root" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}

# The block's lines that are not comments.
block_of() {
  sed -n '/^# BEGIN Omarchy$/,/^# END Omarchy$/p' "$1" | grep -v '^#' || true
}

kernel_defaults=$(
  declare -A KERNEL_CMDLINE=()
  source "$ROOT/etc/limine-entry-tool.d/omarchy-defaults.conf"
  echo ${KERNEL_CMDLINE[default]}
)
[[ " $kernel_defaults " == *" quiet "* && " $kernel_defaults " == *" splash "* ]] ||
  fail "Omarchy's default kernel parameters boot quiet and splashed" "$kernel_defaults"

# ── Who may run them ─────────────────────────────────────────────────────────

reset_root
before=$(fingerprint)
for script in setup-boot update-verify grow-root headless; do
  status=0
  output=$(on x86 "$script" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == *"this is not a Raspberry Pi"* ]] ||
    fail "$script refuses a machine that is not a Raspberry Pi" "status $status: $output"
done
# grow-root checks the platform before its marker, too.
rm "$root/var/lib/pimarchy/grow-root-pending"
status=0
output=$(on x86 grow-root 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"this is not a Raspberry Pi"* ]] ||
  fail "grow-root refuses a machine that is not a Raspberry Pi without its marker" "status $status: $output"
touch "$root/var/lib/pimarchy/grow-root-pending"
[[ $(fingerprint) == "$before" && ! -s $calls ]] || fail "nothing runs or changes off a Raspberry Pi" "$(cat "$calls")"
pass "every Pi boot script refuses a machine that is not a Raspberry Pi, and changes nothing there"

for script in setup-boot update-verify grow-root headless; do
  status=0
  output=$(env -u OMARCHY_RPI_BOOT_ROOT OMARCHY_PROC_ROOT="$tmp/aarch64-rpi/proc" PATH="$stubs:$tmp/aarch64-rpi/bin:$ROOT/bin:$PATH" \
    "$scripts/$script" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == "Error: $script runs as root" ]] || fail "$script needs root without a fixture root" "status $status: $output"
  status=0
  output=$(cd "$tmp" && OMARCHY_RPI_BOOT_ROOT=root OMARCHY_PROC_ROOT="$tmp/aarch64-rpi/proc" PATH="$stubs:$tmp/aarch64-rpi/bin:$ROOT/bin:$PATH" \
    "$scripts/$script" 2>&1) || status=$?
  (( status == 1 )) && [[ $output == "Error: OMARCHY_RPI_BOOT_ROOT must be an absolute path" ]] ||
    fail "$script refuses a relative fixture root" "status $status: $output"
  status=0
  output=$(/usr/bin/bash "$scripts/$script" -p 2>&1) || status=$?
  (( status == 126 )) || fail "$script refuses an ordinary Bash launch" "status $status: $output"
done
for arguments in "setup-boot image-first-boot extra" "setup-boot first-boot" "update-verify now" "grow-root now" "headless now"; do
  status=0
  output=$(on aarch64-rpi $arguments 2>&1) || status=$?
  (( status == 2 )) && [[ $output == Usage:* ]] || fail "'$arguments' is a usage error" "status $status: $output"
done
[[ $(fingerprint) == "$before" ]] || fail "a refused run changes nothing"
pass "the Pi boot scripts need root or an absolute fixture root, a privileged Bash launch and their own arguments"

# Root takes neither the fixture root nor the stubs on its PATH, and checks the
# platform with the installed predicate. A copy whose predicate always answers
# yes shows it: whatever the live system holds (nothing here), the fixture is
# never read or changed and no stub runs. setup-boot stops before it writes
# anything, since no live /boot or root-owned kernel parameters are in reach.
if unshare --user --map-root-user true 2>/dev/null; then
  reset_root
  before=$(fingerprint)
  mkdir -p "$tmp/as-root"
  printf '#!/bin/bash\nexit 0\n' >"$tmp/as-root/yes"
  chmod +x "$tmp/as-root/yes"
  for script in setup-boot update-verify grow-root; do
    sed "s|/usr/bin/omarchy-hw-aarch64-rpi|$tmp/as-root/yes|" "$scripts/$script" >"$tmp/as-root/$script"
    chmod +x "$tmp/as-root/$script"
    grep -qF "$tmp/as-root/yes" "$tmp/as-root/$script" || fail "$script checks the platform with /usr/bin/omarchy-hw-aarch64-rpi as root"
    output=$(OMARCHY_RPI_BOOT_ROOT="$root" PATH="$stubs:$PATH" unshare --user --map-root-user "$tmp/as-root/$script" 2>&1) || true
    [[ $output != *"$root"* && ! -s $calls ]] || fail "root ignores the fixture root and PATH stubs in $script" "$output"
  done
  [[ $(fingerprint) == "$before" ]] || fail "root never changes the fixture root"
  pass "root ignores the fixture root and the stubs on its PATH"
else
  skip "no unprivileged user namespace; skipping the check that root ignores fixture roots"
fi

# ── setup-boot ───────────────────────────────────────────────────────────────

alarm_cmdline="root=PARTUUID=$partuuid rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes"

reset_root
rm "$root/boot/initramfs-linux.img"
output=$(on aarch64-rpi setup-boot 2>&1) || fail "setup-boot sets up ALARM's boot files" "$output"
[[ $(cat "$root/boot/cmdline.txt") == "$alarm_cmdline $kernel_defaults" ]] ||
  fail "cmdline.txt boots the root partition by PARTUUID with ALARM's parameters and Omarchy's" "$(cat "$root/boot/cmdline.txt")"
(( $(wc -l <"$root/boot/cmdline.txt") == 1 )) || fail "cmdline.txt is one line"
alarm_size=$(stat -c %s "$alarm/config.txt")
cmp -s <(head -c "$alarm_size" "$root/boot/config.txt") "$alarm/config.txt" ||
  fail "config.txt keeps everything linux-rpi wrote, in place" "$(cat "$root/boot/config.txt")"
(( $(grep -c '^# BEGIN Omarchy$' "$root/boot/config.txt") == 1 )) && [[ $(tail -n 1 "$root/boot/config.txt") == "# END Omarchy" ]] ||
  fail "config.txt ends in one Omarchy block" "$(cat "$root/boot/config.txt")"
[[ $(block_of "$root/boot/config.txt") == $'[all]\ndisable_splash=1' ]] ||
  fail "the block disables the rainbow splash under [all], and leaves ALARM's initramfs and KMS lines to ALARM" "$(block_of "$root/boot/config.txt")"
cmp -s "$root/boot/cmdline.txt.omarchy-backup" "$alarm/cmdline.txt" && cmp -s "$root/boot/config.txt.omarchy-backup" "$alarm/config.txt" ||
  fail "the first edit keeps ALARM's files as .omarchy-backup"
[[ $(grep '^mkinitcpio' "$calls") == "mkinitcpio -P" ]] || fail "a missing initramfs is rebuilt" "$(cat "$calls")"
[[ -z $(find "$root/boot" -name '.*') ]] || fail "no temporary file is left on /boot" "$(ls -a "$root/boot")"
pass "setup-boot points ALARM's cmdline.txt at the root's PARTUUID with Omarchy's parameters, adds one block to config.txt and builds a missing initramfs"

# The update-verify a fresh setup must pass.
output=$(on aarch64-rpi update-verify 2>&1) || fail "update-verify passes what setup-boot set up" "$output"
[[ $output == "The Raspberry Pi's boot files boot linux-rpi $kversion" ]] || fail "update-verify says what it verified" "$output"

first=$(fingerprint)
: >"$calls"
output=$(on aarch64-rpi setup-boot 2>&1) || fail "setup-boot runs again" "$output"
[[ $(fingerprint) == "$first" && -z $output ]] || fail "a second run changes nothing and says nothing" "$output"
! grep -q '^mkinitcpio' "$calls" || fail "a current initramfs is not rebuilt" "$(cat "$calls")"
# A later change keeps the first backup: the original stays recoverable. A
# missing default goes back at the end, where the last one was.
last_default=${kernel_defaults##* }
sed -i "s/ $last_default\$//" "$root/boot/cmdline.txt"
grep -qvF "$last_default" "$root/boot/cmdline.txt" || fail "the test drops the last default parameter"
sed -i 's/^disable_splash=1$/disable_splash=0/' "$root/boot/config.txt"
output=$(on aarch64-rpi setup-boot 2>&1) || fail "setup-boot repairs its own settings" "$output"
[[ $(fingerprint) == "$first" ]] || fail "setup-boot puts back what it sets"
cmp -s "$root/boot/cmdline.txt.omarchy-backup" "$alarm/cmdline.txt" && cmp -s "$root/boot/config.txt.omarchy-backup" "$alarm/config.txt" ||
  fail "a later edit keeps the first backup"
pass "setup-boot is idempotent, puts back what it sets, and keeps the first backups and a current initramfs"

# While an image's first-boot flag is there, the initramfs hook owns root=:
# setup-boot keeps the UUID it names, and the flag.
reset_root
echo "root=UUID=93f96c19-8612-4030-98f1-3533322a5222 rw rootwait console=tty1 pimarchy.new_disk_id=8a70c72b" >"$root/boot/cmdline.txt"
on aarch64-rpi setup-boot >/dev/null || fail "setup-boot runs on a first-boot cmdline.txt"
[[ " $(<"$root/boot/cmdline.txt") " == *" root=UUID=93f96c19-8612-4030-98f1-3533322a5222 "*" pimarchy.new_disk_id=8a70c72b "* &&
  $(<"$root/boot/cmdline.txt") != *PARTUUID* ]] ||
  fail "setup-boot leaves root= to the disk identifier hook while its flag is there" "$(<"$root/boot/cmdline.txt")"
pass "setup-boot leaves root= to the disk identifier hook while its first-boot flag is there"

# An owner's own tokens stay where they are, a default whose name is already
# there keeps its value, root= is replaced once, and tty1 moves after the serial
# console.
reset_root
echo "root=/dev/mmcblk0p2 rw rootwait console=tty1 console=serial0,115200 fsck.repair=yes cma=256M loglevel=7 quiet root=/dev/sda1" \
  >"$root/boot/cmdline.txt"
on aarch64-rpi setup-boot >/dev/null || fail "setup-boot runs on an edited cmdline.txt"
expected="root=PARTUUID=$partuuid rw rootwait console=serial0,115200 console=tty1 fsck.repair=yes cma=256M loglevel=7 quiet"
for token in $kernel_defaults; do
  [[ " $expected " == *" ${token%%=*}"[=\ ]* ]] || expected+=" $token"
done
[[ $(cat "$root/boot/cmdline.txt") == "$expected" ]] || fail "an owner's tokens and values survive" "$(cat "$root/boot/cmdline.txt")"
pass "setup-boot keeps an owner's own kernel parameters and values, and adds nothing twice"

# A line missing ALARM's parameters gets them after root=; only the first line
# counts, as for the firmware.
reset_root
printf '%s\r\n%s\n' "console=serial0,115200 quiet" "root=/dev/sda1 single" >"$root/boot/cmdline.txt"
output=$(on aarch64-rpi setup-boot 2>&1) || fail "setup-boot runs on a two-line cmdline.txt" "$output"
expected="root=PARTUUID=$partuuid rw rootwait fsck.repair=yes console=serial0,115200 console=tty1 quiet"
for token in $kernel_defaults; do
  [[ $token == "quiet" ]] || expected+=" $token"
done
[[ $(cat "$root/boot/cmdline.txt") == "$expected" ]] || fail "a sparse cmdline.txt gets ALARM's parameters after root=" "$(cat "$root/boot/cmdline.txt")"
[[ $output == *"Dropping the lines after the first"* ]] || fail "setup-boot says it drops the lines the firmware never reads" "$output"
pass "setup-boot adds rw, rootwait and fsck.repair=yes when they are missing, and keeps only the line the firmware reads"

# The initramfs and KMS lines go in the block only while nothing outside it
# loads them on a Pi 400: a comment, [cm4] or [none] does not, [pi4] does.
reset_root
sed -i -e 's/^initramfs /#initramfs /' -e 's/^dtoverlay=vc4-kms-v3d$/#&/' "$root/boot/config.txt"
printf '%s\n' "[none]" "initramfs initramfs-linux.img followkernel" "[cm4]" "dtoverlay=vc4-kms-v3d" >>"$root/boot/config.txt"
on aarch64-rpi setup-boot >/dev/null || fail "setup-boot runs without ALARM's initramfs and KMS lines"
[[ $(block_of "$root/boot/config.txt") == $'[all]\ndisable_splash=1\ninitramfs initramfs-linux.img followkernel\ndtoverlay=vc4-kms-v3d' ]] ||
  fail "the block loads the initramfs and full KMS when nothing else does on this board" "$(block_of "$root/boot/config.txt")"
reset_root
sed -i -e '/^initramfs /d' -e '/^dtoverlay=vc4-kms-v3d$/d' "$root/boot/config.txt"
printf '%s\n' "[pi4]" "initramfs initramfs-linux.img followkernel" "dtoverlay=vc4-kms-v3d,cma-512" "[all]" >>"$root/boot/config.txt"
on aarch64-rpi setup-boot >/dev/null || fail "setup-boot runs with the lines under [pi4]"
[[ $(block_of "$root/boot/config.txt") == $'[all]\ndisable_splash=1' ]] ||
  fail "lines under [pi4] already load on a Pi 400" "$(block_of "$root/boot/config.txt")"
pass "setup-boot adds the initramfs and vc4-kms-v3d lines only when nothing outside its block loads them on a Pi 400"

# An existing block is replaced where it stands, so lines after it stay under
# its [all]; a second block goes, and a damaged one stops the run untouched.
reset_root
cat >>"$root/boot/config.txt" <<'TXT'

# BEGIN Omarchy
disable_splash=0
# END Omarchy
hdmi_enable_4kp60=1
# BEGIN Omarchy
dtoverlay=vc4-fkms-v3d
# END Omarchy
TXT
on aarch64-rpi setup-boot >/dev/null || fail "setup-boot runs on a config.txt with old blocks"
[[ $(sed -n '/^# BEGIN Omarchy$/,$p' "$root/boot/config.txt" | grep -v '^#') == $'[all]\ndisable_splash=1\nhdmi_enable_4kp60=1' ]] ||
  fail "the first block is replaced in place, the owner's line after it stays and the second block goes" "$(cat "$root/boot/config.txt")"
reset_root
printf '%s\n' "# BEGIN Omarchy" "[all]" "arm_boost=1" >>"$root/boot/config.txt"
before=$(fingerprint)
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *'opens a "# BEGIN Omarchy" block that no "# END Omarchy" closes'* ]] ||
  fail "an unclosed block stops setup-boot" "status $status: $output"
[[ $(fingerprint) == "$before" ]] || fail "an unclosed block leaves both files as they were"
pass "setup-boot replaces its block in place, drops a second one, and stops at a block it can't close"

# On an image's first boot the deferred setup rebuilds once, after its last
# step, so setup-boot only asks for it.
reset_root
rm "$root/boot/initramfs-linux.img"
on aarch64-rpi setup-boot image-first-boot >/dev/null || fail "setup-boot runs on an image's first boot"
[[ -e $root/var/lib/omarchy/image/boot-rebuild ]] || fail "an image's first boot asks for the initramfs rebuild"
! grep -q '^mkinitcpio' "$calls" || fail "an image's first boot builds no initramfs itself" "$(cat "$calls")"
[[ $(cat "$root/boot/cmdline.txt") == "$alarm_cmdline $kernel_defaults" ]] || fail "an image's first boot sets up cmdline.txt too"
reset_root
rm -r "$root/var/lib/omarchy/image"
status=0
output=$(on aarch64-rpi setup-boot image-first-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"is for an image's first boot"* ]] || fail "image-first-boot outside an image fails" "status $status: $output"
pass "with image-first-boot, setup-boot asks for the first boot's rebuild instead of building"

# An initramfs older than its configuration is rebuilt, and a failed rebuild
# fails the operation.
reset_root
touch "$root/etc/mkinitcpio.conf.d/00-omarchy-hooks.conf"
touch -d @1600000000 "$root/boot/initramfs-linux.img"
on aarch64-rpi setup-boot >/dev/null || fail "setup-boot rebuilds a stale initramfs"
[[ $(grep '^mkinitcpio' "$calls") == "mkinitcpio -P" ]] || fail "an initramfs older than a drop-in is rebuilt" "$(cat "$calls")"
reset_root
touch -d @1600000000 "$root/boot/initramfs-linux.img"
touch "$state/mkinitcpio-fails"
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"mkinitcpio -P could not rebuild the initramfs"* ]] || fail "a failed rebuild fails setup-boot" "status $status: $output"
pass "setup-boot rebuilds an initramfs older than mkinitcpio's configuration, and fails with the rebuild"

# Nothing changes when the root's PARTUUID or Omarchy's kernel parameters
# can't be trusted, or a boot file is missing.
reset_root
rm "$state/partuuid"
before=$(fingerprint)
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"cannot find the PARTUUID of the partition mounted at /"* ]] ||
  fail "setup-boot stops without the root's PARTUUID" "status $status: $output"
echo "6c586e13-02 rw" >"$state/partuuid"
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *'findmnt reports "6c586e13-02 rw"'* ]] || fail "setup-boot refuses a PARTUUID that is not one" "status $status: $output"
echo "$partuuid" >"$state/partuuid"
chmod g+w "$root/etc/limine-entry-tool.d/omarchy-defaults.conf"
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"refusing $root/etc/limine-entry-tool.d/omarchy-defaults.conf"* ]] ||
  fail "setup-boot refuses kernel parameters someone else could write" "status $status: $output"
chmod g-w "$root/etc/limine-entry-tool.d/omarchy-defaults.conf"
chmod o+w "$root/etc/limine-entry-tool.d"
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"refusing"* ]] || fail "setup-boot refuses kernel parameters in a directory someone else could write" "status $status: $output"
chmod o-w "$root/etc/limine-entry-tool.d"
[[ $(fingerprint) == "$before" ]] || fail "a refused setup-boot changes nothing"
mv "$root/boot/cmdline.txt" "$tmp/cmdline.txt"
status=0
output=$(on aarch64-rpi setup-boot 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"$root/boot/cmdline.txt is missing"* ]] || fail "setup-boot needs cmdline.txt" "status $status: $output"
pass "setup-boot changes nothing without the root's PARTUUID, trusted kernel parameters or both boot files"

# ── update-verify ────────────────────────────────────────────────────────────

# Runs update-verify, which must fail saying $2.
verify_fails() {
  local description=$1 expected=$2 status=0 output

  output=$(on aarch64-rpi update-verify 2>&1) || status=$?
  (( status == 1 )) && [[ $output == *"$expected"* ]] || fail "update-verify fails when $description" "status $status: $output"
}

# ALARM's own root=/dev/mmcblk0p2 boots this card too, and other kernels'
# module directories don't count.
reset_root
mkdir -p "$root/usr/lib/modules/7.2.8-1-omarchy"
echo linux-omarchy >"$root/usr/lib/modules/7.2.8-1-omarchy/pkgbase"
before=$(fingerprint)
output=$(on aarch64-rpi update-verify 2>&1) || fail "update-verify passes ALARM's own boot files" "$output"
[[ $(fingerprint) == "$before" ]] || fail "update-verify changes nothing"
pass "update-verify passes ALARM's boot files for the installed linux-rpi and changes nothing"

reset_root
rm "$root/usr/lib/modules/$kversion/pkgbase"
verify_fails "linux-rpi is not installed" "linux-rpi is not installed"
reset_root
mkdir -p "$root/usr/lib/modules/6.18.50-1-rpi"
echo linux-rpi >"$root/usr/lib/modules/6.18.50-1-rpi/pkgbase"
verify_fails "two kernels claim to be linux-rpi" "more than one kernel claims to be linux-rpi (6.18.50-1-rpi $kversion"
reset_root
: >"$root/boot/kernel8.img"
verify_fails "kernel8.img is empty" "$root/boot/kernel8.img is missing or empty"
reset_root
rm "$root/boot/kernel8.img"
verify_fails "kernel8.img is missing" "$root/boot/kernel8.img is missing or empty"
pass "update-verify fails without exactly one installed linux-rpi or with an empty kernel8.img"

reset_root
rm "$root/boot/initramfs-linux.img"
verify_fails "the initramfs is missing" "$root/boot/initramfs-linux.img is missing"
reset_root
rm "$state/listing"
verify_fails "lsinitcpio cannot read the initramfs" "lsinitcpio cannot list $root/boot/initramfs-linux.img"
reset_root
sed -i "s/$kversion/6.18.50-1-rpi/" "$state/listing"
verify_fails "the initramfs was built for another kernel" \
  "$root/boot/initramfs-linux.img was not built for linux-rpi $kversion (it holds modules for 6.18.50-1-rpi)"
reset_root
grep -v '^usr/lib/modules' "$state/listing" >"$state/listing.new" && mv "$state/listing.new" "$state/listing"
verify_fails "the initramfs holds no kernel's modules" "(it holds modules for no kernel)"
pass "update-verify fails unless the initramfs holds the installed linux-rpi's modules"

reset_root
sed -i 's/^initramfs /#initramfs /' "$root/boot/config.txt"
verify_fails "config.txt loads no initramfs" "$root/boot/config.txt has no active initramfs line"
reset_root
sed -i '/^initramfs /d' "$root/boot/config.txt"
printf '%s\n' "[cm4]" "initramfs initramfs-linux.img followkernel" "[all]" >>"$root/boot/config.txt"
verify_fails "only another board loads the initramfs" "$root/boot/config.txt has no active initramfs line"
reset_root
sed -i '/^initramfs /d' "$root/boot/config.txt"
printf '%s\n' "[pi400]" "initramfs initramfs-linux.img followkernel" >>"$root/boot/config.txt"
output=$(on aarch64-rpi update-verify 2>&1) || fail "an initramfs line under [pi400] loads on a Pi 400" "$output"
reset_root
echo "initramfs initramfs-custom.img followkernel" >>"$root/boot/config.txt"
verify_fails "config.txt loads another initramfs" "loads the initramfs initramfs-custom.img, not initramfs-linux.img"
reset_root
rm "$root/boot/config.txt"
verify_fails "config.txt is missing" "$root/boot/config.txt is missing"
pass "update-verify fails unless config.txt's active initramfs line loads initramfs-linux.img"

reset_root
rm "$root/boot/cmdline.txt"
verify_fails "cmdline.txt is missing" "$root/boot/cmdline.txt is missing"
reset_root
echo "rw rootwait console=tty1" >"$root/boot/cmdline.txt"
verify_fails "cmdline.txt names no root" "$root/boot/cmdline.txt names no root="
reset_root
printf '%s\n' "rw rootwait console=tty1" "root=PARTUUID=$partuuid" >"$root/boot/cmdline.txt"
verify_fails "root= is only on a line the firmware never reads" "$root/boot/cmdline.txt names no root="
reset_root
echo "root=PARTUUID=deadbeef-02 rw rootwait" >"$root/boot/cmdline.txt"
verify_fails "root= matches no device" "root=PARTUUID=deadbeef-02 in $root/boot/cmdline.txt matches no device"
reset_root
echo "root=/dev/mmcblk1p2 rw rootwait" >"$root/boot/cmdline.txt"
verify_fails "root= names a missing device" "root=/dev/mmcblk1p2 in $root/boot/cmdline.txt matches no device"
reset_root
echo "root=PARTUUID=6c586e13-01 rw rootwait" >"$root/boot/cmdline.txt"
verify_fails "root= is the boot partition" "is /dev/mmcblk0p1, but / is mounted from /dev/mmcblk0p2"
reset_root
echo "root=LABEL=data rw rootwait" >"$root/boot/cmdline.txt"
verify_fails "root= is another disk" "root=LABEL=data in $root/boot/cmdline.txt is /dev/sda1, but / is mounted from /dev/mmcblk0p2"
reset_root
echo "root=/dev/sda1 rw rootwait root=PARTUUID=$partuuid" >"$root/boot/cmdline.txt"
output=$(on aarch64-rpi update-verify 2>&1) || fail "the last root= is the one the kernel takes" "$output"
pass "update-verify fails unless the first line of cmdline.txt boots the device mounted at /"

# A second card flashed from the same image carries the root's PARTUUID too, so
# the next boot may mount either. That is the cause, whichever one findfs picks
# now, and setup-boot would not fix it.
for order in after before; do
  reset_root
  echo "root=PARTUUID=$partuuid rw rootwait" >"$root/boot/cmdline.txt"
  touch "$root/dev/sda2"
  if [[ $order == "after" ]]; then
    echo "PARTUUID=$partuuid /dev/sda2" >>"$state/devices"
  else
    sed -i "1i PARTUUID=$partuuid /dev/sda2" "$state/devices"
  fi
  status=0
  output=$(on aarch64-rpi update-verify 2>&1) || status=$?
  (( status == 1 )) && [[ $output == *"names the partition mounted at / (/dev/mmcblk0p2), and also /dev/sda2: another attached disk"* &&
    $output == *"Disconnect that disk before rebooting"* && $output != *setup-boot* ]] ||
    fail "update-verify blames another disk that carries the root's PARTUUID (found $order the root)" "status $status: $output"
done
pass "update-verify fails when another disk carries the root's PARTUUID, and says so"

# Every failure is explained, not just the first.
reset_root
: >"$root/boot/kernel8.img"
rm "$root/boot/config.txt"
echo "rw" >"$root/boot/cmdline.txt"
status=0
output=$(on aarch64-rpi update-verify 2>&1) || status=$?
(( status == 1 && $(grep -c '^Error: ' <<<"$output") == 3 )) || fail "update-verify explains each failure" "status $status: $output"
[[ $output == *"fix the errors above before rebooting"* ]] || fail "update-verify says what a failure means" "$output"
pass "update-verify explains every failure at once"

# ── grow-root ────────────────────────────────────────────────────────────────

growth="lsblk -no KNAME,PKNAME /dev/mmcblk0p2
sfdisk --dump /dev/mmcblk0
lsblk -bdno SIZE /dev/mmcblk0"
lookups="findmnt -nvo SOURCE /
findmnt -no FSTYPE /
$growth"

# Whether grow-root ran anything that changes a partition or a filesystem.
changed_disk() {
  grep -v '^sfdisk --dump ' "$calls" | grep -q '^sfdisk\|^partx\|^resize2fs'
}

reset_root
output=$(on aarch64-rpi grow-root 2>&1) || fail "grow-root grows the root" "$output"
[[ $(cat "$calls") == "$lookups
sfdisk --no-reread --no-tell-kernel --wipe-partitions never -N 2 /dev/mmcblk0
partx -u -n 2 /dev/mmcblk0
resize2fs /dev/mmcblk0p2
systemctl --no-reload disable omarchy-rpi-grow-root.service" ]] ||
  fail "grow-root moves partition 2's end to the end of the disk, tells the kernel, grows the filesystem and disables itself" "$(cat "$calls")"
[[ $(cat "$state/sfdisk-input") == ",+" ]] || fail "sfdisk keeps partition 2's start and takes all the space after it" "$(cat "$state/sfdisk-input")"
[[ ! -e $root/var/lib/pimarchy/grow-root-pending ]] || fail "grow-root removes its marker when done"
[[ $output == *"Growing /dev/mmcblk0p2 by 22243 MiB to fill /dev/mmcblk0"* ]] || fail "grow-root says how much it grows" "$output"
: >"$calls"
output=$(on aarch64-rpi grow-root 2>&1) || fail "grow-root runs again" "$output"
[[ ! -s $calls ]] || fail "without its marker grow-root does nothing" "$(cat "$calls")"
pass "grow-root grows partition 2 and its filesystem to the end of the disk, then retires"

# No free space after partition 2: the end of the disk, the next partition, or
# less than a MiB. The table stays as it is, and resize2fs makes sure the
# filesystem fills the partition (a no-op once it does).
for case in end next sliver; do
  reset_root
  case $case in
    end) echo $(( (1050624 + 15728640) * 512 )) >"$state/disk-bytes" ;;
    next) echo "/dev/mmcblk0p3 : start=    16779264, size=     2097152, type=83" >>"$state/dump" ;;
    sliver) echo $(( (1050624 + 15728640 + 1000) * 512 )) >"$state/disk-bytes" ;;
  esac
  output=$(on aarch64-rpi grow-root 2>&1) || fail "grow-root runs with no free space ($case)" "$output"
  [[ $(cat "$calls") == "$lookups
resize2fs /dev/mmcblk0p2
systemctl --no-reload disable omarchy-rpi-grow-root.service" ]] ||
    fail "grow-root leaves the partition table alone with no free space ($case)" "$(cat "$calls")"
  [[ $output == *"No free space follows /dev/mmcblk0p2"* && ! -e $root/var/lib/pimarchy/grow-root-pending ]] ||
    fail "grow-root retires with no free space ($case)" "$output"
done
pass "with no free space after partition 2, grow-root changes no partition and only makes sure the filesystem fills it"

# A failed step keeps the marker for the next boot.
for tool in sfdisk partx resize2fs; do
  reset_root
  touch "$state/$tool-fails"
  status=0
  output=$(on aarch64-rpi grow-root 2>&1) || status=$?
  (( status == 1 )) && [[ -e $root/var/lib/pimarchy/grow-root-pending ]] || fail "a failed $tool keeps grow-root pending" "status $status: $output"
  ! grep -q '^systemctl' "$calls" || fail "a failed $tool leaves the unit enabled" "$(cat "$calls")"
done
grep -q '^resize2fs' "$calls" || fail "resize2fs ran in the last case"
reset_root
touch "$state/sfdisk-fails"
on aarch64-rpi grow-root >/dev/null 2>&1 || true
! grep -q '^partx\|^resize2fs' "$calls" || fail "nothing runs after a failed sfdisk" "$(cat "$calls")"
reset_root
touch "$state/systemctl-fails"
output=$(on aarch64-rpi grow-root 2>&1) || fail "a unit that won't disable doesn't fail a grown root" "$output"
[[ ! -e $root/var/lib/pimarchy/grow-root-pending && $output == *"without its marker it no longer runs"* ]] ||
  fail "the marker goes even when the unit won't disable" "$output"
pass "a failed sfdisk, partx or resize2fs keeps grow-root pending for the next boot"

# A root this layout doesn't describe is left alone for good.
for case in btrfs nfs gpt partition3 whole-disk; do
  reset_root
  case $case in
    btrfs) echo btrfs >"$state/fstype" ;;
    nfs) echo "server:/export" >"$state/source" ;;
    gpt) sed -i 's/^label: dos$/label: gpt/' "$state/dump" ;;
    partition3) echo 3 >"$root/sys/class/block/mmcblk0p2/partition" ;;
    whole-disk) : >"$state/pkname" ;;
  esac
  output=$(on aarch64-rpi grow-root 2>&1) || fail "grow-root leaves a $case root alone" "$output"
  [[ $output == "Not growing the root filesystem: "* ]] || fail "grow-root says why it leaves a $case root alone" "$output"
  ! changed_disk || fail "grow-root changes nothing on a $case root" "$(cat "$calls")"
  [[ ! -e $root/var/lib/pimarchy/grow-root-pending ]] || fail "grow-root retires on a $case root"
done
pass "grow-root leaves a root that is not ext4 on partition 2 of an MBR disk alone, and retires"

# A table type or partition number it can't read yet is no layout to leave
# alone: the run fails and keeps the marker for the next boot.
for case in no-label no-partition empty-partition; do
  reset_root
  case $case in
    no-label) sed -i '/^label:/d' "$state/dump" ;;
    no-partition) rm "$root/sys/class/block/mmcblk0p2/partition" ;;
    empty-partition) : >"$root/sys/class/block/mmcblk0p2/partition" ;;
  esac
  status=0
  output=$(on aarch64-rpi grow-root 2>&1) || status=$?
  (( status == 1 )) && [[ -e $root/var/lib/pimarchy/grow-root-pending ]] ||
    fail "grow-root keeps its marker when it can't read the layout ($case)" "status $status: $output"
  ! changed_disk && ! grep -q '^systemctl' "$calls" || fail "grow-root changes nothing when it can't read the layout ($case)" "$(cat "$calls")"
done
pass "grow-root reads the layout from the partition table and sysfs, not udev, and retries what it can't read yet"

# The unit runs grow-root in early boot, only while the image's marker is there.
unit=$scripts/omarchy-rpi-grow-root.service
grep -qx 'ConditionPathExists=/var/lib/pimarchy/grow-root-pending' "$unit" &&
  grep -qx 'ExecStart=/usr/lib/omarchy/rpi-boot/grow-root' "$unit" &&
  grep -qx 'DefaultDependencies=no' "$unit" && grep -qx 'After=systemd-remount-fs.service' "$unit" &&
  grep -qx 'Before=local-fs.target omarchy-provision-hardware.service shutdown.target' "$unit" &&
  grep -qx 'WantedBy=local-fs.target' "$unit" || fail "the unit runs grow-root early, while its marker exists"
grep -qF 'marker=$fixture/var/lib/pimarchy/grow-root-pending' "$scripts/grow-root" || fail "grow-root removes the unit's marker"
for script in setup-boot update-verify grow-root headless; do
  [[ -x $scripts/$script && $(head -n 1 "$scripts/$script") == "#!/bin/bash -p" ]] || fail "$script is a privileged Bash executable"
done
pass "the grow-root unit runs grow-root in early boot while its marker exists, and every Pi boot script is a privileged Bash executable"

# ── headless ─────────────────────────────────────────────────────────────────

# A first boot still pending, with the owner form's rules, two of the countries
# wireless-regdb lists, a timezone and a zoneinfo file that is none, a system
# account, and the image's pimarchy.txt on /boot.
settings=$root/boot/pimarchy.txt
status_file=$root/boot/pimarchy-status.txt
provisioning=$root/var/lib/omarchy/provisioning
profile=$root/etc/NetworkManager/system-connections/pimarchy-wifi.nmconnection
reset_headless() {
  reset_root
  mkdir -p "$provisioning" "$root/usr/share/omarchy/install/provisioning" "$root/etc/conf.d" \
    "$root/usr/share/zoneinfo/Europe" "$root/proc/sys/kernel"
  : >"$provisioning/pending"
  cp "$ROOT/install/provisioning/setup-form.sh" "$root/usr/share/omarchy/install/provisioning/"
  printf '%s\n' '#WIRELESS_REGDOM="DE"' '#WIRELESS_REGDOM="GB"' >"$root/etc/conf.d/wireless-regdom"
  touch "$root/usr/share/zoneinfo/Europe/London" "$root/usr/share/zoneinfo/posixrules"
  printf '%s\n' '# tzdata.zi' 'Z Europe/London -0:1:15 - LMT 1847 D' 'L Europe/London GB' >"$root/usr/share/zoneinfo/tzdata.zi"
  printf '%s\n' 'root:x:0:0::/root:/bin/bash' 'sys:x:3:3::/:/usr/bin/nologin' >"$root/etc/passwd"
  printf '%s\n' 'root:x:0:' 'sys:x:3:' 'wheel:x:998:' >"$root/etc/group"
  echo omarchy | tee "$root/etc/hostname" >"$root/proc/sys/kernel/hostname"
  cp "$scripts/pimarchy.txt" "$settings"
  chmod -R go-w "$root"
}

# As the image ships it, every setting empty: nothing happens.
reset_headless
before=$(fingerprint)
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs with the image's pimarchy.txt" "$output"
[[ $(fingerprint) == "$before" && ! -s $calls ]] || fail "the image's pimarchy.txt changes nothing" "$(cat "$calls")"
pass "pimarchy.txt as the image ships it changes nothing"

# Root sources the form's rules, so they must be root's alone.
reset_headless
printf 'HOSTNAME=pi400\n' >"$settings"
chmod g+w "$root/usr/share/omarchy/install/provisioning/setup-form.sh"
before=$(fingerprint)
status=0
output=$(on aarch64-rpi headless 2>&1) || status=$?
(( status == 1 )) && [[ $output == *"refusing $root/usr/share/omarchy/install/provisioning/setup-form.sh"* && $(fingerprint) == "$before" ]] ||
  fail "headless refuses form rules someone else could write" "status $status: $output"
pass "headless refuses form rules someone else could write, and changes nothing"

# Root reads neither the fixture root nor the stubs: on a fixture it would act
# on, as root it finds no first boot pending on this machine and stops.
if unshare --user --map-root-user true 2>/dev/null; then
  reset_headless
  printf 'HOSTNAME=pi400\n' >"$settings"
  before=$(fingerprint)
  mkdir -p "$tmp/as-root"
  printf '#!/bin/bash\nexit 0\n' >"$tmp/as-root/yes"
  chmod +x "$tmp/as-root/yes"
  sed "s|/usr/bin/omarchy-hw-aarch64-rpi|$tmp/as-root/yes|" "$scripts/headless" >"$tmp/as-root/headless"
  chmod +x "$tmp/as-root/headless"
  output=$(OMARCHY_RPI_BOOT_ROOT="$root" PATH="$stubs:$PATH" unshare --user --map-root-user "$tmp/as-root/headless" 2>&1) || true
  [[ $(fingerprint) == "$before" && ! -s $calls ]] || fail "root ignores headless's fixture root and the stubs on its PATH" "$output"
  pass "root ignores headless's fixture root and the stubs on its PATH"
else
  skip "no unprivileged user namespace; skipping the check that root ignores headless's fixture root"
fi

# Filled in on Windows: a byte order mark, CRLF line ends, a lower-case key,
# spaces around an "=", and quotes keeping a password's own spaces.
# NetworkManager takes a passphrase in UTF-8, so one beyond ASCII works too.
reset_headless
{
  printf '\xef\xbb\xbf# Filled in on Windows\r\n'
  printf '%s\r\n' 'WIFI_SSID = Café;Net' 'wifi_password=" s3crét\pass "' 'WIFI_COUNTRY=gb' 'WIFI_HIDDEN=Yes' \
    'USERNAME=pi4' 'PASSWORD=hunter2!' 'FULL_NAME=Ada Lovelace' 'EMAIL=ada@example.com' 'HOSTNAME=pi400' \
    'TIMEZONE=Europe/London' 'KEYBOARD=uk' 'SSH_KEY=ssh-ed25519 AAAAC3Nz ada@laptop'
} >"$settings"
size=$(stat -c %s "$settings")
output=$(on aarch64-rpi headless 2>&1) || fail "headless applies a filled-in pimarchy.txt" "$output"
[[ $(sed 's/^uuid=.*/uuid=/' "$profile") == '[connection]
id=pimarchy-wifi
uuid=
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=67;97;102;195;169;59;78;101;116;
hidden=true

[wifi-security]
key-mgmt=wpa-psk
psk=\ss3crét\\pass\s

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto' && $(stat -c %a "$profile") == "600" ]] ||
  fail "NetworkManager gets a root-only profile naming the network by its bytes, with the password escaped" "$(cat "$profile")"
[[ $(cat "$root/etc/conf.d/wireless-regdom") == $'#WIRELESS_REGDOM="DE"\nWIRELESS_REGDOM="GB"' ]] && grep -q '^set-wireless-regdom' "$calls" ||
  fail "the radio takes the owner's country" "$(cat "$root/etc/conf.d/wireless-regdom")"
[[ $(<"$root/etc/hostname") == "pi400" && $(<"$root/proc/sys/kernel/hostname") == "pi400" &&
  $(readlink "$root/etc/localtime") == "../usr/share/zoneinfo/Europe/London" ]] ||
  fail "the machine takes its name now and its timezone" "$(<"$root/etc/hostname") $(readlink "$root/etc/localtime")"
[[ $(<"$provisioning/answers") == $'USERNAME=pi4\nPASSWORD=hunter2!\nFULL_NAME=Ada Lovelace\nEMAIL=ada@example.com\nHOSTNAME=pi400\nTIMEZONE=Europe/London\nKEYBOARD=uk' &&
  $(stat -c %a "$provisioning/answers") == "600" ]] || fail "first-boot setup gets the account's answers, for root alone" "$(cat "$provisioning/answers")"
[[ $(<"$provisioning/authorized_keys") == "ssh-ed25519 AAAAC3Nz ada@laptop" ]] &&
  grep -qx 'PasswordAuthentication no' "$root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf" ||
  fail "the key is staged for the account, and password logins go"
grep -qx 'systemctl --no-reload enable sshd.service' "$calls" && grep -qx 'systemctl start --no-block sshd.service' "$calls" &&
  grep -qx 'ufw limit 22/tcp comment omarchy-sshd' "$calls" || fail "SSH is on and its port open" "$(cat "$calls")"
[[ $(stat -c %s "$settings") == "$size" ]] && ! grep -q 'hunter2\|s3cr' "$settings" &&
  (( $(grep -c $'^# *\r$' "$settings") == 2 )) && grep -q $'^WIFI_SSID = Café;Net\r$' "$settings" ||
  fail "the passwords are blanked in place, and nothing else in pimarchy.txt changes" "$(cat -A "$settings")"
[[ $(<"$status_file") == *"ssh pi4@pi400.local"* && $(<"$status_file") != *Skipped* ]] ||
  fail "the status file says how to reach the Pi, and skips nothing" "$(cat "$status_file")"
pass "a filled-in pimarchy.txt sets up Wi-Fi, the machine, the account's answers and SSH, then loses its passwords"

# The next boot finds the passwords blanked and keeps what the first one set up.
cp "$profile" "$tmp/profile"
cp "$provisioning/answers" "$tmp/answers"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs again" "$output"
cmp -s "$profile" "$tmp/profile" && cmp -s "$provisioning/answers" "$tmp/answers" ||
  fail "a rerun keeps the Wi-Fi profile and the account's answers"
[[ $(<"$status_file") == *'Wi-Fi network "Café;Net", set up on an earlier boot'* &&
  $(<"$status_file") == *"account pi4, set up on an earlier boot"* && $(<"$status_file") != *Skipped* ]] ||
  fail "a rerun reports what an earlier boot set up" "$(cat "$status_file")"
pass "a rerun after the passwords are blanked keeps the Wi-Fi profile and the account"

# The account's other answers follow the file, and keys taken out of it go.
sed -i -e 's/^HOSTNAME=pi400/HOSTNAME=pi4b/' -e '/^SSH_KEY=/d' "$settings"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs again with another hostname" "$output"
[[ $(<"$provisioning/answers") == $'USERNAME=pi4\nPASSWORD=hunter2!\nFULL_NAME=Ada Lovelace\nEMAIL=ada@example.com\nHOSTNAME=pi4b\nTIMEZONE=Europe/London\nKEYBOARD=uk' &&
  ! -e $provisioning/authorized_keys && ! -e $root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf ]] ||
  fail "a rerun keeps the account's password, takes the file's hostname, and drops the keys it no longer lists" "$(cat "$provisioning/answers")"
cp "$provisioning/answers" "$tmp/answers"
pass "a rerun keeps the account's password, follows the file's other settings, and drops keys taken out of it"

# A rerun that names another network or account, without its password, keeps
# what the first boot set up and says so.
sed -i -e 's/^WIFI_SSID = .*/WIFI_SSID=Other\r/' -e 's/^USERNAME=.*/USERNAME=ada\r/' "$settings"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs again with other names" "$output"
cmp -s "$profile" "$tmp/profile" && cmp -s "$provisioning/answers" "$tmp/answers" ||
  fail "a rerun naming another network or account keeps the first boot's"
[[ $(<"$status_file") == *"- WIFI_SSID: an earlier boot set up another network"* &&
  $(<"$status_file") == *"- USERNAME: an earlier boot set up the account pi4"* && $(<"$status_file") == *"ssh pi4@pi4b.local"* ]] ||
  fail "a rerun naming another network or account says the first boot's stay" "$(cat "$status_file")"
pass "a rerun naming another network or account without its password keeps, and reports, what the first boot set up"

# After owner setup created the account and failed, a rerun gives that account
# a new password, and stages no other.
sed -i 's/^USERNAME=.*/USERNAME=pi4\r/' "$settings"
printf 'PASSWORD=n3w-pass\r\n' >>"$settings"
echo 'pi4:x:1000:1000::/home/pi4:/bin/bash' >>"$root/etc/passwd"
echo pi4 >"$provisioning/setup-user"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs after owner setup pinned the account" "$output"
grep -qx 'PASSWORD=n3w-pass' "$provisioning/answers" && grep -qx 'USERNAME=pi4' "$provisioning/answers" ||
  fail "a rerun gives the pinned account its new password" "$(cat "$provisioning/answers")"
sed -i 's/^USERNAME=.*/USERNAME=bob\r/' "$settings"
printf 'PASSWORD=b0b-pass\r\n' >>"$settings"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs with another account after the pin" "$output"
grep -qx 'USERNAME=pi4' "$provisioning/answers" && [[ $(<"$status_file") == *"- USERNAME: an earlier boot already created the account pi4"* ]] ||
  fail "a rerun stages no account but the pinned one" "$(cat "$status_file")"
pass "after owner setup pinned its account, a rerun can change its password but stage no other"

# The README's block pasted above the template's empty lines: an empty repeat
# doesn't undo a value, and every password line goes, empty ones too, so the
# next boot keeps the network's password rather than taking it for open.
reset_headless
{
  printf '%s\n' 'WIFI_SSID=Home network' 'WIFI_PASSWORD=correct horse battery' 'WIFI_COUNTRY=GB' 'USERNAME=ada' \
    'PASSWORD=a long password' 'HOSTNAME=pi400'
  cat "$scripts/pimarchy.txt"
} >"$settings"
output=$(on aarch64-rpi headless 2>&1) || fail "headless reads a block pasted above the template" "$output"
grep -qx 'psk=correct\\shorse\\sbattery' "$profile" && grep -qx 'USERNAME=ada' "$provisioning/answers" &&
  ! grep -q '^WIFI_PASSWORD=\|^PASSWORD=\|^PASSWORD_HASH=' "$settings" ||
  fail "a pasted block's values win over the template's empty lines, and every password line goes" "$(cat "$profile")"
cp "$profile" "$tmp/profile"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs again after a pasted block" "$output"
cmp -s "$profile" "$tmp/profile" || fail "the next boot keeps the network's password" "$(cat "$profile")"
pass "a block pasted above the template's empty lines is used, and the next boot keeps the network's password"

# An open network, an account by its password's hash, password logins kept on
# with a key, and a last line with no line end, which keeps its length.
reset_headless
printf '%s\n' 'WIFI_SSID=Cafe' 'WIFI_PASSWORD=' 'USERNAME=ada' 'PASSWORD_HASH=$6$salt$hash' 'SSH_PASSWORD_LOGIN=yes' \
  'SSH_KEY=ssh-ed25519 AAAAC3Nz ada@laptop' >"$settings"
printf 'PASSWORD=unused-pass' >>"$settings"
size=$(stat -c %s "$settings")
output=$(on aarch64-rpi headless 2>&1) || fail "headless sets up an open network and a hashed password" "$output"
! grep -q 'wifi-security' "$profile" && grep -qx 'PASSWORD_HASH=$6$salt$hash' "$provisioning/answers" &&
  ! grep -q '^PASSWORD=' "$provisioning/answers" && [[ ! -e $root/etc/ssh/sshd_config.d/10-omarchy-hardening.conf ]] ||
  fail "an open network has no password, the hash goes to owner setup, and password logins stay on" "$(cat "$provisioning/answers")"
[[ $(stat -c %s "$settings") == "$size" && -n $(tail -c 1 "$settings") ]] && ! grep -q 'unused-pass\|salt' "$settings" ||
  fail "a password on a last line with no line end is blanked in place" "$(cat -A "$settings")"
pass "an open network, a hashed password, password logins kept on, and a last line with no line end"

# What pi/flash writes into pimarchy.txt reaches the Pi as it was typed: quotes,
# backslashes, "=" and "#" in passwords, spaces at their ends, and non-ASCII.
reset_headless
wifi_password=' "q\\=#é" '
password='"pa=ss#\\word"'
bash -c 'source "$1"
  settings=("WIFI_SSID=Home Net 5G" "WIFI_PASSWORD=$2" "WIFI_COUNTRY=GB" "USERNAME=ada" "PASSWORD=$3"
    "FULL_NAME=Ada King" "EMAIL=ada@example.com" "HOSTNAME=pi400" "KEYBOARD=uk")
  fill_settings "$4"' bash "$ROOT/pi/flash" "$wifi_password" "$password" "$settings" ||
  fail "pi/flash fills in pimarchy.txt"
output=$(on aarch64-rpi headless 2>&1) || fail "headless reads the pimarchy.txt pi/flash filled in" "$output"
psk=$(sed -n 's/^psk=//p' "$profile")
[[ $(sed -n 's/^PASSWORD=//p' "$provisioning/answers") == "$password" &&
  $psk == "$(printf '%s' "$wifi_password" | sed 's/\\/\\\\/g; s/ /\\s/g')" &&
  $(<"$status_file") != *Skipped* ]] ||
  fail "the Pi gets the passwords pi/flash was given, as they were typed" "$(cat "$provisioning/answers" "$profile" "$status_file")"
pass "what pi/flash writes into pimarchy.txt, quotes, backslashes, = and # in passwords included, reaches the Pi as typed"

# What the owner form wouldn't take is skipped and reported, and changes
# nothing: an account the image has, a zoneinfo file timedated doesn't list.
# Lines it can't read could hold a password, so they are blanked too.
reset_headless
printf '%s\n' 'WIFI_SSID=home' 'WIFI_PASSWORD=short' 'WIFI_COUNTRY=XX' 'USERNAME=wheel' 'PASSWORD=hunter2!' 'HOSTNAME=-bad-' \
  'TIMEZONE=posixrules' 'KEYBOARD=klingon' 'SSH_KEY=not a key' 'WIFI_PASWORD=typo1234' 'secret on its own' \
  'PASSWORD: Zm9vYmFy=' 'USERNAME PASSWORD=joined1234' >"$settings"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs with settings it can't use" "$output"
[[ ! -e $profile && ! -e $provisioning/answers && ! -e $provisioning/authorized_keys && ! -e $root/etc/localtime &&
  ! -e $root/etc/ssh && $(<"$root/etc/hostname") == "omarchy" ]] || fail "settings it can't use change nothing"
! grep -q 'systemctl\|ufw\|set-wireless-regdom' "$calls" || fail "nothing turns on for settings it can't use" "$(cat "$calls")"
for item in "WIFI_PASSWORD: 8 to 63" "WIFI_COUNTRY: no country" "USERNAME: the image already has an account or group named wheel" \
  "HOSTNAME: letters" "TIMEZONE: no timezone is named posixrules" "KEYBOARD: no layout is named klingon" \
  "SSH_KEY on line 9: not a public key" "line 10: there is no setting WIFI_PASWORD" 'line 11: no "="' \
  "line 12: no setting this knows" "line 13: no setting this knows"; do
  [[ $(<"$status_file") == *"- $item"* ]] || fail "the status file reports: $item" "$(cat "$status_file")"
done
[[ $(<"$status_file") != *ZM9V* && $(<"$status_file") != *"not a key"* ]] ||
  fail "the status file repeats nothing from a line it can't read" "$(cat "$status_file")"
! grep -q 'hunter2\|short\|typo1234\|secret\|Zm9v\|joined' "$settings" && grep -qx 'USERNAME=wheel' "$settings" ||
  fail "passwords and lines it can't read are blanked, even unused" "$(cat "$settings")"
pass "settings the owner form wouldn't take are skipped, reported and change nothing"

# A step that fails still blanks the passwords and says so.
reset_headless
printf '%s\n' 'HOSTNAME=pi400' 'WIFI_SSID=home' 'WIFI_PASSWORD=password1' >"$settings"
chmod a-w "$root/proc/sys/kernel/hostname"
status=0
output=$(on aarch64-rpi headless 2>&1) || status=$?
(( status != 0 )) && ! grep -q password1 "$settings" && [[ $(<"$status_file") == *"setup stopped at an error"* ]] ||
  fail "a failed step still blanks the passwords and reports the error" "status $status: $output"
pass "a run that fails partway still blanks the passwords and reports the error"

# A file saved as UTF-16 parses with its NUL bytes dropped, but can't be blanked
# line by line: it is used for nothing, and kept as its owner wrote it.
reset_headless
printf 'WIFI_SSID=home\r\nWIFI_PASSWORD=password1\r\n' | iconv -f UTF-8 -t UTF-16 >"$settings"
cp "$settings" "$tmp/utf16"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs with a UTF-16 pimarchy.txt" "$output"
cmp -s "$settings" "$tmp/utf16" && [[ ! -e $profile && ! -s $calls ]] ||
  fail "a UTF-16 pimarchy.txt changes nothing" "$(cat "$calls")"
[[ $(<"$status_file") == *"pimarchy.txt: unread, since it holds NUL bytes"* ]] ||
  fail "the status file says to save pimarchy.txt as plain text" "$(cat "$status_file")"
pass "a pimarchy.txt saved as UTF-16 is used for nothing, kept, and reported"

# Nor can one whose lines end in a CR alone, as old Mac editors save it.
reset_headless
printf 'WIFI_SSID=home\rWIFI_PASSWORD=password1\r' >"$settings"
cp "$settings" "$tmp/lone-cr"
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs with lone CR line ends" "$output"
cmp -s "$settings" "$tmp/lone-cr" && [[ ! -e $profile && ! -s $calls && $(<"$status_file") == *"its lines end in a CR alone"* ]] ||
  fail "a pimarchy.txt with lone CR line ends is used for nothing, kept, and reported" "$(cat "$status_file")"
pass "a pimarchy.txt with lone CR line ends is used for nothing, kept, and reported"

# Once first-boot setup is done, pimarchy.txt is left alone.
reset_headless
printf '%s\n' 'WIFI_SSID=home' 'WIFI_PASSWORD=password1' >"$settings"
rm "$provisioning/pending"
before=$(fingerprint)
output=$(on aarch64-rpi headless 2>&1) || fail "headless runs after first-boot setup" "$output"
[[ $(fingerprint) == "$before" && ! -s $calls ]] || fail "after first-boot setup headless changes nothing" "$(cat "$calls")"
pass "after first-boot setup pimarchy.txt is left alone"

# ── The package ──────────────────────────────────────────────────────────────

# omarchy-rpi-boot installs each script where the dispatcher and systemd look.
pkgbuild=$ROOT/pi/pkgbuilds/omarchy-rpi-boot/PKGBUILD
bash -n "$pkgbuild" || fail "the PKGBUILD parses"
for script in setup-boot update-verify grow-root headless; do
  grep -q "\\b$script\\b" <(grep -A 3 'for entrypoint in' "$pkgbuild") || fail "the package installs $script"
done
grep -qF 'install -Dm755 "$entrypoint" "$pkgdir/usr/lib/omarchy/rpi-boot/$entrypoint"' "$pkgbuild" &&
  grep -qF 'omarchy-rpi-grow-root.service "$pkgdir/usr/lib/systemd/system/omarchy-rpi-grow-root.service"' "$pkgbuild" &&
  grep -qF 'omarchy-rpi-headless.service "$pkgdir/usr/lib/systemd/system/omarchy-rpi-headless.service"' "$pkgbuild" &&
  grep -qF 'pimarchy.txt "$pkgdir/usr/share/omarchy-rpi-boot/pimarchy.txt"' "$pkgbuild" ||
  fail "the package installs its entrypoints, units and pimarchy.txt where the dispatcher, systemd and the image builder look"
grep -qF 'initcpio-hook "$pkgdir/usr/lib/initcpio/hooks/omarchy-rpi-disk-id"' "$pkgbuild" &&
  grep -qF 'initcpio-install "$pkgdir/usr/lib/initcpio/install/omarchy-rpi-disk-id"' "$pkgbuild" &&
  grep -qF 'mkinitcpio.conf "$pkgdir/etc/mkinitcpio.conf.d/90-omarchy-rpi-disk-id.conf"' "$pkgbuild" ||
  fail "the package installs the disk identifier hook where mkinitcpio looks"
[[ $(ls "$scripts") == $'grow-root\nheadless\ninitcpio-hook\ninitcpio-install\nmkinitcpio.conf\nomarchy-rpi-grow-root.service\nomarchy-rpi-headless.service\npimarchy.txt\nsetup-boot\nupdate-verify' ]] ||
  fail "the package installs every file in pi/rpi-boot" "$(ls "$scripts")"
pass "omarchy-rpi-boot installs every Pi boot script, its units, pimarchy.txt and the disk identifier hook"

# ── The first-boot disk identifier ───────────────────────────────────────────

# The initramfs hook's functions, on a disk image file. Its busybox has
# hexdump; this host may not, so a stand-in gives the one form the hook uses.
if ! command -v sfdisk >/dev/null; then
  skip "the disk identifier hook (it needs sfdisk)"
else
  idbin=$tmp/disk-id-bin
  mkdir -p "$idbin"
  if ! command -v hexdump >/dev/null; then
    printf '%s\n' '#!/bin/bash' '[[ $* == "-v -e /1 \"%02x\"" ]] || exit 2' 'od -An -v -tx1 | tr -d " \n"' >"$idbin/hexdump"
    chmod +x "$idbin/hexdump"
  fi
  disk=$tmp/disk.img
  truncate -s 16M "$disk"
  printf 'label: dos\nlabel-id: 0x8a70c72b\nstart=2048, size=8192, type=c\nstart=10240, type=83\n' |
    sfdisk --quiet --no-reread --no-tell-kernel "$disk" >/dev/null
  before=$(sfdisk --dump "$disk" | grep -v '^label-id:')
  output=$(PATH="$idbin:$PATH" bash -c '
    source "$1"
    old=$(omarchy_rpi_disk_id "$2")
    new=$(omarchy_rpi_random_id "$old")
    omarchy_rpi_set_disk_id "$2" "$new"
    echo "$old $new $(omarchy_rpi_disk_id "$2")"
  ' bash "$scripts/initcpio-hook" "$disk") || fail "the hook gives a disk a new identifier" "$output"
  read -r old new read_back <<<"$output"
  [[ $old == "8a70c72b" && $new =~ ^[0-9a-f]{8}$ && $new != "$old" && $new != "00000000" && $read_back == "$new" ]] ||
    fail "the hook reads and writes the identifier as sfdisk names it" "$output"
  [[ $(sfdisk --dump "$disk" | sed -n 's/^label-id: //p') == "0x$new" && $(sfdisk --dump "$disk" | grep -v '^label-id:') == "$before" ]] ||
    fail "the new identifier is the disk's label-id, and the partitions stay" "$(sfdisk --dump "$disk")"
  pass "the hook gives an MBR disk a random identifier of its own and leaves its partitions alone"

  # Then fstab's / and /boot, and cmdline.txt's root=, follow the new
  # identifier; nothing else on either changes.
  printf '%s\n' '# fstab' \
    'PARTUUID=8a70c72b-02  /      ext4  rw,relatime  0 1' \
    'PARTUUID=8a70c72b-01  /boot  vfat  rw,relatime  0 2' \
    'PARTUUID=0badc0de-01  /mnt/usb  vfat  rw  0 2' >"$tmp/fstab"
  printf 'root=UUID=93f96c19-8612-4030-98f1-3533322a5222 rw rootwait console=tty1 quiet splash pimarchy.new_disk_id=8a70c72b\r\n' >"$tmp/cmdline.txt"
  output=$(bash -c 'source "$1"; omarchy_rpi_fstab "$2/fstab" 1234abcd && omarchy_rpi_cmdline "$2/cmdline.txt" 1234abcd' \
    bash "$scripts/initcpio-hook" "$tmp" 2>&1) || fail "the hook points fstab and cmdline.txt at the new identifier" "$output"
  [[ $(<"$tmp/fstab") == $'# fstab\nPARTUUID=1234abcd-02  /      ext4  rw,relatime  0 1\nPARTUUID=1234abcd-01  /boot  vfat  rw,relatime  0 2\nPARTUUID=0badc0de-01  /mnt/usb  vfat  rw  0 2' ]] ||
    fail "fstab's / and /boot follow the new identifier, and other disks' lines stay" "$(<"$tmp/fstab")"
  [[ $(<"$tmp/cmdline.txt") == "root=PARTUUID=1234abcd-02 rw rootwait console=tty1 quiet splash" && ! -e $tmp/cmdline.txt.omarchy-new ]] ||
    fail "cmdline.txt names the root by its new PARTUUID and drops the first-boot flag" "$(<"$tmp/cmdline.txt")"
  pass "fstab's / and /boot and cmdline.txt's root follow the new identifier, and the first-boot flag goes"

  # When fstab can't follow (no root is mounted), the late hook writes the old
  # identifier back, so systemd still finds /boot, and leaves cmdline.txt for
  # the next boot.
  printf 'root=UUID=93f96c19 rw pimarchy.new_disk_id=8a70c72b\n' >"$tmp/cmdline.txt"
  output=$(PATH="$idbin:$PATH" bash -c '
    source "$1"
    err() { echo "ERROR: $*"; }
    omarchy_rpi_disk=$2 omarchy_rpi_old_id=$(omarchy_rpi_disk_id "$2") omarchy_rpi_new_id=0badcafe omarchy_rpi_boot=/nonexistent
    omarchy_rpi_set_disk_id "$2" 0badcafe
    run_latehook "$3"
  ' bash "$scripts/initcpio-hook" "$disk" "$tmp/unmounted" 2>&1) || fail "the late hook copes with a root it can't update" "$output"
  [[ $(sfdisk --dump "$disk" | sed -n 's/^label-id: //p') == "0x$new" && $output == *"keeps its identifier"* &&
    $(<"$tmp/cmdline.txt") == "root=UUID=93f96c19 rw pimarchy.new_disk_id=8a70c72b" ]] ||
    fail "a new identifier fstab can't follow goes back, and cmdline.txt keeps the flag" "$output $(sfdisk --dump "$disk" | grep label-id)"
  pass "a new identifier fstab can't follow goes back to the old one, and the next boot tries again"

  # mkinitcpio 42 mounts the root on /sysroot and makes /new_root a link to it;
  # the late hook follows the link to the root's fstab and keeps the identifier.
  mkdir -p "$tmp/sysroot/etc"
  ln -s sysroot "$tmp/new_root"
  printf '%s\n' "PARTUUID=$new-02  /  ext4  rw  0 1" "PARTUUID=$new-01  /boot  vfat  rw  0 2" >"$tmp/sysroot/etc/fstab"
  output=$(PATH="$idbin:$PATH" bash -c '
    source "$1"
    mkdir() { :; }
    mount() { return 1; }
    err() { echo "ERROR: $*"; }
    omarchy_rpi_disk=$2 omarchy_rpi_old_id=$(omarchy_rpi_disk_id "$2") omarchy_rpi_new_id=0badcafe omarchy_rpi_boot=/nonexistent
    omarchy_rpi_set_disk_id "$2" 0badcafe
    run_latehook "$3"
  ' bash "$scripts/initcpio-hook" "$disk" "$tmp/new_root" 2>&1) || fail "the late hook updates a root mounted behind a link" "$output"
  [[ $(sfdisk --dump "$disk" | sed -n 's/^label-id: //p') == "0x0badcafe" && $output == *"cannot mount /nonexistent"* &&
    $(<"$tmp/sysroot/etc/fstab") == $'PARTUUID=0badcafe-02  /  ext4  rw  0 1\nPARTUUID=0badcafe-01  /boot  vfat  rw  0 2' ]] ||
    fail "the root's fstab follows the new identifier through mkinitcpio's /new_root link, and the disk keeps it" \
      "$output $(sfdisk --dump "$disk" | grep label-id) $(<"$tmp/sysroot/etc/fstab")"
  pass "the late hook follows mkinitcpio 42's /new_root link to the root's fstab and keeps the new identifier"
fi

# The hook renews the card whose cmdline.txt still carries the image's flag,
# whatever its MBR says and wherever the kernel lists it: a card from the same
# image renewed before, listed first, can't stand in for it, and with no such
# card none is renewed. A root= naming a device names that one partition.
# Partitions and boot volumes come from stand-ins here; blkid lists every
# candidate for a tag and, as the real one does, refuses anything else.
picks=$tmp/picks
mkdir -p "$picks"
printf 'root=PARTUUID=5eed0001-02 rw rootwait quiet\n' >"$picks/sda1.txt"
printf 'root=UUID=93f96c19 rw rootwait quiet pimarchy.new_disk_id=8a70c72b\r\n' >"$picks/mmcblk0p1.txt"
pick() {
  bash -c '
    source "$1"
    root=$2 candidates=$3 picks=$4
    blkid() { [[ ${*: -1} == *=* ]] || return 4; printf "%s\n" $candidates; }
    omarchy_rpi_disk_of() { printf "%s\n" "${1%[0-9]}"; }
    omarchy_rpi_part1() { printf "%s1\n" "$1"; }
    mount() { cp "$picks/${5##*/}.txt" "$6/cmdline.txt"; }
    umount() { rm -f "$1/cmdline.txt"; }
    omarchy_rpi_pick "$root" 8a70c72b "$picks/mnt"
  ' bash "$scripts/initcpio-hook" "$1" "$2" "$picks"
}
output=$(pick UUID=93f96c19 "/dev/sda2 /dev/mmcblk0p2" 2>&1) && [[ $output == "/dev/mmcblk0p2" ]] ||
  fail "the hook picks the card whose cmdline.txt carries the flag, not a renewed card listed first" "$output"
if output=$(pick UUID=93f96c19 "/dev/sda2" 2>&1); then
  fail "with no card carrying the flag the hook renews none" "$output"
fi
output=$(pick /dev/mmcblk0p2 "/dev/sda2" 2>&1) && [[ $output == "/dev/mmcblk0p2" ]] ||
  fail "a root= naming a device picks that partition's card" "$output"
printf 'root=UUID=93f96c19 rw pimarchy.new_disk_id=0badc0de\nroot=UUID=93f96c19 pimarchy.new_disk_id=8a70c72b\n' >"$picks/mmcblk0p1.txt"
if output=$(pick "/dev/mmcblk0p2" 2>&1); then
  fail "only the firmware's line of cmdline.txt, carrying this image's identifier, counts" "$output"
fi
pass "the hook renews the card whose cmdline.txt carries the image's flag, and no card renewed before"

# rootdelay is read as decimal, as its user means it: ash takes a leading 0 for
# octal, and an arithmetic error in a hook ends init itself.
output=$(bash -c '
  source "$1"
  getarg() { echo 08; }
  cat() { echo "root=UUID=93f96c19 pimarchy.new_disk_id=8a70c72b"; }
  omarchy_rpi_pick() { return 1; }
  err() { echo "ERROR: $*"; }
  waits=0
  sleep() { waits=$((waits + 1)); }
  run_hook
  echo "waited $waits half seconds"
' bash "$scripts/initcpio-hook" 2>&1)
[[ $output == *"none gets a new identifier"* && $output == *"waited 32 half seconds" ]] ||
  fail "the hook waits twice rootdelay=08 seconds for the flagged card and then gives up" "$output"
pass "the hook waits twice rootdelay, read as decimal, for the flagged card"

# When it gives up, a root= tag every card from the image shares would have
# mkinitcpio mount any of them, a card renewed before included: the boot waits
# for the image's own root partition instead. A root= naming a device stays.
gave_up() {
  bash -c '
    source "$1"
    root=$2
    getarg() { echo 0; }
    cat() { echo "root=$root pimarchy.new_disk_id=8a70c72b"; }
    omarchy_rpi_pick() { return 1; }
    err() { :; }
    sed() { :; }
    run_hook
    echo "$root"
  ' bash "$scripts/initcpio-hook" "$1"
}
[[ $(gave_up UUID=93f96c19) == "PARTUUID=8a70c72b-02" && $(gave_up /dev/sda2) == "/dev/sda2" ]] ||
  fail "a boot whose flagged card doesn't show up waits for the image's own root" "$(gave_up UUID=93f96c19) $(gave_up /dev/sda2)"
pass "a boot whose flagged card doesn't show up waits for the image's own root, not a renewed card's"

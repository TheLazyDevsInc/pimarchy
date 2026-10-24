#!/bin/bash

# pi/build-image, the Raspberry Pi image builder: its options and prerequisite
# checks, the package names it maps, the checks it makes on a finished image
# root, and its packing of a root into a disk image, run on small fake roots.
# Building a real image takes hours under emulation and root; none of that runs
# here.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

BUILDER=$ROOT/pi/build-image
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
umask 022
# The builder wants every directory above its output searchable by anyone.
chmod 0755 "$TMPDIR"

[[ -x $BUILDER ]] || fail "pi/build-image is executable"
bash -n "$BUILDER" || fail "pi/build-image parses"
pass "pi/build-image is an executable bash script"

# ── Options, which it reads before it asks for root ─────────────────────────

output=$("$BUILDER" --help) || fail "--help exits 0"
[[ $output == *"Usage: pi/build-image"* && $output == *"--keep-root"* && $output == *"--no-compress"* ]] ||
  fail "--help describes the options" "$output"
pass "--help describes the options"

expect_refusal() {
  local description=$1 expected=$2 output status=0
  shift 2

  output=$("$BUILDER" "$@" 2>&1) || status=$?
  (( status != 0 )) || fail "$description" "it exited 0: $output"
  [[ $output == *"$expected"* ]] || fail "$description" "expected '$expected' in: $output"
  pass "$description"
}

expect_refusal "an unknown option is refused" "unknown option: --frobnicate" --frobnicate
expect_refusal "a channel other than stable, rc or edge is refused" "--channel must be stable, rc or edge" --channel beta
expect_refusal "a size that is not a size is refused" "--size must be a size" --size 12X
expect_refusal "a size with no room beside the boot partition is refused" "leaves no room for a root partition" --size 700M
expect_refusal "an option without its value is refused" "--output needs a value" --output
expect_refusal "a tarball that does not exist is refused" "is not a file" --tarball "$TMPDIR/missing.tar.gz"

if (( EUID != 0 )); then
  expect_refusal "it refuses to run as anyone but root" "must run as root" --output "$TMPDIR/not-root"
  [[ ! -e $TMPDIR/not-root ]] || fail "refusing to run as a user creates nothing"
  pass "refusing to run as a user creates nothing"
else
  skip "the refusal to run as a user (this test runs as root)"
fi

# ── Its functions, sourced: nothing runs ─────────────────────────────────────

output=$(bash -c 'source "$1"; echo sourced' bash "$BUILDER" 2>&1) || fail "sourcing pi/build-image runs nothing" "$output"
[[ $output == "sourced" ]] || fail "sourcing pi/build-image runs nothing" "$output"
pass "sourcing pi/build-image only defines its functions"

source "$BUILDER"

for case in "8G=8589934592" "8g=8589934592" "8GiB=8589934592" "7500M=7864320000" "1T=1099511627776" "1500K=1048576" \
  "1048577=1048576"; do
  [[ $(parse_size "${case%%=*}") == "${case#*=}" ]] || fail "parse_size ${case%%=*} is ${case#*=} bytes" "$(parse_size "${case%%=*}")"
done
for size in "" "G" "8X" "-1G" "8.5G" "8 G"; do
  ! parse_size "$size" >/dev/null || fail "parse_size refuses '$size'"
done
pass "sizes are read in binary units and rounded down to whole MiB"

version_at_least 5.4.0 5.4 && version_at_least 10.0.13 9.0 && ! version_at_least 5.1.0 5.4 && ! version_at_least 8.2.2 9.0 ||
  fail "versions compare numerically"
pass "versions compare numerically"

mapfile -t mapped < <(filter_package_names nvim vi linux linux-headers obs-studio superwhisper-bin lib32-glibc intel-ucode \
  hyprland linux-rpi 2>/dev/null)
[[ ${mapped[*]} == "neovim ex-vi-compat linux-rpi linux-rpi-headers hyprland linux-rpi" ]] ||
  fail "package names map as the ISO's aarch64 filter maps them, with linux-rpi as the kernel" "${mapped[*]}"
pass "package names map as the ISO's aarch64 filter maps them, with linux-rpi as the kernel"

# ── Prerequisites ────────────────────────────────────────────────────────────

stubs=$TMPDIR/stubs
mkdir -p "$stubs" "$TMPDIR/prereq-out"
stub() {
  printf '#!/bin/bash\n%s\n' "$2" >"$stubs/$1"
  chmod +x "$stubs/$1"
}
for tool in bsdtar mkfs.vfat fsck.vfat mcopy e2fsck sfdisk xz git curl; do
  stub "$tool" 'exit 0'
done
good_stubs() {
  stub mke2fs 'echo "mke2fs 1.47.0 (5-Feb-2023)" >&2'
  stub findmnt 'echo "ext4 rw,relatime"'
  stub proot 'echo "|__|  |__|__\_____/\_____/\____| 5.4.0"'
  stub qemu-aarch64-static 'echo "qemu-aarch64 version 10.0.13"'
  stub qemu-aarch64 'echo "qemu-aarch64 version 10.0.13"'
}
good_stubs
output=$(PATH="$stubs:$PATH" output="$TMPDIR/prereq-out" runner=proot bash -c 'source "$1"; check_prerequisites' bash "$BUILDER" 2>&1) ||
  fail "current tools pass the prerequisite checks" "$output"
pass "current tools pass the prerequisite checks"

# The chroot runner: binfmt_misc runs the image's binaries through qemu-user,
# registered with the fix-binary flag so the handler works inside the chroot.
binfmt=$TMPDIR/binfmt
mkdir -p "$binfmt"
printf '%s\n' 1 >"$binfmt/status"
binfmt_entry() { # name, flags, interpreter
  printf 'enabled\ninterpreter %s\nflags: %s\noffset 0\nmagic 7f454c460201010000000000000000000200b700\nmask ffffffffffffff00fffffffffffffffffeffffff\n' "$3" "$2" >"$binfmt/$1"
}
binfmt_entry qemu-aarch64 POCF "$stubs/qemu-aarch64"
prereq() { # runner, then extra environment
  local runner=$1
  shift
  PATH="$stubs:$PATH" output="$TMPDIR/prereq-out" OMARCHY_BINFMT_DIR="$binfmt" runner=$runner "$@" \
    bash -c 'source "$1"; check_prerequisites && echo "chosen: $runner"' bash "$BUILDER" 2>&1
}
if [[ $(uname -m) != "aarch64" ]]; then
  output=$(prereq chroot) || fail "a registered aarch64 handler passes the chroot runner's checks" "$output"
  [[ $output == *"Runner: chroot"* && $output == *"through binfmt_misc"* ]] ||
    fail "the chroot runner runs the image's binaries through binfmt_misc" "$output"
  output=$(prereq auto) || fail "auto picks the chroot runner where binfmt_misc can run aarch64 binaries" "$output"
  [[ $output == *"chosen: chroot"* ]] || fail "auto picks the chroot runner where binfmt_misc can run aarch64 binaries" "$output"
  binfmt_entry qemu-aarch64 POC "$stubs/qemu-aarch64"
  output=$(prereq auto) || fail "auto falls back to proot without a fix-binary handler" "$output"
  [[ $output == *"chosen: proot"* ]] || fail "auto falls back to proot without a fix-binary handler" "$output"
  status=0
  output=$(prereq chroot) || status=$?
  (( status != 0 )) && [[ $output == *"needs binfmt_misc to run aarch64 binaries"* ]] ||
    fail "the chroot runner refuses a host whose binfmt_misc can't run aarch64 binaries in a chroot" "$output"
  stub old-qemu 'echo "qemu-aarch64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1)"'
  binfmt_entry qemu-aarch64 POCF "$stubs/old-qemu"
  status=0
  output=$(prereq chroot) || status=$?
  (( status != 0 )) && [[ $output == *"is qemu 8.2.2; qemu-user 8.2 crashes"* ]] ||
    fail "the chroot runner checks the qemu behind binfmt_misc" "$output"
  pass "the chroot runner needs a fix-binary aarch64 handler and a recent qemu behind it, and auto falls back to proot"
else
  skip "the chroot runner's binfmt checks (an aarch64 host runs the image natively)"
fi

stub mke2fs 'echo "mke2fs 1.42.9 (28-Dec-2013)" >&2'
stub findmnt 'echo "vfat rw,noexec,relatime"'
stub proot 'echo "|__|  |__|__\_____/\_____/\____| 5.1.0"'
stub qemu-aarch64-static 'echo "qemu-aarch64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1)"'
stub qemu-aarch64 'echo "qemu-aarch64 version 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1)"'
mkdir -m 0700 "$TMPDIR/private"
mkdir "$TMPDIR/private/prereq-out"
status=0
output=$(PATH="$stubs:$PATH" output="$TMPDIR/private/prereq-out" runner=proot bash -c 'source "$1"; check_prerequisites' bash "$BUILDER" 2>&1) || status=$?
(( status != 0 )) || fail "old tools fail the prerequisite checks" "$output"
for expected in "proot 5.1.0 does not translate faccessat2" "mke2fs 1.42.9 can't build a filesystem from a directory" \
  "is on a vfat filesystem" "mounted noexec" "$TMPDIR/private is not searchable by other users"; do
  [[ $output == *"$expected"* ]] || fail "old tools fail the prerequisite checks with a reason each" "expected '$expected' in: $output"
done
if [[ $(uname -m) != "aarch64" ]]; then
  [[ $output == *"is qemu 8.2.2; qemu-user 8.2 crashes"* ]] || fail "qemu 8.2 fails the prerequisite checks" "$output"
fi
pass "old proot, qemu and mke2fs, a FAT or noexec output, and an output under a private directory fail the prerequisite checks with a reason each"

# ── The image's checkout ─────────────────────────────────────────────────────

if ! command -v git >/dev/null; then
  skip "the image's checkout (it needs git)"
else
  # A source whose history carries a file its last commit no longer has.
  source_dir=$TMPDIR/clone-source
  git init -q -b main "$source_dir"
  head -c 65536 /dev/urandom >"$source_dir/intro.mp4"
  git -C "$source_dir" add -A
  git -C "$source_dir" -c user.name=Test -c user.email=test@example.invalid commit -q -m "Add an intro"
  old_blob=$(git -C "$source_dir" rev-parse HEAD:intro.mp4)
  git -C "$source_dir" rm -q intro.mp4
  printf 'Pimarchy\n' >"$source_dir/README.md"
  git -C "$source_dir" add -A
  git -C "$source_dir" -c user.name=Test -c user.email=test@example.invalid commit -q -m "Drop the intro"
  source_commit=$(git -C "$source_dir" rev-parse HEAD)

  # The test is not root: the checkout stays the test's own.
  output=$(
    root=$TMPDIR/clone-root branch=main commit=$source_commit origin_url=https://example.invalid/pimarchy.git
    install() { mkdir -p -- "${@: -1}"; }
    chown() { :; }
    clone_source 2>&1
  ) || fail "the image's checkout clones the commit being built" "$output"
  dest=$TMPDIR/clone-root$guest_src
  [[ $(git -C "$dest" rev-parse HEAD) == "$source_commit" && $(git -C "$dest" rev-list --count HEAD) == 2 &&
    $(git -C "$dest" rev-parse '@{upstream}') == "$source_commit" && -z $(git -C "$dest" status --porcelain) &&
    $(<"$dest/README.md") == "Pimarchy" ]] ||
    fail "the image's checkout is the commit being built, with its whole history, on a branch that tracks it" "$output"
  pass "the image's checkout is the commit being built, with its whole history, on a branch that tracks it"
  git -C "$dest" rev-list --objects --all --missing=print | grep -qx "?$old_blob" ||
    fail "the image's checkout leaves out file contents only older commits have"
  [[ $(git -C "$dest" config remote.origin.url) == "https://example.invalid/pimarchy.git" &&
    $(git -C "$dest" config remote.origin.promisor) == "true" && -z $(git -C "$dest" config remote.origin.uploadpack) ]] ||
    fail "the image's checkout fetches what it lacks from the real origin" "$(git -C "$dest" config --list --local)"
  pass "the image's checkout leaves out file contents only older commits have, and fetches them from the real origin"
fi

# ── The checks on a finished image root ──────────────────────────────────────

if ! command -v bsdtar >/dev/null || ! command -v git >/dev/null; then
  skip "the image root checks (they need bsdtar and git)"
else
  root=$TMPDIR/image-root
  work=$TMPDIR/validate-work
  mkdir -p "$work"
  disk_id=1a2b3c4d
  channel=stable
  branch=main
  origin_url=https://example.invalid/pimarchy.git
  version_suffix=.r1.gabc1234

  # A root as the build leaves it, owned by whoever runs this test, which the
  # checks take for root.
  mkdir -p "$root"/{boot,home,tmp,run,etc/ssh,etc/pacman.d,etc/sddm.conf.d,etc/limine-entry-tool.d} \
    "$root"/etc/systemd/system/{multi-user.target.wants,local-fs.target.wants} \
    "$root"/var/lib/omarchy/{image,provisioning} "$root"/var/lib/pacman/{sync,local} "$root"/var/cache/pacman/pkg \
    "$root"/usr/lib/omarchy/rpi-boot "$root"/usr/share/omarchy/install/hardware/rpi "$root$guest_repo"
  printf 'format=1\nplatform=aarch64-rpi\n' >"$root/var/lib/omarchy/image/target"
  printf 'install/hardware/rpi/sleep.sh\n' >"$root/var/lib/omarchy/image/deferred-steps"
  : >"$root/usr/share/omarchy/install/hardware/rpi/sleep.sh"
  : >"$root/var/lib/omarchy/image/pacman-keyring"
  : >"$root/var/lib/omarchy/image/boot-rebuild"
  : >"$root/var/lib/omarchy/provisioning/pending"
  ln -s /usr/lib/systemd/system/omarchy-provision-hardware.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-provision-hardware.service"
  : >"$root/etc/systemd/system/omarchy-provision-owner.service"
  ln -s /etc/systemd/system/omarchy-provision-owner.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
  ln -s /usr/lib/systemd/system/sddm.service "$root/etc/systemd/system/display-manager.service"
  ln -s /usr/lib/systemd/system/omarchy-rpi-grow-root.service \
    "$root/etc/systemd/system/local-fs.target.wants/omarchy-rpi-grow-root.service"
  printf '[Theme]\nCurrent=omarchy\n' >"$root/etc/sddm.conf.d/99-omarchy-login.conf"
  printf 'root:x:0:0::/root:/bin/bash\nsddm:x:960:960::/var/lib/sddm:/usr/bin/nologin\nowner:x:%s:%s::/:/usr/bin/nologin\n' \
    "$EUID" "$(id -g)" >"$root/etc/passwd"
  printf 'root:!:20000::::::\n' >"$root/etc/shadow"
  printf 'root:x:0:\nsddm:x:960:\nowner:x:%s:\n' "$(id -g)" >"$root/etc/group"
  for file in kernel8.img initramfs-linux.img bcm2711-rpi-400.dtb start4.elf fixup4.dat; do
    printf 'x' >"$root/boot/$file"
  done
  printf 'root=PARTUUID=%s-02 rw rootwait console=tty1 quiet splash\n' "$disk_id" >"$root/boot/cmdline.txt"
  printf '[all]\ninitramfs initramfs-linux.img followkernel\n' >"$root/boot/config.txt"
  printf 'PARTUUID=%s-02  /      ext4    rw,relatime  0 1\nPARTUUID=%s-01  /boot  vfat    rw,relatime  0 2\n' \
    "$disk_id" "$disk_id" >"$root/etc/fstab"
  : >"$root/var/lib/pimarchy/grow-root-pending"
  for file in setup-boot update-verify grow-root; do
    install -m 0755 /dev/null "$root/usr/lib/omarchy/rpi-boot/$file"
  done
  printf 'KERNEL_CMDLINE[default]="quiet splash"\n' >"$root/etc/limine-entry-tool.d/omarchy-defaults.conf"
  mkdir -p "$root/usr/bin" "$root/var/lib/pacman/local/iptables-1:1.8.13-1"
  printf '%%NAME%%\niptables\n\n%%VERSION%%\n1:1.8.13-1\n' >"$root/var/lib/pacman/local/iptables-1:1.8.13-1/desc"
  for name in iptables ip6tables; do
    ln -s xtables-nft-multi "$root/usr/bin/$name"
  done

  # The checkout, the Pi's templates in it, and the pacman state built from it.
  checkout=$root$guest_src
  mkdir -p "$checkout/default/pacman/aarch64-rpi" "$checkout/bin"
  printf '[pimarchy]\nServer = file:///var/lib/pimarchy/repo\n' >"$checkout/default/pacman/aarch64-rpi/pacman-stable.conf"
  printf 'Server = https://example.invalid/$arch/$repo\n' >"$checkout/default/pacman/aarch64-rpi/mirrorlist-stable"
  : >"$checkout/bin/omarchy"
  git -C "$checkout" init -q -b "$branch"
  git -C "$checkout" add -A
  git -C "$checkout" -c user.name=Test -c user.email=test@example.invalid commit -q -m "Pimarchy"
  git -C "$checkout" remote add origin "$origin_url"
  git -C "$checkout" config "branch.$branch.remote" origin
  git -C "$checkout" config "branch.$branch.merge" "refs/heads/$branch"
  commit=$(git -C "$checkout" rev-parse HEAD)
  git -C "$checkout" update-ref "refs/remotes/origin/$branch" "$commit"
  cp "$checkout/default/pacman/aarch64-rpi/pacman-stable.conf" "$root/etc/pacman.conf"
  cp "$checkout/default/pacman/aarch64-rpi/mirrorlist-stable" "$root/etc/pacman.d/mirrorlist"
  for name in pimarchy omarchy core extra alarm; do
    printf 'db' >"$root/var/lib/pacman/sync/$name.db"
  done
  mkdir -p "$TMPDIR/db"
  for name in "${local_packages[@]}"; do
    mkdir -p "$TMPDIR/db/$name-1$version_suffix-1" "$root/var/lib/pacman/local/$name-1$version_suffix-1"
    printf '%%NAME%%\n%s\n' "$name" >"$TMPDIR/db/$name-1$version_suffix-1/desc"
  done
  bsdtar -czf "$root$guest_repo/pimarchy.db.tar.gz" -C "$TMPDIR/db" .
  ln -s pimarchy.db.tar.gz "$root$guest_repo/pimarchy.db"

  # Sealed.
  : >"$root/etc/machine-id"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
  printf 'omarchy\n' >"$root/etc/hostname"

  # Whatever the checks find on this root: the test's own account is the one
  # problem a real root would not have.
  problems_now() {
    root_problems | grep -v '^the image has user accounts: owner $' || true
  }
  output=$(problems_now)
  [[ -z $output ]] || fail "a finished image root passes its checks" "$output"
  pass "a finished image root passes its checks"

  # Each breakage on its own is found and named.
  expect_problem() {
    local description=$1 expected=$2 output

    output=$(problems_now)
    [[ $output == *"$expected"* ]] || fail "$description" "expected '$expected' in: ${output:-no problems}"
    pass "$description"
  }

  mv "$root/var/lib/omarchy/image/deferred-steps" "$TMPDIR/deferred-steps"
  expect_problem "a root with no deferred hardware steps is refused" "no hardware steps are queued"
  mv "$TMPDIR/deferred-steps" "$root/var/lib/omarchy/image/deferred-steps"

  chmod 0664 "$root/var/lib/omarchy/image/target"
  expect_problem "a manifest others can write is refused" "/var/lib/omarchy/image/target is missing or not root-owned"
  chmod 0644 "$root/var/lib/omarchy/image/target"

  rm "$root/var/lib/omarchy/provisioning/pending"
  expect_problem "a root without owner setup armed is refused" "/var/lib/omarchy/provisioning/pending is missing"
  : >"$root/var/lib/omarchy/provisioning/pending"

  printf 'alarm:x:1001:1001::/home/alarm:/bin/bash\n' >>"$root/etc/passwd"
  expect_problem "a root that still has the alarm account is refused" "alarm account is still in the image"
  sed -i '/^alarm:/d' "$root/etc/passwd"

  printf 'root:$6$hash:20000::::::\n' >"$root/etc/shadow"
  expect_problem "a root whose root password is not locked is refused" "root's password is not locked"
  printf 'root:!:20000::::::\n' >"$root/etc/shadow"

  printf 'root=/dev/mmcblk0p2 rw rootwait\n' >"$root/boot/cmdline.txt"
  expect_problem "a cmdline.txt that names another root is refused" "does not name root=PARTUUID=$disk_id-02"
  printf 'root=PARTUUID=%s-02 rw rootwait console=tty1 quiet splash\n' "$disk_id" >"$root/boot/cmdline.txt"

  : >"$root/boot/initramfs-linux.img"
  expect_problem "a root without an initramfs is refused" "/boot/initramfs-linux.img is missing"
  printf 'x' >"$root/boot/initramfs-linux.img"

  mv "$root/var/lib/pacman/local/omarchy-1$version_suffix-1" "$root/var/lib/pacman/local/omarchy-4.0.6-1"
  expect_problem "an omarchy that is not the [pimarchy] build is refused" "omarchy 4.0.6-1 is not the [pimarchy] build"
  mv "$root/var/lib/pacman/local/omarchy-4.0.6-1" "$root/var/lib/pacman/local/omarchy-1$version_suffix-1"

  printf '[omarchy]\n' >"$root/etc/pacman.conf"
  expect_problem "a pacman.conf other than the Pi's template is refused" "/etc/pacman.conf is not default/pacman/aarch64-rpi"
  cp "$checkout/default/pacman/aarch64-rpi/pacman-stable.conf" "$root/etc/pacman.conf"

  git -C "$checkout" update-ref -d "refs/remotes/origin/$branch"
  expect_problem "a checkout whose branch tracks nothing is refused" "does not track origin/$branch"
  git -C "$checkout" update-ref "refs/remotes/origin/$branch" "$commit"

  mkdir "$root/etc/pacman.d/gnupg"
  expect_problem "a root that keeps the build's keyring is refused" "the build's pacman keyring is still in the image"
  rmdir "$root/etc/pacman.d/gnupg"

  printf 'key' >"$root/etc/ssh/ssh_host_ed25519_key"
  printf '0123456789abcdef0123456789abcdef\n' >"$root/etc/machine-id"
  expect_problem "a root with SSH host keys is refused" "the image carries SSH host keys"
  expect_problem "a root with a machine ID is refused" "/etc/machine-id is not empty"
  rm "$root/etc/ssh/ssh_host_ed25519_key"
  : >"$root/etc/machine-id"

  # ufw's firewall setup sees an iptables that knows its version and nothing
  # else, and the real links come back afterwards.
  shim_iptables
  [[ $("$root/usr/bin/ip6tables" -V) == "ip6tables v1.8.13 (nf_tables)" ]] && ! "$root/usr/bin/iptables" -L 2>/dev/null ||
    fail "the build's iptables answers -V with the image's version and refuses the rest"
  pass "the build's iptables answers -V with the image's version and refuses the rest"
  expect_problem "a root that keeps the build's iptables shim is refused" "/usr/bin/iptables is not iptables' own link"
  shim_iptables
  unshim_iptables
  [[ $(readlink "$root/usr/bin/iptables") == "xtables-nft-multi" && ! -e $root/usr/bin/iptables.pimarchy-build ]] ||
    fail "a second shim keeps the real link, and unshimming restores it"
  pass "a second shim keeps the real link, and unshimming restores it"

  mkdir -p "$root/usr/local/sbin"
  printf '#!/bin/sh\n' >"$root/usr/local/sbin/pacman"
  expect_problem "a root that keeps the build's pacman shim is refused" "the build's command shims are still in the image"
  rm "$root/usr/local/sbin/pacman"

  # Every file here belongs to the test's group, so without that group in the
  # image they all belong to a group the image doesn't have.
  cp "$root/etc/group" "$TMPDIR/group"
  sed -i '/^owner:/d' "$root/etc/group"
  expect_problem "files of a group the image does not have are refused" "files belong to gid $(id -g), which the image has no group for"
  cp "$TMPDIR/group" "$root/etc/group"

  output=$(problems_now)
  [[ -z $output ]] || fail "the repaired root passes its checks again" "$output"
  status=0
  output=$(validate_root 2>&1) || status=$?
  if grep -q '^owner:' "$root/etc/passwd" && (( EUID >= 1000 && EUID < 60000 )); then
    (( status != 0 )) && [[ $output == *"not ready to pack (1 problems)"* ]] ||
      fail "validate_root fails on any problem" "$output"
  else
    (( status == 0 )) || fail "validate_root passes a finished root" "$output"
  fi
  pass "validate_root stops the build on any problem"
fi

# ── Packing ──────────────────────────────────────────────────────────────────

missing=()
for tool in mkfs.vfat fsck.vfat mcopy mtype mdir mke2fs e2fsck debugfs dumpe2fs sfdisk xz; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
if (( ${#missing[@]} )); then
  skip "packing an image (missing ${missing[*]})"
  exit 0
fi

output=$TMPDIR/pack
work=$output/work
root=$work/root
image_name=pimarchy-test
disk_id=0c0ffee1
root_fs_uuid=7d4b1f0a-2c6e-4b8e-9a1d-5e3f2c1b0a99
keep_root=1
compress=1
mkdir -p "$root"/{boot/overlays,etc,usr/bin,var/lib}
printf 'root=PARTUUID=%s-02 rw rootwait\n' "$disk_id" >"$root/boot/cmdline.txt"
printf '[all]\ninitramfs initramfs-linux.img followkernel\n' >"$root/boot/config.txt"
head -c 1048576 /dev/urandom >"$root/boot/kernel8.img"
head -c 4096 /dev/urandom >"$root/boot/overlays/vc4-kms-v3d.dtbo"
printf 'hidden\n' >"$root/boot/.hidden"
head -c 524288 /dev/urandom >"$root/usr/bin/tool"
chmod 4755 "$root/usr/bin/tool"
ln "$root/usr/bin/tool" "$root/usr/bin/tool-link"
ln -s ../usr/bin/tool "$root/etc/tool"
mkdir -m 0750 "$root/var/lib/private"
kernel_sum=$(sha256sum <"$root/boot/kernel8.img")
tool_sum=$(sha256sum <"$root/usr/bin/tool")

# An explicit size too small for the root stops the packing with the size it needs.
image_bytes=$((600 * 1048576))
size_text=600M
size_explicit=1
status=0
result=$(pack_image 2>&1) || status=$?
(( status != 0 )) && [[ $result == *"pass a larger --size"* ]] || fail "a --size too small for the root stops the packing" "$result"
[[ ! -e $output/$image_name.img && ! -e $output/$image_name.img.xz ]] || fail "a refused packing leaves no image"
pass "a --size too small for the root stops the packing, naming the size it needs"
rmdir "$root/boot"
mv "$work/boot" "$root/boot"

# The default size grows to the next whole GiB the root fits in.
size_text=8G
size_explicit=0
result=$(pack_image 2>&1) || fail "the root packs into an image" "$result"
[[ $result == *"so the image is 1 GiB"* ]] || fail "the default size grows to the next whole GiB the root fits in" "$result"
pass "the default size grows to the next whole GiB the root fits in"

image=$output/$image_name.img.xz
[[ -f $image && -f $image.sha256 ]] || fail "packing writes the compressed image and its checksum" "$(ls -la "$output")"
(cd "$output" && sha256sum -c --quiet "$image_name.img.xz.sha256") || fail "the checksum matches the image"
pass "packing writes the compressed image and a checksum that matches it"
[[ -d $root/boot && -f $root/boot/cmdline.txt && ! -e $work/boot && ! -e $work/boot.img && ! -e $work/root.img ]] ||
  fail "a kept root gets its /boot back, and no intermediate images stay" "$(ls -la "$work" "$root/boot")"
pass "a kept root gets its /boot back, and no intermediate images stay"

xz -dc "$image" >"$TMPDIR/disk.img"
dump=$(sfdisk --dump "$TMPDIR/disk.img")
grep -q "^label: dos$" <<<"$dump" && grep -q "^label-id: 0x$disk_id$" <<<"$dump" ||
  fail "the disk is MBR with the build's disk identifier" "$dump"
grep -q "start= *2048, size= *1048576, type=c$" <<<"$dump" ||
  fail "partition 1 is the 512 MiB FAT32 (LBA) boot partition 1 MiB in" "$dump"
grep -q "start= *1050624, size= *1046528, type=83$" <<<"$dump" ||
  fail "partition 2 is the Linux root partition, filling the rest of the disk" "$dump"
pass "the disk is MBR with the build's identifier, a 512 MiB FAT32 boot partition at 1 MiB and the root after it"

dd if="$TMPDIR/disk.img" of="$TMPDIR/boot.part" bs=1M skip=1 count=512 conv=sparse status=none
dd if="$TMPDIR/disk.img" of="$TMPDIR/root.part" bs=1M skip=513 conv=sparse status=none

fsck.vfat -n "$TMPDIR/boot.part" >/dev/null || fail "the boot partition checks clean"
[[ $(MTOOLS_SKIP_CHECK=1 mtype -i "$TMPDIR/boot.part" ::/cmdline.txt) == "root=PARTUUID=$disk_id-02 rw rootwait" ]] ||
  fail "the boot partition holds /boot's files"
[[ $(MTOOLS_SKIP_CHECK=1 mtype -i "$TMPDIR/boot.part" ::/kernel8.img | sha256sum) == "$kernel_sum" ]] ||
  fail "the boot partition holds /boot's files byte for byte"
listing=$(MTOOLS_SKIP_CHECK=1 mdir -/ -a -i "$TMPDIR/boot.part" ::/)
[[ $listing == *"vc4-kms-v3d.dtbo"* && $listing == *".hidden"* ]] || fail "the boot partition holds /boot's subdirectories and dotfiles" "$listing"
pass "the boot partition is a clean FAT32 filesystem with all of /boot in it"

e2fsck -fn "$TMPDIR/root.part" >/dev/null 2>&1 || fail "the root partition checks clean" "$(e2fsck -fn "$TMPDIR/root.part" 2>&1)"
dumpe2fs -h "$TMPDIR/root.part" 2>/dev/null | grep -q "^Filesystem UUID: *$root_fs_uuid$" ||
  fail "the root filesystem has the build's UUID"
[[ $(debugfs -R 'stat /' "$TMPDIR/root.part" 2>/dev/null) == *"User:     0   Group:     0"* ]] ||
  fail "the root filesystem's top directory belongs to root"
# debugfs -p lists /inode/mode/uid/gid/name/size/, . and .. included.
[[ $(debugfs -R 'ls -p /boot' "$TMPDIR/root.part" 2>/dev/null | grep -c '^/') == 2 ]] ||
  fail "the root filesystem's /boot is an empty mount point" "$(debugfs -R 'ls -l /boot' "$TMPDIR/root.part" 2>&1)"
stat_tool=$(debugfs -R 'stat /usr/bin/tool' "$TMPDIR/root.part" 2>/dev/null)
[[ $stat_tool == *"Mode:  04755"* && $stat_tool == *"Links: 2"* ]] || fail "modes and hard links survive packing" "$stat_tool"
[[ $(debugfs -R 'stat /etc/tool' "$TMPDIR/root.part" 2>/dev/null) == *'Fast link dest: "../usr/bin/tool"'* ]] ||
  fail "symlinks survive packing"
debugfs -R "dump /usr/bin/tool $TMPDIR/tool.out" "$TMPDIR/root.part" >/dev/null 2>&1
[[ $(sha256sum <"$TMPDIR/tool.out") == "$tool_sum" ]] || fail "files survive packing byte for byte"
[[ $(debugfs -R 'stat /var/lib/private' "$TMPDIR/root.part" 2>/dev/null) == *"Mode:  0750"* ]] || fail "directory modes survive packing"
pass "the root partition is a clean ext4 filesystem with the build's UUID, an empty /boot, and every file, mode, link and owner kept"

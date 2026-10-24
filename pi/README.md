# Pimarchy: Omarchy on the Raspberry Pi 400

This directory builds Pimarchy, this fork's Omarchy for the Raspberry Pi 400, as an SD card image. Like `test/`, `docs/` and `plans/`, it ships in no package. [`docs/raspberry-pi.md`](../docs/raspberry-pi.md) explains how Omarchy runs on the Pi, and [`plans/pi-400-port.md`](../plans/pi-400-port.md) explains why it is built this way.

- `build-image` builds the image.
- `pkgbuilds/` holds the PKGBUILDs the Pi builds its Omarchy packages from: `omarchy` and `omarchy-settings`, vendored from upstream, and `omarchy-rpi-boot`, the Pi's boot package.
- `rpi-boot/` holds the boot package's sources.

## The image

`pimarchy-<version>-<channel>-<date>-g<commit>.img.xz` is a whole SD card: an MBR disk with a 512 MiB FAT32 boot partition and an ext4 root partition, which grows to fill the card on the first boot. It is Arch Linux ARM's Raspberry Pi root filesystem turned into Omarchy:

- The kernel is `linux-rpi`, booted by the Pi's own firmware from the boot partition (`config.txt`, `cmdline.txt`, `kernel8.img`). There is no U-Boot, Limine or UEFI.
- Omarchy's packages come from Omarchy's aarch64 repository and Omarchy's mirror of Arch Linux ARM, except `omarchy`, `omarchy-settings` and `omarchy-rpi-boot`. The image builds those three from this repository into a local repository, `[pimarchy]` at `/var/lib/pimarchy/repo`, which `pacman.conf` lists first.
- The image carries the Pimarchy checkout it was built from, at `/var/lib/pimarchy/src`. It is on the branch the image was built from, and that branch tracks the `origin` of the checkout the image was built from. The Pi rebuilds its Omarchy packages from it on every update.
- Nothing in it belongs to one machine: there is no user account, the root account is locked, and there is no machine ID, no SSH host key and no pacman keyring. The hardware setup an install would run is queued for the Pi's first boot, so it runs on the Pi rather than on the computer that built the image.

## Building an image

`pi/build-image` runs on an x86_64 or aarch64 Linux computer, as root. It needs no loop devices and leaves no mounts behind. It runs every command meant for the image inside the image root, so package installs, scriptlets and Omarchy's own setup run as they would on the Pi, only slower on x86_64. It has two ways to do that, and picks one with `--runner`:

- `chroot`, the default wherever it works: each command runs in a real chroot inside its own private mount namespace, whose mounts (`/proc`, `/sys`, `/dev`, the package cache) go when the command does. On x86_64 the kernel runs the image's aarch64 programs through qemu-user, registered with binfmt_misc. A build took about an hour and a quarter on a 4-core x86_64 host, half of it compressing the image.
- `proot`, for a host that can't register binfmt_misc handlers, such as an unprivileged container: proot maps the image root and runs its programs through qemu-user itself. It traces every system call, so a build takes several hours.

Either way, expect to need about 25 GiB of free disk where `--output` points. Everything the build runs inside the image runs as root on this computer's kernel, with its network, `/dev` and `/sys`. Package scripts and Omarchy's setup are written for the machine they install, so build in a container or a throwaway VM rather than on a computer you care about.

```bash
sudo pi/build-image --output ~/pimarchy-image
```

That builds `HEAD` of the checkout the script lives in, on the stable channel, into an image of at least 8 GiB: if the installed system doesn't fit in 8 GiB, the image grows to the next whole GiB that fits it. Today's system takes about 9.5 GiB, so the image is 12 GiB (about 2.9 GB compressed) and needs a 16 GB card or larger. The output directory then holds the image, its `.sha256` and `build.log`.

| Option | Default | Meaning |
| --- | --- | --- |
| `--output DIR` | `./pimarchy-image` | Where the image, its checksum and `build.log` go. The image root is built in `DIR/work`. |
| `--size SIZE` | `8G` | The image size, such as `8G` or `7500M`. A size given here that is too small for the system stops the build. |
| `--channel NAME` | `stable` | Omarchy's channel: `stable`, `rc` or `edge`. |
| `--source PATH` | this checkout | The Pimarchy checkout to build. |
| `--ref REF` | `HEAD` | The commit, branch or tag to build. Uncommitted changes are never built. |
| `--cache DIR` | `/var/cache/pimarchy-build` | The downloaded Arch Linux ARM tarball and every package, kept for the next build. |
| `--tarball PATH` | | Use this Arch Linux ARM Raspberry Pi tarball instead of downloading it. A `PATH.md5` next to it is checked. |
| `--keep-root` | | Keep `DIR/work`, the image root included, for inspection. |
| `--no-compress` | | Write a plain `.img` instead of `.img.xz`. |
| `--runner NAME` | `auto` | How to run the image's programs: `chroot`, `proot`, or `auto`, which takes `chroot` on an aarch64 host or where binfmt_misc runs aarch64 programs, and `proot` otherwise. |

The Pi updates from the origin of the checkout the image was built from, so build from a checkout whose `origin` is an `https://` URL the Pi can fetch, such as the fork on GitHub, and push the branch before you flash. The image is built from the committed state of `--ref`, not from the working tree.

### Prerequisites

The builder checks for all of these before it starts and says what is missing:

- `bsdtar`, `mkfs.vfat` and `fsck.vfat`, `mcopy`, `mke2fs` and `e2fsck` (e2fsprogs 1.43 or newer), `sfdisk`, `findmnt`, `xz`, `git` and `curl`.
- For the chroot runner, `unshare`, `mount` and `chroot`, and on an x86_64 host a static qemu-user 10 or newer registered with binfmt_misc for aarch64 with the fix-binary (`F`) flag. The kernel then opens qemu when it is registered, so it runs the image's programs inside a chroot that has no qemu of its own. The builder reads the registration from `/proc/sys/fs/binfmt_misc` and checks the qemu it names.
- For the proot runner, proot 5.4 or newer, and on an x86_64 host qemu-user 10 or newer, found as `qemu-aarch64-static`, then `qemu-aarch64`. proot 5.1, which Ubuntu 24.04 and Debian 13 ship, does not translate the `faccessat2` system call that Arch Linux ARM's glibc uses, so tests inside the image look at the build host's files.
- qemu 8.2, which Ubuntu 24.04 ships, crashes on Arch Linux ARM's glibc under either runner. No qemu is needed on an aarch64 host.

On Arch Linux, `qemu-user-static-binfmt` registers its static qemu with the `F` flag through systemd-binfmt:

```bash
sudo pacman -S --needed libarchive dosfstools mtools e2fsprogs util-linux xz git curl qemu-user-static qemu-user-static-binfmt
```

On Debian 13 (trixie) or newer, whose qemu is new enough and static, `qemu-user-binfmt` registers it:

```bash
sudo apt install libarchive-tools dosfstools mtools e2fsprogs fdisk util-linux xz-utils git curl qemu-user qemu-user-binfmt
```

On Ubuntu 24.04 or Debian 12, install everything above except the qemu packages, then take qemu from Debian 13 without installing it. Debian 13's `qemu-user` is a static build (its `qemu-user-static` holds only links to it). Download `qemu-user` for your architecture from [packages.debian.org/trixie/qemu-user](https://packages.debian.org/trixie/qemu-user), unpack it, and register its `qemu-aarch64` in place of any older one until the next reboot:

```bash
mkdir -p ~/pimarchy-tools
dpkg-deb -x qemu-user_10.*_amd64.deb ~/pimarchy-tools
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && echo -1 | sudo tee /proc/sys/fs/binfmt_misc/qemu-aarch64
printf ':qemu-aarch64:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\xb7\\x00:\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:%s:POCF\n' \
  "$HOME/pimarchy-tools/usr/bin/qemu-aarch64" | sudo tee /proc/sys/fs/binfmt_misc/register
sudo pi/build-image --output ~/pimarchy-image
```

Where binfmt_misc can't be registered, as in an unprivileged container, use the proot runner. It needs proot 5.4, which Debian has only in forky and sid ([packages.debian.org/sid/proot](https://packages.debian.org/sid/proot)) and Arch only in the AUR. Debian's build needs glibc 2.38, so it runs on Ubuntu 24.04, Debian 13 and newer. Under proot, the image's build account runs programs by their paths on this computer, so qemu (Debian 13's static `qemu-user`, as above), proot and `--output` must sit where other users can reach them (every directory above them searchable by others), not in a private home:

```bash
sudo mkdir -p /opt/pimarchy-tools
sudo dpkg-deb -x proot_5.4.0-*_amd64.deb /opt/pimarchy-tools
sudo dpkg-deb -x qemu-user_10.*_amd64.deb /opt/pimarchy-tools
sudo apt install libtalloc2   # proot's one library
sudo env PATH="/opt/pimarchy-tools/usr/bin:$PATH" pi/build-image --runner proot --output /srv/pimarchy-image
```

### What a build does

Each step prints a numbered banner, `==> [n/17]`, and everything goes to `build.log`:

1. **Checking prerequisites**: the tools and their versions, the runner, and room where `--output` points.
2. **Resolving the Pimarchy source**: the commit `--ref` names, the branch the image will follow, and that the checkout has the Pi's pacman templates and PKGBUILDs.
3. **Fetching Arch Linux ARM's Raspberry Pi root filesystem**: `ArchLinuxARM-rpi-aarch64-latest.tar.gz` (about 850 MB, checked against its `.md5`). Arch Linux ARM serves both over plain HTTP. For a stronger check, verify the tarball's `.sig` against Arch Linux ARM's signing key yourself and pass it with `--tarball`.
4. **Extracting the root filesystem**: as root, so the image's files keep their real owners and modes, then the image-target manifest (`/var/lib/omarchy/image/target`, `platform=aarch64-rpi`), so everything that asks which computer this is gets the Pi's answer.
5. **Cloning the Pimarchy source into the image**: a blobless clone of the commit at `/var/lib/pimarchy/src`.
6. **Setting up pacman**: the Pi's `pacman.conf` and mirrorlist for the channel, and the empty `[pimarchy]` repository.
7. **Creating the build's pacman keyring**: Arch Linux ARM's keys, and Omarchy's signing key.
8. **Swapping in the Raspberry Pi kernel**: `linux-aarch64` and U-Boot out, `linux-rpi`, the Pi's firmware and the rest of its family list in, the PipeWire audio stack the ISO installs, and the root upgraded.
9. **Building Omarchy's packages into the local repository**: `omarchy-settings`, `omarchy` and `omarchy-rpi-boot` from the clone, built as a temporary user by the checkout's own `omarchy-update-rpi-pkgs` and published to `[pimarchy]`.
10. **Installing Omarchy**: the way the ISO does, `omarchy-settings` and the keyrings first, then LuaRocks, then the Neovim config, then `omarchy`, the boot package and the default set from `omarchy-pkg-defaults aarch64-rpi`.
11. **Removing Arch Linux ARM's account and network defaults**: the `alarm` account, root's password, and its SSH daemon and systemd-networkd setup.
12. **Running Omarchy's system setup**: `omarchy-apply-system --defer-provisioning --first-install`, which sets the system up and queues every hardware step for the first boot.
13. **Writing the boot files**: `cmdline.txt`, `config.txt` and `fstab` for the image's own partition IDs, through the boot package's `setup-boot`, and a generic initramfs.
14. **Arming first-boot setup**: the root grower and owner setup.
15. **Sealing the root filesystem**: no keyring, machine ID, host keys, logs, caches or build tools are left.
16. **Validating the root filesystem**: everything above, checked before anything is packed.
17. **Packing the image**: the boot and root filesystems written into the disk image without mounting anything, compressed and checksummed.

If a step fails, the build stops there and names the step. Rerun it with `--keep-root` to look inside `DIR/work/root`. The cache keeps every download, so a rerun only repeats the work.

Under the proot runner, a few pacman runs in a hundred die of a heap corruption abort ("double free or corruption"), most of them as they exit; the same pacman under qemu alone does not. The builder runs a crashed pacman or gpg again, runs a failed multi-program step (Omarchy's system setup, the package builds, mkinitcpio) once more, and makes sure the build keyring trusts the keys it needs. A crash inside a package's install script is only reported by pacman, so a build that saw any crash says so at the end; its log shows what each crashed program was doing.

### Booting an image under QEMU

QEMU 9.0 and newer emulate the Pi 4's SoC as the `raspi4b` machine, which is enough to run an image's first boot without a Pi: the root grows, the deferred hardware setup runs, the initramfs is rebuilt and the owner wizard starts on tty1. QEMU emulates no GPU, USB, network, Wi-Fi or Bluetooth for this board, so Hyprland never starts, and its SD card must be a power of two in size. Ubuntu 24.04's QEMU is 8.2, so build QEMU 10 with `./configure --target-list=aarch64-softmmu` there.

The Pi's console is the mini UART, which QEMU can't drive, and the PL011 belongs to Bluetooth, so the test copy of the device tree drops the Bluetooth node and swaps the two UARTs' aliases, so the PL011 is `serial0` and `ttyAMA0`. The firmware never runs: QEMU loads the kernel, device tree and initramfs itself, and a debug shell on the serial console stands in for a login, since the image has none. Work on a copy, since the first boot changes it:

```bash
xz -dk pimarchy-*.img.xz && mv pimarchy-*.img test.img
truncate -s 16G test.img
for file in kernel8.img bcm2711-rpi-400.dtb initramfs-linux.img; do mcopy -i test.img@@1M ::$file .; done
fdtput -r bcm2711-rpi-400.dtb /soc/serial@7e201000/bluetooth
fdtput -t s bcm2711-rpi-400.dtb /aliases serial0 /soc/serial@7e201000
fdtput -t s bcm2711-rpi-400.dtb /aliases serial1 /soc/serial@7e215040
qemu-system-aarch64 -M raspi4b -nographic -serial mon:stdio \
  -kernel kernel8.img -dtb bcm2711-rpi-400.dtb -initrd initramfs-linux.img \
  -drive file=test.img,if=sd,format=raw \
  -append "root=PARTUUID=$(sfdisk --dump test.img | sed -n 's/^label-id: 0x//p')-02 rw rootwait console=ttyAMA0,115200 systemd.debug_shell=ttyAMA0 systemd.mask=serial-getty@ttyAMA0.service"
```

The first boot takes about fifteen minutes under emulation on an x86_64 host. `journalctl -u omarchy-rpi-grow-root -u omarchy-provision-hardware` in the debug shell shows what it did, and `omarchy-lifecycle-dispatch update-verify` checks the boot files. `systemctl poweroff` halts the board, since QEMU can't cut its power; quit QEMU with Ctrl-A X once it has. To boot the result again, copy the initramfs the first boot rebuilt out of the image (`mcopy -o -i test.img@@1M ::initramfs-linux.img .`) first.

## Flashing

Check the image, find the SD card's device (`lsblk` lists it, `/dev/sdX` or `/dev/mmcblkX`), and write the image to the whole card, not to a partition:

```bash
sha256sum -c pimarchy-*.img.xz.sha256
xzcat pimarchy-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Raspberry Pi Imager works too: choose "Use custom" under the operating system and pick the `.img.xz`. Answer no when it offers OS customisation. That customisation is meant for Raspberry Pi OS, and it edits `cmdline.txt` to run its own first-boot script. balenaEtcher writes the image unchanged.

## The first boot

Connect a monitor to the micro-HDMI port next to the power socket, then power on. The first boot takes a few minutes; don't cut the power while it runs. It needs no network:

1. The root partition and its filesystem grow to fill the card.
2. The queued hardware setup runs on the Pi: it creates the Pi's own pacman keyring, sets up its audio, sleep, network, Vulkan and boot files, and rebuilds the initramfs for its hardware.
3. The setup screen on the first console asks for your keyboard layout, your account and password, the computer's name, and the timezone.
4. It logs you into Hyprland once. From the next boot on, the login screen asks for your password.

The Pi has no battery-backed clock, so until it reaches the network its clock starts from the time the image was built. Wi-Fi is set up from Omarchy's network menu. SSH stays off, as on any Omarchy install. To turn it on, run `sudo systemctl enable --now sshd` and `sudo ufw allow ssh`.

## Updates on the Pi

`omarchy update` works as on any Omarchy machine, with one extra step before the package transaction. `omarchy-update-rpi-pkgs` fast-forwards `/var/lib/pimarchy/src` from its origin, the repository and branch the image was built from. When the checkout has moved, it rebuilds `omarchy`, `omarchy-settings` and `omarchy-rpi-boot` from it, as the user running the update, and publishes them to `[pimarchy]`. That takes a few minutes on the Pi. The transaction then installs them with everything else from Omarchy and Arch Linux ARM. Afterwards the boot package's `update-verify` checks the kernel, initramfs and boot files before the update offers a reboot.

The checkout is an ordinary git clone owned by root, blobless: old file contents are fetched from origin when git needs them. To follow another branch or fork, change it with `sudo git -C /var/lib/pimarchy/src ...` and run `omarchy update`; that also sets where a later switch to the dev channel clones `~/omarchy` from. If the checkout has uncommitted changes, an update leaves it alone and builds nothing until you commit them or set them aside with `sudo git -C /var/lib/pimarchy/src stash`. Local commits that origin lacks are built, with a warning.

`omarchy-update-firmware` updates the Pi's bootloader EEPROM with `rpi-eeprom-update`.

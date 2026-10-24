# Raspberry Pi

How Omarchy runs on a Raspberry Pi: the `aarch64-rpi` platform family, the Pi firmware boot chain it drives through a platform boot package, the local repository its Omarchy packages are built into, the hardware setup it adds, what it leaves out, and how an SD-card image is built. The Pi 400 is the model this fork targets; the design and the reasons behind each decision are in [`plans/pi-400-port.md`](../plans/pi-400-port.md).

## Status

Everything here is covered by the shell suite and by an emulated image build (`pi/build-image`, run on an x86_64 host under proot and qemu-user). None of it has been booted on a Pi 400 yet. The checklist at the end is what a first hardware run has to confirm.

## Platform

`omarchy-hw-platform` prints `aarch64-rpi` when the device tree's root `compatible` carries a `raspberrypi,` token: the Pi 400 is `raspberrypi,400`, `brcm,bcm2711`, a Pi 4 Model B `raspberrypi,4-model-b`, a CM4 `raspberrypi,4-compute-module`. A `brcm,` token alone is not a Pi, since other Broadcom SoCs carry it. A Pi device tree next to Apple, Qualcomm, N1x or GB10 evidence, or on an x86 CPU, is a contradiction and the detector fails. Feature code asks `omarchy-hw-aarch64-rpi`; a Pi 400-only quirk asks `omarchy-hw-match-device-tree raspberrypi,400`.

An image names `platform=aarch64-rpi` in its image-target manifest, so the build host's own device tree never decides anything while the image is built.

## Packages and repositories

The Pi composes the base list, `install/omarchy-aarch64.packages` and `install/omarchy-aarch64-rpi.packages` (`omarchy-pkg-defaults aarch64-rpi`). Its own list carries the boot chain and the board's hardware:

- `linux-rpi` and its headers, the Raspberry Pi Foundation kernel from Arch Linux ARM's core. Omarchy's own aarch64 kernel is built without BCM2711 support.
- `raspberrypi-bootloader` (the GPU firmware that boots the board) and `firmware-raspberrypi` (Wi-Fi and Bluetooth firmware for its Cypress radio), both from `[alarm]`.
- `raspberrypi-utils`, `rpi4-eeprom` for the bootloader EEPROM, `vulkan-broadcom` for the v3d GPU, and `wf-recorder` for screen recording.

Its pacman templates, `default/pacman/aarch64-rpi/`, are the aarch64 ones (`[omarchy]`, then Omarchy's mirror of Arch Linux ARM's `[core]`, `[extra]` and `[alarm]`) with one repository in front: `[pimarchy]`, a local `file:///var/lib/pimarchy/repo`. Upstream's aarch64 `omarchy` and `omarchy-settings` packages don't know the Pi, so the Pi builds those two, and its boot package, from its own Pimarchy checkout at `/var/lib/pimarchy/src`. pacman installs and upgrades a package from the first repository that carries its name, so the local builds win over `[omarchy]`'s without pinning anything, and every other package still comes from Omarchy and Arch Linux ARM.

`omarchy-update-rpi-pkgs` keeps that repository current. `omarchy update` runs it on a Pi before the package transaction: it fast-forwards the checkout, and when the checkout moved it builds the three packages from `pi/pkgbuilds/` as the updating user, versioned `<PKGBUILD pkgver>.r<commits>.g<sha>`, and publishes them. With `--init` it only makes sure the repository exists, since pacman refuses to sync a `file://` repository without a database; everything that installs the Pi templates runs it first.

The `omarchy` and `omarchy-settings` PKGBUILDs in `pi/pkgbuilds/` are upstream's, vendored from `omacom/omarchy-pkgs`; `pi/pkgbuilds/README.md` records the source and any local change.

## Boot chain

The Pi has no UEFI. Its firmware reads `config.txt` from the FAT partition mounted at `/boot`, loads `kernel8.img`, the board's device tree and `initramfs-linux.img`, and passes `cmdline.txt` to the kernel. `linux-rpi` owns `config.txt` and `cmdline.txt` as `backup=` files, so Omarchy edits them in place rather than replacing them. There is no Limine, no UKI, no snapper and no LUKS.

The initramfs comes from `linux-rpi`'s mkinitcpio preset, rebuilt by mkinitcpio's own pacman hook whenever the kernel changes. `etc/mkinitcpio.conf.d/00-omarchy-hooks.conf` gives the Pi its own baseline, `base udev plymouth keyboard autodetect modconf kms keymap consolefont block filesystems fsck`: no `btrfs-overlayfs`, which only `limine-mkinitcpio-hook` ships and whose absence makes mkinitcpio exit 1, no `microcode`, and no `encrypt`.

The Pi registers a platform boot package with `omarchy-lifecycle-dispatch`, as Apple Silicon does ([`lifecycle-dispatch.md`](lifecycle-dispatch.md)): `omarchy-rpi-boot`, with its operations in `/usr/lib/omarchy/rpi-boot/`. Its sources are `pi/rpi-boot/`.

- `setup-boot` runs as hardware setup's last leaf on every install and rerun, and on an image's first boot. It points `cmdline.txt`'s `root=` at the root partition's PARTUUID, adds the kernel parameters every Omarchy machine boots with (`KERNEL_CMDLINE[default]` in `/etc/limine-entry-tool.d/omarchy-defaults.conf`), keeps any parameter the user added, and maintains one managed block at the end of `config.txt` (`disable_splash=1`, plus the initramfs and `vc4-kms-v3d` lines if the file lacks them). It then rebuilds the initramfs when its inputs changed, or on an image's first boot asks the first-boot service to.
- `update-verify` runs at the end of `omarchy update` and proves the updated system boots: the installed `linux-rpi` kernel and modules are in `/boot`, the initramfs carries that kernel's modules, `config.txt` loads the initramfs, and `cmdline.txt`'s root is the running root. Until it passes, the update does not offer a reboot.
- Provisioning and factory reset keep the generic path. The Pi's root is unencrypted ext4, which owner setup handles directly and factory reset refuses (it needs btrfs).

`omarchy-rpi-grow-root.service`, also from the boot package, grows the root partition and its filesystem to fill the card on an image's first boot.

## Hardware setup

`install/hardware/rpi/` holds the Pi's leaves, each gated on the family or the Pi 400:

- **Audio.** The Pi 400 has no 3.5 mm jack, but `snd_bcm2835` still registers a Headphones card, and WirePlumber ranks analogue outputs above HDMI. `options snd_bcm2835 enable_headphones=0` removes it, so sound goes to HDMI.
- **Sleep.** The BCM2711 has no suspend-to-RAM, so suspend and hibernation are turned off and the menu hides Suspend, as on the GB10.
- **Network.** Arch Linux ARM's stock systemd-networkd DHCP files are retired, as other machines' are, so NetworkManager owns the interfaces.
- **Vulkan.** v3d is a device-tree platform device that `lspci` never sees, so `vulkan.sh` installs `vulkan-broadcom` by platform.
- **Display scale.** A Pi drives HDMI monitors at 1x, so the user's `GDK_SCALE` starts at 1 instead of the shipped 2.

What already works on a Pi without a branch of its own: Hyprland (Aquamarine opens only KMS cards, so it scans out on vc4 and renders on v3d), the monitor panel's two external outputs, DDC brightness (failures are cached), power profiles (the placeholder driver offers balanced and power-saver), the hidden power panel with no battery, and Bluetooth on the UART.

## What is off, and why

| Feature | On a Pi | Why |
| --- | --- | --- |
| Limine, UKIs, Direct Boot | Not available; `omarchy-refresh-limine` and `omarchy-kernel set` say so, and the menu hides Direct Boot | No UEFI; the firmware boots `kernel8.img` |
| Snapshots | Skipped; `install/config/snapper.sh` does nothing without snapper and a btrfs root | ext4 root |
| LUKS, hibernation, factory reset | Not available | v1 image has an unencrypted ext4 root and no swap |
| Firmware updates | `omarchy-update-firmware` updates the bootloader EEPROM with `rpi-eeprom-update` instead of fwupd | fwupd has no Pi support |
| Docker databases | MSSQL is offered on x86 only and MongoDB not on a Pi | No arm64 MSSQL image; MongoDB needs ARMv8.2-A, the Cortex-A72 is ARMv8.0 |
| Windows VM, x86 games | Hidden, as on every aarch64 machine | x86-only |

## Images

`pi/build-image` builds a flashable `pimarchy-*.img.xz` from Arch Linux ARM's Pi rootfs on an x86_64 or aarch64 host, without mounts or loop devices; [`pi/README.md`](../pi/README.md) covers running it and flashing the result. It follows the image-target contract every Omarchy image build uses: it writes the manifest naming `aarch64-rpi`, swaps U-Boot and `linux-aarch64` for `linux-rpi`, builds the local packages, installs the Pi's default set, runs `omarchy-apply-system --defer-provisioning --first-install` (which queues every hardware leaf for the first boot), writes the boot files for the image's own PARTUUIDs, arms owner provisioning, and seals the root.

On first boot the root grows to fill the card, `omarchy-provision-hardware` creates the pacman keyring and runs the queued hardware leaves offline, the boot package's `setup-boot` settles the boot files and the initramfs is rebuilt on the device, and the owner wizard on tty1 asks for keyboard, account, hostname and timezone before logging into Hyprland once.

## Hardware checklist

A first run on a Pi 400 has to confirm, in order:

1. The image boots to the owner wizard, and the root partition fills the card.
2. Hyprland starts on vc4 with the Quickshell bar, on one and on two HDMI monitors, at 1080p and 4K30.
3. `aplay -l` shows no Headphones card, and sound plays on each HDMI output.
4. Wi-Fi joins a network from the network panel, and Bluetooth pairs a device.
5. The cursor draws without corruption (if not, Hyprland needs `cursor:no_hardware_cursors`, also in SDDM's greeter config).
6. `omarchy update` rebuilds the local packages, `update-verify` passes, and the machine reboots into the new kernel.
7. A theme switch, a screenshot, a screen recording and the nightlight toggle work.

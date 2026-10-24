# Porting Omarchy to the Raspberry Pi 400 ("Pimarchy")

Revision 2. Revision 1 assumed Omarchy had no aarch64 packages; upstream has since grown a full aarch64 platform layer (families `aarch64`, `aarch64-apple`, `aarch64-qualcomm`, `aarch64-n1x`, `aarch64-gb10`, an aarch64 package repository at `pkgs.omarchy.org/<channel>/aarch64`, and Omarchy's own Arch Linux ARM mirrors). This revision builds the Pi on that layer instead of beside it.

## Problem

A Raspberry Pi 400 (BCM2711, Cortex-A72 ARMv8.0-A, 4 GB, VideoCore VI with vc4 KMS and v3d render, two micro-HDMI outputs, a built-in keyboard, no audio jack, no battery, no backlight, no DMI, no UEFI) cannot run Omarchy from upstream's packages or ISO:

- Upstream's aarch64 ISO is UEFI-only and boots `linux-omarchy`, which is built with `# CONFIG_ARCH_BCM is not set`. The Pi boots its own firmware from a FAT partition into a kernel named in `config.txt`.
- On a Pi, upstream's generic initramfs baseline names `btrfs-overlayfs`, which only `limine-mkinitcpio-hook` ships, so `mkinitcpio` exits 1.
- `install/config/snapper.sh` assumes a btrfs root and snapper, and the Limine commands assume an ESP.
- The Pi's GPU is a device-tree platform device, so `lspci`-driven Vulkan setup installs nothing.

## Shape

### Decisions

| Decision | Call | Why |
| --- | --- | --- |
| Base | Arch Linux ARM `aarch64` through Omarchy's own mirror (`arm-stable-mirror.omarchy.org` and `arm-rc-mirror.omarchy.org`, `arm-mirror.omarchy.org` for edge) and `[omarchy]` aarch64 packages | Exactly what every other ARM Omarchy machine uses. ALARM's `[alarm]` repo, which the aarch64 templates already enable, carries the Pi bootloader and firmware. |
| Platform | A new family, `aarch64-rpi`, detected from the `raspberrypi,` device-tree vendor prefix | AGENTS.md adds a family "once it needs code of its own". The Pi needs a kernel, a boot chain, an initramfs baseline and hardware leaves of its own. The Pi 400 itself is `omarchy-hw-match-device-tree raspberrypi,400`. |
| Kernel | `linux-rpi` (ALARM core) | Omarchy's aarch64 kernel lacks BCM support; `linux-aarch64` needs U-Boot and mainline vc4. `linux-rpi` ships `kernel8.img`, the device trees, overlays, and a mkinitcpio preset writing `/boot/initramfs-linux.img`. |
| Boot chain | Pi firmware, `config.txt` and `cmdline.txt` edited in place, no Limine, no UKI | `linux-rpi` owns both files as `backup=` files, so Omarchy edits them rather than replacing them. |
| Filesystem | ext4 root, FAT32 `/boot`, no LUKS, no snapper, no hibernation in v1 | Upstream already skips snapshots when snapper is absent (`omarchy-snapshot` exits 127) and factory reset and hibernation when there is no btrfs root or Limine. |
| Boot integration | A platform boot package, `omarchy-rpi-boot`, registered in `omarchy-lifecycle-dispatch` for `setup-boot` and `update-verify` | AGENTS.md: boot chains Omarchy can't drive generically live in a platform package behind lifecycle dispatch. `update-verify` proves the initramfs matches the installed kernel after every update. Provisioning and factory reset keep the generic path, which handles an unencrypted ext4 root. |
| Omarchy packages | Built on the Pi from its Pimarchy checkout into a local `[pimarchy]` repository listed before `[omarchy]` | Upstream's aarch64 `omarchy` doesn't know `aarch64-rpi`. pacman installs and upgrades a package from the first repository that has it, so the local builds shadow upstream's without pinning. No hosting is needed. |
| Delivery | A flashable SD image with deferred provisioning armed, built off-device | Upstream's image-target manifest contract (`install/helpers/image-target.sh`) already defers hardware setup to the first boot. The owner wizard asks for keyboard, account, hostname and timezone on tty1. |
| Overclocking, 4K60 | Off by default | The Pi 400 runs 1.8 GHz stock. `hdmi_enable_4kp60` is opt-in heat. |

### Names and paths every part agrees on

- Platform `aarch64-rpi`; predicate `omarchy-hw-aarch64-rpi`; model check `omarchy-hw-match-device-tree raspberrypi,400`.
- Family package list `install/omarchy-aarch64-rpi.packages`.
- Pacman templates `default/pacman/aarch64-rpi/`: the aarch64 templates with `[pimarchy]` (`SigLevel = Optional TrustAll`, `Server = file:///var/lib/pimarchy/repo`) first.
- Local repository `/var/lib/pimarchy/repo` (`pimarchy.db`), root-owned. The Pimarchy checkout it is built from is `/var/lib/pimarchy/src`, root-owned, a git clone with an `origin` remote and the branch the image was built from.
- PKGBUILDs live in `pi/pkgbuilds/<package>/` (`omarchy`, `omarchy-settings` vendored from `omacom/omarchy-pkgs`, and `omarchy-rpi-boot`). They build with `OMARCHY_SRC=<checkout>`; the version is the PKGBUILD's `pkgver` plus `.r<serial>.g<short sha>`, where the serial is the commit count, or one past the last build's when that is not lower.
- `bin/omarchy-update-rpi-pkgs` (hidden) creates the repository when it is missing, fast-forwards the checkout, rebuilds the three packages when the checkout moved, and publishes them. `omarchy update` runs it before the package transaction on a Pi.
- The Pi boot package installs its operations to `/usr/lib/omarchy/rpi-boot/` and its first-boot root partition grower as `omarchy-rpi-grow-root.service`. Its sources live in `pi/rpi-boot/`.
- Kernel parameters come from `KERNEL_CMDLINE[default]` in `/etc/limine-entry-tool.d/omarchy-defaults.conf`, the same list Limine machines boot with, so the Pi stays quiet and splashed like every other Omarchy machine.
- `config.txt` gets one managed block, between `# BEGIN Omarchy` and `# END Omarchy`, under `[all]`.

### Parts

1. **Platform family.** Detector, predicate, package composer, manifest names, pacman routing, initramfs baseline (done in "Add the aarch64-rpi platform family").
2. **Boot package and dispatch.** `pi/rpi-boot/{setup-boot,update-verify,grow-root}`, the unit, `pi/pkgbuilds/omarchy-rpi-boot`, the dispatcher registration, `docs/lifecycle-dispatch.md`, tests.
3. **Hardware and guards.** `install/hardware/rpi/sleep.sh` (suspend off), ALARM's stock networkd files retired by the generic `install/hardware/network.sh` (no headphone leaf: the Pi 400's device tree already turns its headphone card off), `vulkan.sh`, `install/config/snapper.sh`, `omarchy-refresh-limine`, `omarchy-kernel set`, the Direct Boot menu entry, `omarchy-update-firmware` (`rpi-eeprom-update` on a Pi), `omarchy-install-docker-dbs` (no MSSQL off x86, no MongoDB on ARMv8.0), `wf-recorder` for screen recording, GDK scale 1 for the Pi's user, tests.
4. **Packaging and updates.** Vendored PKGBUILDs, `omarchy-update-rpi-pkgs`, the Pi pacman templates, the update-pipeline step, tests.
5. **Image builder.** `pi/build-image`: Arch Linux ARM's Pi rootfs, run on an x86_64 host in a chroot through binfmt_misc and qemu-user (or under proot where binfmt_misc can't be registered), turned into a Pimarchy root through the same entry points an ISO install uses, then packed into a two-partition `.img.xz` without loop devices or lasting mounts.
6. **Docs.** `docs/raspberry-pi.md` (reference), the "Omarchy on..." manual chapter, `pi/README.md` (build and flash).

## Rejected approaches

- **DietPi or another Debian base.** Omarchy is pacman throughout: its packages, migrations and update pipeline. Debian carries no Hyprland 0.56 or Quickshell.
- **`linux-aarch64` with U-Boot and UEFI Limine.** It would make the Pi look like other UEFI aarch64 machines, but mainline vc4 on the BCM2711 is weaker, ALARM's tarball already ships it with U-Boot only as a stopgap, and `linux-omarchy` cannot drive the board at all.
- **Replacing `config.txt` and `cmdline.txt` with Omarchy's own files.** `linux-rpi` owns them; replacing them produces `.pacnew` churn and drops ALARM's camera and display auto-detection.
- **A `file://` repository with a `pi` channel and signing key of its own (revision 1).** Upstream's channels and keyring already cover aarch64; only the two runtime packages need local builds.
- **Hosting aarch64 Pimarchy packages.** Building on the Pi from its checkout needs no infrastructure and keeps the update path inside `omarchy update`.
- **Overriding `AQ_DRM_DEVICES`.** Aquamarine opens only KMS-capable cards, so it already scans out on vc4 and renders on v3d.

## Verification

- `./test/cli` and the shell suite as an unprivileged user, never as root.
- `pi/build-image` run end to end in this repository's development container under emulation, then the image's partition table, boot files, `cmdline.txt` root, fstab, the image-target manifest, the deferred-step queue, the local repository and the armed provisioning inspected.
- On a Pi 400: flash, boot, complete the owner form, reach Hyprland with the Quickshell bar, run `omarchy update` (the local packages rebuild, `update-verify` passes), and check Wi-Fi, Bluetooth, HDMI audio on both outputs, a theme switch, a screenshot and a screen recording. Hardware verification is outstanding until someone runs it.

## Open follow-ups

- **The keyboard layout.** Raspberry Pi OS preselects the Pi 400's keyboard layout from the keyboard's country code, which the firmware passes in the device tree; the owner wizard could do the same instead of asking.
- **Hardware verification.** The checklist in [`docs/raspberry-pi.md`](../docs/raspberry-pi.md) is what a first run on a Pi 400 has to confirm.

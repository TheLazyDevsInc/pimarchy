# Pimarchy: Omarchy on the Raspberry Pi 400

This tree holds the build tooling for porting Omarchy to the Raspberry Pi
400. Like `test/`, `docs/`, and `plans/`, it ships in neither the `omarchy`
nor `omarchy-settings` package — it is not part of the running system.

The full plan, with every task and its rationale, lives at
[`plans/pi-400-port.md`](../plans/pi-400-port.md).

## Hardware target

Only the Raspberry Pi 400 is supported. It does not need to run on anything
under a Pi 400. Concretely, that means:

- Broadcom BCM2711, quad-core Cortex-A72 (ARMv8-A — **not** the newer
  ARMv8.2 that Arch Linux's own `aarch64` port now targets)
- 4 GB RAM
- VideoCore VI, exposed as two DRM devices: `vc4` (display/KMS, owns both
  connectors) and `v3d` (render-only)
- Dual micro-HDMI output, no HDMI audio jack workaround needed — there is
  no 3.5 mm jack on this board at all, audio is HDMI/USB/Bluetooth only
- No battery, no backlight, no DMI (`/sys/class/dmi/id` does not exist),
  no PCI bus, no UEFI
- Built-in USB keyboard (the Pi 400 *is* a keyboard) with no media keys

## Base OS

[Arch Linux ARM](https://archlinuxarm.org/) `aarch64`, with the `linux-rpi`
kernel. Arch Linux ARM already ships prebuilt `hyprland`, `quickshell`,
`mesa`, and `vulkan-broadcom` for aarch64 — the reason this port is
tractable at all is that none of the hard graphics-stack dependencies need
to be built from source.

Omarchy itself installs as two pacman packages built locally on the Pi (see
Phase 4 of the plan) into a local `file://` repository, rather than
depending on the x86_64-only `pkgs.omarchy.org`.

## Workflows

**`pi/bootstrap`** (not yet implemented — see Phases 3–9 of the plan) turns
a stock Arch Linux ARM install into Pimarchy. This is the iteration loop:
flash Arch Linux ARM aarch64, run the bootstrap script, test, and if
something's wrong, reflash and repeat. Minutes per cycle, not an image
rebuild.

**`pi/build-image`** (not yet implemented — see Phase 10 of the plan) bakes
the result into a flashable `pimarchy-<version>-aarch64.img.xz`, with
deferred provisioning armed so a fresh flash boots straight into the
existing `omarchy-provision-owner` first-run wizard (keyboard, username,
password, hostname, timezone) rather than a bare shell.

## What's here now

- `config.txt` / `cmdline.txt` — the Raspberry Pi firmware boot templates
  that `omarchy-refresh-rpi-boot` (not yet implemented) will install to
  `/boot`, replacing the Limine/UKI chain a Pi has no UEFI to run.

Everything else in the plan — the pacman repo, the package builds, the
hardware detectors, the Hyprland/Quickshell fixes, the install pipeline
integration, and the image builder — is tracked in
[`plans/pi-400-port.md`](../plans/pi-400-port.md) and lands incrementally.

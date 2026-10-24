# Porting Omarchy to the Raspberry Pi 400 ("Pimarchy")

## Context

`pimarchy` is a fork of `omacom/omarchy` at `4.0.0.alpha`. Omarchy is Arch + Hyprland + a Quickshell desktop, and version 4 is **package-backed**: it installs itself as two pacman packages (`omarchy`, `omarchy-settings`) from `pkgs.omarchy.org/<channel>/$arch`, with `core`/`extra`/`multilib` coming from Omarchy's own Arch mirrors. None of that exists for `aarch64`.

The goal is a Raspberry Pi 400 that boots into the real Omarchy desktop — Hyprland, the Quickshell bar, themes, the `omarchy` CLI, the update/migration pipeline — installed from a flashable SD image. Only the Pi 400 must be supported (BCM2711 / Cortex-A72 / 4 GB / VideoCore VI / dual micro-HDMI / built-in keyboard / no audio jack / no battery / no backlight / no PCI / no DMI / no UEFI).

**The port is viable because Arch Linux ARM already ships the hard parts for aarch64:** `hyprland` 0.56.1 (extra), `quickshell` (extra), `mesa` 26.2.2 (extra), `vulkan-broadcom` 1:26.2.2 (extra), and `linux-rpi` 6.18.51 (core, built 2026-09-13). What is missing is everything Omarchy layers on top: its own package repo, the Limine/UEFI boot chain, and ~37 hardware setup leaves that all gate on DMI strings or `lspci`.

### Answering the DietPi question

**DietPi will not work as the base, but its delivery model is exactly right and we get it for free.**

DietPi is Debian. Omarchy is pacman all the way down: `omarchy-pkg-add` wraps `pacman -S`, all 118 migrations call it, the update pipeline is `pacman -Syu` behind an ALPM guard hook, and the whole product ships *as* pacman packages. Rebasing onto Debian means rewriting the package layer, the update pipeline, and the packaging — and Debian has no Hyprland 0.56 or Quickshell, so you would be compiling the entire Hyprland ecosystem from source on a Pi 400 and redoing it on every update. Arch Linux ARM hands us those prebuilt.

What DietPi actually gives users is: *flash one image, boot, answer a few questions, done*. Omarchy already has that machinery — `omarchy-provision-owner` + `install/provisioning/setup-form.sh` is a deferred-provisioning ("OEM") first-boot wizard that asks for keyboard, username, password, identity, hostname and timezone on tty1 before the display manager starts. **Phase 9 ships the image with deferred provisioning armed**, which reproduces the DietPi experience on the stack Omarchy already runs on.

### Decisions made (you asked me to call these)

| Decision | Call | Why |
| --- | --- | --- |
| **Base OS** | Arch Linux ARM `aarch64` + `linux-rpi` kernel | Only base with prebuilt Hyprland + Quickshell for ARMv8-A. Note: the *newer* official Arch ARM port (`ports.archlinux.page/aarch64`) targets **ARMv8.2** and will not run on the Pi 400's Cortex-A72 — it must be ALARM. |
| **Fork posture** | Guarded port, decide on deletion later | Your answer. Everything x86 stays but no-ops behind guards. |
| **Naming** | Commands stay `omarchy-*` | The router derives routes from filenames; renaming breaks 458 binaries, 118 migrations and both test suites. "Pimarchy" is the distro name only. |
| **Packaging** | Build `omarchy` + `omarchy-settings` for aarch64 with `makepkg`, publish into a **local `file://` pacman repo** on the Pi | Keeps the entire update/migration/channel pipeline working unchanged, with zero hosting. `omarchy-dev-link` alone is not enough — it explicitly does not cover `/etc`, systemd units, udev bodies or `/etc/skel`, which is most of `omarchy-settings`. |
| **Boot & filesystem** | Pi firmware → `linux-rpi` via `config.txt`/`cmdline.txt`. **ext4 root, no LUKS, no snapper, no Plymouth** in v1 | No UEFI means no Limine, no UKI, no `efibootmgr`, no boot-menu snapshot entries. LUKS argon2id on a Cortex-A72 is slow and is the most likely way to end up with an unbootable card. `omarchy-update` already skips snapshots silently when snapper is absent. Rollback is `dd` an image backup. btrfs+snapper is a Phase 12 stretch item. |
| **Overclocking** | Off by default, opt-in command | Pi 400 runs 1.8 GHz stock; pushing it is the user's call, not the installer's. |

### Two things every executing agent must know

1. **Read `AGENTS.md` first.** Two-space indent, `#!/bin/bash` shebangs exactly, `[[ ]]` for strings and `(( ))` for numbers, no `\ ` escaping of spaces in paths, `install/` leaves have no shebang and are sourced.
2. **Run `./test/all` after every change.** Both suites are arch-neutral and headless-safe (`require_compositor` turns a skip into a pass), so they run in any container. `test/cli` will fail loudly if a new command lacks `# omarchy:summary=`.

---

## Phase 0 — Groundwork

### Task 0.1 — Create the Pi tree and the design note
Create `pi/` at the repo root, a fourth tree that ships in neither package (like `test/`, `docs/`, `plans/`):

```
pi/README.md          # how to build and flash, one page
pi/bootstrap          # Phase 8 — executable, #!/bin/bash
pi/build-image        # Phase 9 — executable, #!/bin/bash
pi/config.txt         # firmware boot config template
pi/cmdline.txt        # kernel cmdline template
```

Also write `plans/pi.md` following the house style of `plans/server.md` (`## Problem`, `## Shape`, `## Rejected approaches`) recording the decisions table above. This is the in-repo record; this plan file is the working document.

**Done when:** `pi/README.md` and `plans/pi.md` exist; `./test/all` passes.

### Task 0.2 — Decide the PKGBUILD source
The PKGBUILDs for `omarchy` and `omarchy-settings` live in a **separate repo**, `omacom/omarchy-pkgs`, under `pkgbuilds/<pkg>/PKGBUILD`. `bin/omarchy-dev-pkg-test` reads them from `${OMARCHY_PKGBUILDS_DIR:-~/Work/omarchy/omarchy-pkgs/pkgbuilds}`.

Try in order:
1. Add `omacom/omarchy-pkgs` to the session (`add_repo`) and clone it. Copy `pkgbuilds/omarchy/` and `pkgbuilds/omarchy-settings/` into `pi/pkgbuilds/`.
2. If inaccessible, **write them from scratch** using `docs/file-layout.md` — it contains the authoritative repo→installed-path map (§"Build-time map"), which is the entire content of both PKGBUILDs.

**Done when:** `pi/pkgbuilds/omarchy/PKGBUILD` and `pi/pkgbuilds/omarchy-settings/PKGBUILD` exist with `arch=('x86_64' 'aarch64')`.

---

## Phase 1 — Get a bare Arch Linux ARM onto the Pi (you, once, by hand)

This phase is manual and produces the machine everything else is tested on. It is not agent work.

1. Flash a card: partition as **1 GB FAT32 `/boot`** + remaining **ext4 `/`**, then
   ```bash
   wget http://os.archlinuxarm.org/os/ArchLinuxARM-rpi-aarch64-latest.tar.gz
   bsdtar -xpf ArchLinuxARM-rpi-aarch64-latest.tar.gz -C root
   mv root/boot/* boot
   ```
   Default login `alarm`/`alarm`, root `root`/`root`.
2. Boot, then on the Pi:
   ```bash
   pacman-key --init && pacman-key --populate archlinuxarm
   pacman -Syu
   pacman -S --needed base-devel git sudo openssh vim
   ```
3. Confirm you are on `linux-rpi` (not `linux-aarch64` + u-boot): `pacman -Q linux-rpi`. If not, `pacman -S linux-rpi` (it conflicts with and replaces `uboot-raspberrypi`).
4. Enable SSH, set a static-ish address or hostname, and clone `pimarchy` to `~/pimarchy`.

**Done when:** you can `ssh` into the Pi, `uname -m` says `aarch64`, and `~/pimarchy` is checked out on branch `claude/exciting-albattani-tzrrhe`.

### Task 1.1 — Record the hardware baseline
Run and capture into `pi/BASELINE.md` (this is the ground truth every later task checks against):

```bash
uname -a; cat /proc/cpuinfo | head -20
ls -l /dev/dri/ /dev/dri/by-path/
cat /sys/class/drm/*/status
cat /proc/device-tree/model | tr -d '\0'; echo
lsmod | grep -E 'vc4|v3d|brcmfmac|genet'
ls /sys/class/backlight /sys/class/power_supply 2>&1
ls /sys/class/dmi/id 2>&1
aplay -l; cat /proc/asound/cards
free -h; cat /sys/kernel/mm/transparent_hugepage/enabled
```

Expected and load-bearing: **no** `/sys/class/dmi/id`, **no** `/sys/class/power_supply`, **no** `/sys/class/backlight`, two DRM devices (`vc4` for KMS/display, `v3d` for render), connectors named `HDMI-A-1`/`HDMI-A-2`.

---

## Phase 2 — Platform detection

Every later guard keys off these. Follow `agents/skills/command-metadata.md`: `# omarchy:summary=` is mandatory, `hw-` commands return exit codes and print nothing.

### Task 2.1 — `bin/omarchy-hw-raspberry-pi`
Detect via device tree, not DMI (there is no DMI):

```bash
#!/bin/bash

# omarchy:summary=Check if running on a Raspberry Pi
# omarchy:hidden=true

model_path="${OMARCHY_DT_MODEL_PATH:-/proc/device-tree/model}"
[[ -r $model_path ]] || exit 1
tr -d '\0' <"$model_path" | grep -qi "raspberry pi"
```

The `$OMARCHY_DT_MODEL_PATH` override is required so `test/shell.d` can point it at a fixture — this is the pattern every existing detector uses (`$OMARCHY_PCI_DEVICES_PATH`, `$OMARCHY_DMI_PRODUCT_SKU`).

### Task 2.2 — `bin/omarchy-hw-raspberry-pi-400`
Same file, matching `Raspberry Pi 400`. Used only where 400-specific behaviour is needed (no audio jack, built-in keyboard).

### Task 2.3 — `bin/omarchy-hw-broadcom-vc4`
Detect the VideoCore display/render split by walking `/sys/class/drm/card*/device/of_node/compatible` (or `${OMARCHY_DRM_PATH:-/sys/class/drm}`) for `brcm,bcm2711-vc5` / `brcm,2711-v3d`. This is what `install/hardware/vulkan.sh` will call, since that file currently detects GPUs only via `lspci` and has no Broadcom entry at all.

### Task 2.4 — `bin/omarchy-hw-drm-primary`
Print the stable path of the **KMS/scanout** device (the `vc4` card, the one with connectors), not the render node. Card numbering is not stable across boots, so resolve through `/dev/dri/by-path/`. Prefer the entry whose `/sys/class/drm/card*/` contains `card*-HDMI-A-*` subdirectories. Print nothing and exit 1 when there is exactly one card (the normal x86 case), so callers can treat empty as "no override needed".

### Task 2.5 — Tests
Add `test/shell.d/hw-raspberry-pi-test.sh` sourcing `base-test.sh`. Use fixture directories under `test/shell.d/fixtures/` and the env overrides. Cover: Pi 4 model string matches, Pi 400 model string matches both commands, an x86 machine (missing model file) fails cleanly, a `Raspberry Pi 5` string matches the generic but not the 400 detector.

**Done when:** `./test/shell` passes and `./bin/omarchy commands --check` is clean.

---

## Phase 3 — Pacman: repos, mirrors, keyring

### Task 3.1 — `default/pacman/pacman-pi.conf` + `default/pacman/mirrorlist-pi`
Model on `default/pacman/pacman-stable.conf`, with four changes:

- **Drop `[multilib]` entirely** — it does not exist on any ARM architecture.
- Replace `[omarchy]` with a local repo:
  ```ini
  [pimarchy]
  SigLevel = Optional TrustAll
  Server = file:///var/cache/pimarchy/repo
  ```
- Add ALARM's own repos after `[core]`/`[extra]`: `[alarm]` and `[aur]`, both `Include = /etc/pacman.d/mirrorlist`.
- Keep `Architecture = auto` (resolves to `aarch64` correctly).

`mirrorlist-pi` is one line: `Server = http://mirror.archlinuxarm.org/$arch/$repo`.

Note the path shape differs from Arch's (`$arch/$repo`, not `$repo/os/$arch`) — this is why the mirrorlist must be a separate file rather than a substitution.

### Task 3.2 — Teach the channel commands about `pi`
Three files, small diffs:

- `bin/omarchy-refresh-pacman` — already interpolates `$channel` into both filenames, so `pi` works with no change. **Verify only.**
- `bin/omarchy-channel-set` — add a `pi)` case setting `pacman_channel=pi` and `packages=(omarchy omarchy-settings)`. Then, at the top, refuse the other channels on a Pi:
  ```bash
  if omarchy-hw-raspberry-pi && [[ $channel != "pi" && $channel != "dev" ]]; then
    fail "Only the 'pi' and 'dev' channels are available on Raspberry Pi."
  fi
  ```
- `bin/omarchy-version-channel` — it greps `/etc/pacman.conf` for `pkgs.omarchy.org/<channel>/`. Add a branch matching `file:///var/cache/pimarchy/repo` → `pi`.

### Task 3.3 — Guard `bin/omarchy-update-keyring`
It receives Omarchy's signing key `40DFB630FF42BCFFB047046CF0134EE680CAC571` and then runs `pacman -Sy --noconfirm archlinux-keyring`. On ALARM the keyring package is `archlinuxarm-keyring` and there is no Omarchy repo to trust. Wrap the whole body:

```bash
if omarchy-hw-raspberry-pi; then
  sudo pacman -Sy --noconfirm archlinuxarm-keyring
  exit 0
fi
```

### Task 3.4 — Local repo bootstrap
Add `bin/omarchy-refresh-rpi-repo` (`# omarchy:hidden=true`) that creates `/var/cache/pimarchy/repo`, runs `repo-add` over every `*.pkg.tar.zst` in it, and is safe to re-run. Called by Phase 4 and by the bootstrap.

---

## Phase 4 — Build the two packages for aarch64

### Task 4.1 — Port the PKGBUILDs
In `pi/pkgbuilds/{omarchy,omarchy-settings}/PKGBUILD`:
- Add `aarch64` to `arch=()`.
- Strip `depends` that have no aarch64 existence: anything `lib32-*`, `limine*`, `intel-ucode`, `amd-ucode`.
- Confirm `omarchy-settings` still installs `etc/**`, `default/fonts/**`, the plymouth and sddm themes, and `/etc/skel/**` — that tree is the reason we package at all.

### Task 4.2 — `bin/omarchy-update-rpi-pkgs`
Hidden command. Rebuilds Omarchy from the local checkout into the local repo:

1. `git -C "$checkout" pull --ff-only` (skip if dirty, warn, continue).
2. For each of `omarchy-settings`, `omarchy`: copy the PKGBUILD dir to a temp dir, set `pkgver` to `pi.$(git rev-parse --short HEAD)`, run `OMARCHY_SRC="$checkout" makepkg -s --skipchecksums --noconfirm`.
3. `cp` the results into `/var/cache/pimarchy/repo`, then `omarchy-refresh-rpi-repo`.

Mirror the `remove_pkgver_function` + `sed -i "s/^pkgver=.*/pkgver=$new/"` approach already in `bin/omarchy-dev-pkg-test` rather than inventing a new one.

### Task 4.3 — Hook it into the update pipeline
In `bin/omarchy-update`, immediately after the existing `omarchy-update-dev` line:

```bash
omarchy-hw-raspberry-pi && omarchy-update-rpi-pkgs
```

`omarchy-update-dev` already no-ops on a package install, and this runs before `omarchy-update-system-pkgs`, so the freshly built packages are in the repo when pacman looks. Add `test/shell.d/update-sequence-test.sh` coverage for the new ordering — that file already pins the pipeline order.

**Done when:** on the Pi, `sudo pacman -S omarchy omarchy-settings` installs from `[pimarchy]` and `omarchy-version` reports `pi.<sha>`.

---

## Phase 5 — Boot, initramfs, and the things that assume UEFI

### Task 5.1 — `pi/config.txt` and `pi/cmdline.txt` templates
`config.txt`:
```
arm_64bit=1
kernel=kernel8.img
initramfs initramfs-linux.img followkernel
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_overscan=1
disable_splash=1
arm_boost=1
```
Deliberately **not** set: `gpu_mem` (legacy, irrelevant under full KMS), `hdmi_enable_4kp60` (extra heat, opt-in), any overclock.

`cmdline.txt` — one line, mirroring the cmdline `etc/limine-entry-tool.d/omarchy-defaults.conf` sets on x86 minus the UEFI-only parts:
```
root=PARTUUID=@@ROOT_PARTUUID@@ rw rootwait fsck.repair=yes console=tty1 quiet loglevel=0 systemd.show_status=false rd.udev.log_level=0 vt.global_cursor_default=0
```

### Task 5.2 — `bin/omarchy-refresh-rpi-boot`
Writes both files to `/boot`, substituting the real root PARTUUID from `findmnt -no PARTUUID /`. Must be idempotent and must back up what it replaces (follow the `omarchy-refresh-limine` pattern of moving the old file aside). This is the Pi's equivalent of `omarchy-refresh-limine`.

### Task 5.3 — Pi mkinitcpio drop-in
ALARM's `linux-rpi` *does* use mkinitcpio and ships an ALPM hook targeting `kernel8.img`, so an initramfs exists. But `etc/mkinitcpio.conf.d/omarchy_hooks.conf` sets:

```
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap consolefont block encrypt filesystems fsck btrfs-overlayfs)
```

`microcode` is x86-only, `btrfs-overlayfs` comes from `limine-mkinitcpio-hook` which we do not install, and `encrypt`/`plymouth` are not wanted in v1. A missing hook makes `mkinitcpio` fail outright.

Add `etc/mkinitcpio.conf.d/omarchy_rpi.conf`, which must **sort after** `omarchy_hooks.conf` (drop-ins are sourced in sort order):

```bash
# The Pi has no microcode, no Limine (so no btrfs-overlayfs hook), no LUKS in
# the shipped image, and no Plymouth until the theme is verified on vc4.
if [[ -r /proc/device-tree/model ]] && tr -d '\0' </proc/device-tree/model | grep -qi "raspberry pi"; then
  HOOKS=(base udev keyboard autodetect modconf kms keymap consolefont block filesystems fsck)
  MODULES+=(vc4 v3d)
fi
```

Also neutralise `etc/mkinitcpio.conf.d/thunderbolt_module.conf`, which adds `MODULES+=(thunderbolt)` unconditionally — guard it with the same check or let the Pi drop-in remove it.

### Task 5.4 — Guard the UEFI/Limine commands
Each of these should exit early with a clear message on a Pi rather than failing obscurely. They already have partial guards; make them explicit:

| File | Change |
| --- | --- |
| `bin/omarchy-refresh-limine` | `omarchy-hw-raspberry-pi && { echo "Limine is not used on Raspberry Pi; run omarchy-refresh-rpi-boot."; exit 0; }` |
| `bin/omarchy-setup-direct-boot` | Already requires `/sys/firmware/efi` — extend the error to name the Pi. |
| `bin/omarchy-hibernation-setup` | Already refuses without `limine-mkinitcpio`. Add an explicit Pi message; a 4 GB swapfile on microSD would be destructive. |
| `bin/omarchy-update-firmware` | `fwupd` has no Pi path. Skip entirely on Pi. |
| `bin/omarchy-snapshot` | `create` must exit **127** (the code `omarchy-update` reads as "snapper deliberately absent, continue"). `restore` should explain that rollback on the Pi is an image restore. |
| `install/config/snapper.sh` | Wrap the body in `omarchy-hw-raspberry-pi || { ... }`. |

### Task 5.5 — I/O scheduler
`etc/udev/rules.d/60-omarchy-io-scheduler.rules` sets `kyber` for `mmcblk*`. On a single-queue microSD, `mq-deadline` or `bfq` is the better pick. Add a higher-numbered rule `etc/udev/rules.d/61-omarchy-rpi-io-scheduler.rules` setting `mq-deadline` for `mmcblk*` only, and leave the original rule untouched so USB-SSD boots still get `kyber` on `sd*`.

**Done when:** `sudo mkinitcpio -P` succeeds on the Pi and the machine reboots cleanly into a console.

---

## Phase 6 — Graphics: Hyprland on vc4/v3d

This is the highest-risk phase. Do it incrementally and capture a screenshot at each step (`agents/skills/visual-verification.md`).

### Task 6.1 — First light, before touching config
On the Pi, install `hyprland mesa vulkan-broadcom` and verify:
```bash
eglinfo -B 2>/dev/null | head -30    # expect GLES 3.1, renderer "V3D 4.2"
vulkaninfo --summary | head -20      # expect "V3D 4.2"
ls /dev/dri/                         # expect card0, card1, renderD128
```
Then run bare `Hyprland` from a TTY with no Omarchy config. **If this does not produce a desktop, stop and fix it before writing any code** — every later task assumes a working compositor.

### Task 6.2 — `default/hypr/broadcom.lua`
Model exactly on `default/hypr/nvidia.lua`, which is the only existing vendor conditional and is `require`d from `default/hypr/envs.lua`. Add `require("default.hypr.broadcom")` on the line after the nvidia require.

```lua
local is_vc4 = "omarchy-hw-broadcom-vc4"

if o.shell_succeeds(o.shell_quote(is_vc4)) then
  -- The Pi splits display (vc4) and render (v3d) across two DRM devices.
  -- Aquamarine must scan out on the KMS card, not the render node.
  local primary = o.shell_output(o.shell_quote("omarchy-hw-drm-primary"))
  if primary and primary ~= "" then
    hl.env("AQ_DRM_DEVICES", primary)
  end
end
```

Check the exact helper names available on the `o.` table in `default/hypr/helpers.lua` before writing this — `o.shell_succeeds` and `o.shell_quote` are confirmed to exist from `nvidia.lua`; a shell-output helper may need adding.

### Task 6.3 — Software cursors
`install/user/hardware/fix-nouveau-cursor.sh` already does exactly this for nouveau by appending to the user's `~/.config/hypr/looknfeel.lua`. Add `install/user/hardware/fix-vc4-cursor.sh` alongside it, gated on `omarchy-hw-broadcom-vc4`, appending:

```lua
hl.config({ cursor = { no_hardware_cursors = true } })
```

Register it in `install/user/all.sh` next to the nouveau one. **Test both settings on real hardware first** — vc4 does have a cursor plane, and if hardware cursors work they are cheaper. Only ship this leaf if software cursors measurably fix tearing or corruption.

### Task 6.4 — Fix the hardcoded `GDK_SCALE = 2`
`config/hypr/monitors.lua` ships `local omarchy_gdk_scale = 2`, which makes every GTK and XWayland app 2× too big on a 1080p HDMI panel. This is the single most visible wrong default on the Pi.

`bin/omarchy-hyprland-monitor-scaling` already rewrites both the `omarchy_monitor_scale` and `omarchy_gdk_scale` lines with `sed -E`, so the mechanism exists. Add a user-setup leaf `install/user/hardware/rpi-display-scale.sh` that calls it with scale `1` when `omarchy-hw-raspberry-pi`. Do **not** change the shipped default in `config/hypr/monitors.lua` — that would regress every x86 HiDPI laptop.

### Task 6.5 — The "internal display" assumption
Seven scripts treat `^(eDP|LVDS|DSI)-` as internal and everything else as external: `bin/omarchy-hyprland-monitor-{laptop,internal,internal-mirror,external-active}`, `bin/omarchy-monitor-state`, `bin/omarchy-brightness-display`, `bin/omarchy-hw-external-monitors`.

On a Pi both outputs are `HDMI-A-*`, so everything reads as external, and `omarchy-brightness-display` routes into the **DDC** branch — `ddcutil --skip-ddc-checks detect` probes I²C on every 5-second monitor-panel refresh and will usually fail slowly.

Fix at the narrowest point: in `bin/omarchy-brightness-display`, short-circuit `use_ddc_display()` to false when `omarchy-hw-raspberry-pi` unless the user has opted in via a state file. Leave the other six scripts alone — "everything is external" is *correct* on a Pi 400.

### Task 6.6 — Vulkan driver selection
`install/hardware/vulkan.sh` maps vendors by `lspci`:
```bash
declare -A VULKAN_DRIVERS=( [Intel]=vulkan-intel [AMD]=vulkan-radeon [Apple]=vulkan-asahi )
```
There is no Broadcom entry and the Pi's V3D is a device-tree device, not PCI, so **no ICD gets installed at all**. Add before the loop:

```bash
if omarchy-hw-broadcom-vc4; then
  PACKAGES+=(vulkan-broadcom)
fi
```
(`vulkan-broadcom` 1:26.2.2-1 is in ALARM `extra` for aarch64 — confirmed.)

### Task 6.7 — Animation budget
`default/hypr/looknfeel.lua` already ships blur and shadows **off**, which is the right starting point. Animations are on. Measure first with `hyprctl` frame timings; only if compositing is visibly janky, add a Pi branch that shortens the bezier durations. Do not disable animations pre-emptively.

**Done when:** Hyprland starts under Omarchy's own config, both HDMI outputs light up at native resolution and correct scale, and you have a `omarchy capture screenshot fullscreen save` of the desktop.

---

## Phase 7 — The Quickshell desktop

`quickshell` is in ALARM `extra` for aarch64. The shell uses `Quickshell.Networking` and `Quickshell.Bluetooth`, which are recent modules — **verify the packaged version exposes them before starting** by running `quickshell -n -p $OMARCHY_PATH/shell` and reading `journalctl -t omarchy-shell`. If they are missing, building `quickshell-git` from the AUR is the fallback (several migrations already install it).

### Task 7.1 — Stop the 2-second power-profile poll
`shell/plugins/services/battery/Service.qml` runs unconditionally:

```qml
Timer { interval: 2000;  running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshPowerProfile() }
Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.checkBattery() }
```

The 2 s timer spawns `busctl get-property net.hadess.PowerProfiles ...` forever. The Pi has no battery, no `platform_profile`, and no `intel_pstate`/`amd_pstate` — so this is a permanent process-spawn tax for data that never changes.

Gate both timers on availability:
```qml
running: UPower.displayDevice && UPower.displayDevice.isPresent
```
for the battery timer, and on a `powerProfilesAvailable` property (set false when the first `busctl` call yields no profiles) for the profile timer. The existing `parseActiveProfile()` already returns `""` on failure, so this degrades rather than breaks.

**Keep the `busctl` call itself** — the code comment explains it replaced `powerprofilesctl get` because that is a PyGObject script that hit a CPython 3.14 shutdown race causing daily SIGSEGV core dumps.

Read `agents/skills/shell-dev.md` first: the shell is one long-running process, `omarchy-restart-shell` after QML edits, and **agent edit tools strip Nerd Font glyphs from `shell/plugins/bar/widgets/`** — do not let an agent reformat those files.

### Task 7.2 — Power profiles daemon
`power-profiles-daemon` is in the base package list and enabled by `install/config/enable-services.sh`. On BCM2711 it will either fail to start or expose only `balanced`, so `omarchy-powerprofiles-init` (called from `default/hypr/autostart.lua` on every boot) fails noisily.

Two small changes: guard the `systemctl enable power-profiles-daemon.service` line in `install/config/enable-services.sh`, and make `bin/omarchy-powerprofiles-set` exit 0 quietly when `omarchy-powerprofiles-list` is empty.

### Task 7.3 — Verify the panels self-hide
These are *expected* to already work; confirm on hardware and file bugs only if they do not:
- `shell/plugins/panels/power/Panel.qml` — `visible: batteryPresent`, collapses to zero size.
- `shell/plugins/panels/monitor/Panel.qml` — drops the brightness section when `omarchy-monitor-state` reports `unavailable`; keeps text-size, scale, and the multi-display section, which is exactly right for two micro-HDMI ports.
- `bin/omarchy-brightness-keyboard` — prints "No keyboard backlight device found"; the `XF86Kbd*` bindings become harmless no-ops.

### Task 7.4 — Shell smoke test
Add `test/shell.d/rpi-shell-gating-test.sh` using `run_node_test` against `shell/plugins/services/battery/BatteryModel.js` to pin that an absent device yields `-1` / `notify:false`, and a bash assertion that the new timer gating property exists in `Service.qml`.

---

## Phase 8 — Audio (HDMI only)

The Pi 400 **has no 3.5 mm jack** — output is HDMI, USB, or Bluetooth only. PipeWire will enumerate `vc4-hdmi-0` and `vc4-hdmi-1`.

### Task 8.1 — Sink priority
`bin/omarchy-audio-sink-availability` and `bin/omarchy-audio-output-switch` filter on port availability, and `vc4-hdmi` cards report availability oddly when nothing is streaming — PipeWire may pick the silent HDMI port. Add a WirePlumber drop-in alongside the two that already ship in `config/wireplumber/wireplumber.conf.d/`:

`config/wireplumber/wireplumber.conf.d/rpi-hdmi-priority.conf` — an `monitor.alsa.rules` block matching `~alsa_output.platform-fef00700.hdmi.*` that raises `priority.session` on HDMI-0 and marks both HDMI nodes always-available.

Follow the shape of the existing `kef-lsx-no-suspend.conf`. Verify the actual node names from `pactl list sinks short` on the Pi first; the object path depends on the SoC address.

### Task 8.2 — Speaker tuning is already a clean no-op
`install/hardware/speaker-tuning.sh` matches on DMI, which the Pi lacks, so `lsp-plugins-lv2` is never installed. **Verify only, change nothing.**

---

## Phase 9 — The install pipeline

### Task 9.1 — `install/omarchy-base-aarch64.packages` (the triage)
This is the biggest mechanical task and is ideal for a small agent. `install/omarchy-base.packages` has ~140 entries; a large fraction come from the `[omarchy]` repo and do not exist for aarch64.

Run **on the Pi**, after Phase 3, a script `pi/triage-packages.sh` that for every line in both `.packages` files runs `pacman -Si <pkg>` and classifies:

| Class | Meaning | Action |
| --- | --- | --- |
| **A** | Found in ALARM `core`/`extra`/`alarm` | Keep as-is |
| **B** | Not found, but an AUR PKGBUILD builds on aarch64 | Keep, note the build cost |
| **C** | Omarchy-original (`aether`, `cliamp`, `herdr`, `omacalc`, `omacut`, `omawrite`, `tensaku`, `tobi-try`, `ttfx`, `omarchy-nvim`, `mise-bin`, `ttf-jetbrains-mono-nerd-basic`, `woff2-font-awesome`, `gpu-screen-recorder`, `asdcontrol`, `hyprland-preview-share-picker`) | Needs a source build — defer all of these out of v1 |
| **D** | x86-only with no ARM analogue (every `lib32-*`, `dotnet-runtime`, `nvidia-*`, `intel-*`, `linux-t2`, `broadcom-wl-dkms`, `macbook12-spi-driver-dkms`, `tuxedo-*`, `yt6801-dkms`, `sof-firmware`, `thermald`, `egl-wayland`) | Drop |

Output: `install/omarchy-base-aarch64.packages` (the Pi pacstrap set) and `docs/pi-package-triage.md` (the full table, so the next person knows *why* each one was dropped).

**Known specifics to bake in:**
- `yay` is **not** in ALARM aarch64 (404) and Omarchy never bootstraps it — it is shipped as a prebuilt package. Build it from the AUR PKGBUILD with `makepkg -si` in the bootstrap; it is Go and builds fine on aarch64. Add `pi/pkgbuilds/` handling or just a bootstrap step.
- Must be **added** for the Pi: `linux-rpi`, `linux-rpi-headers`, `raspberrypi-bootloader`, `raspberrypi-firmware`, `firmware-raspberrypi`, `vulkan-broadcom`, `archlinuxarm-keyring`.
- Check `pi-bluetooth` / `bluez-firmware` for the Pi 400's UART Bluetooth, and confirm `brcmfmac` board firmware (`brcmfmac43455-sdio.raspberrypi,400.txt`) is present for Wi-Fi. Both are verify-then-fix, not assume.

### Task 9.2 — Fix the hardcoded `linux-x64` Node tarball
`install/user/mise-work.sh` is a **hard `exit 1`** in image-build context:

```bash
NODE_TARBALL=$(find "$NODE_PACKAGE_DIR" -name "node-v*-linux-x64.tar.gz" -type f | head -n1)
NODE_VERSION=$(basename "$NODE_TARBALL" | sed 's/node-v\(.*\)-linux-x64.tar.gz/\1/')
```

Generalise both the glob and the `sed` to accept `x64` or `arm64`, deriving the arch from `uname -m`. `bin/omarchy-system-factory-reset` already stages the same tarball with a looser glob (`node-v*.tar.gz`) — match that looseness.

### Task 9.3 — Audit the mise-installed CLIs
`install/user/mise.sh` installs ~18 CLIs from `github:`/`npm:`/`aqua:` backends on every install. `npm:` ones are fine. The `github:` release-asset ones (`codex`, `claude`, `crush`, `antigravity-cli`, `gh`, `copilot`, `opencode`, `pi`, `oh-my-pi`, `cursor-agent`, `hunk`, `hey-cli`, `basecamp-cli`, `ori`) each need a `linux-arm64` asset or they fail on first invocation.

`omarchy-mise-install` only writes a lazy wrapper into `~/.local/bin/` — nothing downloads at install time, so a missing asset fails *later*, at first use, which is a bad experience. Produce `docs/pi-mise-triage.md` by checking each project's latest release assets, and guard the confirmed-x86-only ones with `omarchy-hw-raspberry-pi ||`.

### Task 9.4 — Audit the bare `lspci` calls
Most of the ~37 hardware leaves are DMI/PCI-gated and no-op safely on a Pi. But these call `lspci` bare, and `install/` leaves run under `bash -eE`, so a failure aborts setup: `install/hardware/fix-yt6801-ethernet-adapter.sh`, `fix-bcm43xx.sh`, `apple/fix-t2.sh`, `apple/fix-brcmfmac-supplicant.sh`, `intel/fix-wifi7-eht.sh`, `hardware/pacman.sh`, `hardware/vulkan.sh`, `hardware/nvidia.sh`, `intel/video-acceleration.sh`.

Add `|| true` or an `omarchy-cmd-present lspci` guard to each. `pciutils` may not even be installed on the Pi.

### Task 9.5 — `install/hardware/raspberry-pi.sh` and its leaves
New leaf sourced from `install/hardware/all.sh` (add it **first**, before the x86 vendor leaves, matching how `intel/ptl-kernel.sh` is ordered before anything that pulls DKMS). No shebang, no `exit`, uses `$OMARCHY_INSTALL`:

```bash
# Raspberry Pi hardware setup. Everything here is a no-op on other machines.
if omarchy-hw-raspberry-pi; then
  run_logged "$OMARCHY_INSTALL/hardware/rpi/boot-config.sh"
  run_logged "$OMARCHY_INSTALL/hardware/rpi/firmware.sh"
  run_logged "$OMARCHY_INSTALL/hardware/rpi/bluetooth.sh"
fi
```

- `rpi/boot-config.sh` → calls `omarchy-refresh-rpi-boot`
- `rpi/firmware.sh` → installs `firmware-raspberrypi`, verifies brcmfmac board firmware for Wi-Fi
- `rpi/bluetooth.sh` → whatever Task 9.1 determines the UART Bluetooth needs

### Task 9.6 — `pi/bootstrap`
A standalone script (this one **does** get `#!/bin/bash`) that turns a stock ALARM install into Pimarchy. This is the iteration loop: reflash ALARM, re-run, test — minutes, not an image build.

Ordered steps:
1. Refuse to run if not `omarchy-hw-raspberry-pi` and not `aarch64`.
2. `pacman-key --init && pacman-key --populate archlinuxarm`
3. Install `base-devel git` if missing; build and install `yay` from AUR.
4. Clone or update `~/pimarchy`.
5. Copy `default/pacman/pacman-pi.conf` → `/etc/pacman.conf`, `mirrorlist-pi` → `/etc/pacman.d/mirrorlist`; `omarchy-refresh-rpi-repo`.
6. `pacman -Syu` then install `install/omarchy-base-aarch64.packages`.
7. `omarchy-update-rpi-pkgs` → builds and installs `omarchy` + `omarchy-settings`.
8. `sudo omarchy-apply-system --install-user "$USER" --first-install`
9. `omarchy-provision-user --force --first-install`
10. `omarchy-refresh-rpi-boot`, `mkinitcpio -P`, prompt for reboot.

Steps 8–9 are the **existing** target-side entry points — `bin/omarchy-apply-system` sources `install/config/all.sh`, calls `omarchy-apply-hardware`, then `install/login/all.sh` and `install/post-install/all.sh`. Do not reimplement any of it.

**Done when:** a freshly flashed ALARM card plus `curl ... | bash` of `pi/bootstrap` reboots into the Omarchy desktop.

---

## Phase 10 — The flashable image (the DietPi-style deliverable)

Only start this once Phase 9 reliably produces a working system.

### Task 10.1 — `pi/build-image`
Builds `pimarchy-<version>-aarch64.img.xz`. Runs either natively on the Pi (slow but simple) or on an x86 host under `qemu-user-static` + `binfmt` (`qemu-user-static-binfmt` is already in Omarchy's base package list).

1. `truncate` a sparse image, `losetup`, partition 1 GB FAT32 + rest ext4.
2. Extract `ArchLinuxARM-rpi-aarch64-latest.tar.gz`, move `boot/*` to the FAT partition.
3. `arch-chroot` in and run `pi/bootstrap` in a non-interactive mode with `OMARCHY_SETUP_CONTEXT=iso-chroot`.
4. **Arm deferred provisioning**: `touch /var/lib/omarchy/provisioning/pending` and enable `omarchy-provision-owner.service` (`install/provisioning/omarchy-provision-owner.service`, ordered `Before=display-manager.service` on tty1).
5. Zero free space, unmount, `xz -9`.

### Task 10.2 — First-boot wizard on the Pi
`bin/omarchy-provision-owner` sources `install/provisioning/setup-form.sh` and asks keyboard → username → password → identity → hostname → timezone, then creates the user, configures SDDM autologin, runs `omarchy-provision-user --force --first-install`, re-keys LUKS, and runs `limine-update`.

Two Pi-specific edits:
- Skip `rekey_luks` — there is no LUKS in the v1 image.
- Replace the `limine-update` call with `omarchy-refresh-rpi-boot`.

Both behind `omarchy-hw-raspberry-pi`. This is what makes the image behave like DietPi: flash, boot, answer six questions, land in Hyprland.

### Task 10.3 — Shrink the first boot
Add a `systemd` unit or a `pi/bootstrap` step that grows the root partition to fill the card on first boot (standard `parted resizepart` + `resize2fs`), so the image can ship small.

---

## Phase 11 — Remove or gate what cannot work

Guarded, not deleted (your call was "decide later"). Each of these should print one clear line and exit 0 on a Pi.

| Area | Files |
| --- | --- |
| **Windows VM** — `dockurr/windows` is x86-only and the script's own error text says `modprobe kvm-intel`/`kvm-amd` | `bin/omarchy-windows-vm`, `bin/omarchy-windows-key`, `default/hypr/apps/windows-vm.lua`, the `GROUP_DESCRIPTIONS[windows]` entry in `bin/omarchy`, `manual/28-windows-vm.md` |
| **Gaming** — Steam, Lutris, wine, umu, Battle.net, GeForce Now (downloads an x86 ELF) and all `lib32-*` | `bin/omarchy-install-gaming-*`, `bin/omarchy-remove-gaming-steam`, `default/hypr/apps/{steam,battlenet,geforce,retroarch,moonlight}.lua` |
| **x86-only proprietary apps** — 1Password, Dropbox, Zoom, Spotify, Chrome, VS Code `-bin`, Cursor, NordVPN | `bin/omarchy-install-service-*`, `bin/omarchy-install-editor-*`, `bin/omarchy-install-browser`, and the matching entries in `default/omarchy/omarchy-menu.jsonc` (see `docs/menu.md` for the guard schema — the menu already supports guards, use them rather than deleting entries) |
| **MSSQL container** — no arm64 manifest; MongoDB's arm64 build needs ARMv8.2 and will not run on a Cortex-A72 | `bin/omarchy-install-docker-dbs` — drop both entries on Pi. No `--platform` flag exists anywhere in the repo; the other images are multi-arch and fine. |

Prefer the menu's existing guard mechanism over editing command bodies wherever the entry is menu-driven.

---

## Phase 12 — Tests, docs, and stretch items

### Task 12.1 — Test coverage
New files in `test/shell.d/` (the runner globs `*-test.sh`, no registration needed):
- `hw-raspberry-pi-test.sh` (Task 2.5)
- `rpi-boot-config-test.sh` — `omarchy-refresh-rpi-boot` substitutes PARTUUID, is idempotent, backs up
- `rpi-pacman-channel-test.sh` — `omarchy-version-channel` reports `pi`; `omarchy-channel-set` refuses `stable` on a Pi
- `rpi-shell-gating-test.sh` (Task 7.4)
- Extend `test/shell.d/update-sequence-test.sh` for the `omarchy-update-rpi-pkgs` step

All use fixture dirs + env overrides + `HOME=$(mktemp -d)` with `OMARCHY_PATH="$ROOT"`, per `docs/testing.md`.

### Task 12.2 — Docs
- `docs/raspberry-pi.md` — reference: the ALARM base, the boot chain, the local repo, what is disabled and why. Link it from `AGENTS.md`'s documentation-layout section.
- `manual/49-omarchy-on.md` — add a "Raspberry Pi 400" section alongside the existing Asahi/Steam Deck/NixOS entries. This is the user-facing home for the port and follows the precedent those entries set.
- `pi/README.md` — build and flash instructions.

### Task 12.3 — Graphical acceptance tests
`test/acceptance` requires the sibling `omarchy-iso` repo's QEMU/QMP harness, which is x86-only. **Out of scope.** Verify visually on the Pi per `agents/skills/visual-verification.md` instead: `omarchy capture screenshot fullscreen save` for each of bar, menu, panels, lock screen, theme switch.

### Stretch items (explicitly not v1)
- btrfs + snapper (no boot-menu rollback without Limine; restore from a running system or a rescue card)
- LUKS (argon2id is slow on a Cortex-A72; re-tune `--iter-time` well below 2000 if attempted)
- Plymouth (needs the theme verified against vc4 KMS)
- `omarchy-setup-rpi-overclock` — opt-in `over_voltage`/`arm_freq` writer with a loud warning
- `hdmi_enable_4kp60` toggle
- Hosting a real aarch64 pacman repo instead of the local `file://` one

---

## Verification

End-to-end, in order:

1. **In this container, after every code change:** `./test/all` — both suites are arch-neutral and headless-safe.
2. **Metadata lint:** `./bin/omarchy commands --check` — fails on any new command missing `# omarchy:summary=`.
3. **On the Pi, Phase 6 gate:** bare `Hyprland` from a TTY produces a desktop; `eglinfo -B` reports V3D 4.2 with GLES 3.1.
4. **On the Pi, Phase 9 gate:** flash stock ALARM → run `pi/bootstrap` → reboot → SDDM → Hyprland with the Quickshell bar. Then `omarchy update` completes, `omarchy-version` reports `pi.<sha>`, and `omarchy-migrate --pending` is empty.
5. **On the Pi, functional sweep:** open the menu (Super), switch themes (`omarchy theme set`), take a screenshot, connect Wi-Fi from the network panel, pair a Bluetooth device, play audio over HDMI, verify the power panel is hidden and the monitor panel shows no brightness section.
6. **Phase 10 gate:** flash `pimarchy-*.img.xz` to a blank card on a second Pi (or the same one), boot, complete the first-run wizard, land in Hyprland without touching a terminal.
7. **Regression check:** nothing in this plan may change x86 behaviour. Every new branch is behind `omarchy-hw-raspberry-pi` or `omarchy-hw-broadcom-vc4`, and `config/hypr/monitors.lua`'s shipped `GDK_SCALE = 2` stays as it is.

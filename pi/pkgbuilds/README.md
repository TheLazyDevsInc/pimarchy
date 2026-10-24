# Pimarchy package builds

A Raspberry Pi installs Omarchy's own packages from a local repository, `[pimarchy]` at `/var/lib/pimarchy/repo`, which `omarchy-update-rpi-pkgs` builds from these PKGBUILDs in the Pi's Pimarchy checkout at `/var/lib/pimarchy/src` ([`docs/raspberry-pi.md`](../../docs/raspberry-pi.md)).

- `omarchy/` and `omarchy-settings/` are upstream's, vendored from [`omacom/omarchy-pkgs`](https://github.com/omacom/omarchy-pkgs) at commit `fccc432` (its `pkgbuilds/omarchy/` and `pkgbuilds/omarchy-settings/`, without their `.omarchy/` release metadata).
- `omarchy-rpi-boot/` is Pimarchy's own: the Pi's platform boot package.

## How they are built

`omarchy-update-rpi-pkgs` always builds with `OMARCHY_SRC` set to the checkout, so the vendored PKGBUILDs copy the tree they are part of and never fetch anything; their pinned `_tag`, `_commit`, `source` and `sha256sums` are upstream's release pins and go unused here. It builds a copy of each PKGBUILD whose `pkgver` is the vendored one plus `.r<commit count>.g<short sha>` of the checkout, as an unprivileged user with `makepkg --nodeps`, and publishes the results with `repo-add`.

`omarchy` depends on `omarchy-settings` of exactly its own version, so the two must keep the same `pkgver`; the build refuses to start when they differ.

## Rules for the vendored PKGBUILDs

- Keep them as upstream wrote them. Change only what the Pi needs, and list every such change below with its reason, so the next re-vendor can carry it over or drop it.
- Re-vendor by copying upstream's files over these, then reapplying the changes listed below, and update the commit named above.

## Local changes

1. `omarchy/PKGBUILD` and `omarchy-settings/PKGBUILD`, `prepare()`: the copy of `OMARCHY_SRC` leaves out the checkout's `.git`. Upstream copies the whole checkout, history included, into each package's build directory. The Pi's checkout is a clone of this fork, whose history runs past a gigabyte, and both packages are built on the Pi's SD card at every update that moves it; `package()` never reads the history.

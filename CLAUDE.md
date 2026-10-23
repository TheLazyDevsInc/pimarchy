# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

`AGENTS.md` above is the shared agent contract: style, command naming, helper commands, menu and config conventions, the test entry points, and the per-task guides under `agents/skills/`. This file adds what it leaves out: the commands a contributor actually runs and the architecture that only becomes clear after reading several files.

## What this repository is

Omarchy is an Arch Linux desktop built on the Hyprland compositor and a Quickshell desktop shell, developed here as a fork of `omacom/omarchy`. The default branch is `quattro` (the 4.0 line; see `version`). The code is almost entirely bash (`bin/`, `install/`, `migrations/`, `test/`), QML plus plain JavaScript (`shell/`), and Lua (Hyprland config under `default/hypr/` and `config/hypr/`). There is no build step: the checkout *is* the product, installed to `/usr/share/omarchy` and exposed to all runtime code as `$OMARCHY_PATH`.

Packaging and installation live in sibling repositories, not here. `omarchy-pkgs` holds the PKGBUILDs that split this tree into the `omarchy` package (runtime: `bin/`, `install/`, `migrations/`, `themes/`, `shell/`) and the `omarchy-settings` package (everything that must exist before the user is created: `config/**` as `/etc/skel`, `etc/`, `default/`, fonts, branding). `omarchy-iso` builds the installer and runs the graphical acceptance suite. `docs/file-layout.md` has the full repo-path to installed-path map and a "where does X live?" table; consult it before adding a file anywhere other than `bin/`.

## Commands

Every suite is plain bash and runs from the repo root with no setup:

```bash
./test/all                              # test/cli + test/shell; keeps going past a failing suite
./test/cli                              # router, command metadata lint, theme pipeline (one script)
./test/shell                            # every test/shell.d/*-test.sh, one file per area
bash test/shell.d/menu-test.sh          # a single shell test file
bin/omarchy commands --check            # the metadata lint alone (test/cli runs it too)
bin/omarchy theme set --help            # see which binary a route resolves to
bin/omarchy-dev-add-migration --no-edit # new migrations/<unix-timestamp>.sh
```

Test protocol: TAP-flavoured `ok - ...` / `not ok - ...` lines; a file exits at its first failed assertion, and the runner continues with the next file and lists the failures at the end. Tests exercise the checkout (`ROOT`, `OMARCHY_PATH=$ROOT`) against a fake `$HOME` and stub binaries prepended to `PATH`, and they must stay green on headless machines: files that need a live session gate themselves with `require_compositor`, and a skip counts as a pass. Shell model logic in plain `.js` modules is tested from bash through `run_node_test`. `node`, `rg`, and `jq` are needed by various test files. `docs/testing.md` is the full contract.

Do not run `./test/shell` as root. `test/shell.d/windows-vm-mount-boundary-test.sh` only enters a private user+mount namespace when `EUID != 0`; as real root it mounts tmpfs over the live `/run`, `/var`, and `/home` and never unmounts them, which hides the checkout itself when it lives under `/home`. Run the suite as an unprivileged user, in CI containers included.

The graphical acceptance suite (`./test/acceptance`, `test/acceptance.d/`) runs only inside a disposable VM driven from `../omarchy-iso`, never in the development session; `agents/skills/acceptance-tests.md` has the invocations.

On an Omarchy machine, `omarchy dev link` points the running system at a checkout (via `/etc/omarchy.conf` and a sudoers `secure_path` drop-in), `omarchy dev unlink` restores the package, `omarchy dev status` shows which is active, and `omarchy-restart-shell` reloads QML changes. `omarchy dev benchmark cli` tracks router latency, `omarchy dev pkg test` builds and installs a package from the checkout, and `omarchy dev ui preview` opens the `qs.Ui` component gallery.

## Architecture

### The CLI: `bin/omarchy` routes a flat namespace

`bin/` holds roughly 450 flat `omarchy-<group>-<name>` executables and one router, `bin/omarchy`, that maps `omarchy theme set foo` onto `exec omarchy-theme-set foo`. There is no registry: every executable file is a command, its filename is its default route, and a comment header (`# omarchy:summary=`, `group=`, `name=`, `args=`, `alias=`, `hidden=true`, `requires-sudo=true`; read from the first 80 lines up to the first non-comment line) refines presentation and routing. Dispatch is longest-prefix: a fast path probes filenames joined with hyphens, and only aliases or metadata-moved routes fall back to parsing every header. `--help`/`-h` anywhere in the leftover arguments prints help instead of executing, and a command whose `args` metadata lists required arguments shows help when called bare. `GROUP_DESCRIPTIONS` in `bin/omarchy` is the one hand-curated piece; it drives the top-level listing. `docs/cli-router.md` covers the rest.

### How a user's `$HOME` is populated

1. **Seed.** `config/**` ships inside `omarchy-settings` as `/etc/skel/.config/**`, so `useradd -m` copies it into a new user's home. This fires only at user creation.
2. **Finalize.** `bin/omarchy-provision-user` runs once per user for what `/etc/skel` cannot do (agent skill symlinks, XDG dirs, mime defaults, `install/user/all.sh`); `bin/omarchy-provision-first-run` then handles the steps that need a live graphical session (user units, dconf, welcome toasts). Both are idempotent through markers in `~/.local/state/omarchy/done/` managed by `omarchy-done`.
3. **Resync.** `omarchy-reinstall-configs` replays `/etc/skel` over `$HOME` destructively for users who want shipped defaults back.

Root-side setup at ISO time is `bin/omarchy-apply-system`, which sources the leaves under `install/config/`, `install/hardware/` (through `omarchy-apply-hardware`), `install/login/`, and `install/post-install/`. Those leaves are sourced, not executed, so they carry no shebang and must not `exit`. `install/omarchy-base.packages` and `install/omarchy-other.packages` are the package lists the ISO pacstraps.

State split: regenerable state goes under `~/.local/state/omarchy/` (`current/` holds the active theme and background symlink, `migrations/` the per-user markers, `done/` completion markers, `notifications/` live toasts and history); anything a user may want to version in dotfiles goes under `~/.config/omarchy/` (user themes, hooks, `shell.json`, `shell.toml`, plugins, `themed/*.tpl` overrides, `extensions/omarchy-menu.jsonc`).

### Updates and migrations

`omarchy update` owns the update pipeline: package transaction, then `omarchy-migrate`, then `omarchy-hook post-update`, then an unconditional shell restart. `bin/omarchy-update-pacman-guard` aborts a bare `pacman -Syu` unless `OMARCHY_ALLOW_DIRECT_PACMAN=1` is set. Migrations are `migrations/<unix-timestamp>.sh`, mode `0644`, no shebang, run with `bash -euo pipefail` as the user, strictly ordered and idempotent, with per-user markers in `~/.local/state/omarchy/migrations/`; the login-time notifier only prompts for pending ones and never runs them in the background. The 3-to-4 crossing is `bin/omarchy-upgrade-to-quattro`, not a migration. `agents/skills/migrations.md` and `docs/update-process.md` are the references.

### Theming

A theme is `themes/<name>/colors.toml` plus optional `shell.toml`, backgrounds, and previews. `omarchy-theme-set <name>` stages the theme under `~/.local/state/omarchy/current/next-theme`, overlays `~/.config/omarchy/themes/<name>/`, renders every `default/themed/*.tpl` (`{{ variable }}` placeholders; existing hand-written files win over templates, and user templates in `~/.config/omarchy/themed/` win over built-ins), swaps it into `current/theme`, notifies the shell over IPC, fires the `theme-set` hook, and runs the `post_theme_commands` retint list in `bin/omarchy-theme-set`. That list is where a new application gets added so it follows theme switches. Themes cloned from git by `omarchy theme install` are untrusted: `INSTALLED_THEME_DENIED` in `bin/omarchy-theme-set` drops anything that can run code (`*.lua`, terminal configs, `vscode.json`), and `test/shell.d/theme-staging-test.sh` fails until every new `.tpl` is classified as code or colour. `docs/theming.md` has the details.

### The shell: one Quickshell process, everything is a plugin

`shell/shell.qml` is the single long-running `omarchy-shell` process, launched by Hyprland autostart through `omarchy-launch-shell`. The bar, panels, overlays, menus, lock screen, OSD, polkit agent, and the notification daemon (the shell itself claims `org.freedesktop.Notifications`; there is no dunst or mako) are plugins under `shell/plugins/`, each with a `manifest.json` whose `kinds` are `bar-widget`, `bar`, `panel`, `overlay`, `menu`, or `service`, discovered by `shell/services/PluginRegistry.qml`. Third-party plugins live in `~/.config/omarchy/plugins/<id>/` and receive capability-scoped facades rather than host objects. Shared tokens come from the `qs.Commons` singletons `Color`, `Style`, and `Border`, fed by the active theme's `shell.toml`; reusable controls live in `qs.Ui`.

CLIs talk to the shell over IPC through `bin/omarchy-shell <target> <method> ...`. Targets are named for plugins (`shell`, `background`, `osd`, `notifications`, `omarchy.clock`, ...); there is no `bar` target. `~/.config/omarchy/shell.json` is canonical once it exists, with no deep-merge against `config/omarchy/shell.json`. The menu is data: `default/omarchy/omarchy-menu.jsonc` overlaid by the user's `extensions/omarchy-menu.jsonc`, parsed and watched live by `shell/plugins/menu/MenuModel.js`.

Model logic deliberately lives in plain `.js` files (`MenuModel.js`, `BarModel.js`, `NotificationLogic.js`, `panels/*/Model.js`, ...) that end in a guarded `module.exports`. QML imports them directly and Node loads them as CommonJS, which is what lets `test/shell.d/` test shell behaviour without a compositor; keep new shell logic in that shape. `docs/omarchy-shell.md`, `shell/README.md`, and `shell/plugins/README.md` are the references, and `agents/skills/shell-dev.md` warns that bar widget files contain raw Nerd Font glyphs that wholesale rewrites can corrupt.

### Hyprland config is Lua

`default/hypr/*.lua` is the package-owned Hyprland configuration (`bootstrap.lua`, `bindings/`, `apps/`, `toggles/`, `windows.lua`, ...) and `config/hypr/*.lua` is the thin user-editable layer seeded into `~/.config/hypr/`. `.luarc.json` points the Lua language server at `/usr/share/hypr/stubs` and declares the `hl` global.

## Reference docs

`docs/` is the system-shape reference: `file-layout.md` (repo to installed map, `$HOME` layers, env bootstrap), `cli-router.md`, `omarchy-shell.md` (plugins, IPC, `shell.json`, theme tokens), `theming.md`, `menu.md`, `notifications.md`, `update-process.md`, `testing.md`, and `audio-tuning.md`. `manual/` is end-user documentation and `plans/` holds design proposals; neither documents internals.

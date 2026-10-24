#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
# The platform detector ignores its fixtures as root, and root would publish
# for real: everything here runs as the unprivileged caller omarchy update is.
require_platform_fixtures "the Raspberry Pi's local package builds"
require_command git
require_command tar

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

real_git=$(command -v git)
export HOME=$test_tmp/home GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME"

fixture=$test_tmp/fixture
pimarchy=$fixture/pimarchy
repo=$pimarchy/repo
src=$pimarchy/src
scratch=$fixture/tmp
bin=$test_tmp/bin
stubs=$test_tmp/stubs
log=$test_tmp/log
mkdir -p "$fixture" "$scratch" "$bin" "$stubs" "$log.d"

# The command works on fixed root-owned paths that nothing in its environment
# moves. This copy works on the fixture's instead, beside the real platform
# predicate and detector, which read the fixture device trees below.
sed -e "s|/var/lib/pimarchy|$pimarchy|g" -e "s|/var/tmp|$scratch|g" \
  "$ROOT/bin/omarchy-update-rpi-pkgs" >"$bin/omarchy-update-rpi-pkgs"
chmod +x "$bin/omarchy-update-rpi-pkgs"
! grep -qE '/var/lib/pimarchy|/var/tmp' "$bin/omarchy-update-rpi-pkgs" || fail "the copy works on the fixture alone"
ln -s "$ROOT/bin/omarchy-hw-aarch64-rpi" "$ROOT/bin/omarchy-hw-platform" "$bin/"
for platform in aarch64-rpi aarch64 x86; do
  fake_platform "$test_tmp/$platform" "$platform"
done

# sudo and runuser run what they are given as the caller, and say so.
cat >"$stubs/sudo" <<'STUB'
#!/bin/bash
printf 'sudo %s\n' "$*" >>"$RPI_TEST_LOG"
exec "$@"
STUB
cat >"$stubs/runuser" <<'STUB'
#!/bin/bash
[[ ${1:-} == "-u" && ${3:-} == "--" ]] || exit 90
printf 'runuser %s\n' "$*" >>"$RPI_TEST_LOG"
shift 3
exec "$@"
STUB
# git is the real one, logged, and offline when a test says so.
cat >"$stubs/git" <<STUB
#!/bin/bash
printf 'git %s\n' "\$*" >>"\$RPI_TEST_LOG"
if [[ \${RPI_TEST_OFFLINE:-0} == 1 && " \$* " == *" fetch "* ]]; then
  exit 128
fi
exec "$real_git" "\$@"
STUB
# makepkg writes the package its PKGBUILD names, keeps a copy of that PKGBUILD,
# and fails the package a test names. A pkgver() left in would override the
# version it was given.
cat >"$stubs/makepkg" <<'STUB'
#!/bin/bash
pkgname=$(sed -n "s/^pkgname=['\"]\{0,1\}\([^'\"]*\).*/\1/p" PKGBUILD | head -1)
pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
pkgrel=$(sed -n 's/^pkgrel=//p' PKGBUILD)
printf 'makepkg %s pkg=%s-%s cwd=%s OMARCHY_SRC=%s PKGDEST=%s BUILDDIR=%s PKGEXT=%s\n' \
  "$*" "$pkgname" "$pkgver" "$PWD" "$OMARCHY_SRC" "$PKGDEST" "$BUILDDIR" "$PKGEXT" >>"$RPI_TEST_LOG"
cp PKGBUILD "$RPI_TEST_LOG.d/$pkgname.PKGBUILD"
! grep -q '^pkgver()' PKGBUILD || exit 91
[[ ${RPI_TEST_FAIL_PKG:-} != "$pkgname" ]] || exit 1
mkdir -p "$PKGDEST"
printf 'pkgname = %s\npkgver = %s-%s\n' "$pkgname" "$pkgver" "$pkgrel" >"$PKGDEST/$pkgname-$pkgver-$pkgrel-aarch64$PKGEXT"
STUB
# repo-add keeps its database the way the real one does, one <name>-<version>/desc
# entry per package, and with --remove deletes a replaced package's file as it
# replaces the entry, before it writes the database. With no packages it writes
# an empty database; either way it links pimarchy.db. A test can make it fail
# where the real one writes its database, after everything before that.
cat >"$stubs/repo-add" <<'STUB'
#!/bin/bash
printf 'repo-add %s\n' "$*" >>"$RPI_TEST_LOG"
remove=0
args=()
for arg in "$@"; do
  case $arg in
    -R | --remove) remove=1 ;;
    -q | --quiet) ;;
    -*) exit 92 ;;
    *) args+=("$arg") ;;
  esac
done
db=${args[0]}
dir=${db%/*}
[[ -d $dir ]] || exit 93
entries=$(mktemp -d)
[[ ! -f $db ]] || tar -xzf "$db" -C "$entries"
for package in "${args[@]:1}"; do
  file=${package##*/}
  name=$(sed -n 's/^pkgname = //p' "$package")
  version=$(sed -n 's/^pkgver = //p' "$package")
  for old in "$entries"/*/desc; do
    [[ -f $old && $(sed -n '/^%NAME%$/{n;p;q}' "$old") == "$name" ]] || continue
    old_file=$(sed -n '/^%FILENAME%$/{n;p;q}' "$old")
    rm -rf "${old%/desc}"
    if (( remove )) && [[ $old_file != "$file" ]]; then
      rm -f "$dir/$old_file"
    fi
  done
  mkdir -p "$entries/$name-$version"
  printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n' "$file" "$name" "$version" >"$entries/$name-$version/desc"
done
if [[ ${RPI_TEST_FAIL_REPO_ADD:-0} == 1 ]]; then
  rm -rf "$entries"
  exit 1
fi
tar -czf "$db.tmp" -C "$entries" .
mv "$db.tmp" "$db"
ln -sfn "${db##*/}" "$dir/pimarchy.db"
rm -rf "$entries"
STUB
chmod +x "$stubs"/*

run_on() {
  local platform=$1
  shift
  : >"$log"
  RPI_TEST_LOG=$log OMARCHY_PROC_ROOT="$test_tmp/$platform/proc" PATH="$test_tmp/$platform/bin:$stubs:$PATH" \
    "$bin/omarchy-update-rpi-pkgs" "$@" >"$test_tmp/out" 2>&1
}

run() {
  run_on aarch64-rpi "$@"
}

output() {
  cat "$test_tmp/out" "$log"
}

repo_state() {
  (
    cd "$repo"
    find . -mindepth 1 -printf '%p %y %m %l\n' | LC_ALL=C sort
    find . -type f -exec sha256sum {} + | LC_ALL=C sort
  )
}

db_entries() {
  tar -tzf "$repo/pimarchy.db" | sed -n 's|^\./\([^/]*\)/$|\1|p' | LC_ALL=C sort | tr '\n' ' '
}

makepkg_runs() {
  sed -n 's/^makepkg .* pkg=\([^ ]*\) .*/\1/p' "$log" | tr '\n' ' '
}

# Git and repo-add work on root's checkout and repository: only through sudo,
# the fetch through env and timeout under it.
assert_root_steps_through_sudo() {
  local command
  for command in git repo-add; do
    (( $(grep -c "^$command " "$log" || true) == $(grep -cE "^sudo (env GIT_TERMINAL_PROMPT=0 timeout [0-9]+ )?$command " "$log" || true) )) ||
      fail "$1: $command runs only through sudo" "$(output)"
  done
}

# The fixture's Pimarchy upstream: the vendored PKGBUILDs and a boot package
# whose pkgver() the build has to drop.
origin=$test_tmp/origin.git
seed=$test_tmp/seed
"$real_git" -c init.defaultBranch=quattro init -q --bare "$origin"
"$real_git" -c init.defaultBranch=quattro init -q "$seed"
mkdir -p "$seed/pi/pkgbuilds/omarchy-rpi-boot"
cp -a "$ROOT/pi/pkgbuilds/omarchy" "$ROOT/pi/pkgbuilds/omarchy-settings" "$seed/pi/pkgbuilds/"
cat >"$seed/pi/pkgbuilds/omarchy-rpi-boot/PKGBUILD" <<'PKGBUILD'
pkgname=omarchy-rpi-boot
pkgver=1
pkgrel=1
arch=('aarch64')

pkgver() {
  if true; then
    echo "from.the.function"
  fi
}

package() {
  :
}
PKGBUILD
"$real_git" -C "$seed" add -A
"$real_git" -C "$seed" commit -qm "Seed"
"$real_git" -C "$seed" remote add origin "$origin"
"$real_git" -C "$seed" push -q origin quattro

push_commit() {
  echo "$1" >>"$seed/CHANGES"
  "$real_git" -C "$seed" add CHANGES
  "$real_git" -C "$seed" commit -qm "$1"
  "$real_git" -C "$seed" push -q origin quattro
}

base_version=$(sed -n 's/^pkgver=//p' "$ROOT/pi/pkgbuilds/omarchy/PKGBUILD")
[[ $base_version == "$(sed -n 's/^pkgver=//p' "$ROOT/pi/pkgbuilds/omarchy-settings/PKGBUILD")" ]] ||
  fail "the vendored omarchy and omarchy-settings carry the same pkgver"

# The versions a build of the checkout's HEAD carries under serial $1, by
# default the checkout's commit count.
expect_versions() {
  local serial=${1:-} short
  [[ -n $serial ]] || serial=$("$real_git" -C "$src" rev-list --count HEAD)
  short=$("$real_git" -C "$src" rev-parse --short HEAD)
  omarchy_version=$base_version.r$serial.g$short
  boot_version=1.r$serial.g$short
  expected_packages="omarchy-$omarchy_version-1 omarchy-rpi-boot-$boot_version-1 omarchy-settings-$omarchy_version-1 "
}

# The serial the published builds carry.
published_serial() {
  tar -tzf "$repo/pimarchy.db" | sed -n 's|^\./omarchy-rpi-boot-1\.r\([0-9]*\)\.g[^/]*/$|\1|p'
}

# ── off the Pi ───────────────────────────────────────────────────────────────

for platform in aarch64 x86; do
  for args in "" --init; do
    run_on "$platform" $args || fail "$platform: '$args' succeeds" "$(output)"
    [[ ! -s $log ]] || fail "$platform: '$args' runs nothing" "$(output)"
    [[ ! -e $pimarchy ]] || fail "$platform: '$args' creates no repository"
  done
done
pass "off a Raspberry Pi it does nothing, --init included"

# ── --init ───────────────────────────────────────────────────────────────────

run --init || fail "--init creates the repository" "$(output)"
[[ -d $repo && $(stat -c %a "$pimarchy") == 755 && $(stat -c %a "$repo") == 755 ]] ||
  fail "--init creates the repository directories readable by pacman's download user" "$(ls -la "$pimarchy" 2>&1)"
[[ -L $repo/pimarchy.db && $(readlink "$repo/pimarchy.db") == "pimarchy.db.tar.gz" && -f $repo/pimarchy.db.tar.gz ]] ||
  fail "--init leaves a database pacman can sync" "$(ls -la "$repo")"
[[ -z $(db_entries) ]] || fail "--init's database is empty" "$(db_entries)"
grep -qx "sudo install -d -m 0755 $pimarchy $repo" "$log" || fail "--init creates the directories as root" "$(output)"
grep -qx "sudo repo-add --quiet $repo/pimarchy.db.tar.gz" "$log" || fail "--init has repo-add write the empty database as root" "$(output)"
assert_root_steps_through_sudo "--init"
! grep -qE '^(git|makepkg|runuser) ' "$log" || fail "--init builds nothing" "$(output)"
pass "--init creates an empty, valid repository as root"

before=$(repo_state)
run --init || fail "--init on an existing repository succeeds" "$(output)"
[[ ! -s $log ]] || fail "--init on an existing repository runs nothing, sudo included" "$(output)"
[[ $(repo_state) == "$before" ]] || fail "--init leaves an existing repository as it is"
rm "$repo/pimarchy.db"
run --init || fail "--init restores a missing database link" "$(output)"
[[ $(readlink "$repo/pimarchy.db") == "pimarchy.db.tar.gz" && $(repo_state) == "$before" ]] ||
  fail "--init relinks the existing database" "$(output)"
! grep -q '^repo-add ' "$log" || fail "--init keeps the existing database" "$(output)"
pass "--init is idempotent and relinks a database whose link went missing"

# ── building ─────────────────────────────────────────────────────────────────

if run; then fail "a Pi without a Pimarchy checkout has nothing to build from"; fi
grep -q "There is no Pimarchy checkout at $src" "$test_tmp/out" || fail "the missing checkout is named" "$(output)"
pass "without a checkout to build from, it says so and fails"

"$real_git" clone -q "$origin" "$src"

run || fail "the first build succeeds" "$(output)"
expect_versions
[[ $(makepkg_runs) == "omarchy-settings-$omarchy_version omarchy-$omarchy_version omarchy-rpi-boot-$boot_version " ]] ||
  fail "the three packages build in order, versioned by the checkout" "$(output)"
pass "the three packages carry the PKGBUILD's pkgver plus the checkout's commit count and short sha, omarchy and omarchy-settings alike"

while read -r line; do
  [[ $line == *" --nodeps --noconfirm pkg="* && $line == *" OMARCHY_SRC=$src "* && $line == *" PKGEXT=.pkg.tar.zst"* ]] ||
    fail "makepkg builds the checkout with --nodeps" "$line"
  [[ $line == *" cwd=$scratch/pimarchy-pkgs."* && $line == *" PKGDEST=$scratch/pimarchy-pkgs."* && $line == *" BUILDDIR=$scratch/pimarchy-pkgs."* ]] ||
    fail "makepkg builds in a fresh directory under the scratch space" "$line"
done < <(grep '^makepkg ' "$log")
! grep -qE '^sudo .*makepkg|^runuser ' "$log" || fail "the caller builds as itself, never as root" "$(output)"
assert_root_steps_through_sudo "a build"
pass "makepkg builds from the checkout as the caller, while git, the copy and repo-add run as root"

diff <(sed "s/^pkgver=.*/pkgver=$omarchy_version/" "$ROOT/pi/pkgbuilds/omarchy/PKGBUILD") "$log.d/omarchy.PKGBUILD" >/dev/null ||
  fail "the omarchy PKGBUILD changes only in its pkgver"
diff <(sed "s/^pkgver=.*/pkgver=$omarchy_version/" "$ROOT/pi/pkgbuilds/omarchy-settings/PKGBUILD") "$log.d/omarchy-settings.PKGBUILD" >/dev/null ||
  fail "the omarchy-settings PKGBUILD changes only in its pkgver"
[[ $(grep -c 'pkgver' "$log.d/omarchy-rpi-boot.PKGBUILD") == 1 ]] && grep -qx "pkgver=$boot_version" "$log.d/omarchy-rpi-boot.PKGBUILD" &&
  grep -qx 'package() {' "$log.d/omarchy-rpi-boot.PKGBUILD" || fail "a pkgver() function is dropped, and nothing else" "$(cat "$log.d/omarchy-rpi-boot.PKGBUILD")"
pass "each build gets a copy of its PKGBUILD rewritten only in its version"

[[ $(db_entries) == "$expected_packages" ]] || fail "the database lists the three builds" "$(db_entries)"
for package in $expected_packages; do
  [[ -f $repo/$package-aarch64.pkg.tar.zst && $(stat -c %a "$repo/$package-aarch64.pkg.tar.zst") == 644 ]] ||
    fail "$package is published, readable by pacman's download user" "$(ls -la "$repo")"
done
grep -q "^sudo repo-add .*$repo/pimarchy.db.tar.gz $repo/omarchy-settings-" "$log" ||
  fail "repo-add publishes them" "$(output)"
[[ $(<"$repo/.built-commit") == "$("$real_git" -C "$src" rev-parse HEAD)" ]] || fail "the built commit is recorded"
[[ -z $(ls -A "$scratch") ]] || fail "the build directory is removed" "$(ls -la "$scratch")"
pass "the builds are published to the repository, the commit recorded and the build directory removed"

# ── up to date ───────────────────────────────────────────────────────────────

before=$(repo_state)
run || fail "an up-to-date run succeeds" "$(output)"
grep -qx "sudo env GIT_TERMINAL_PROMPT=0 timeout 120 git -C $src fetch --quiet --prune" "$log" ||
  fail "an up-to-date run still fetches, as root, without a credential prompt, within a time limit and pruning" "$(output)"
[[ -z $(makepkg_runs) ]] || fail "nothing is rebuilt for the commit already built" "$(output)"
grep -q "up to date" "$test_tmp/out" || fail "an up-to-date run says so" "$(output)"
[[ $(repo_state) == "$before" ]] || fail "an up-to-date run leaves the repository alone"
pass "a checkout that hasn't moved is not rebuilt"

# ── a moved checkout ─────────────────────────────────────────────────────────

old_packages=$expected_packages
push_commit "Second"
push_commit "Third"
run || fail "a moved checkout rebuilds" "$(output)"
[[ $("$real_git" -C "$src" rev-parse HEAD) == "$("$real_git" -C "$origin" rev-parse quattro)" ]] ||
  fail "the checkout fast-forwards to its upstream"
grep -qx "sudo git -C $src merge --ff-only --quiet origin/quattro" "$log" || fail "the checkout merges fast-forward only" "$(output)"
expect_versions
[[ $omarchy_version == "$base_version.r3."* ]] || fail "the serial is the commit count when that is past the last build's" "$omarchy_version"
[[ $(makepkg_runs) == "omarchy-settings-$omarchy_version omarchy-$omarchy_version omarchy-rpi-boot-$boot_version " ]] ||
  fail "the moved checkout's packages build" "$(output)"
[[ $(db_entries) == "$expected_packages" ]] || fail "the database moves to the new builds" "$(db_entries)"
for package in $old_packages; do
  [[ ! -e $repo/$package-aarch64.pkg.tar.zst ]] || fail "the replaced $package is removed" "$(ls -la "$repo")"
done
[[ $(<"$repo/.built-commit") == "$("$real_git" -C "$src" rev-parse HEAD)" ]] || fail "the new commit is recorded"
pass "a moved checkout fast-forwards, rebuilds and replaces the previous builds"

# ── failures leave the repository alone ──────────────────────────────────────

push_commit "Fourth"
before=$(repo_state)
if RPI_TEST_FAIL_PKG=omarchy run; then fail "a failed build fails the run"; fi
grep -q "Building omarchy failed" "$test_tmp/out" || fail "the failed package is named" "$(output)"
[[ $(makepkg_runs) == "omarchy-settings-"*" omarchy-"*" " && $(makepkg_runs) != *rpi-boot* ]] ||
  fail "the build stops at the failed package" "$(output)"
[[ $(repo_state) == "$before" ]] || fail "a failed build leaves the repository untouched" "$(diff <(echo "$before") <(repo_state))"
! grep -qE '^sudo (install -m|repo-add|tee)' "$log" || fail "a failed build publishes nothing" "$(output)"
[[ -z $(ls -A "$scratch") ]] || fail "a failed build removes its build directory" "$(ls -la "$scratch")"
pass "a failed build leaves the repository and the recorded commit untouched, and cleans up"

if RPI_TEST_FAIL_REPO_ADD=1 run; then fail "a failed publish fails the run"; fi
grep -q "Could not publish the packages" "$test_tmp/out" || fail "a failed publish says so" "$(output)"
[[ $(repo_state) == "$before" ]] ||
  fail "a failed publish removes the packages it copied and keeps every published one" "$(diff <(echo "$before") <(repo_state))"
pass "a publish repo-add fails as it writes its database leaves the repository as it was, the builds it replaces included"

run || fail "the next run after a failure builds" "$(output)"
expect_versions
[[ $(db_entries) == "$expected_packages" ]] || fail "the next run publishes the commit that failed before" "$(db_entries)"
pass "the next run builds what failed before"

# ── local work in the checkout ───────────────────────────────────────────────

# A local commit not built yet, an uncommitted change on top of it, and a new
# commit upstream.
echo "local commit" >"$src/LOCAL"
"$real_git" -C "$src" add LOCAL
"$real_git" -C "$src" commit -qm "Local"
local_commit=$("$real_git" -C "$src" rev-parse HEAD)
echo "local edit" >>"$src/LOCAL"
push_commit "Fifth"
before=$(repo_state)
run || fail "a checkout with uncommitted changes lets the update go on" "$(output)"
grep -q "has uncommitted changes, so it is neither updated nor built" "$test_tmp/out" || fail "uncommitted changes are reported" "$(output)"
grep -qF "sudo git -C $src stash" "$test_tmp/out" || fail "the warning says how to set the changes aside" "$(output)"
[[ $("$real_git" -C "$src" rev-parse HEAD) == "$local_commit" ]] || fail "a checkout with uncommitted changes is not merged"
[[ -z $(makepkg_runs) && $(repo_state) == "$before" ]] ||
  fail "uncommitted changes are never built under the name of the commit they sit on" "$(output)"
"$real_git" -C "$src" checkout -q -- LOCAL
pass "a checkout with uncommitted changes is neither merged nor built, and the warning says how to set them aside"

run || fail "a diverged checkout still builds" "$(output)"
grep -q "cannot fast-forward to origin/quattro; building what is there" "$test_tmp/out" || fail "a diverged checkout is reported" "$(output)"
expect_versions
[[ $(makepkg_runs) == "omarchy-settings-$omarchy_version omarchy-$omarchy_version omarchy-rpi-boot-$boot_version " &&
  $(db_entries) == "$expected_packages" ]] || fail "a diverged checkout builds its own HEAD" "$(output)"
pass "a diverged checkout is built as it is"

"$real_git" -C "$src" merge -q --no-edit origin/quattro
run || fail "a checkout ahead of its upstream builds" "$(output)"
grep -q "has local commits that origin/quattro lacks; building them" "$test_tmp/out" || fail "local commits are reported" "$(output)"
expect_versions
[[ $(db_entries) == "$expected_packages" ]] || fail "a checkout ahead of its upstream builds its own HEAD" "$(output)"
pass "a checkout ahead of its upstream is built as it is, with a warning"

before=$(repo_state)
if ! RPI_TEST_OFFLINE=1 run; then fail "an offline run still succeeds" "$(output)"; fi
grep -q "Could not fetch the Pimarchy checkout" "$test_tmp/out" || fail "an offline run says it could not fetch" "$(output)"
[[ $(repo_state) == "$before" ]] || fail "an offline run with nothing new changes nothing"
pass "an offline run warns and builds what is there"

# The branch the checkout follows is deleted from origin.
"$real_git" -C "$src" checkout -q -b gone
"$real_git" -C "$src" push -q -u origin gone
"$real_git" -C "$origin" branch -q -D gone
run || fail "a run whose upstream branch is gone still succeeds" "$(output)"
grep -q "follows no branch of its origin, or that branch is gone from it" "$test_tmp/out" ||
  fail "a branch deleted from origin is reported the run it goes" "$(output)"
! "$real_git" -C "$src" rev-parse -q --verify refs/remotes/origin/gone >/dev/null || fail "the fetch prunes the deleted branch"
"$real_git" -C "$src" checkout -q quattro
"$real_git" -C "$src" branch -q -D gone
pass "a branch deleted from origin is pruned and reported, not followed at its last known commit"

# ── versions never go backwards ──────────────────────────────────────────────

# Upstream is rewritten with fewer commits than the last build's serial, and the
# checkout reset onto it.
last_serial=$(published_serial)
"$real_git" -C "$seed" reset -q --hard "$("$real_git" -C "$seed" rev-list --max-parents=0 HEAD)"
echo "Rebased" >"$seed/CHANGES"
"$real_git" -C "$seed" add CHANGES
"$real_git" -C "$seed" commit -qm "Rebased"
"$real_git" -C "$seed" push -q --force origin quattro
"$real_git" -C "$src" fetch -q
"$real_git" -C "$src" reset -q --hard origin/quattro
(( $("$real_git" -C "$src" rev-list --count HEAD) < last_serial )) || fail "the rewritten history is shorter than the last serial"
run || fail "a checkout reset onto a shorter history builds" "$(output)"
expect_versions $(( last_serial + 1 ))
[[ $(makepkg_runs) == "omarchy-settings-$omarchy_version omarchy-$omarchy_version omarchy-rpi-boot-$boot_version " &&
  $(db_entries) == "$expected_packages" ]] || fail "a shorter history builds under the serial after the last one" "$(output)"
pass "a checkout reset onto fewer commits still builds versions that sort above the last ones"

# The same commit rebuilt, since one of its packages is gone.
last_serial=$(published_serial)
old_packages=$expected_packages
rm "$repo/omarchy-$omarchy_version-1-aarch64.pkg.tar.zst"
run || fail "a run with a package missing succeeds" "$(output)"
expect_versions $(( last_serial + 1 ))
[[ $(makepkg_runs) == "omarchy-settings-$omarchy_version omarchy-$omarchy_version omarchy-rpi-boot-$boot_version " ]] ||
  fail "a package missing from the repository rebuilds them, under the next serial" "$(output)"
[[ $(db_entries) == "$expected_packages" ]] || fail "the rebuild is published" "$(db_entries)"
for package in $old_packages; do
  [[ ! -e $repo/$package-aarch64.pkg.tar.zst ]] || fail "the rebuild replaces $package rather than keeping its name" "$(ls -la "$repo")"
done
pass "a package gone from the repository is rebuilt even when the commit is unchanged, under names no published file has had"

# ── who builds ───────────────────────────────────────────────────────────────

rm "$repo/.built-commit"
expect_versions $(( $(published_serial) + 1 ))
run --as-user nobody || fail "a build as another user succeeds" "$(output)"
for step in mktemp cp tee env rm; do
  grep -q "^sudo runuser -u nobody -- $step " "$log" || fail "--as-user runs $step as that user" "$(output)"
done
(( $(grep -c '^makepkg ' "$log") == 3 && $(grep -c '^runuser -u nobody -- env -C .* makepkg --nodeps --noconfirm$' "$log") == 3 )) ||
  fail "--as-user builds every package as that user through runuser" "$(output)"
[[ $(db_entries) == "$expected_packages" ]] || fail "a build as another user is published" "$(db_entries)"
pass "--as-user builds as the named user through runuser"

if run --as-user root; then fail "a build as root is refused"; fi
grep -q "makepkg doesn't build as root" "$test_tmp/out" || fail "a build as root is refused with the reason" "$(output)"
if run --as-user; then fail "--as-user without a user is refused"; fi
pass "a build as root, or --as-user without a user, is refused"

# ── mismatched versions ──────────────────────────────────────────────────────

sed -i 's/^pkgver=.*/pkgver=9.9.9/' "$src/pi/pkgbuilds/omarchy-settings/PKGBUILD"
"$real_git" -C "$src" commit -qam "Mismatch"
before=$(repo_state)
if run; then fail "omarchy and omarchy-settings with different pkgver values are refused"; fi
grep -q "omarchy and omarchy-settings set different pkgver values" "$test_tmp/out" || fail "the mismatch is named" "$(output)"
[[ -z $(makepkg_runs) && $(repo_state) == "$before" ]] || fail "a mismatch stops before building" "$(output)"
pass "omarchy and omarchy-settings must carry the same pkgver"

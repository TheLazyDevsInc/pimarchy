#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# First-boot setup with nobody at the screen: omarchy-provision-owner's answers
# file stands in for the owner form. load_answers, run_unattended, create_user
# and configure_login run as the script defines them, against a fixture
# provisioning directory and root, with the account tools faked.

tmp=$(cd -- "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

stub_bin=$tmp/bin
mkdir -p "$stub_bin"
cat >"$stub_bin/timedatectl" <<'SH'
#!/bin/bash
[[ $1 == list-timezones ]] || exit 1
printf '%s\n' America/New_York Europe/London UTC
SH
cat >"$stub_bin/chpasswd" <<SH
#!/bin/bash
printf 'chpasswd %s: %s\n' "\$*" "\$(cat)" >>"$tmp/calls"
SH
for tool in useradd usermod; do
  printf '#!/bin/bash\necho "%s $*" >>"%s/calls"\n' "$tool" "$tmp" >"$stub_bin/$tool"
done
printf '#!/bin/bash\nexit 2\n' >"$stub_bin/getent"
chmod +x "$stub_bin"/*
export PATH="$stub_bin:$PATH"

sed -n '/^load_answers() {/,/^}/p; /^run_unattended() {/,/^}/p; /^create_user() {/,/^}/p; /^configure_login() {/,/^}/p' \
  "$ROOT/bin/omarchy-provision-owner" | sed "s|/etc/|$tmp/root/etc/|g; s|/var/lib/sddm|$tmp/root/var/lib/sddm|g" >"$tmp/owner.sh"
grep -q '^load_answers() {' "$tmp/owner.sh" && grep -q '^run_unattended() {' "$tmp/owner.sh" ||
  fail "omarchy-provision-owner defines unattended setup"

# Runs $1 (shell code) with the extracted functions, the shared form's rules and
# the fixture paths.
owner() {
  OMARCHY_FORM_DEFAULTS=$tmp/no-defaults bash -c '
    set -euo pipefail
    source "$ROOT/install/provisioning/setup-form.sh"
    source "$TMP/owner.sh"
    PROVISIONING_DIR=$TMP/provisioning
    LOG_FILE=$TMP/log
    OMARCHY_PATH=$TMP/omarchy
    log_step() { printf "%s\n" "$1" >>"$LOG_FILE"; }
    omarchy_username_taken() { [[ $1 == taken ]]; }
    luks_rekey_pending() { [[ -e $TMP/rekey-pending ]]; }
    user_groups() { echo wheel; }
    eval "$1"
  ' bash "$1"
}
export ROOT TMP=$tmp

reset() {
  rm -rf "$tmp/provisioning" "$tmp/root" "$tmp/omarchy" "$tmp/log" "$tmp/calls" "$tmp/rekey-pending"
  mkdir -p "$tmp/provisioning" "$tmp/root/etc/sudoers.d" "$tmp/omarchy/install/helpers"
  printf 'BROWSER_POLICY_MANAGED_DIRS=()\n' >"$tmp/omarchy/install/helpers/browser-policy.sh"
  : >"$tmp/log"
  : >"$tmp/calls"
}

# Writes the answers file from its arguments, one KEY=value line each, the last
# without a newline, as a hand-written file may end.
answers() {
  local IFS=$'\n'
  printf '%s' "$*" >"$tmp/provisioning/answers"
  chmod 600 "$tmp/provisioning/answers"
}

loaded() {
  owner 'load_answers && printf "%s|" "$username" "$password" "${password_hash:-}" "$full_name" "$email_address" \
    "$hostname" "$timezone" "$keyboard" "$keyboard_label" "$keyboard_input_method"'
}

# ── Reading the answers ──────────────────────────────────────────────────────

reset
answers 'KEYBOARD=English (UK)' USERNAME=owner 'PASSWORD=p=ss word#1' 'FULL_NAME=Pi Owner' $'EMAIL=owner@example.com\r' \
  HOSTNAME=pi400 UNKNOWN=ignored TIMEZONE=Europe/London
output=$(loaded) || fail "valid answers load" "$output $(cat "$tmp/log")"
[[ $output == "owner|p=ss word#1||Pi Owner|owner@example.com|pi400|Europe/London|uk|English (UK)|none|" ]] ||
  fail "the answers are read as data: values keep their = and #, a CR goes, unknown keys are ignored" "$output"

reset
answers USERNAME=owner PASSWORD=secret KEYBOARD=de
output=$(loaded) || fail "answers with defaults load" "$output $(cat "$tmp/log")"
[[ $output == "owner|secret||||omarchy|UTC|de|German|none|" ]] ||
  fail "a keymap names its layout, and the hostname and timezone default as the form's do" "$output"

reset
answers USERNAME=owner 'PASSWORD_HASH=$6$salt$hash/value.'
output=$(loaded) || fail "a password hash loads" "$output $(cat "$tmp/log")"
[[ $output == "owner||\$6\$salt\$hash/value.|||omarchy|UTC|us|English (US)|none|" ]] ||
  fail "PASSWORD_HASH is taken instead of a password, and the layout defaults to English (US)" "$output"
pass "unattended answers are read as data, with the form's defaults"

refused() {
  local why=$1
  shift
  reset
  answers "$@"
  if output=$(loaded); then
    fail "unattended setup refuses $why" "$output"
  fi
}
refused "a reserved username" USERNAME=root PASSWORD=secret
refused "an existing account" USERNAME=taken PASSWORD=secret
refused "a username the form rejects" 'USERNAME=Not Valid' PASSWORD=secret
refused "a missing password" USERNAME=owner
refused "a hash that is no crypt(3) hash" USERNAME=owner PASSWORD_HASH=plain
refused "a hostname the form rejects" USERNAME=owner PASSWORD=secret HOSTNAME=-bad-
refused "an unknown timezone" USERNAME=owner PASSWORD=secret TIMEZONE=Mars/Base
refused "an unknown keyboard layout" USERNAME=owner PASSWORD=secret KEYBOARD=klingon
reset
answers USERNAME=owner PASSWORD=secret
chmod 640 "$tmp/provisioning/answers"
! output=$(loaded) || fail "unattended setup refuses answers others may read" "$output"
reset
printf 'USERNAME=owner\nPASSWORD=secret\n' >"$tmp/real-answers"
chmod 600 "$tmp/real-answers"
ln -s "$tmp/real-answers" "$tmp/provisioning/answers"
! output=$(loaded) || fail "unattended setup refuses answers behind a link" "$output"
reset
answers USERNAME=owner 'PASSWORD_HASH=$6$salt$hash'
touch "$tmp/rekey-pending"
! output=$(loaded) || fail "unattended setup refuses a hash when the disk is re-keyed to the password" "$output"
reset
answers USERNAME=other PASSWORD=secret
echo owner >"$tmp/provisioning/setup-user"
! output=$(loaded) || fail "unattended setup resumes only the account an earlier attempt pinned" "$output"
answers USERNAME=owner PASSWORD=secret
output=$(loaded) || fail "unattended setup resumes the pinned account" "$output $(cat "$tmp/log")"
pass "unattended setup refuses what the form refuses, unreadable answers and a hash a re-key can't use"

# ── Running unattended ───────────────────────────────────────────────────────

# The real run_setup is replaced by one that records what the overridden steps
# do, as the form's steps would run in it.
unattended() {
  owner '
    apply_keyboard() { echo "keyboard $1" >>"$TMP/calls"; }
    omarchy_persist_input_selection() { echo "persist $keyboard_input_method" >>"$TMP/calls"; }
    run_setup() {
      keyboard_form || return 1
      user_form
      confirm_form
      echo "provisioning $username $hostname unattended=$UNATTENDED" >>"$TMP/calls"
    }
    gum() { echo "gum $*" >>"$TMP/calls"; exit 7; }
    run_unattended'
}

reset
answers USERNAME=owner PASSWORD=secret KEYBOARD=fr HOSTNAME=pi400
unattended || fail "unattended setup runs" "$(cat "$tmp/calls" "$tmp/log")"
[[ $(<"$tmp/calls") == $'keyboard fr\npersist none\nprovisioning owner pi400 unattended=1' ]] ||
  fail "unattended setup applies the layout and provisions without asking anything" "$(cat "$tmp/calls")"
[[ $(stat -c %a "$tmp/log") == 600 ]] || fail "the setup log is root's alone" "$(stat -c %a "$tmp/log")"

reset
answers USERNAME=root PASSWORD=secret
! unattended || fail "unattended setup stops at answers the form refuses"
[[ ! -s $tmp/calls ]] || fail "refused answers change nothing" "$(cat "$tmp/calls")"
pass "unattended setup applies the answers and provisions without a prompt, and stops at refused ones"

# ── The account ──────────────────────────────────────────────────────────────

reset
owner 'username=owner password="" password_hash="\$6\$salt\$hash" full_name="" create_user' ||
  fail "create_user takes a password hash" "$(cat "$tmp/calls")"
grep -qxF 'chpasswd -e: owner:$6$salt$hash' "$tmp/calls" && grep -qxF 'chpasswd -e: root:$6$salt$hash' "$tmp/calls" ||
  fail "a hashed password is set with chpasswd -e for the owner and root" "$(cat "$tmp/calls")"
reset
owner 'username=owner password=secret full_name="" create_user' || fail "create_user takes a password" "$(cat "$tmp/calls")"
grep -qxF 'chpasswd : owner:secret' "$tmp/calls" && ! grep -q 'chpasswd -e' "$tmp/calls" ||
  fail "a password from the form is set as it was before" "$(cat "$tmp/calls")"
pass "the account takes a crypt(3) hash as well as the form's password"

reset
owner 'username=owner; install_autologin_once_cleanup() { echo cleanup >>"$TMP/calls"; }; encrypted_install() { return 1; }
  UNATTENDED=1 configure_login'
[[ -f $tmp/root/var/lib/sddm/state.conf && ! -e $tmp/root/etc/sddm.conf.d/autologin.conf && ! -s $tmp/calls ]] ||
  fail "an unattended setup remembers the owner at the login screen but logs nobody in" "$(ls -R "$tmp/root")"
reset
owner 'username=owner; install_autologin_once_cleanup() { echo cleanup >>"$TMP/calls"; }; encrypted_install() { return 1; }
  configure_login'
[[ -f $tmp/root/etc/sddm.conf.d/autologin.conf && $(<"$tmp/calls") == cleanup ]] ||
  fail "the form's setup still logs the owner in once" "$(ls -R "$tmp/root")"
pass "nobody is logged in after an unattended setup, and the form's setup still logs the owner in once"

#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nvm-fork-installer.XXXXXX")
test_root=$(cd -- "$test_root" && pwd -P)
trap 'rm -rf "$test_root"' EXIT
checks=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
check() { "$@" || fail "$*"; checks=$((checks + 1)); }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

fixture() {
  local name=$1
  fixture_root="$test_root/$name 项目 with 'quotes'"
  checkout=$fixture_root/checkout
  nvm_dir=$fixture_root/nodes
  profile=$fixture_root/.zshrc
  mkdir -p "$checkout/auto-switch" "$nvm_dir/versions/node/v16.16.0" "$nvm_dir/alias" "$nvm_dir/.cache" "$fixture_root/brew"
  cp "$repo/install-fork.sh" "$repo/uninstall-fork.sh" "$repo/fork-install-common.sh" "$checkout/"
  printf '# mock fork\n' > "$checkout/nvm.sh"
  printf '# mock exec\n' > "$checkout/nvm-exec"
  printf '# mock completion\n' > "$checkout/bash_completion"
  printf '# original brew\n' > "$fixture_root/brew/nvm.sh"
  ln -s "$fixture_root/brew/nvm.sh" "$nvm_dir/nvm.sh"
  printf '# original regular executable\n' > "$nvm_dir/nvm-exec"
  chmod 751 "$nvm_dir/nvm-exec"
  ln -s "$fixture_root/brew/missing-completion" "$nvm_dir/bash_completion"
  printf '# prior configuration\nexport KEEP=yes\n' > "$profile"
  cp "$profile" "$fixture_root/profile.before"
  cp -p "$nvm_dir/nvm-exec" "$fixture_root/exec.before"
  printf '16.16.0\n' > "$nvm_dir/alias/default"
  printf 'untouched node version\n' > "$nvm_dir/versions/node/v16.16.0/keep"
  printf 'untouched cache\n' > "$nvm_dir/.cache/keep"
}

install() { bash "$checkout/install-fork.sh" --nvm-dir "$nvm_dir" --profile "$profile"; }
uninstall() { bash "$checkout/uninstall-fork.sh" --nvm-dir "$nvm_dir" --profile "$profile"; }

check_original_entries() {
  check test "$(readlink "$nvm_dir/nvm.sh")" = "$fixture_root/brew/nvm.sh"
  check cmp -s "$nvm_dir/nvm-exec" "$fixture_root/exec.before"
  check test -x "$nvm_dir/nvm-exec"
  check test "$(readlink "$nvm_dir/bash_completion")" = "$fixture_root/brew/missing-completion"
  check absent "$nvm_dir/auto-switch"
  check test "$(cat "$nvm_dir/alias/default")" = '16.16.0'
  check test "$(cat "$nvm_dir/versions/node/v16.16.0/keep")" = 'untouched node version'
  check test "$(cat "$nvm_dir/.cache/keep")" = 'untouched cache'
}

fixture normal
install
for entry in nvm.sh nvm-exec bash_completion auto-switch; do
  check test "$(readlink "$nvm_dir/$entry")" = "$checkout/$entry"
done
cp "$profile" "$fixture_root/profile.installed"
install
check cmp -s "$profile" "$fixture_root/profile.installed"
# The generated, quoted NVM_DIR survives spaces and apostrophes.
check test "$(bash -c '. "$1"; printf "%s" "$NVM_DIR"' fixture "$profile")" = "$nvm_dir"
printf '# user added after install\nexport ADDED=yes\n' >> "$profile"
uninstall
check_original_entries
check test "$(cat "$profile")" = "$(cat "$fixture_root/profile.before")
# user added after install
export ADDED=yes"
check absent "$nvm_dir/.nvm-fork-install"
uninstall

fixture absent_profile
rm "$profile"
install
uninstall
check absent "$profile"
check_original_entries

fixture symlink_profile
mv "$profile" "$fixture_root/profile.actual"
ln -s profile.actual "$profile"
printf 'original without newline' > "$fixture_root/profile.actual"
cp "$fixture_root/profile.actual" "$fixture_root/profile.before"
install
check test "$(readlink "$profile")" = profile.actual
uninstall
check test "$(readlink "$profile")" = profile.actual
check cmp -s "$profile" "$fixture_root/profile.before"

fixture altered_entry
install
cp "$profile" "$fixture_root/profile.installed"
rm "$nvm_dir/nvm-exec"
printf 'user replacement\n' > "$nvm_dir/nvm-exec"
if uninstall > "$fixture_root/refusal.log" 2>&1; then fail 'Uninstall should refuse a user-modified entry'; fi
check grep -q 'refusing to overwrite' "$fixture_root/refusal.log"
check test "$(cat "$nvm_dir/nvm-exec")" = 'user replacement'
check test "$(readlink "$nvm_dir/nvm.sh")" = "$checkout/nvm.sh"
check cmp -s "$profile" "$fixture_root/profile.installed"
rm "$nvm_dir/nvm-exec"
ln -s "$checkout/nvm-exec" "$nvm_dir/nvm-exec"
uninstall

fixture altered_block
install
sed 's/nvm auto on/nvm auto off/' "$profile" > "$fixture_root/profile.modified"
cat "$fixture_root/profile.modified" > "$profile"
if uninstall > "$fixture_root/refusal.log" 2>&1; then fail 'Uninstall should refuse a modified managed block'; fi
check grep -q 'Managed profile block was changed' "$fixture_root/refusal.log"
check cmp -s "$profile" "$fixture_root/profile.modified"
check test "$(readlink "$nvm_dir/nvm.sh")" = "$checkout/nvm.sh"

fixture unknown_marker
printf '# >>> nvm auto-switch fork >>>\n' >> "$profile"
if install > "$fixture_root/refusal.log" 2>&1; then fail 'Install should refuse an orphaned marker'; fi
check_original_entries
check absent "$nvm_dir/.nvm-fork-install"

fixture failed_install
mkdir "$fixture_root/bin"
cat > "$fixture_root/bin/ln" <<'MOCK'
#!/usr/bin/env bash
if [ "${3##*/}" = bash_completion ]; then
  printf 'injected link failure\n' >&2
  exit 23
fi
exec /bin/ln "$@"
MOCK
chmod +x "$fixture_root/bin/ln"
if PATH="$fixture_root/bin:$PATH" install > "$fixture_root/failure.log" 2>&1; then fail 'Injected install failure should fail'; fi
check grep -q 'original entry points and profile restored' "$fixture_root/failure.log"
check_original_entries
check cmp -s "$profile" "$fixture_root/profile.before"
check absent "$nvm_dir/.nvm-fork-install"
check absent "$nvm_dir/.nvm-fork-install.lock"
install
uninstall

fixture failed_profile_write
mkdir "$fixture_root/bin"
cat > "$fixture_root/bin/cat" <<'MOCK'
#!/usr/bin/env bash
case "${1-}" in
  */block) printf '# interrupted profile append\n'; exit 25 ;;
esac
exec /bin/cat "$@"
MOCK
chmod +x "$fixture_root/bin/cat"
if PATH="$fixture_root/bin:$PATH" install > "$fixture_root/failure.log" 2>&1; then fail 'Partial profile append should fail'; fi
check grep -q 'original entry points and profile restored' "$fixture_root/failure.log"
check_original_entries
check cmp -s "$profile" "$fixture_root/profile.before"
check absent "$nvm_dir/.nvm-fork-install"

fixture failed_uninstall
install
cp "$profile" "$fixture_root/profile.installed"
mkdir "$fixture_root/bin"
cat > "$fixture_root/bin/cp" <<'MOCK'
#!/usr/bin/env bash
case "${2-}" in
  */.nvm-fork-install/entries/nvm-exec)
    if [ ! -f "$NVM_FORK_FAILURE_MARKER" ]; then
      : > "$NVM_FORK_FAILURE_MARKER"
      printf 'injected restore failure\n' >&2
      exit 24
    fi ;;
esac
exec /bin/cp "$@"
MOCK
chmod +x "$fixture_root/bin/cp"
if NVM_FORK_FAILURE_MARKER="$fixture_root/failed-once" PATH="$fixture_root/bin:$PATH" uninstall > "$fixture_root/failure.log" 2>&1; then fail 'Injected uninstall failure should fail'; fi
check grep -q 'original entry points and profile restored' "$fixture_root/failure.log"
for entry in nvm.sh nvm-exec bash_completion auto-switch; do
  check test "$(readlink "$nvm_dir/$entry")" = "$checkout/$entry"
done
check cmp -s "$profile" "$fixture_root/profile.installed"
check test -f "$nvm_dir/.nvm-fork-install/complete"
uninstall
check_original_entries

fixture existing_module_directory
mkdir "$nvm_dir/auto-switch"
printf 'existing user module\n' > "$nvm_dir/auto-switch/keep"
if install > "$fixture_root/refusal.log" 2>&1; then fail 'Install should refuse an existing real module directory'; fi
check test "$(cat "$nvm_dir/auto-switch/keep")" = 'existing user module'
check test "$(readlink "$nvm_dir/nvm.sh")" = "$fixture_root/brew/nvm.sh"
check cmp -s "$profile" "$fixture_root/profile.before"

fixture protected_profile
profile=$nvm_dir/alias/default
if install > "$fixture_root/refusal.log" 2>&1; then fail 'Install should refuse a profile inside NVM_DIR'; fi
check grep -q 'Profile must be outside NVM_DIR' "$fixture_root/refusal.log"
check_original_entries
check absent "$nvm_dir/.nvm-fork-install"
profile=$fixture_root/.zshrc
rm "$profile"
ln -s "$nvm_dir/alias/default" "$profile"
if install > "$fixture_root/refusal.log" 2>&1; then fail 'Install should refuse a profile symlink into NVM_DIR'; fi
check grep -q 'Profile must be outside NVM_DIR' "$fixture_root/refusal.log"
check test "$(cat "$nvm_dir/alias/default")" = '16.16.0'
check test "$(readlink "$profile")" = "$nvm_dir/alias/default"

if command -v dot_clean >/dev/null 2>&1; then dot_clean "$test_root"; fi
printf 'Installer checks passed: %s\n' "$checks"

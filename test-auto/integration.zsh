#!/usr/bin/env zsh
# Execute with zsh -f -i: real nvm commands against isolated, simulated installs.
setopt err_exit no_unset pipe_fail
ROOT=${0:A:h:h}
REAL_NODE=${NVM_AUTO_TEST_NODE:-$(command -v node)}
[[ -x $REAL_NODE ]] || exit 1
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nvm-auto.XXXXXX")
trap 'cd /; command rm -rf -- "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" NVM_DIR="$TEST_ROOT/nvm"
export NVM_AUTO_TEST_NODE="$REAL_NODE" NVM_AUTO_TEST_LOG="$TEST_ROOT/parser.log"
unset NODE_OPTIONS NODE_PATH NPM_CONFIG_PREFIX npm_config_prefix PREFIX NVM_BIN NVM_INC
mkdir -p "$HOME" "$NVM_DIR/alias" "$TEST_ROOT/outside" "$TEST_ROOT/project/中文 子目录" "$TEST_ROOT/other"
ln -s "$ROOT/nvm.sh" "$NVM_DIR/nvm.sh"
ln -s "$ROOT/nvm-exec" "$NVM_DIR/nvm-exec"
ln -s "$ROOT/auto-switch" "$NVM_DIR/auto-switch"
make_node() {
  local version=$1
  mkdir -p "$NVM_DIR/versions/node/$version/bin"
  cat > "$NVM_DIR/versions/node/$version/bin/node" <<'NODE'
#!/bin/sh
if [ "$1" = --version ] || [ "$1" = -v ]; then
  path=${0%/bin/node}; printf '%s\n' "${path##*/}"; exit 0
fi
case "$1" in */resolve.cjs) printf 'parse\n' >> "$NVM_AUTO_TEST_LOG";; esac
exec "$NVM_AUTO_TEST_NODE" "$@"
NODE
  chmod +x "$NVM_DIR/versions/node/$version/bin/node"
}
for version in v16.16.0 v20.19.5 v22.22.3 v24.17.0; do make_node "$version"; done
print 16.16.0 > "$NVM_DIR/alias/default"
print 22.22.3 > "$NVM_DIR/alias/project-lts"
print 22.22.3 > "$TEST_ROOT/project/.nvmrc"
print 20.19.5 > "$TEST_ROOT/project/.node-version"
print '{"engines":{"node":"24.x"}}' > "$TEST_ROOT/project/package.json"
print 20.19.5 > "$TEST_ROOT/other/.node-version"
cd "$TEST_ROOT/outside"
source "$NVM_DIR/nvm.sh" --no-use
nvm_download() { print -u2 'FAIL: attempted network download'; return 99; }
assert_eq() { [[ $1 == "$2" ]] || { print -u2 -- "FAIL $3: expected [$2], got [$1]"; exit 1; }; }
current_is() { assert_eq "$(nvm current)" "$1" "$2"; }
assert_eq "${+functions[_nvm_auto_switch_precmd]}" 0 '--no-use does not register auto hooks'
other_hook() { :; }
typeset -ga chpwd_functions=(other_hook) precmd_functions=(other_hook)
nvm auto on
current_is v16.16.0 'startup default'
cd "$TEST_ROOT/project/中文 子目录"
current_is v22.22.3 'nearest parent and nvmrc precedence'
nvm use --silent 16.16.0
_nvm_auto_switch_precmd
current_is v16.16.0 'manual override survives prompt'
nvm auto refresh
current_is v22.22.3 'refresh reapplies declaration'
print 20.19.5 > "$TEST_ROOT/project/.nvmrc"
_nvm_auto_switch_precmd
current_is v20.19.5 'in-place declaration edit'
print '{"name":"child"}' > package.json
_nvm_auto_switch_precmd
current_is v20.19.5 'package without engines does not block ancestor'
print '{"engines":{"node":">=22 <25"}}' > package.json
_nvm_auto_switch_precmd
current_is v24.17.0 'nearest package beats ancestor nvmrc and chooses highest stable'
parses=$(wc -l < "$NVM_AUTO_TEST_LOG")
export NODE_OPTIONS='--require /must-never-load.cjs' NODE_PATH=/must-never-resolve
for iteration in {1..4}; do _nvm_auto_switch_precmd; done
assert_eq "$(wc -l < "$NVM_AUTO_TEST_LOG")" "$parses" 'unchanged prompt uses parser cache'
nvm auto refresh
current_is v24.17.0 'resolver sanitizes Node environment'
unset NODE_OPTIONS NODE_PATH
print 22.22.3 > .node-version
_nvm_auto_switch_precmd
current_is v22.22.3 'node-version precedence over engines'
print project-lts > .node-version
_nvm_auto_switch_precmd
current_is v22.22.3 'local alias'
print 20.19.5 > "$NVM_DIR/alias/project-lts"
_nvm_auto_switch_precmd
current_is v20.19.5 'alias change invalidates cache'
print 99.1.0 > .node-version
_nvm_auto_switch_precmd 2> "$TEST_ROOT/errors"
current_is v20.19.5 'missing version preserves environment'
[[ -s "$TEST_ROOT/errors" ]] || { print -u2 'missing version should explain error'; exit 1; }
_nvm_auto_switch_precmd 2> "$TEST_ROOT/repeated"
[[ ! -s "$TEST_ROOT/repeated" ]] || { print -u2 'repeated prompt diagnostic'; exit 1; }
make_node v99.1.0
_nvm_auto_switch_precmd
current_is v99.1.0 'new install invalidates cache'
print 'invalid version with spaces' > .node-version
_nvm_auto_switch_precmd 2>/dev/null
current_is v99.1.0 'invalid declaration preserves version'
rm .node-version
print '{invalid-json' > package.json
_nvm_auto_switch_precmd 2>/dev/null
current_is v99.1.0 'invalid JSON does not silently fall back'
rm package.json
_nvm_auto_switch_precmd
current_is v20.19.5 'declaration removal returns to ancestor'
pushd "$TEST_ROOT/other" >/dev/null
current_is v20.19.5 'pushd switching'
popd >/dev/null
current_is v20.19.5 'popd switching'
cd "$TEST_ROOT/outside"
current_is v16.16.0 'leave project restores default'
nvm use --silent 20.19.5
_nvm_auto_switch_precmd
current_is v20.19.5 'manual override also survives outside projects'
nvm auto refresh
current_is v16.16.0 'refresh ends override outside projects'
nvm use --silent 20.19.5
mkdir "$TEST_ROOT/outside/subdir"
cd "$TEST_ROOT/outside/subdir"
current_is v16.16.0 'directory change ends override outside projects'
nvm auto on
source "$NVM_DIR/nvm.sh" --no-use
assert_eq "${(M)#chpwd_functions:#_nvm_auto_switch_chpwd}" 1 'one chpwd hook'
assert_eq "${(M)#precmd_functions:#_nvm_auto_switch_precmd}" 1 'one precmd hook'
[[ ${chpwd_functions[(Ie)other_hook]} -gt 0 && ${precmd_functions[(Ie)other_hook]} -gt 0 ]] || exit 1
# Exercise nvm's real prefix failure after PATH mutation, including current.
ln -s "$NVM_DIR/versions/node/v16.16.0" "$NVM_DIR/current"
export NVM_SYMLINK_CURRENT=true PREFIX=/unrelated-prefix
export NODE_PATH="$NVM_DIR/versions/node/v16.16.0/lib/node_modules:/extra"
saved_node_path=$NODE_PATH saved_path=$PATH
_nvm_auto_switch_use v22.22.3 && { print -u2 'prefix conflict should fail'; exit 1; }
assert_eq "$PATH" "$saved_path" 'real prefix failure PATH rollback'
assert_eq "$NODE_PATH" "$saved_node_path" 'real prefix failure NODE_PATH rollback'
assert_eq "$(readlink "$NVM_DIR/current")" "$NVM_DIR/versions/node/v16.16.0" 'failed switch keeps current symlink'
unset PREFIX NODE_PATH
_nvm_auto_switch_use v22.22.3
assert_eq "$(readlink "$NVM_DIR/current")" "$NVM_DIR/versions/node/v22.22.3" 'successful switch updates current symlink'
_nvm_auto_switch_use v16.16.0
unset NVM_SYMLINK_CURRENT
# Force a partial nvm use failure after mutation to exercise transactional restore.
old_path=$PATH old_bin=$NVM_BIN old_inc=$NVM_INC
export NODE_PATH='/test/original/node-path'
unset MANPATH
functions[nvm_saved]=$functions[nvm]
nvm() { if [[ $1 == use ]]; then export PATH=/broken MANPATH=/broken NVM_BIN=/broken NVM_INC=/broken NODE_PATH=/broken; return 42; fi; nvm_saved "$@"; }
_nvm_auto_switch_use v22.22.3 && { print -u2 'partial use should fail'; exit 1; }
assert_eq "$PATH" "$old_path" 'PATH rollback'
assert_eq "$NVM_BIN" "$old_bin" 'NVM_BIN rollback'
assert_eq "$NVM_INC" "$old_inc" 'NVM_INC rollback'
assert_eq "${+MANPATH}" 0 'unset MANPATH rollback'
assert_eq "$NODE_PATH" /test/original/node-path 'NODE_PATH rollback'
unset NODE_PATH
functions[nvm]=$functions[nvm_saved]
unfunction nvm_saved
nvm auto off
cd "$TEST_ROOT/other"
current_is v16.16.0 'off disables switching'
nvm auto on
current_is v20.19.5 'on immediately resolves cwd'
print 88.0.0 > "$NVM_DIR/alias/default"
cd "$TEST_ROOT/outside" 2>/dev/null
current_is v20.19.5 'unavailable default keeps current version'
status_output=$(nvm auto status)
[[ $status_output == *'current: v20.19.5'* ]] || exit 1
nvm unload
assert_eq "${+functions[nvm]}" 0 'nvm unload removes nvm'
assert_eq "${+functions[_nvm_auto_switch_precmd]}" 0 'nvm unload removes autoswitch'
assert_eq "${+NVM_AUTO_SWITCH_ENABLED}" 0 'nvm unload clears state'
assert_eq "${(j:,:)chpwd_functions}" other_hook 'unload preserves other chpwd hooks'
assert_eq "${(j:,:)precmd_functions}" other_hook 'unload preserves other precmd hooks'
print 'PASS: zsh integration (isolated versions, no downloads)'

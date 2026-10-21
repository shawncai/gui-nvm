# Shared installer implementation. Requires Bash 3.2+, not Node or Python.

FORK_BEGIN='# >>> nvm auto-switch fork >>>'
FORK_END='# <<< nvm auto-switch fork <<<'
FORK_ENTRIES=(nvm.sh nvm-exec bash_completion auto-switch)
FORK_STAGE=''
FORK_LOCK=''
FORK_MUTATING=0

fork_die() { printf 'nvm fork: %s\n' "$*" >&2; exit 1; }

fork_usage() {
  printf 'Usage: %s [--nvm-dir DIR] [--profile FILE]\n' "$0"
  printf 'Defaults: NVM_DIR (or ~/.nvm), ZDOTDIR/.zshrc (or ~/.zshrc).\n'
}

fork_exists() { [ -e "$1" ] || [ -L "$1" ]; }

# Resolve existing directory components without changing HOME or following a
# user-controlled shell program. Newlines are rejected in metadata paths.
fork_absolute() {
  local path=$1 parent base
  case "$path" in *$'\n'*|*$'\r'*) fork_die 'Paths cannot contain newlines.' ;; esac
  parent=$(dirname -- "$path")
  base=$(basename -- "$path")
  [ -d "$parent" ] || fork_die "Parent directory does not exist: $parent"
  printf '%s/%s\n' "$(cd -- "$parent" && pwd -P)" "$base"
}

fork_profile_target() {
  local path=$1 target hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || fork_die "Profile symlink cycle: $1"
    target=$(readlink "$path")
    case "$target" in /*) path=$target ;; *) path="$(dirname -- "$path")/$target" ;; esac
    path=$(fork_absolute "$path")
  done
  printf '%s\n' "$path"
}

fork_parse() {
  local entry
  FORK_NVM_DIR=${NVM_DIR:-"$HOME/.nvm"}
  FORK_PROFILE=${ZDOTDIR:-"$HOME"}/.zshrc
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --nvm-dir) [ "$#" -ge 2 ] || fork_die '--nvm-dir requires a value'; FORK_NVM_DIR=$2; shift 2 ;;
      --profile) [ "$#" -ge 2 ] || fork_die '--profile requires a value'; FORK_PROFILE=$2; shift 2 ;;
      -h|--help) fork_usage; exit 0 ;;
      *) fork_die "Unknown argument: $1" ;;
    esac
  done
  [ -d "$FORK_NVM_DIR" ] || fork_die "NVM_DIR must already exist: $FORK_NVM_DIR"
  FORK_NVM_DIR=$(cd -- "$FORK_NVM_DIR" && pwd -P)
  case "$FORK_NVM_DIR" in *$'\n'*|*$'\r'*) fork_die 'Paths cannot contain newlines.' ;; esac
  [ "$FORK_NVM_DIR" != "$FORK_CHECKOUT" ] || fork_die 'The checkout must be separate from NVM_DIR.'
  FORK_PROFILE=$(fork_absolute "$FORK_PROFILE")
  FORK_PROFILE_TARGET=$(fork_profile_target "$FORK_PROFILE")
  for entry in "$FORK_PROFILE" "$FORK_PROFILE_TARGET"; do
    case "$entry" in
      "$FORK_NVM_DIR"|"$FORK_NVM_DIR/"*|"$FORK_CHECKOUT"|"$FORK_CHECKOUT/"*)
        fork_die 'Profile must be outside NVM_DIR and the checkout to protect versions, aliases, cache, and source.' ;;
    esac
  done
  if fork_exists "$FORK_PROFILE_TARGET" && [ ! -f "$FORK_PROFILE_TARGET" ]; then
    fork_die "Profile is not a regular file: $FORK_PROFILE"
  fi
  FORK_STATE=$FORK_NVM_DIR/.nvm-fork-install
  for entry in "${FORK_ENTRIES[@]}"; do
    case "$FORK_CHECKOUT" in "$FORK_NVM_DIR/$entry"|"$FORK_NVM_DIR/$entry/"*) fork_die 'The checkout cannot be inside a managed entry point.' ;; esac
  done
  [ ! -L "$FORK_STATE" ] || fork_die "Installer state must not be a symlink: $FORK_STATE"
  FORK_LOCK=$FORK_STATE.lock
  mkdir "$FORK_LOCK" 2>/dev/null || fork_die "Installer is already running, or a stale lock exists: $FORK_LOCK"
  trap fork_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

fork_snapshot() {
  local source=$1 destination=$2
  if fork_exists "$source"; then
    [ -f "$source" ] || [ -L "$source" ] || fork_die "Refusing to replace a directory or special file: $source"
    cp -pP "$source" "$destination"
    printf 'present\n' > "$destination.kind"
  else
    printf 'absent\n' > "$destination.kind"
  fi
}

fork_restore() {
  local destination=$1 snapshot=$2 kind
  # This is only called after ownership checks, or during this transaction.
  kind=$(cat "$snapshot.kind") || return 1
  case "$kind" in
    present)
      cp -pP "$snapshot" "$destination.nvm-fork-restore-$$" || return 1
      rm -f "$destination" || return 1
      mv "$destination.nvm-fork-restore-$$" "$destination" || return 1 ;;
    absent) rm -f "$destination" || return 1 ;;
    *) printf 'nvm fork: invalid snapshot metadata: %s\n' "$snapshot.kind" >&2; return 1 ;;
  esac
}

fork_cleanup() {
  local result=$? entry rollback_failed=0
  trap - EXIT INT TERM
  set +e
  if [ "$FORK_MUTATING" = 1 ]; then
    for entry in "${FORK_ENTRIES[@]}"; do
      fork_restore "$FORK_NVM_DIR/$entry" "$FORK_STAGE/entries/$entry" || rollback_failed=1
    done
    fork_restore "$FORK_PROFILE_TARGET" "$FORK_STAGE/profile-content" || rollback_failed=1
    if [ "$rollback_failed" = 1 ]; then
      printf 'nvm fork: rollback needs attention; backups retained at %s\n' "$FORK_STAGE" >&2
    else
      printf 'nvm fork: transaction failed; original entry points and profile restored.\n' >&2
    fi
  fi
  if [ -n "$FORK_STAGE" ] && [ "$rollback_failed" = 0 ]; then rm -rf "$FORK_STAGE"; fi
  if [ -n "$FORK_LOCK" ]; then rmdir "$FORK_LOCK" 2>/dev/null; fi
  exit "$result"
}

fork_quote() {
  local value=$1
  # Avoid Bash 3.2 printf %q emitting mixed raw/escaped multibyte characters.
  printf "'"
  while [[ "$value" == *"'"* ]]; do
    printf '%s' "${value%%\'*}"
    printf '%s' "'\\''"
    value=${value#*\'}
  done
  printf "%s'" "$value"
}

fork_block() {
  printf '%s\n' "$FORK_BEGIN"
  printf 'export NVM_DIR='
  fork_quote "$FORK_NVM_DIR"
  printf '\n'
  printf '%s\n' 'if [ -n "${ZSH_VERSION-}" ] && [[ -o interactive ]]; then' \
    '  . "$NVM_DIR/nvm.sh" --no-use' \
    '  nvm auto on' \
    'fi' "$FORK_END"
}

fork_check_markers_absent() {
  if [ -f "$FORK_PROFILE_TARGET" ] && grep -F -e "$FORK_BEGIN" -e "$FORK_END" "$FORK_PROFILE_TARGET" >/dev/null; then
    fork_die "Profile already has a fork marker without matching installer state: $FORK_PROFILE"
  fi
}

fork_validate_state() {
  local entry expected current
  [ -f "$FORK_STATE/complete" ] || fork_die "Incomplete installer state: $FORK_STATE"
  [ "$(cat "$FORK_STATE/checkout")" = "$FORK_CHECKOUT" ] || fork_die 'Installed checkout differs; uninstall using its original checkout first.'
  [ "$(cat "$FORK_STATE/profile")" = "$FORK_PROFILE" ] || fork_die 'Profile differs from the installed profile.'
  [ "$(cat "$FORK_STATE/profile-target")" = "$FORK_PROFILE_TARGET" ] || fork_die 'Profile symlink target changed; refusing to overwrite it.'
  for entry in "${FORK_ENTRIES[@]}"; do
    expected=$FORK_CHECKOUT/$entry
    [ -L "$FORK_NVM_DIR/$entry" ] || fork_die "Entry point was changed by another program; refusing to overwrite: $FORK_NVM_DIR/$entry"
    current=$(readlink "$FORK_NVM_DIR/$entry")
    [ "$current" = "$expected" ] || fork_die "Entry point was changed by another program; refusing to overwrite: $FORK_NVM_DIR/$entry"
  done
  [ -f "$FORK_PROFILE_TARGET" ] || fork_die 'Installed profile no longer exists.'
  # Reject changed, duplicate, or unbalanced owned blocks; unrelated edits stay.
  current=$(awk -v begin="$FORK_BEGIN" -v end="$FORK_END" '
    $0 == begin { starts++; inside = 1 }
    inside { print }
    $0 == end { ends++; inside = 0 }
    END { if (starts != 1 || ends != 1 || inside) exit 1 }
  ' "$FORK_PROFILE_TARGET") || fork_die 'Managed profile block was changed; refusing to overwrite it.'
  [ "$current" = "$(cat "$FORK_STATE/block")" ] || fork_die 'Managed profile block was changed; refusing to overwrite it.'
}

fork_install() {
  local entry
  fork_parse "$@"
  for entry in "${FORK_ENTRIES[@]}"; do
    [ -e "$FORK_CHECKOUT/$entry" ] || fork_die "Checkout is incomplete: $FORK_CHECKOUT/$entry"
  done
  if fork_exists "$FORK_STATE"; then
    fork_validate_state
    printf 'nvm fork: already installed from %s\n' "$FORK_CHECKOUT"
    return
  fi
  fork_check_markers_absent
  FORK_STAGE=$(mktemp -d "$FORK_NVM_DIR/.nvm-fork-install.pending.XXXXXX")
  chmod 700 "$FORK_STAGE"
  mkdir "$FORK_STAGE/entries"
  for entry in "${FORK_ENTRIES[@]}"; do
    fork_snapshot "$FORK_NVM_DIR/$entry" "$FORK_STAGE/entries/$entry"
  done
  fork_snapshot "$FORK_PROFILE" "$FORK_STAGE/profile-entry"
  fork_snapshot "$FORK_PROFILE_TARGET" "$FORK_STAGE/profile-content"
  printf '%s\n' "$FORK_CHECKOUT" > "$FORK_STAGE/checkout"
  printf '%s\n' "$FORK_PROFILE" > "$FORK_STAGE/profile"
  printf '%s\n' "$FORK_PROFILE_TARGET" > "$FORK_STAGE/profile-target"
  fork_block > "$FORK_STAGE/block"
  FORK_MUTATING=1
  for entry in "${FORK_ENTRIES[@]}"; do
    rm -f "$FORK_NVM_DIR/$entry"
    ln -s "$FORK_CHECKOUT/$entry" "$FORK_NVM_DIR/$entry"
  done
  # Keep all existing configuration lines, including a possible Homebrew setup.
  if [ -s "$FORK_PROFILE_TARGET" ] && [ -n "$(tail -c 1 "$FORK_PROFILE_TARGET")" ]; then
    printf '\n' >> "$FORK_PROFILE_TARGET"
  fi
  cat "$FORK_STAGE/block" >> "$FORK_PROFILE_TARGET"
  cp -p "$FORK_PROFILE_TARGET" "$FORK_STAGE/profile-installed"
  printf 'installed\n' > "$FORK_STAGE/complete"
  mv "$FORK_STAGE" "$FORK_STATE"
  FORK_STAGE=''
  FORK_MUTATING=0
  printf 'nvm fork: installed. Backup: %s\n' "$FORK_STATE"
  printf 'Open a new zsh, or run: source '
  fork_quote "$FORK_PROFILE"
  printf '\n'
}

fork_strip_block() {
  local line read_status inside=0
  # Preserve user lines and whether their final line has a newline.
  while :; do
    line=''
    read_status=0
    IFS= read -r line || read_status=$?
    [ "$read_status" = 0 ] || [ -n "$line" ] || break
    if [ "$line" = "$FORK_BEGIN" ]; then inside=1
    elif [ "$line" = "$FORK_END" ]; then inside=0
    elif [ "$inside" = 0 ]; then
      printf '%s' "$line"
      [ "$read_status" != 0 ] || printf '\n'
    fi
    [ "$read_status" = 0 ] || break
  done
}

fork_uninstall() {
  local entry archive
  fork_parse "$@"
  if ! fork_exists "$FORK_STATE"; then
    printf 'nvm fork: no managed installation found.\n'
    return
  fi
  fork_validate_state
  FORK_STAGE=$(mktemp -d "$FORK_NVM_DIR/.nvm-fork-uninstall.pending.XXXXXX")
  chmod 700 "$FORK_STAGE"
  mkdir "$FORK_STAGE/entries"
  for entry in "${FORK_ENTRIES[@]}"; do
    fork_snapshot "$FORK_NVM_DIR/$entry" "$FORK_STAGE/entries/$entry"
  done
  fork_snapshot "$FORK_PROFILE_TARGET" "$FORK_STAGE/profile-content"
  fork_strip_block < "$FORK_PROFILE_TARGET" > "$FORK_STAGE/profile-without-block"
  FORK_MUTATING=1
  for entry in "${FORK_ENTRIES[@]}"; do
    fork_restore "$FORK_NVM_DIR/$entry" "$FORK_STATE/entries/$entry"
  done
  if cmp -s "$FORK_PROFILE_TARGET" "$FORK_STATE/profile-installed"; then
    fork_restore "$FORK_PROFILE_TARGET" "$FORK_STATE/profile-content"
  else
    # Write through the original profile symlink, preserving its mode/identity.
    cat "$FORK_STAGE/profile-without-block" > "$FORK_PROFILE_TARGET"
  fi
  # Retain original backup for inspection; it no longer marks an active install.
  archive=$FORK_NVM_DIR/.nvm-fork-uninstalled-$(date +%Y%m%d%H%M%S)-$$
  mv "$FORK_STATE" "$archive"
  FORK_MUTATING=0
  printf 'nvm fork: restored original entry points and removed its profile block.\n'
  printf 'Original backup retained at: %s\n' "$archive"
  printf 'Open a new zsh to use the restored installation. Node versions and aliases were not changed.\n'
}

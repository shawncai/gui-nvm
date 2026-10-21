# Project version switching for the nvm fork. Loaded only by `nvm auto`.
# This file is zsh-specific; nvm.sh itself remains POSIX compatible.

if [[ -z ${ZSH_VERSION-} || ! -o interactive ]]; then
  return 1
fi

zmodload zsh/stat || return 1
autoload -Uz add-zsh-hook

typeset -g NVM_AUTO_SWITCH_ENABLED=${NVM_AUTO_SWITCH_ENABLED:-0}
typeset -g NVM_AUTO_SWITCH_SIGNATURE=${NVM_AUTO_SWITCH_SIGNATURE-}
typeset -g NVM_AUTO_SWITCH_SOURCE=${NVM_AUTO_SWITCH_SOURCE-}
typeset -g NVM_AUTO_SWITCH_REQUEST=${NVM_AUTO_SWITCH_REQUEST-}
typeset -g NVM_AUTO_SWITCH_TARGET=${NVM_AUTO_SWITCH_TARGET-}
typeset -g NVM_AUTO_SWITCH_RESULT=${NVM_AUTO_SWITCH_RESULT:-none}
typeset -g NVM_AUTO_SWITCH_MESSAGE=${NVM_AUTO_SWITCH_MESSAGE-}
typeset -g NVM_AUTO_SWITCH_WARNING=${NVM_AUTO_SWITCH_WARNING-}

# Fingerprints include bounded file contents, so same-size edits in the same
# timestamp tick are detected without launching Node at every prompt.
_nvm_auto_switch_fingerprint_file() {
  emulate -L zsh
  local file=$1 limit=$2 contents
  local -A info
  REPLY="${(q)file}:absent"
  if [[ -e $file || -L $file ]]; then
    if [[ ! -f $file || ! -r $file ]] || ! zstat -H info -- "$file" 2>/dev/null; then
      REPLY="${(q)file}:unreadable"
    elif (( info[size] > limit )); then
      REPLY="${(q)file}:oversize:${info[size]}:${info[mtime]}:${info[ctime]}"
    else
      contents=$(<"$file")
      REPLY="${(q)file}:${info[mode]}:${info[inode]}:${info[size]}:${(q)contents}"
    fi
  fi
}

_nvm_auto_switch_snapshot() {
  emulate -L zsh
  setopt extendedglob
  local dir=$PWD file version node_path limit signature="${(q)PWD}" REPLY
  local -a versions node_paths
  while true; do
    for file in .nvmrc .node-version package.json; do
      limit=8192
      [[ $file == package.json ]] && limit=1048576
      _nvm_auto_switch_fingerprint_file "${dir%/}/$file" "$limit"
      signature+="|$REPLY"
    done
    [[ $dir == / ]] && break
    dir=${dir:h}
  done
  for node_path in "$NVM_DIR"/versions/node/v*/bin/node(N) "$NVM_DIR"/v*/bin/node(N); do
    version=${${node_path:h:h}:t}
    if [[ -x $node_path && ${version#v} == <->.<->.<-> ]]; then
      versions+=("$version")
      node_paths+=("$node_path")
    fi
  done
  versions=(${(u)versions})
  signature+="|versions:${(j:,:)versions}|executables:${(j:,:)node_paths}"
  for file in "$NVM_DIR"/alias/**/*(N); do
    [[ -f $file || -L $file ]] || continue
    _nvm_auto_switch_fingerprint_file "$file" 8192
    signature+="|$REPLY"
  done
  typeset -ga _NVM_AUTO_SWITCH_VERSIONS=("${versions[@]}")
  typeset -ga _NVM_AUTO_SWITCH_NODE_PATHS=("${node_paths[@]}")
  REPLY=$signature
  typeset -g _NVM_AUTO_SWITCH_NEW_SIGNATURE=$REPLY
}

_nvm_auto_switch_node() {
  emulate -L zsh
  local candidate version best='' major minor patch
  local best_major=0 best_minor=0 best_patch=0
  for candidate in "${_NVM_AUTO_SWITCH_NODE_PATHS[@]}"; do
    version=${${candidate:h:h}:t}
    version=${version#v}
    major=${version%%.*}
    minor=${${version#*.}%%.*}
    patch=${version##*.}
    (( major >= 10 )) || continue
    if [[ -z $best ]] || (( major > best_major || (major == best_major && minor > best_minor) || (major == best_major && minor == best_minor && patch > best_patch) )); then
      best=$candidate
      best_major=$major best_minor=$minor best_patch=$patch
    fi
  done
  REPLY=$best
  [[ -n $best ]]
}

_nvm_auto_switch_package() {
  emulate -L zsh
  local file=$1 REPLY output runtime
  local -a response
  if ! _nvm_auto_switch_node; then
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
    _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='Reading engines.node requires a locally installed Node >=10. Install one explicitly with nvm install VERSION, then run nvm auto refresh; no download was attempted.'
    return
  fi
  runtime=$REPLY
  if ! output=$(command env -u NODE_OPTIONS -u NODE_PATH "$runtime" "$NVM_DIR/auto-switch/resolve.cjs" package "$file" "${_NVM_AUTO_SWITCH_VERSIONS[@]}" 2>/dev/null); then
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
    _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='The bundled engines.node resolver could not run.'
    return
  fi
  response=("${(@f)output}")
  case ${response[1]-} in
    ok|none|missing|error)
      _NVM_AUTO_SWITCH_RESOLVED_RESULT=${response[1]}
      _NVM_AUTO_SWITCH_RESOLVED_REQUEST=${response[2]-}
      if [[ ${response[1]} == ok ]]; then
        _NVM_AUTO_SWITCH_RESOLVED_TARGET=${response[3]-}
        if [[ ${_NVM_AUTO_SWITCH_RESOLVED_TARGET#v} != <->.<->.<-> ]]; then
          _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
          _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='The bundled resolver returned an invalid version.'
        fi
      else
        _NVM_AUTO_SWITCH_RESOLVED_MESSAGE=${response[3]-}
        if [[ ${response[1]} == missing ]]; then
          _NVM_AUTO_SWITCH_RESOLVED_MESSAGE+='; install a compatible version with nvm install VERSION, then run nvm auto refresh.'
        fi
      fi
      ;;
    *)
      _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
      _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='The bundled resolver returned an invalid response.'
      ;;
  esac
}

_nvm_auto_switch_native() {
  emulate -L zsh
  setopt extendedglob
  local file=$1 requested resolved
  local -A info
  if [[ ! -f $file || ! -r $file ]] || ! zstat -H info -- "$file" 2>/dev/null || (( info[size] > 8192 )); then
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
    _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='Version declaration is unreadable, not a regular file, or exceeds 8 KiB.'
    return
  fi
  if ! requested=$(nvm_process_nvmrc "$file" 2>/dev/null); then
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
    _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='Invalid version declaration; provide one nvm version or alias.'
    return
  fi
  # Retain nvm's alias syntax, but do not let an automatic declaration walk
  # outside the alias directory or inject terminal control characters.
  if [[ $requested == *[[:cntrl:]]* || $requested == *$'\u2028'* || $requested == *$'\u2029'* ]] ||
      { [[ $requested == */* ]] && [[ $requested != lts/* || ${requested#lts/} == */* || ${requested#lts/} == . || ${requested#lts/} == .. ]]; }; then
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=error
    _NVM_AUTO_SWITCH_RESOLVED_MESSAGE='Version declaration contains unsupported characters.'
    return
  fi
  _NVM_AUTO_SWITCH_RESOLVED_REQUEST=$requested
  if resolved=$(nvm version "$requested" 2>/dev/null) && [[ $resolved != N/A && -n $resolved ]]; then
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=ok
    _NVM_AUTO_SWITCH_RESOLVED_TARGET=$resolved
  else
    _NVM_AUTO_SWITCH_RESOLVED_RESULT=missing
    _NVM_AUTO_SWITCH_RESOLVED_MESSAGE="No installed version resolves '$requested'. Run nvm install ${(q)requested}, then nvm auto refresh."
  fi
}

_nvm_auto_switch_resolve() {
  emulate -L zsh
  local dir=$PWD file
  typeset -g _NVM_AUTO_SWITCH_RESOLVED_SOURCE=''
  typeset -g _NVM_AUTO_SWITCH_RESOLVED_REQUEST=''
  typeset -g _NVM_AUTO_SWITCH_RESOLVED_TARGET=''
  typeset -g _NVM_AUTO_SWITCH_RESOLVED_RESULT=none
  typeset -g _NVM_AUTO_SWITCH_RESOLVED_MESSAGE=''
  while true; do
    for file in .nvmrc .node-version package.json; do
      file="${dir%/}/$file"
      [[ -e $file || -L $file ]] || continue
      _NVM_AUTO_SWITCH_RESOLVED_SOURCE=$file
      if [[ ${file:t} == package.json ]]; then
        _nvm_auto_switch_package "$file"
      else
        _nvm_auto_switch_native "$file"
      fi
      [[ $_NVM_AUTO_SWITCH_RESOLVED_RESULT == none ]] || return
    done
    [[ $dir == / ]] && break
    dir=${dir:h}
  done
  _NVM_AUTO_SWITCH_RESOLVED_SOURCE=''
}

# nvm use can fail after changing PATH (for example due to a prefix in .npmrc).
# Keep both the values and the set/unset state of the caller's environment.
_nvm_auto_switch_use() {
  emulate -L zsh
  local target=$1 variable value current_link="$NVM_DIR/current" old_link=''
  local update_current=${NVM_SYMLINK_CURRENT:-false} had_link=0
  local NVM_SYMLINK_CURRENT=false
  local -A previous existed exported
  # Defer the optional persistent symlink until nvm's environment checks pass.
  # Never replace an ordinary file/directory at this location automatically.
  if [[ $update_current == true && $target != system ]]; then
    if [[ -L $current_link ]]; then
      old_link=$(command readlink "$current_link") || return 1
      had_link=1
    elif [[ -e $current_link ]]; then
      return 1
    fi
  fi
  for variable in PATH MANPATH NODE_PATH NVM_BIN NVM_INC; do
    existed[$variable]=${+parameters[$variable]}
    if (( existed[$variable] )); then
      previous[$variable]=${(P)variable}
      [[ ${(tP)variable} == *export* ]] && exported[$variable]=1
    fi
  done
  if nvm use --silent "$target" >/dev/null 2>&1; then
    if [[ $update_current != true || $target == system ]]; then
      return 0
    fi
    if [[ ! -e $current_link || -L $current_link ]] && command ln -sfn "${NVM_BIN:h}" "$current_link" 2>/dev/null; then
      return 0
    fi
    # A failed link replacement must not silently discard the old link.
    if (( had_link )) && [[ ! -e $current_link || -L $current_link ]]; then
      command ln -sfn "$old_link" "$current_link" 2>/dev/null || :
    fi
  fi
  for variable in PATH MANPATH NODE_PATH NVM_BIN NVM_INC; do
    if (( existed[$variable] )); then
      value=${previous[$variable]}
      typeset -g "$variable=$value"
      if [[ ${exported[$variable]-} == 1 ]]; then
        export "$variable"
      else
        typeset -g +x "$variable"
      fi
    else
      unset "$variable"
    fi
  done
  rehash
  return 1
}

_nvm_auto_switch_tick() {
  emulate -L zsh
  local force=${1:-0} target='' warning
  [[ ${NVM_AUTO_SWITCH_ENABLED:-0} == 1 ]] || return 0
  _nvm_auto_switch_snapshot
  if [[ $force != 1 && $NVM_AUTO_SWITCH_SIGNATURE == $_NVM_AUTO_SWITCH_NEW_SIGNATURE ]]; then
    return 0
  fi
  NVM_AUTO_SWITCH_SIGNATURE=$_NVM_AUTO_SWITCH_NEW_SIGNATURE
  _nvm_auto_switch_resolve
  NVM_AUTO_SWITCH_SOURCE=$_NVM_AUTO_SWITCH_RESOLVED_SOURCE
  NVM_AUTO_SWITCH_REQUEST=$_NVM_AUTO_SWITCH_RESOLVED_REQUEST
  NVM_AUTO_SWITCH_TARGET=$_NVM_AUTO_SWITCH_RESOLVED_TARGET
  NVM_AUTO_SWITCH_RESULT=$_NVM_AUTO_SWITCH_RESOLVED_RESULT
  NVM_AUTO_SWITCH_MESSAGE=$_NVM_AUTO_SWITCH_RESOLVED_MESSAGE
  case $NVM_AUTO_SWITCH_RESULT in
    ok) target=$NVM_AUTO_SWITCH_TARGET ;;
    none)
      # Changed context or an explicit refresh ends a manual override even
      # when neither the old nor the new directory has a declaration.
      target=$(nvm version default 2>/dev/null)
      if [[ -z $target || $target == N/A ]]; then
        NVM_AUTO_SWITCH_RESULT=missing
        NVM_AUTO_SWITCH_MESSAGE='The default alias does not resolve to an installed version; keeping the current environment. Run nvm alias default INSTALLED_VERSION, then nvm auto refresh.'
        target=''
      else
        NVM_AUTO_SWITCH_TARGET=$target
      fi
      ;;
  esac
  if [[ -n $target ]] && [[ $(nvm current 2>/dev/null) != $target ]]; then
    if ! _nvm_auto_switch_use "$target"; then
      NVM_AUTO_SWITCH_RESULT=error
      NVM_AUTO_SWITCH_MESSAGE="Could not switch to $target; the previous Node environment was restored. Run nvm use $target to inspect the error, then nvm auto refresh."
    fi
  fi
  if [[ $NVM_AUTO_SWITCH_RESULT == error && $NVM_AUTO_SWITCH_MESSAGE != *'nvm auto refresh'* ]]; then
    NVM_AUTO_SWITCH_MESSAGE+='; correct the declaration or resolver installation, then run nvm auto refresh.'
  fi
  if [[ $NVM_AUTO_SWITCH_RESULT == error || $NVM_AUTO_SWITCH_RESULT == missing ]]; then
    warning="$NVM_AUTO_SWITCH_SOURCE|$NVM_AUTO_SWITCH_REQUEST|$NVM_AUTO_SWITCH_MESSAGE"
    if [[ $force == 1 || $warning != $NVM_AUTO_SWITCH_WARNING ]]; then
      print -r -- "nvm auto: $NVM_AUTO_SWITCH_MESSAGE${NVM_AUTO_SWITCH_SOURCE:+ [${NVM_AUTO_SWITCH_SOURCE}]}" >&2
    fi
    NVM_AUTO_SWITCH_WARNING=$warning
  else
    NVM_AUTO_SWITCH_WARNING=''
  fi
  return 0
}

_nvm_auto_switch_chpwd() { _nvm_auto_switch_tick; }
_nvm_auto_switch_precmd() { _nvm_auto_switch_tick; }

nvm_auto_switch_command() {
  emulate -L zsh
  if (( $# > 1 )); then
    print -r -- 'Usage: nvm auto [on|off|status|refresh]' >&2
    return 2
  fi
  case ${1:-status} in
    on)
      if [[ $NVM_AUTO_SWITCH_ENABLED != 1 ]]; then
        NVM_AUTO_SWITCH_ENABLED=1
        add-zsh-hook chpwd _nvm_auto_switch_chpwd
        add-zsh-hook precmd _nvm_auto_switch_precmd
        _nvm_auto_switch_tick 1
      fi
      ;;
    off)
      add-zsh-hook -d chpwd _nvm_auto_switch_chpwd
      add-zsh-hook -d precmd _nvm_auto_switch_precmd
      NVM_AUTO_SWITCH_ENABLED=0
      ;;
    refresh)
      if [[ $NVM_AUTO_SWITCH_ENABLED != 1 ]]; then
        print -r -- 'nvm auto is off; run nvm auto on first.' >&2
        return 1
      fi
      _nvm_auto_switch_tick 1
      ;;
    status)
      print -r -- "nvm auto: $([[ $NVM_AUTO_SWITCH_ENABLED == 1 ]] && print on || print off)"
      print -r -- "source: ${NVM_AUTO_SWITCH_SOURCE:-none}"
      print -r -- "requested: ${NVM_AUTO_SWITCH_REQUEST:-none}"
      print -r -- "resolved: ${NVM_AUTO_SWITCH_TARGET:-none}"
      print -r -- "current: $(nvm current 2>/dev/null)"
      print -r -- "result: $NVM_AUTO_SWITCH_RESULT"
      [[ -z $NVM_AUTO_SWITCH_MESSAGE ]] || print -r -- "$NVM_AUTO_SWITCH_MESSAGE"
      ;;
    *)
      print -r -- 'Usage: nvm auto [on|off|status|refresh]' >&2
      return 2
      ;;
  esac
  return 0
}

nvm_auto_switch_unload() {
  emulate -L zsh
  nvm_auto_switch_command off
  unset NVM_AUTO_SWITCH_ENABLED NVM_AUTO_SWITCH_SIGNATURE NVM_AUTO_SWITCH_SOURCE \
    NVM_AUTO_SWITCH_REQUEST NVM_AUTO_SWITCH_TARGET NVM_AUTO_SWITCH_RESULT \
    NVM_AUTO_SWITCH_MESSAGE NVM_AUTO_SWITCH_WARNING _NVM_AUTO_SWITCH_VERSIONS _NVM_AUTO_SWITCH_NODE_PATHS \
    _NVM_AUTO_SWITCH_NEW_SIGNATURE _NVM_AUTO_SWITCH_RESOLVED_SOURCE \
    _NVM_AUTO_SWITCH_RESOLVED_REQUEST _NVM_AUTO_SWITCH_RESOLVED_TARGET \
    _NVM_AUTO_SWITCH_RESOLVED_RESULT _NVM_AUTO_SWITCH_RESOLVED_MESSAGE
  unfunction _nvm_auto_switch_fingerprint_file _nvm_auto_switch_snapshot \
    _nvm_auto_switch_node _nvm_auto_switch_package _nvm_auto_switch_native \
    _nvm_auto_switch_resolve _nvm_auto_switch_use _nvm_auto_switch_tick \
    _nvm_auto_switch_chpwd _nvm_auto_switch_precmd nvm_auto_switch_command \
    nvm_auto_switch_unload
}

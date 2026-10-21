#!/bin/sh
# Curated upstream compatibility subset: no downloads or package managers.
set -eu
TASK_SOURCE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
export TASK_SOURCE
exec python3 - <<'PY'
import os
import pathlib
import shutil
import subprocess
import tempfile

source = pathlib.Path(os.environ['TASK_SOURCE'])
units = ['nvm_change_path', 'nvm_add_iojs_prefix', 'nvm_find_up',
         'nvm_version_greater', 'nvm_version_path', 'nvm_version_dir',
         'nvm_format_version', 'nvm_is_version_installed',
         'nvm_use_if_needed', 'nvm_version']
tests = ['test/fast/Unit tests/' + name for name in units]
tests += ['test/fast/' + name for name in [
    'Sourcing nvm.sh should make the nvm command available',
    'Sourcing nvm.sh should not modify parameters of caller',
    "Running 'nvm unload' should unset all function and variables",
]]
tests += [str(path.relative_to(source)) for path in sorted((source / 'test/sourcing').iterdir())
          if path.name.startswith('Sourcing ')]
tests += ['test/slow/nvm run/' + name for name in [
    "Running 'nvm run --harmony --version' should work",
    "Running 'nvm run 0.x' should work",
    "Running 'nvm run 0.x' should error out sensibly when 0.x is not installed",
    "Running 'nvm run' should pick up .nvmrc version",
]]

node_script = '''#!/bin/sh
directory=${0%/bin/node}
case "$*" in
  --help) printf '%s\\n' 'Usage: node [options]';;
  *) printf '%s\\n' "${directory##*/}";;
esac
'''
curl_script = '''#!/bin/sh
for argument do
  case "$argument" in
    -V|--version) printf 'curl 8.0.0\\nFeatures: offline-fixture\\n'; exit 0;;
    https://nodejs.org/dist/index.tab)
      cat "$TEST_AUTO_FIXTURES/nodejs.org-dist-index.tab"; exit 0;;
    https://iojs.org/dist/index.tab)
      cat "$TEST_AUTO_FIXTURES/iojs.org-dist-index.tab"; exit 0;;
  esac
done
printf '%s\\n' "Blocked unexpected download: $*" >> "$TEST_AUTO_BLOCKED"
exit 97
'''
smoke = '''#!/bin/sh
set -e
. "$NVM_DIR/nvm.sh" --no-use
! command -v nvm_auto_switch_command >/dev/null 2>&1
nvm use --silent 0.10.1
[ "$(nvm current)" = v0.10.1 ]
[ "$(nvm run --silent 0.10.7 --version)" = v0.10.7 ]
[ "$(nvm exec --silent 0.10.3 node --version)" = v0.10.3 ]
[ "$(nvm exec --silent 0.10.3 sh -c 'printf "%s" "two words"')" = 'two words' ]
if nvm exec --silent 0.10.3 sh -c 'exit 42'; then exit 1; else [ "$?" -eq 42 ]; fi
[ "$(nvm current)" = v0.10.1 ]
nvm install 0.10.2 --skip-default-packages
[ "$(nvm current)" = v0.10.2 ]
[ -x "$NVM_DIR/v0.10.2/bin/node" ]
nvm use --silent 99.99.99 >/dev/null 2>&1 && exit 1
[ "$(nvm current)" = v0.10.2 ]
nvm unload
! command -v nvm >/dev/null 2>&1
'''

def write_executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)

with tempfile.TemporaryDirectory(prefix='nvm-upstream-') as temporary:
    task = pathlib.Path(temporary)
    tools = task / 'tools'
    tools.mkdir()
    # Explicit allowlist prevents finding a real Node or package manager in PATH.
    for name in ['awk', 'basename', 'bash', 'cat', 'chmod', 'cp', 'cut', 'date',
                 'diff', 'dirname', 'env', 'find', 'grep', 'head', 'ln', 'ls',
                 'mkdir', 'mktemp', 'mv', 'printf', 'readlink', 'rm', 'rmdir', 'sed', 'sh',
                 'sleep', 'sort', 'tail', 'touch', 'tput', 'tr', 'uname', 'wc', 'which', 'xargs', 'zsh']:
        executable = shutil.which(name)
        if executable:
            (tools / name).symlink_to(executable)
    write_executable(tools / 'curl', curl_script)
    total = 0
    for shell in ['sh', 'bash', 'zsh']:
        executable = shutil.which(shell)
        if not executable:
            raise SystemExit('Required compatibility shell is unavailable: ' + shell)
        shell_total = 0
        for index, test in enumerate(tests + ['compat-smoke.sh']):
            sandbox = task / (shell + '-' + str(index))
            tree = sandbox / 'nvm'
            shutil.copytree(source, tree, symlinks=True,
                            ignore=shutil.ignore_patterns('.git', 'node_modules', 'output', '._*', '__pycache__'))
            # Equivalent to sourcing/setup_dir: exclude this fork's dev .nvmrc.
            if (tree / '.nvmrc').exists():
                (tree / '.nvmrc').unlink()
            (sandbox / 'user').mkdir()
            (sandbox / 'tmp').mkdir()
            (tree / 'alias').mkdir(exist_ok=True)
            (tree / 'alias/default').write_text('0.10.1\n')
            for version in ['v0.10.1', 'v0.10.2', 'v0.10.3', 'v0.10.7', 'v4.1.0']:
                directory = tree / version if version.startswith('v0.10.') else tree / 'versions/node' / version
                write_executable(directory / 'bin/node', node_script)
            write_executable(tree / 'compat-smoke.sh', smoke)
            fixtures = tree / 'test/fast/Unit tests/mocks'
            blocked = sandbox / 'blocked-network'
            environment = {
                'HOME': str(sandbox / 'user'), 'NVM_DIR': str(tree), 'PATH': str(tools),
                'TMPDIR': str(sandbox / 'tmp'), 'TERM': 'xterm-256color', 'SHELL': executable,
                'TEST_AUTO_FIXTURES': str(fixtures), 'TEST_AUTO_BLOCKED': str(blocked),
                'LC_ALL': 'C',
            }
            target = tree / test
            if test == "test/fast/Running 'nvm unload' should unset all function and variables":
                # Upstream intends to ignore IFS, but line-based grep leaves the
                # newline inside exported IFS behind on some shells. Remove the
                # variable before env serializes it; keep every other assertion.
                original = target.read_text()
                prefix = 'env | grep -v PATH= | grep -v IFS='
                assert original.count(prefix) == 2, 'Upstream unload fixture changed'
                target.write_text(original.replace(prefix, 'env -u IFS | grep -v PATH='))
            command = [executable]
            if shell == 'zsh':
                command.append('-f')
            command.append(str(target))
            result = subprocess.run(command, cwd=target.parent, env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors='replace', timeout=45)
            if result.returncode or blocked.exists():
                print('FAIL: ' + shell + ': ' + test)
                print(result.stdout[-16000:])
                if blocked.exists():
                    print(blocked.read_text())
                raise SystemExit(result.returncode or 1)
            total += 1
            shell_total += 1
            shutil.rmtree(sandbox)
        print('PASS: %s: %d curated upstream/compatibility cases' % (shell, shell_total), flush=True)
    print('PASS: %d cases; isolated copies; offline index fixtures; no Node download or package manager' % total)
PY

#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
export NVM_AUTO_TEST_NODE
NVM_AUTO_TEST_NODE=$(command -v node)
python3 auto-switch/verify-vendor.py
node auto-switch/test-resolve.cjs
zsh -f -i test-auto/integration.zsh
bash test-auto/installer.sh
bash test-auto/upstream.sh
for shell in sh bash zsh; do "$shell" -n nvm.sh; done
bash -n install-fork.sh uninstall-fork.sh fork-install-common.sh
zsh -n auto-switch/nvm-auto-switch.zsh
git diff --check
printf '%s\n' 'PASS: all fork checks'

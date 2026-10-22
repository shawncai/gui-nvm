#!/bin/zsh
set -e
GUI_NVM_ROOT="${0:A:h}"
cd "$GUI_NVM_ROOT"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
source "$GUI_NVM_ROOT/nvm.sh" --no-use
nvm use 22.22.3
if ! command -v pnpm >/dev/null 2>&1; then
  print "未找到 pnpm，请安装 pnpm 8.15.8 后重试。"
  exit 1
fi
if [[ ! -d desktop/node_modules ]]; then
  pnpm --dir desktop install --frozen-lockfile --ignore-scripts
fi
pnpm --dir desktop build
dot_clean ./
pnpm --dir desktop start

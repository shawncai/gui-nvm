#!/usr/bin/env bash
# Install this checkout without changing installed Node versions or Homebrew.
set -euo pipefail
FORK_CHECKOUT=$(cd -- "$(dirname -- "$0")" && pwd -P)
. "$FORK_CHECKOUT/fork-install-common.sh"
fork_install "$@"

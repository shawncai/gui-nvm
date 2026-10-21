#!/usr/bin/env bash
# Restore the entry points saved by install-fork.sh.
set -euo pipefail
FORK_CHECKOUT=$(cd -- "$(dirname -- "$0")" && pwd -P)
. "$FORK_CHECKOUT/fork-install-common.sh"
fork_uninstall "$@"

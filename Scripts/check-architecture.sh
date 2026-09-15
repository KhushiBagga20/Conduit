#!/usr/bin/env bash
#
# Enforces Conduit's one-connection-owner rule on the Mac.
#
# Interface code — the menu bar and the workspace — must observe ConduitStore
# and call ConduitCommands. Only the composition root in Mac/Conduit/App may
# import ConduitCore, the module that owns adb, servers and sessions.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

violations=$(grep -rlE '^\s*(@testable\s+)?import\s+ConduitCore\b' Mac/Conduit --include='*.swift' \
    | grep -v '^Mac/Conduit/App/' || true)

if [ -n "$violations" ]; then
    echo "✗ Only Mac/Conduit/App may import ConduitCore. Found in:"
    printf '  %s\n' $violations
    exit 1
fi
echo "✓ Interfaces depend on ConduitState, not ConduitCore"

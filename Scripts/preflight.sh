#!/usr/bin/env bash
#
# Pre-commit checks for Conduit.
#
# Run before every commit:
#
#   Scripts/preflight.sh
#
# Prints the working-tree status and diff summary, then fails if anything
# staged or untracked looks like a secret, a signing asset or private data.
# It is a guard rail, not a guarantee — always read the diff as well.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "== Status"
git status --short

echo
echo "== Diff summary (staged and unstaged)"
git diff --stat HEAD 2>/dev/null | tail -n 25 || true

candidates=$( { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard; } | sort -u )

echo
echo "== Secret scan"
status=0

# Signing assets and credential files, by name.
if printf '%s\n' "$candidates" | grep -nE '\.(p12|cer|mobileprovision|provisionprofile|keystore|jks|pem|key)$|google-services\.json|(^|/)\.env' ; then
    echo "✗ Signing or credential files would be committed."
    status=1
fi

# Secret-shaped content inside changed text files.
patterns='BEGIN (RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{32,}'
while IFS= read -r file; do
    [ -f "$file" ] || continue
    if grep -IqE "$patterns" "$file" 2>/dev/null; then
        echo "✗ Secret-like content in $file"
        status=1
    fi
done <<< "$candidates"

# Local machine paths must not leak into committed files.
while IFS= read -r file; do
    [ -f "$file" ] || continue
    case "$file" in Scripts/preflight.sh) continue ;; esac
    if grep -IqE '/Users/[A-Za-z0-9._-]+/' "$file" 2>/dev/null; then
        echo "✗ Absolute home-directory path in $file"
        status=1
    fi
done <<< "$candidates"

[ "$status" -eq 0 ] && echo "✓ Nothing secret-shaped found"
exit "$status"

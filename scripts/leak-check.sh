#!/usr/bin/env bash
# leak-check.sh -- refuse to publish local operational detail to the public fork.
#
# The fork this install pushes to is PUBLIC (measured 2026-09-21: sasfeszek/marveen,
# private=false). A fork of a public repository cannot be made private on GitHub, so
# "the branch is ours" is never a reason to relax this. Run before every push.
#
#   bash scripts/leak-check.sh              # scan what is staged (pre-commit)
#   bash scripts/leak-check.sh <ref>        # scan <ref>..HEAD (pre-push)
#   bash scripts/leak-check.sh --files a b  # scan named files
#
# Exit 0 = clean, 1 = findings. Findings print as path:line:pattern.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

mode=${1:-staged}
findings=0

collect() {
  case "$mode" in
    --files) shift; printf '%s\n' "$@" ;;
    staged)  git diff --cached --name-only --diff-filter=ACM ;;
    *)       git diff --name-only --diff-filter=ACM "$mode"..HEAD ;;
  esac
}

# Patterns are deliberately about THIS install's operational surface, not generic
# "password" words: a generic word list drowns real findings in false positives.
#   1-4  private addressing and host names that map our network
#   5-7  identities that tie the code to a person or a chat
#   8-10 material that is a credential by shape, not by name
patterns=(
  '10\.10\.(99|10[0-4])\.[0-9]+'
  '94\.130\.136\.[0-9]+'
  '178\.48\.191\.[0-9]+'
  '(svc|office|mail|nas|gitea)\.trust4sec\.hu'
  '665871484'
  'kucseracs'
  'AgAAA[A-Za-z0-9_-]{20,}'
  '[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    scripts/leak-check.sh) continue ;;   # this file names the patterns by design
  esac
  for p in "${patterns[@]}"; do
    if out=$(grep -nEI "$p" -- "$f" 2>/dev/null); then
      while IFS= read -r line; do
        echo "LEAK $f:${line%%:*} :: $p"
        findings=$((findings + 1))
      done <<< "$out"
    fi
  done
done < <(collect "$@")

# Binary documents (network diagrams, screenshots) cannot be grepped, so they are
# judged by path. An HQ topology picture leaks more than any string would.
while IFS= read -r f; do
  case "$f" in
    docs/hq-*|*nas-mount*|scripts/secret/*|*.bak-*|*CLAUDE.md.bak*)
      echo "LEAK $f :: local-only path (network topology / host credentials / backup)"
      findings=$((findings + 1)) ;;
  esac
done < <(collect "$@")

if [ "$findings" -gt 0 ]; then
  echo
  echo "$findings finding(s). Nothing was pushed."
  echo "Local-only material belongs in .gitignore, not in a commit to a public fork."
  exit 1
fi

echo "leak-check: clean"

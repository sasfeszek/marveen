#!/usr/bin/env bash
# leak-check.sh -- refuse to publish local operational detail to the public fork.
#
# The fork this install pushes to is PUBLIC (measured 2026-09-21: sasfeszek/marveen,
# private=false). A fork of a public repository cannot be made private on GitHub, so
# "the branch is ours" is never a reason to relax this. Run before every push.
#
#   bash scripts/leak-check.sh                 # scan what is staged (pre-commit)
#   bash scripts/leak-check.sh <base> [<tip>]  # scan <base>..<tip>, tip defaults to HEAD
#   bash scripts/leak-check.sh --files a b     # scan named files
#
# <tip> is not cosmetic: a push can send a branch that is NOT checked out, and
# scanning HEAD in that case measures the wrong tree while reporting "clean".
#
# Exit 0 = clean, 1 = findings. Findings print as path:line:pattern.
set -uo pipefail

# Work in the repository the CALLER is in, not the one this script lives in.
# Measured 2026-09-21: `cd $(dirname $0)/..` sent every scan to the main
# checkout, so running the gate from a worktree silently measured a different
# tree and reported on the wrong branch. That is a false clean in the one tool
# that must not have one, and it is invisible: the output looks normal.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
cd "${TOP:-$(dirname "$0")/..}" || exit 2

mode=${1:-staged}
tip=${2:-HEAD}
findings=0
scandir=""   # non-empty when files must be read out of a ref, not the worktree

collect() {
  case "$mode" in
    --files) shift; printf '%s\n' "$@" ;;
    staged)  git diff --cached --name-only --diff-filter=ACM ;;
    *)       git diff --name-only --diff-filter=ACM "$mode".."$tip" ;;
  esac
}

# For a range, read the files from <tip> rather than the worktree: the branch
# being pushed may not be the one checked out.
if [ "$mode" != "staged" ] && [ "$mode" != "--files" ]; then
  scandir=$(mktemp -d)
  trap 'rm -rf "$scandir"' EXIT
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$scandir/$(dirname "$f")"
    git show "$tip:$f" > "$scandir/$f" 2>/dev/null || rm -f "$scandir/$f"
  done < <(collect "$@")
fi

# Resolve a listed path to the copy that should actually be read.
srcof() { if [ -n "$scandir" ] && [ -f "$scandir/$1" ]; then echo "$scandir/$1"; else echo "$1"; fi; }

# Patterns are deliberately about THIS install's operational surface, not generic
# "password" words: a generic word list drowns real findings in false positives.
#   1-5   private addressing and host names that map our network
#   6-8   identities that tie the code to a person or a chat
#   9-12  CLIENT material: engagement names, their hosts, their devices. This
#         block is the one the operator asked for by name on 2026-09-21 ("csak
#         tenyleg ne legyen ugyfel- es sajat adat benn"), and it is the block a
#         generic secret scanner does NOT have, because a client's name is not a
#         secret by shape -- only by context.
#   13-16 material that is a credential by shape, not by name
patterns=(
  '10\.10\.(99|10[0-4])\.[0-9]+'
  '10\.10\.1\.[0-9]+'
  '94\.130\.136\.[0-9]+'
  '178\.48\.191\.[0-9]+'
  '(svc|office|mail|nas|gitea)\.trust4sec\.hu'
  '665871484'
  'kucseracs'
  't4s-(hq|cloud)-[a-z0-9-]+'
  '\b[Oo][Mm][Ss][Zz]\b'
  'mentok\.hu'
  '\b[Vv]-?[Ee][Dd][Ii][Tt][Hh]\b'
  '[A-Za-z]+_Access_[0-9]+'
  'AgAAA[A-Za-z0-9_-]{20,}'
  '[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}'
  'sk-ant-[A-Za-z0-9_-]{20,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

while IFS= read -r f; do
  src=$(srcof "$f")
  [ -f "$src" ] || continue
  case "$f" in
    scripts/leak-check.sh) continue ;;   # this file names the patterns by design
  esac
  for p in "${patterns[@]}"; do
    # -e is not decoration: a pattern that starts with "-" (the PRIVATE KEY
    # header) is otherwise parsed as options. In the file loop stderr was
    # discarded, so that pattern was never actually applied and nothing said so.
    if out=$(grep -nEI -e "$p" -- "$src" 2>/dev/null); then
      while IFS= read -r line; do
        echo "LEAK $f:${line%%:*} :: $p"
        findings=$((findings + 1))
      done <<< "$out"
    fi
  done
done < <(collect "$@")

# COMMIT MESSAGES are published too, and they are the part a file scanner never
# sees. Measured 2026-09-21: two commit bodies named a client agent and its host
# while every file in the same range was clean -- the gate said "clean" and was
# right about the files and wrong about the push.
if [ "$mode" != "staged" ] && [ "$mode" != "--files" ]; then
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    msg=$(git log -1 --format='%B' "$sha")
    for p in "${patterns[@]}"; do
      if echo "$msg" | grep -qE -e "$p"; then
        echo "LEAK commit ${sha:0:9} (message) :: $p"
        findings=$((findings + 1))
      fi
    done
  done < <(git rev-list "$mode".."$tip" 2>/dev/null)
fi

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

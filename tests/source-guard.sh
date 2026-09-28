#!/usr/bin/env bash
# source-guard (D-106 §c): шаг извлекается из .github/workflows/gates.yml и
# выполняется с событиями-подделками. В GitHub не ходит.
#
#   tests/source-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass () { printf 'PASS: %s\n' "$1"; }
fail () { printf 'FAIL: %s\n' "$1"; FAILED=1; }

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  j = y["jobs"]["source-guard"] or abort("no source-guard job")
  abort("source-guard has a job-level if:") if j.key?("if")
  abort("verdict does not need source-guard") unless y["jobs"]["verdict"]["needs"].include?("source-guard")
  File.write(ARGV[1], j["steps"].find { |s| (s["env"] || {}).key?("HEAD_REF") }["run"])
' "$ROOT/.github/workflows/gates.yml" "$WORK/step.sh" && pass "структура: source-guard без if:, verdict от него зависит" \
  || { fail "структура source-guard"; exit 1; }

grep -q '"\$SOURCE"' "$ROOT/.github/workflows/gates.yml" && pass "verdict учитывает итог source-guard" \
  || fail "verdict не учитывает SOURCE"

while IFS='|' read -r label event head base want; do
  out="$(env -i PATH=/usr/bin:/bin EVENT="$event" HEAD_REF="$head" BASE_REF="$base" DEFAULT_BRANCH=main \
         bash --noprofile --norc -e -o pipefail "$WORK/step.sh" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then pass "$label → $rc"; else fail "$label → $rc, ожидалось $want: $out"; fi
done <<'CASES'
canary-base → main|pull_request|canary-base|main|1
canary/known-defect → main|pull_request|canary/known-defect|main|1
canary/x/y → main|pull_request|canary/x/y|main|1
canary/known-defect → canary-base|pull_request|canary/known-defect|canary-base|0
agent/2026-09-29-x → main|pull_request|agent/2026-09-29-x|main|0
canary-basement → main (не канарейка)|pull_request|canary-basement|main|0
feature/canary → main (не канарейка)|pull_request|feature/canary|main|0
push в main|push|||0
pull_request_target canary-base → main|pull_request_target|canary-base|main|1
CASES

out="$(env -i PATH=/usr/bin:/bin EVENT=pull_request HEAD_REF=canary-base BASE_REF=main DEFAULT_BRANCH= \
       bash --noprofile --norc -e -o pipefail "$WORK/step.sh" 2>&1)"; rc=$?
[ "$rc" = 1 ] && pass "ветка по умолчанию неизвестна → красный" || fail "ветка по умолчанию неизвестна → $rc"

[ "$FAILED" = 0 ] && echo "OK: source-guard" || exit 1

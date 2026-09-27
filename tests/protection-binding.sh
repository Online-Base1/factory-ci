#!/usr/bin/env bash
# BB-23 / L-012: привязка обязательной проверки и запрет ослабления защиты.
# Работает на локальных фикстурах через поддельный gh — в GitHub не ходит.
#
#   tests/protection-binding.sh              — проверяет setup/ этого репозитория
#   SETUP_DIR=<dir> tests/protection-binding.sh — проверяет другие версии скриптов
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${SETUP_DIR:-$ROOT/setup}"
FIX="$ROOT/tests/fixtures/protection"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PATH="$ROOT/tests/lib:$PATH" FAKE_GH_FIXTURES="$FIX"
REPO=Online-Base1/fixture

FAILED=0
pass () { printf 'PASS: %s\n' "$1"; }
fail () { printf 'FAIL: %s\n' "$1"; FAILED=1; }

run_script () { # script protection-fixture|"" -> $OUT, $RC, $LOG
  LOG="$WORK/log.$RANDOM"; : > "$LOG"
  OUT="$(FAKE_GH_LOG="$LOG" FAKE_GH_PROTECTION="$2" bash "$SETUP/$1" "$REPO" 2>&1)"; RC=$?
}
writes () { grep -v '^GET ' "$LOG" | grep -v '^$' || true; }

# (а) verify краснеет на защите без привязки источника.
run_script verify.sh "$FIX/unbound.json"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "без привязки"; then
  pass "(а) verify.sh: защита без app_id — РАСХОЖДЕНИЕ"
else
  fail "(а) verify.sh: защита без app_id не распознана (код $RC)"
fi

# Контрольная к (а): на привязанной защите verify зелёный — тест не краснеет
# всегда.
run_script verify.sh "$FIX/bound.json"
if [ "$RC" -eq 0 ]; then pass "(а-контроль) verify.sh: привязанная защита — ok"
else fail "(а-контроль) verify.sh: привязанная защита дала код $RC"; printf '%s\n' "$OUT" | grep РАСХОЖДЕНИЕ; fi

# (б) bootstrap отказывается писать поверх более строгой защиты и не делает
# НИ ОДНОЙ записи.
run_script bootstrap.sh "$FIX/probe-2026-09-27.json"
W="$(writes)"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "require_last_push_approval: true → false" && [ -z "$W" ]; then
  pass "(б) bootstrap.sh: отказ против более строгой защиты, записей нет"
else
  fail "(б) bootstrap.sh: код $RC, записи: [$(printf '%s' "$W" | tr '\n' ';')]"
fi

# Контрольные к (б): без защиты и при равной/более слабой защите запись идёт,
# и в ней обязательная проверка привязана к GitHub Actions.
for case in "" "$FIX/bound.json" "$FIX/unbound.json"; do
  name="${case:+$(basename "$case")}"; name="${name:-нет защиты}"
  run_script bootstrap.sh "$case"
  body="$(cat "$LOG".body.* 2>/dev/null | jq -c 'select(.required_status_checks) | .required_status_checks.checks' 2>/dev/null | head -1)"
  if [ "$RC" -eq 0 ] && [ "$body" = '[{"context":"gates / verdict","app_id":15368}]' ]; then
    pass "(б-контроль) bootstrap.sh против [$name]: запись с app_id 15368"
  else
    fail "(б-контроль) bootstrap.sh против [$name]: код $RC, checks=[$body]"
  fi
  rm -f "$LOG".body.*
done

# (б, по параметрам) фильтр ослаблений ловит каждый параметр по отдельности.
# Текущая защита — probe; желаемая — она же с одной ослабленной настройкой.
FILTER="$SETUP/protection-weakening.jq"
if [ ! -f "$FILTER" ]; then
  fail "(б-параметры) нет $FILTER"
else
  base="$WORK/desired-base.json"
  jq '{required_status_checks: {strict: .required_status_checks.strict, checks: .required_status_checks.checks},
       enforce_admins: .enforce_admins.enabled,
       required_pull_request_reviews: (.required_pull_request_reviews | del(.url)),
       restrictions: null,
       required_linear_history: .required_linear_history.enabled,
       allow_force_pushes: .allow_force_pushes.enabled,
       allow_deletions: .allow_deletions.enabled,
       block_creations: .block_creations.enabled,
       required_conversation_resolution: .required_conversation_resolution.enabled,
       lock_branch: .lock_branch.enabled,
       allow_fork_syncing: .allow_fork_syncing.enabled}' "$FIX/probe-2026-09-27.json" > "$base"
  weak () { jq -rn --slurpfile cur "$FIX/probe-2026-09-27.json" --slurpfile des "$1" -f "$FILTER"; }
  got="$(weak "$base")"
  [ -z "$got" ] && pass "(б-параметры) равная защита: ослаблений нет" || fail "(б-параметры) равная защита: [$got]"
  while IFS='|' read -r label edit expect; do
    jq "$edit" "$base" > "$WORK/d.json"
    got="$(weak "$WORK/d.json")"
    if printf '%s\n' "$got" | grep -qF -- "$expect"; then pass "(б-параметры) $label"
    else fail "(б-параметры) $label: ожидалось «$expect», получено [$got]"; fi
  done <<'CASES'
снятие app_id|.required_status_checks.checks = [{"context":"gates / verdict"}]|app_id 15368 → без привязки
другой app_id|.required_status_checks.checks[0].app_id = 99|app_id 15368 → 99
переход на contexts|.required_status_checks = {"strict":true,"contexts":["gates / verdict"]}|app_id 15368 → без привязки
снятие проверки|.required_status_checks.checks = []|required check 'gates / verdict': снимается
strict|.required_status_checks.strict = false|required_status_checks.strict: true → false
число одобрений|.required_pull_request_reviews.required_approving_review_count = 0|required_approving_review_count: 1 → 0
require_last_push_approval|.required_pull_request_reviews.require_last_push_approval = false|require_last_push_approval: true → false
dismiss_stale_reviews|.required_pull_request_reviews.dismiss_stale_reviews = false|dismiss_stale_reviews: true → false
ревью целиком|.required_pull_request_reviews = null|required_pull_request_reviews: снимается целиком
enforce_admins|.enforce_admins = false|enforce_admins: true → false
required_linear_history|.required_linear_history = false|required_linear_history: true → false
required_conversation_resolution|.required_conversation_resolution = false|required_conversation_resolution: true → false
allow_force_pushes|.allow_force_pushes = true|allow_force_pushes: false → true
allow_deletions|.allow_deletions = true|allow_deletions: false → true
CASES
fi

exit "$FAILED"

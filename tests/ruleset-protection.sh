#!/usr/bin/env bash
# Защита main через ruleset (D-089 §b): verify.sh понимает ruleset, bootstrap.sh
# не ставит классическую защиту поверх него. Локальные фикстуры и поддельный
# gh — в GitHub не ходит.
#
#   tests/ruleset-protection.sh
#   SETUP_DIR=<dir> tests/ruleset-protection.sh — другие версии скриптов
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${SETUP_DIR:-$ROOT/setup}"
FIX="$ROOT/tests/fixtures/protection"
RSFIX="$ROOT/tests/fixtures/ruleset"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export PATH="$ROOT/tests/lib:$PATH" FAKE_GH_FIXTURES="$FIX"
REPO=Online-Base1/fixture

FAILED=0
pass () { printf 'PASS: %s\n' "$1"; }
fail () { printf 'FAIL: %s\n' "$1"; FAILED=1; }

run_script () { # script classic-fixture|"" rulesets-fixture|"" -> $OUT $RC $LOG
  LOG="$WORK/log.$RANDOM"; : > "$LOG"
  OUT="$(FAKE_GH_LOG="$LOG" FAKE_GH_PROTECTION="$2" FAKE_GH_RULESETS="$3" \
         bash "$SETUP/$1" "$REPO" 2>&1)"; RC=$?
}
writes () { grep -v '^GET ' "$LOG" | grep -v '^$' || true; }
variant () { # jq-правка правильного ruleset -> путь к фикстуре
  local f="$WORK/rs.$RANDOM.json"
  jq "$1" "$RSFIX/good.json" > "$f"; printf '%s' "$f"
}

# --- verify.sh: правильный ruleset без классической защиты ------------------
run_script verify.sh "" "$RSFIX/good.json"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q -- "-- ruleset: main protection"; then
  pass "verify: правильный ruleset без классической защиты — ok"
else
  fail "verify: правильный ruleset дал код $RC"; printf '%s\n' "$OUT" | grep РАСХОЖДЕНИЕ
fi

# --- verify.sh: по одному нарушению на требование ---------------------------
while IFS='#' read -r label edit expect; do
  run_script verify.sh "" "$(variant "$edit")"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF -- "$expect"; then
    pass "verify: $label"
  else
    fail "verify: $label — код $RC, ожидалось «$expect»"
  fi
done <<'CASES'
нет обязательной проверки#.[0].rules |= map(select(.type != "required_status_checks"))#нет обязательной проверки gates / verdict
integration_id отсутствует#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks = [{"context":"gates / verdict"}] else . end)#без integration_id
integration_id чужой#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks[0].integration_id = 99 else . end)#integration_id 99, ожидался 15368
нет source-guard#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks |= map(select(.context != "gates / source-guard")) else . end)#нет обязательной проверки gates / source-guard
source-guard без integration_id#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks |= map(if .context == "gates / source-guard" then del(.integration_id) else . end) else . end)#gates / source-guard без integration_id
source-guard чужой integration_id#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks |= map(if .context == "gates / source-guard" then .integration_id = 4882611 else . end) else . end)#gates / source-guard привязан к integration_id 4882611
source-guard только именем в другом ruleset#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks |= map(select(.context != "gates / source-guard")) else . end) | . + [.[0] | .id = 2 | .name = "extra" | .rules = [{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,"required_status_checks":[{"context":"gates / source-guard"}]}}] | .bypass_actors = []]#gates / source-guard без integration_id
лишняя обязательная проверка#.[0].rules |= map(if .type == "required_status_checks" then .parameters.required_status_checks += [{"context":"lint","integration_id":15368}] else . end)#должны быть ровно
нет правила pull_request#.[0].rules |= map(select(.type != "pull_request"))#нет правила pull_request
одобрений 0#.[0].rules |= map(if .type == "pull_request" then .parameters.required_approving_review_count = 0 else . end)#required_approving_review_count < 1
нет одобрения после push#.[0].rules |= map(if .type == "pull_request" then .parameters.require_last_push_approval = false else . end)#require_last_push_approval не включён
нет линейной истории#.[0].rules |= map(select(.type != "required_linear_history"))#нет required_linear_history
нет non_fast_forward#.[0].rules |= map(select(.type != "non_fast_forward"))#нет non_fast_forward
нет deletion#.[0].rules |= map(select(.type != "deletion"))#нет deletion
обход always у администратора#.[0].bypass_actors[0].bypass_mode = "always"#обход «always»
обход exempt#.[0].bypass_actors[0].bypass_mode = "exempt"#обход «exempt»
обход у приложения#.[0].bypass_actors += [{"actor_id":4882611,"actor_type":"Integration","bypass_mode":"pull_request"}]#допустима только роль администратора
обход у роли write#.[0].bypass_actors = [{"actor_id":4,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}]#допустима только роль администратора
CASES

# --- verify.sh: ruleset, который main не защищает ---------------------------
while IFS='#' read -r label edit; do
  run_script verify.sh "" "$(variant "$edit")"
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "защита main вообще не настроена"; then
    pass "verify: $label — защиты нет"
  else
    fail "verify: $label — код $RC, защита засчитана"
  fi
done <<'CASES'
enforcement evaluate#.[0].enforcement = "evaluate"
enforcement disabled#.[0].enforcement = "disabled"
только другая ветка#.[0].conditions.ref_name.include = ["refs/heads/release"]
main исключён#.[0].conditions.ref_name.exclude = ["~DEFAULT_BRANCH"]
CASES

# --- verify.sh: классическая защита и ruleset вместе ------------------------
run_script verify.sh "$FIX/bound.json" "$RSFIX/good.json"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q -- "-- классическая защита ветки --" \
   && printf '%s' "$OUT" | grep -q -- "-- ruleset: main protection"; then
  pass "verify: классическая + ruleset — обе проверены, ok"
else
  fail "verify: классическая + ruleset — код $RC"
fi
run_script verify.sh "$FIX/bound.json" "$(variant '.[0].bypass_actors[0].bypass_mode = "always"')"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "обход «always»"; then
  pass "verify: классическая ок, ruleset с обходом always — РАСХОЖДЕНИЕ"
else
  fail "verify: классическая + плохой ruleset — код $RC"
fi
run_script verify.sh "$FIX/unbound.json" "$RSFIX/good.json"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "без привязки к источнику"; then
  pass "verify: ruleset ок, классическая без app_id — РАСХОЖДЕНИЕ"
else
  fail "verify: хороший ruleset скрыл плохую классическую защиту (код $RC)"
fi

# --- bootstrap.sh: main уже защищён ruleset ----------------------------------
run_script bootstrap.sh "" "$RSFIX/good.json"
W="$(writes)"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q "уже защищён ruleset" && [ -z "$W" ]; then
  pass "bootstrap: main под ruleset — отказ, записей нет"
else
  fail "bootstrap: код $RC, записи: [$(printf '%s' "$W" | tr '\n' ';')]"
fi
run_script bootstrap.sh "" "$(variant '.[0].enforcement = "evaluate"')"
if [ "$RC" -eq 0 ] && grep -q '^PUT repos/.*/branches/main/protection' "$LOG"; then
  pass "bootstrap: ruleset в режиме evaluate не защищает — классическая ставится"
else
  fail "bootstrap: ruleset evaluate — код $RC"
fi
rm -f "$LOG".body.* 2>/dev/null

exit "$FAILED"

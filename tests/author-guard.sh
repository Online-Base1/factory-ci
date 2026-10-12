#!/usr/bin/env bash
# Защищённые пути по АВТОРУ заявки (D-134): шаг «Защищённые пути» извлекается
# из .github/workflows/gates.yml и выполняется в одноразовом git-репозитории
# с событиями-подделками. В GitHub не ходит.
#
#   приложение (Bot) — .github/** запрещён целиком, пин тоже (D-134, п. 1);
#   человек (User)   — .github/** разрешён, блок «Изменение проверок» (п. 2),
#                      но только из своего репозитория: из форка — отказ (D-135 §c);
#   автор не назван в событии pull_request — как приложение (fail closed);
#   прочие защищённые пути — красные для всех, как раньше.
#
#   tests/author-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" /tmp/changed.txt' EXIT
FAILED=0
pass () { printf 'PASS: %s\n' "$1"; }
fail () { printf 'FAIL: %s\n' "$1"; FAILED=1; }

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  s = y["jobs"]["diff-guards"]["steps"].find { |x| x["name"] == ARGV[2].dup.force_encoding("UTF-8") } or abort("no protected-paths step")
  env = s["env"] || {}
  abort("PR author type is not passed via env") unless env["PR_USER_TYPE"] == "${{ github.event.pull_request.user.type }}"
  abort("PR author login is not passed via env") unless env["PR_USER_LOGIN"] == "${{ github.event.pull_request.user.login }}"
  abort("PR head repo is not passed via env") unless env["PR_HEAD_REPO"] == "${{ github.event.pull_request.head.repo.full_name }}"
  abort("repository is not passed via env") unless env["REPO"] == "${{ github.repository }}"
  abort("${{ }} expression inside run: event data only via env") if s["run"].include?("${{")
  File.write(ARGV[1], s["run"])
' "$ROOT/.github/workflows/gates.yml" "$WORK/step.sh" "Защищённые пути" && pass "структура: автор, login и репозиторий заявки — из события через env" \
  || { fail "структура шага «Защищённые пути»"; exit 1; }

# Одноразовый репозиторий: base и по ветке на каждый вид изменения.
R="$WORK/repo"; mkdir -p "$R/.github/workflows" && cd "$R" || exit 1
git init -q && git config user.email t@example.invalid && git config user.name t
A=$(printf 'a%.0s' $(seq 40)); B=$(printf 'b%.0s' $(seq 40))
printf 'jobs:\n  gates:\n    uses: Online-Base1/factory-ci/.github/workflows/gates.yml@%s\n' "$A" > .github/workflows/ci.yml
echo agents > AGENTS.md; echo src > src.txt
git add -A && git commit -qm base && BASE=$(git rev-parse HEAD)
variant () {  # имя, затем команды правки
  local name="$1"; shift
  git checkout -q "$BASE" && "$@" && git add -A && git commit -qm "$name" && git rev-parse HEAD
}
H_NEW=$(variant new  bash -c 'mkdir -p .github/reviewer && echo "name: digest" > .github/workflows/digest.yml && echo x > .github/reviewer/x.py')
H_PIN=$(variant pin  sed -i.bak "s/@$A/@$B/" .github/workflows/ci.yml)
H_ADDR=$(variant addr sed -i.bak "s#factory-ci/.github/workflows/gates.yml@$A#factory-ci/.github/workflows/other.yml@$A#" .github/workflows/ci.yml)
H_AGENTS=$(variant agents bash -c 'echo changed >> AGENTS.md')
H_SRC=$(variant src bash -c 'echo changed >> src.txt')
rm -f .github/workflows/ci.yml.bak

SELF=Online-Base1/probe
run_case () {  # event type login head [head_repo] → rc, вывод в $OUT
  git diff --name-only "$BASE" "$4" > /tmp/changed.txt
  OUT="$(env -i PATH="$PATH" HOME="$HOME" BASE="$BASE" HEAD="$4" EVENT="$1" PR_USER_TYPE="$2" PR_USER_LOGIN="$3" \
         REPO="$SELF" PR_HEAD_REPO="${5-$SELF}" \
         bash --noprofile --norc -e -o pipefail "$WORK/step.sh" 2>&1)"
}

WORKER='online-base1-factory-worker[bot]'
while IFS='|' read -r label event type login head want block from; do
  repo_of_pr="${from:-$SELF}"; [ "$from" = none ] && repo_of_pr=""
  run_case "$event" "$type" "$login" "${!head}" "$repo_of_pr"; rc=$?
  if [ "$rc" != "$want" ]; then fail "$label → $rc, ожидалось $want: $OUT"; continue; fi
  if [ "$block" = block ] && ! grep -q '^Изменение проверок' <<<"$OUT"; then fail "$label → нет блока «Изменение проверок»: $OUT"; continue; fi
  pass "$label → $rc${block:+, $block}"
done <<CASES
человек: новый workflow и код под .github|pull_request|User|MartynPin|H_NEW|0|block
человек: смена пина|pull_request|User|MartynPin|H_PIN|0|block
человек: смена адреса workflow|pull_request|User|MartynPin|H_ADDR|0|block
агент: новый workflow|pull_request|Bot|$WORKER|H_NEW|1|
агент: смена пина — тоже запрещена|pull_request|Bot|$WORKER|H_PIN|1|
другое приложение: новый workflow|pull_request|Bot|online-base1-reviewer[bot]|H_NEW|1|
автор не назван: новый workflow|pull_request|||H_NEW|1|
человек: AGENTS.md по-прежнему защищён|pull_request|User|MartynPin|H_AGENTS|1|
агент: обычный файл|pull_request|Bot|$WORKER|H_SRC|0|
push в main после вливания|push|||H_NEW|0|block|
человек из форка: новый workflow|pull_request|User|stranger|H_NEW|1||stranger/probe
человек из форка: смена пина|pull_request|User|stranger|H_PIN|1||stranger/probe
человек, репозиторий заявки не назван (форк удалён)|pull_request|User|stranger|H_NEW|1||none
человек из форка: обычный файл|pull_request|User|stranger|H_SRC|0||stranger/probe
CASES

# Блок называет каждый затронутый файл .github.
run_case pull_request User MartynPin "$H_NEW"
grep -q '  .github/workflows/digest.yml' <<<"$OUT" && grep -q '  .github/reviewer/x.py' <<<"$OUT" \
  && pass "блок перечисляет файлы" || fail "блок не перечисляет файлы: $OUT"

[ "$FAILED" = 0 ] && echo "OK: author-guard" || exit 1

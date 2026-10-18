#!/usr/bin/env bash
# «Сужение контракта» (L-009, BB-48): шаг извлекается из
# .github/workflows/gates.yml и выполняется в одноразовом git-репозитории.
# В GitHub не ходит.
#
#   регрессия BB-48 — параметры функции по одному на строку не контракт;
#   предохранитель — добавлено обязательное, убрано, опциональное стало
#   обязательным в СУЩЕСТВУЮЩЕМ контракте → красный; опциональное → зелёный.
#
#   tests/contract-guard.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILED=0
pass () { printf 'PASS: %s\n' "$1"; }
fail () { printf 'FAIL: %s\n' "$1"; FAILED=1; }

ruby -ryaml -e '
  y = YAML.load_file(ARGV[0])
  s = y["jobs"]["diff-guards"]["steps"].find { |x| x["name"] == ARGV[2].dup.force_encoding("UTF-8") } or abort("no contract step")
  env = s["env"] || {}
  abort("base is not passed via env") unless env["BASE_SHA"] == "${{ github.event.pull_request.base.sha || github.event.before }}"
  abort("head is not passed via env") unless env["HEAD_SHA"] == "${{ github.event.pull_request.head.sha || github.sha }}"
  abort("${{ }} expression inside run") if s["run"].include?("${{")
  abort("product script is trusted") if s["run"].include?("scripts/contract-guard.mjs")
  File.write(ARGV[1], s["run"])
' "$ROOT/.github/workflows/gates.yml" "$WORK/step.sh" "Сужение контракта" \
  && pass "структура: base/head через env, проверка внутри factory-ci" \
  || { fail "структура шага «Сужение контракта»"; exit 1; }

R="$WORK/repo"; mkdir -p "$R/lib" "$R/components" "$R/tests/unit" && cd "$R" || exit 1
git init -q && git config user.email t@example.invalid && git config user.name t
cat > lib/types.ts <<'TS'
export interface Opts {
  name: string;
  limit?: number;
}
export type Point = { x: number; y: number };
TS
cat > components/View.tsx <<'TS'
export function View({ data }: {
  data: string | null;
}) {
  return data;
}
TS
cat > lib/util.ts <<'TS'
// базовая утилита
export function chunk<T>(array: readonly T[], size: number): T[][] {
  const config = {
    label: "x",
    count: 1,
  };
  return [array.slice(0, size), [config as unknown as T]];
}
TS
printf 'export interface K {\n  open: "{";\n  a: string;\n}\n' > lib/kinds.ts
printf 'export function Gen<T extends object>({ v }: {\n  v: T;\n}) {\n  return v;\n}\n' > components/Gen.tsx
printf 'interface X {\n  a: string;\n}\nexport const t = 1;\n' > tests/unit/a.test.ts
git add -A && git commit -qm base && BASE=$(git rev-parse HEAD)

variant () {  # команды правки → SHA
  git checkout -q "$BASE" && bash -c "$1" && git add -A && git commit -qm v && git rev-parse HEAD
}
run_case () {  # head → rc, вывод в $OUT
  OUT="$(env -i PATH="$PATH" HOME="$HOME" BASE_SHA="$BASE" HEAD_SHA="$1" \
         bash --noprofile --norc -e -o pipefail "$WORK/step.sh" 2>&1)"
}
expect () {  # имя, ожидаемый rc, head[, подстрока вывода]
  run_case "$3"; local rc=$?
  if [ "$rc" = "$2" ] && { [ -z "${4:-}" ] || grep -qF -- "$4" <<<"$OUT"; }; then pass "$1"
  else fail "$1 (rc=$rc, ждали $2)"; printf '%s\n' "$OUT" | sed 's/^/    /'; fi
}

# --- регрессия BB-48: параметры по строкам — не контракт ---
GROUPBY='cat >> lib/util.ts <<EOF
export function groupBy<T, K extends PropertyKey>(
  array: readonly T[],
  keyFn: (item: T) => K,
): Record<K, T[]> {
  const result = {} as Record<K, T[]>;
  for (const item of array) (result[keyFn(item)] ??= []).push(item);
  return result;
}
EOF'
expect "BB-48: groupBy с параметрами по строкам в существующем файле — зелёный" 0 "$(variant "$GROUPBY")"
expect "BB-48: новый файл с параметрами по строкам — зелёный" 0 "$(variant "printf 'export function f(\n  a: string,\n  b: number,\n) {\n  return a + b;\n}\n' > lib/new.ts")"
expect "BB-48: существующая сигнатура переформатирована по строкам — зелёный" 0 \
  "$(variant "perl -0pi -e 's/chunk<T>\(array: readonly T\[\], size: number\)/chunk<T>(\n  array: readonly T[],\n  size: number,\n)/' lib/util.ts")"
expect "BB-48: литерал объекта со строками key: value — зелёный" 0 \
  "$(variant "perl -0pi -e 's/count: 1,/count: 1,\n    extra: true,/' lib/util.ts")"
expect "комментарий вида a: b — зелёный" 0 "$(variant "echo '// note: not a contract' >> lib/types.ts")"
expect "новый контракт в существующем файле — зелёный" 0 "$(variant "printf 'export interface Fresh {\n  id: string;\n}\n' >> lib/types.ts")"
expect "tests/ не судится: обязательное в контракт теста — зелёный" 0 "$(variant "perl -0pi -e 's/  a: string;/  a: string;\\n  b: number;/' tests/unit/a.test.ts")"

# --- предохранитель: настоящее сужение существующего контракта ---
expect "interface: добавлено обязательное — красный" 1 \
  "$(variant "perl -0pi -e 's/  name: string;/  name: string;\n  owner: string;/' lib/types.ts")" "тип Opts — добавлено ОБЯЗАТЕЛЬНОЕ свойство owner"
expect "interface: добавлено опциональное — зелёный (положительная контрольная)" 0 \
  "$(variant "perl -0pi -e 's/  name: string;/  name: string;\n  owner?: string;/' lib/types.ts")"
expect "interface: убрано свойство — красный" 1 \
  "$(variant "perl -0pi -e 's/  limit\?: number;\n//' lib/types.ts")" "тип Opts — убрано свойство limit"
expect "interface: опциональное стало обязательным — красный" 1 \
  "$(variant "perl -0pi -e 's/limit\?: number/limit: number/' lib/types.ts")" "тип Opts — свойство limit стало обязательным"
expect "type в одну строку: добавлено обязательное — красный" 1 \
  "$(variant "perl -0pi -e 's/y: number \}/y: number; z: number }/' lib/types.ts")" "тип Point — добавлено ОБЯЗАТЕЛЬНОЕ свойство z"
expect "сигнатура по строкам: добавлен обязательный проп — красный" 1 \
  "$(variant "perl -0pi -e 's/  data: string \| null;/  data: string | null;\n  reconciliations: number[];/' components/View.tsx")" "сигнатура View #0 — добавлено ОБЯЗАТЕЛЬНОЕ свойство reconciliations"
expect "сигнатура: добавлен опциональный проп — зелёный" 0 \
  "$(variant "perl -0pi -e 's/  data: string \| null;/  data: string | null;\n  reconciliations?: number[];/' components/View.tsx")"
expect "сигнатура в одну строку: добавлен обязательный проп — красный" 1 \
  "$(variant "perl -0pi -e 's/\(\{ data \}: \{\n  data: string \| null;\n\}\)/({ data, x }: { data: string | null; x: number })/' components/View.tsx")" "сигнатура View #0 — добавлено ОБЯЗАТЕЛЬНОЕ свойство x"
expect "скобка в строковом типе не сбивает разбор — добавлено обязательное, красный" 1 \
  "$(variant "perl -0pi -e 's/  a: string;/  a: string;\\n  b: number;/' lib/kinds.ts")" "тип K — добавлено ОБЯЗАТЕЛЬНОЕ свойство b"
expect "generic-сигнатура: добавлен обязательный проп — красный" 1 \
  "$(variant "perl -0pi -e 's/  v: T;/  v: T;\\n  w: T;/' components/Gen.tsx")" "сигнатура Gen #0 — добавлено ОБЯЗАТЕЛЬНОЕ свойство w"
OUT="$(env -i PATH="$PATH" HOME="$HOME" BASE_SHA= HEAD_SHA= bash --noprofile --norc -e -o pipefail "$WORK/step.sh" 2>&1)" && pass "не pull_request (нет base) — зелёный" || fail "не pull_request"

[ "$FAILED" = 0 ] && echo "OK: contract-guard" || { echo "FAILED: contract-guard"; exit 1; }

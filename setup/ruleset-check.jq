# Проверка rulesets, действующих на main.
#
#   jq -r --arg mode check|names -f setup/ruleset-check.jq <массив rulesets>
#
# Вход — массив ПОЛНЫХ объектов ruleset (GET /repos/{repo}/rulesets/{id}),
# а не список из /rulesets: только в полном объекте есть rules и bypass_actors.
#
# mode=names — по строке на каждый ruleset, действующий на main (пусто — нет).
# mode=check — строки «ok<TAB>текст» / «bad<TAB>текст» и одна «ctx<TAB>имена»
#              с обязательными проверками (для сверки с приходящими check-runs).
#
# Действует на main: target branch, enforcement active, include содержит
# ~DEFAULT_BRANCH, refs/heads/main или ~ALL, и exclude их не исключает.
# enforcement evaluate не защищает: это режим наблюдения.

def applies_to_main:
  .target == "branch" and .enforcement == "active"
  and ((.conditions.ref_name.include // [])
       | any(. == "~DEFAULT_BRANCH" or . == "refs/heads/main" or . == "~ALL"))
  and ((.conditions.ref_name.exclude // [])
       | any(. == "~DEFAULT_BRANCH" or . == "refs/heads/main") | not);

# id приложения GitHub Actions и роли «Repository admin».
def actions_app_id: 15368;
def admin_role_id: 5;

[ .[] | select(applies_to_main) ] as $rs
| if $mode == "names" then $rs[] | "\(.name) (id \(.id))"
  else
    ([ $rs[] | .rules[]? ]) as $rules
    | def rules_of($t): [ $rules[] | select(.type == $t) ];
    ([ rules_of("required_status_checks")[] | .parameters.required_status_checks[]? ]) as $checks
    | ([ $checks[] | select(.context == "gates / verdict") ]) as $verdict
    | ([ rules_of("pull_request")[] | .parameters ]) as $pr
    | ([ $rs[] | .bypass_actors[]? ]) as $bypass
    | "ctx\t" + ([ $checks[] | .context ] | unique | join(",")),

      # обязательная проверка и её источник
      ( if ($verdict | length) == 0 then
          "bad\truleset: нет обязательной проверки gates / verdict"
        elif ([ $checks[] | .context ] | unique) != ["gates / verdict"] then
          "bad\truleset: обязательные проверки должны быть ровно ['gates / verdict'], фактически \([ $checks[] | .context ] | unique)"
        elif any($verdict[]; .integration_id == actions_app_id) then
          "ok\truleset: gates / verdict привязан к GitHub Actions (integration_id \(actions_app_id))"
        elif any($verdict[]; .integration_id == null) then
          "bad\truleset: gates / verdict без integration_id — статус засчитается от любого источника"
        else
          "bad\truleset: gates / verdict привязан к integration_id \([ $verdict[] | .integration_id ] | join(",")), ожидался \(actions_app_id)"
        end ),

      # ревью через заявку
      ( if ($pr | length) == 0 then "bad\truleset: нет правила pull_request"
        else
          ( if ([ $pr[] | .required_approving_review_count // 0 ] | max) >= 1
              then "ok\truleset: требуется не меньше одного одобрения"
              else "bad\truleset: required_approving_review_count < 1" end ),
          ( if any($pr[]; .require_last_push_approval == true)
              then "ok\truleset: одобрение после последнего push"
              else "bad\truleset: require_last_push_approval не включён" end )
        end ),

      # история и ветка
      ( if (rules_of("required_linear_history") | length) > 0
          then "ok\truleset: линейная история" else "bad\truleset: нет required_linear_history" end ),
      ( if (rules_of("non_fast_forward") | length) > 0
          then "ok\truleset: force-push запрещён (non_fast_forward)" else "bad\truleset: нет non_fast_forward — force-push разрешён" end ),
      ( if (rules_of("deletion") | length) > 0
          then "ok\truleset: удаление ветки запрещено" else "bad\truleset: нет deletion — ветку можно удалить" end ),

      # обход: только роль администратора и только через заявку
      ( if ($bypass | length) == 0 then "ok\truleset: обхода нет ни у кого"
        else
          $bypass[]
          | if .actor_type == "RepositoryRole" and .actor_id == admin_role_id and .bypass_mode == "pull_request"
              then "ok\truleset: обход — роль администратора, только через заявку"
            elif .bypass_mode == "always" or .bypass_mode == "exempt"
              then "bad\truleset: обход «\(.bypass_mode)» у \(.actor_type) \(.actor_id // "") — допустим только pull_request"
            else "bad\truleset: обход у \(.actor_type) \(.actor_id // "") — допустима только роль администратора репозитория"
            end
        end )
  end

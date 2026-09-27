# Перечисляет, что ослабит запись защиты ветки по сравнению с текущей.
#
#   jq -rn --slurpfile cur <GET protection> --slurpfile des <тело PUT> \
#      -f setup/protection-weakening.jq
#
# Пустой вывод — запись ничего не ослабляет. Каждая строка — одно ослабление.
# Урок L-012: путь восстановления не имеет права понижать защиту, поэтому
# сравнение идёт по каждому параметру, а не по «ожидаемому образцу».

# GET отдаёт флаги как {"enabled": x}, тело PUT — как x.
def flag: if type == "object" then .enabled else . end;

($cur[0]) as $c | ($des[0]) as $d
| [
    # --- обязательные проверки ---
    ( ($c.required_status_checks // null) as $cs
      | if $cs == null then empty
        else ( ($d.required_status_checks // null) as $ds
          | if $ds == null then "required_status_checks: снимаются целиком"
            else
              ( ($ds.checks // []) ) as $dc
              | ( ($dc | map(.context)) + ($ds.contexts // []) ) as $dnames
              # привязка к источнику: app_id не может исчезнуть или смениться
              | ( ($cs.checks // [])[] as $x
                  | ($dc | map(select(.context == $x.context))) as $m
                  | if ($dnames | index($x.context)) == null
                      then "required check '\($x.context)': снимается"
                    elif ($x.app_id != null and $x.app_id != -1)
                         and (($m | length) == 0 or $m[0].app_id != $x.app_id)
                      then "required check '\($x.context)': app_id \($x.app_id) → \(if ($m | length) == 0 then "без привязки" else ($m[0].app_id // "без привязки") end)"
                    else empty end ),
                ( ($cs.contexts // [])[] as $ctx
                  | if ($dnames | index($ctx)) == null
                      then "required check '\($ctx)': снимается" else empty end ),
                ( if $cs.strict == true and $ds.strict != true
                    then "required_status_checks.strict: true → \($ds.strict // false)" else empty end )
            end )
        end ),

    # --- обязательное ревью ---
    ( ($c.required_pull_request_reviews // null) as $cr
      | if $cr == null then empty
        else ( ($d.required_pull_request_reviews // null) as $dr
          | if $dr == null then "required_pull_request_reviews: снимается целиком"
            else
              ( if ($dr.required_approving_review_count // 0) < ($cr.required_approving_review_count // 0)
                  then "required_approving_review_count: \($cr.required_approving_review_count) → \($dr.required_approving_review_count // 0)"
                  else empty end ),
              ( ["dismiss_stale_reviews", "require_code_owner_reviews", "require_last_push_approval"][] as $k
                | if $cr[$k] == true and $dr[$k] != true
                    then "\($k): true → \($dr[$k] // false)" else empty end )
            end )
        end ),

    # --- флаги, где true строже ---
    ( ["enforce_admins", "required_linear_history", "required_conversation_resolution",
       "block_creations", "lock_branch"][] as $k
      | if ($c[$k] | flag) == true and $d[$k] != true
          then "\($k): true → \($d[$k] // false)" else empty end ),

    # --- флаги, где false строже ---
    ( ["allow_force_pushes", "allow_deletions", "allow_fork_syncing"][] as $k
      | if $c[$k] != null and ($c[$k] | flag) != true and $d[$k] == true
          then "\($k): false → true" else empty end ),

    # --- ограничения на push ---
    ( if ($c.restrictions // null) != null and ($d.restrictions // null) == null
        then "restrictions: снимаются" else empty end )
  ]
| unique | .[]

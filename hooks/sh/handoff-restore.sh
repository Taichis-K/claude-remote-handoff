#!/bin/sh
# handoff-restore.sh - 層1: SessionStartフック（matcher: compact / clear。sh版・jq必須）
# PS版 handoff-restore.ps1 と挙動一致必須。仕様（解決順序・必須ゲート・予算・消費/失効）は
# PS版ヘッダと HANDOFF.md「層1」参照
. "$(dirname "$0")/handoff-common.sh"

BUDGET_CURRENT_HEAD=3500
BUDGET_CURRENT_TAIL=2000
BUDGET_GIT=2000
TOTAL_MAX=10000
GIT_TIMEOUT_SEC=10
POINTER_MAX_AGE_DAYS=7

main() {
    ho_require_jq handoff-restore || exit 0
    ho_read_input || exit 0
    handoff_root=$(ho_handoff_root) || exit 0
    project_dir=$(ho_project_dir)

    source_kind=$(ho_string_field source)
    own_sid=$(ho_string_field session_id)
    ho_is_uuid "$own_sid" || own_sid=""

    # 削除・参照対象はprojects_root配下の包含ゲートを通った実在通常ファイルのみ
    # （issue #33 — 挙動変更）。ゲートNG・不存在は空＝従来の「stateなし」と同じ扱い
    tp=$(ho_path_field transcript_path)
    state_file=$(ho_valid_state_path "$tp" delete) || state_file=""

    # --- 1. ポインタ読込み（スキーマ・消費済み・有効期限を検証） ---
    latest_path="$handoff_root/latest.json"
    pointer_ok="no"
    p_sid=""
    if [ -f "$latest_path" ]; then
        # 閉じたスキーマ（issue #38 — 設計文書4.2）: 既知キー以外が1つでもあればファイル無効。
        # schema_versionは必須の整数1（欠落=旧形式 / 不一致=未知の形式でログ文言を区別 —
        # 旧producerのポインタは次のhandoffサイクルで再生成される）。判定は数値比較
        # （.schema_version == 1。PS版のdouble正規化比較と同一契約）。非objectとjq失敗は
        # 従来どおり診断なしの静かな無効（PS版のnon-PSCustomObject分岐と同一）
        schema_state=$(jq -r --argjson known "$HO_POINTER_KNOWN_KEYS" '
            if type != "object" then "notobj"
            elif ([keys_unsorted[] | select(. as $k | $known | index($k) | not)] | length) > 0 then "unknown"
            elif (has("schema_version") | not) then "old"
            elif (.schema_version == 1 | not) then "badver"
            else "ok" end' "$latest_path" 2>/dev/null)
        if [ "$schema_state" = "unknown" ]; then
            ho_error "$handoff_root" "restore" "latest.jsonに未知のキーがあります。ポインタを無効として扱いました"
        elif [ "$schema_state" = "old" ]; then
            ho_error "$handoff_root" "restore" "latest.jsonにschema_versionがありません（旧形式のポインタ）。ポインタを無効として扱いました"
        elif [ "$schema_state" = "badver" ]; then
            ho_error "$handoff_root" "restore" "latest.jsonのschema_versionが1ではありません（未知の形式）。ポインタを無効として扱いました"
        fi
        # 消費判定はdual-read（issue #34 — 設計文書4.2）: consumed == true または
        # consumed_at非空なら消費済み。consumedは存在するならboolean falseのみ許可
        # （"true"等の型違いはポインタごと無効 — PS版の -is [bool] と同一契約・罠8）
        [ "$schema_state" = "ok" ] && pointer_ok=$(jq -r '
            if type == "object"
               and (.session_id | type == "string")
               and (.nonce | type == "string" and test("^[A-Za-z0-9-]{8,64}$"))
               and ((has("consumed") | not) or (.consumed == false))
               and ((has("consumed_at") | not) or (.consumed_at == null) or (.consumed_at == ""))
            then "ok" else "no" end' "$latest_path" 2>/dev/null)
        if [ "$pointer_ok" = "ok" ]; then
            p_sid=$(jq -r '.session_id' "$latest_path")
            ho_is_uuid "$p_sid" || pointer_ok="no"
        fi
        if [ "$pointer_ok" = "ok" ]; then
            # 有効期限。鮮度判定の唯一の正はupdated_epoch＝UNIX秒の整数（issue #34 —
            # 挙動変更）。人間可読日時のパース（date -d/-j+暦日検証）は判定経路から排除し、
            # updated_atは表示専用。契約: 数値かつ整数値（jq floor同値）・0 < v・
            # v ≤ now+86400（未来skew上限1日）・now-v ≤ 7日。旧producerのポインタ
            # （updated_epochなし）はfail-closed → 次サイクルで再生成される。
            # 比較はjq内（double・53bit精度）で行い、shの算術オーバーフローを避ける —
            # 2^53超は丸まるが範囲検証の受否は変わらない（正しく拒否される）
            now_epoch=$(ho_now_epoch) || now_epoch=""
            case "$now_epoch" in ''|*[!0-9]*) now_epoch="" ;; esac
            if [ -z "$now_epoch" ]; then
                # nowを取得できなければ鮮度を判定できない（fail-closed）
                pointer_ok="no"
                ho_error "$handoff_root" "restore" "現在時刻(epoch)を取得できないため鮮度判定できません。ポインタを無効として扱いました"
            else
                epoch_state=$(jq -r --argjson now "$now_epoch" --argjson maxage "$POINTER_MAX_AGE_DAYS" '
                    if (has("updated_epoch") | not) then "bad"
                    else .updated_epoch as $v |
                        if (($v | type) != "number") or ($v != ($v | floor)) or ($v <= 0)
                           or ($v > ($now + 86400)) then "bad"
                        elif ($now - $v) > ($maxage * 86400) then "expired"
                        else "ok" end
                    end' "$latest_path" 2>/dev/null)
                if [ "$epoch_state" = "expired" ]; then
                    # 契約内の値で期限超過のみ静かに無効（毎回の復元でerror.logを埋めない —
                    # 旧updated_at時代の期限切れと同じ扱い）
                    pointer_ok="no"
                elif [ "$epoch_state" != "ok" ]; then
                    pointer_ok="no"
                    ho_error "$handoff_root" "restore" "latest.jsonのupdated_epochが無いか不正です。ポインタを無効として扱いました"
                fi
            fi
        fi
    fi

    # --- 2. handoff解決: compactは自session直接参照を最優先、clearはポインタ ---
    resolved_sid=""
    origin=""
    use_pointer="no"
    if [ "$source_kind" != "clear" ] && [ -n "$own_sid" ] && [ -f "$handoff_root/$own_sid/current.md" ]; then
        resolved_sid="$own_sid"
        origin="セッションディレクトリ直接参照（${own_sid}）"
    elif [ "$pointer_ok" = "ok" ]; then
        resolved_sid="$p_sid"
        use_pointer="yes"
        # updated_atは非信頼の表示値（鮮度検証から外れた — issue #34）。producer形式の
        # 1行に一致する場合のみ表示する（改行入り指示や巨大文字列が有効なepoch+SHAの
        # ままで復元出力へ注入される経路を遮断 — レビュー1回目 H1。PS版と同一契約）。
        # アンカーは \A/\z（文字列端）: jqのOniguruma正規表現では ^/$ が行端のため、
        # 「有効な1行目+改行+任意テキスト」が一致して値全体が出力される（レビュー2回目 H1）
        upd_disp=$(jq -r 'if (.updated_at | type) == "string"
               and (.updated_at | test("\\A[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([+-]((0[0-9]|1[0-3]):?[0-5][0-9]|14:?00)|[Zz])\\z"))
            then .updated_at else "?" end' "$latest_path" 2>/dev/null)
        [ -n "$upd_disp" ] || upd_disp="?"
        origin="latest.json経由（作成セッション: $p_sid / 更新: ${upd_disp}）"
    elif [ -n "$own_sid" ] && [ -f "$handoff_root/$own_sid/current.md" ]; then
        resolved_sid="$own_sid"
        origin="セッションディレクトリ直接参照（${own_sid}）"
    fi

    # パスは検証済みUUIDから再構築（ポインタのパスは信用しない）+ root配下検証
    current_md=""
    if [ -n "$resolved_sid" ]; then
        cand="$handoff_root/$resolved_sid/current.md"
        if [ -f "$cand" ] && ho_under_root "$handoff_root" "$cand"; then
            current_md="$cand"
        fi
    fi

    # --- 3. 必須ゲート: 完了検証 + SHA-256照合 ---
    gate="no"
    gate_note=""
    if [ -n "$current_md" ]; then
        verify_nonce=""
        if [ "$use_pointer" = "yes" ]; then
            verify_nonce=$(jq -r '.nonce' "$latest_path")
        elif [ "$pointer_ok" = "ok" ] && [ "$p_sid" = "$resolved_sid" ]; then
            verify_nonce=$(jq -r '.nonce' "$latest_path")
        elif [ "$source_kind" != "clear" ] && [ -n "$state_file" ] && [ -f "$state_file" ]; then
            # compactで自セッション参照時: 削除前の状態ファイル（completed済み）のnonceで検証。
            # 閉じたスキーマ（issue #38）: 未知キー入り・schema_version不正のstateは
            # nonce源として使わない（check側の破棄契約と同一の受否 — PS版と同一契約）
            verify_nonce=$(jq -r --argjson known "$HO_STATE_KNOWN_KEYS" '
                if type == "object" and .completed == true
                   and ([keys_unsorted[] | select(. as $k | $known | index($k) | not)] | length == 0)
                   and ((has("schema_version") | not) or (.schema_version == 1))
                   and (.nonce | type == "string" and test("^[A-Za-z0-9-]{8,64}$"))
                then .nonce else "" end' "$state_file" 2>/dev/null)
        fi
        if [ -n "$verify_nonce" ]; then
            if ho_test_complete "$current_md" "$verify_nonce"; then
                gate="yes"
                # SHA照合は**有効な**ポインタ経由時か、有効なポインタが解決先セッション自身の
                # ものの場合のみ（無効ポインタのsha256と照合するとPS版〔pointer=null→スキップ〕と
                # 分裂する）。sha256は必須（issue #31: 欠落・null・空文字列の照合スキップ縮退を
                # 廃止 — fail-closed。producerはSHA計算失敗時にポインタを書かなくなったため、
                # 無いのは旧形式か改変）。型も固定: 文字列以外は不一致として拒否
                # （`// empty` はfalseもempty扱いしてスキップし、非文字列を拒否するPS版と
                # 分裂していた — 罠8）
                if [ "$pointer_ok" = "ok" ] && { [ "$use_pointer" = "yes" ] || [ "$p_sid" = "$resolved_sid" ]; }; then
                    # 種別と値は別々に取得する（値をsentinel文字列で分類すると、sha256の実値が
                    # sentinelと同綴りの場合にPS版と分類が分裂する）。jq失敗時は空→非文字列扱い
                    p_sha_kind=$(jq -r 'if (has("sha256") | not) or (.sha256 == null) or (.sha256 == "") then "missing" elif (.sha256 | type) == "string" then "string" else "nonstring" end' "$latest_path" 2>/dev/null)
                    if [ "$p_sha_kind" = "missing" ]; then
                        gate="no"
                        gate_note="SHA-256照合不可（ポインタにsha256が無い）"
                    elif [ "$p_sha_kind" != "string" ]; then
                        gate="no"
                        gate_note="SHA-256不一致（ポインタのsha256が文字列でない）"
                    else
                        p_sha=$(jq -r '.sha256' "$latest_path" 2>/dev/null)
                        h=$(ho_sha256 "$current_md")
                        if [ -z "$h" ] || [ "$h" != "$p_sha" ]; then
                            gate="no"
                            gate_note="SHA-256不一致（完了検証後にcurrent.mdが改変されている）"
                        fi
                    fi
                fi
            else
                gate_note="完了検証NG（マーカー/構造が不正 — 未完成か改変の可能性）"
            fi
        else
            gate_note="検証情報なし（ポインタが無くnonceを確認できない）"
        fi
    fi

    # --- 4. バックアップ導線（解決したセッションのもののみ） ---
    newest_backup=""
    if [ -n "$resolved_sid" ] && [ -d "$handoff_root/$resolved_sid/backup" ]; then
        nb=$(ls -1 "$handoff_root/$resolved_sid/backup" 2>/dev/null | sort -r | head -n 1)
        [ -n "$nb" ] && newest_backup="$handoff_root/$resolved_sid/backup/$nb"
    fi

    # 注入対象が無ければ無言終了（状態ファイル削除のみ）
    if [ -z "$current_md" ] && [ -z "$newest_backup" ]; then
        [ -n "$state_file" ] && rm -f "$state_file" 2>/dev/null
        exit 0
    fi

    out="# 引き継ぎコンテキスト自動再注入（claude-remote-handoff / source: ${source_kind}）"

    # ポインタ経由で自分以外のセッションの資料を注入する場合は冒頭で明示する
    # （同一プロジェクトで複数セッションを並行させると他セッションの資料が来得る。issue #19）
    if [ "$use_pointer" = "yes" ] && { [ -z "$own_sid" ] || [ "$p_sid" != "$own_sid" ]; }; then
        out="$out

※ この資料は別セッション（${p_sid}）で作成されたものです。同一プロジェクトで複数のセッションを併用している場合は、現在の作業に対応する内容か確認してから使うこと。"
    fi

    # --- 5. current.md（ゲート通過時のみ内容を注入） ---
    # 中略行に省略区間の見出し名を含める（issue #6）。表示は既知の7必須見出しのみ・
    # 正順・重複なし（codexレビュー3回目 High-2: 任意見出しの無制限表示は注入・肥大の経路）。
    # 任意見出しの文字列は収集せず「## 必須名」の行単位完全一致（大小厳密・末尾空白のみ許容）で
    # 存在確認する（codexレビュー4回目 M2。PS版Limit-TextHeadTailと同一契約）
    if [ -n "$current_md" ] && [ "$gate" = "yes" ]; then
        md_body=$(jq -Rs --argjson h "$BUDGET_CURRENT_HEAD" --argjson t "$BUDGET_CURRENT_TAIL" \
            --argjson req '["Goal","Completed","Not Yet Done","Failed Approaches","Key Decisions","Current State","Resume Instructions"]' '
            if length <= ($h + $t) then .
            else
              ( [ .[($h):(length - $t)] | split("\n")[] | sub("\r$"; "") | sub("[ \t]+$"; "") ] ) as $ls
              | ( [ $req[] | select(("## " + .) as $hl | $ls | index($hl)) ] | join(", ") ) as $names
              | .[0:$h]
                + "\n...(中略: 全" + (length | tostring) + "文字"
                + (if ($names | length) > 0 then "。省略区間の見出し: " + $names else "" end)
                + ")...\n"
                + .[(length - $t):]
            end' "$current_md" | jq -r .)
        out="$out

## 引き継ぎ資料 current.md（$origin / 検証済み）

$md_body"
    elif [ -n "$current_md" ]; then
        out="$out

## 引き継ぎ資料 current.md: ⚠️ 検証に失敗したため注入しない（${gate_note}）。必要なら下記バックアップから状況を確認すること"
    else
        out="$out

## 引き継ぎ資料 current.md: 見つからない（下記バックアップ導線から復元を検討すること）"
    fi

    # --- 6. git状態（--stat要約。予算2,000文字） ---
    if [ -n "$project_dir" ] && ho_git_repo "$project_dir" "$handoff_root"; then
        git_text=""
        for spec in "status --porcelain|status;--porcelain" "diff --stat|diff;--no-ext-diff;--stat" "diff --cached --stat|diff;--cached;--no-ext-diff;--stat"; do
            label=${spec%%|*}
            args=$(printf '%s' "${spec#*|}" | tr ';' ' ')
            tmp_out="$handoff_root/~ho-restore.$$.tmp"
            # shellcheck disable=SC2086
            r=$(ho_git_capture "$tmp_out" "$project_dir" "$GIT_TIMEOUT_SEC" 65536 $args)
            txt=$(cat "$tmp_out" 2>/dev/null)
            rm -f "$tmp_out" 2>/dev/null
            if [ -n "$(printf '%s' "$txt" | tr -d '[:space:]')" ]; then
                git_text="$git_text### git $label
$txt
"
            elif [ "$r" != "ok" ]; then
                git_text="$git_text### git $label: 取得失敗（${r}）
"
            fi
        done
        if [ -n "$git_text" ]; then
            git_text=$(printf '%s' "$git_text" | jq -Rs --argjson m "$BUDGET_GIT" \
                'if length <= $m then . else .[0:$m] + "\n...(切り詰め)" end' | jq -r .)
            out="$out

## git状態

$git_text"
        fi
    fi

    # --- 7. 直近ユーザーメッセージ（text contentのみ・最大5件・合計1,200文字） ---
    src_transcript=""
    if [ "$source_kind" = "clear" ]; then
        if [ "$use_pointer" = "yes" ]; then
            p_tp=$(jq -r '.transcript_path // empty' "$latest_path")
            projects_root="$HOME/.claude/projects"
            if [ -n "$p_tp" ] && [ -f "$p_tp" ] && ho_under_root "$projects_root" "$p_tp"; then
                src_transcript="$p_tp"
            fi
        fi
    else
        [ -n "$tp" ] && [ -f "$tp" ] && src_transcript="$tp"
    fi
    if [ -n "$src_transcript" ]; then
        msgs=$(tail -n 2000 "$src_transcript" 2>/dev/null | jq -rRn '
            [ inputs | fromjson? // empty
              | select(type == "object" and .type == "user"
                       and (.isSidechain != true) and (.isMeta != true))
              | .message.content?
              | if type == "string" then .
                elif type == "array" then ([ .[] | select(type == "object" and .type == "text") | .text? | strings ] | join("\n"))
                else "" end
              | select(length > 0)
              | select(test("^\\s*<") | not)
              | if length > 300 then .[0:300] + "..." else . end
            ]
            | reverse
            | reduce .[] as $t ({sel: [], tot: 0, stop: false};
                if .stop or ((.sel | length) >= 5) then . + {stop: true}
                elif (.tot + ($t | length)) > 1200 then . + {stop: true}
                else {sel: (.sel + [$t]), tot: (.tot + ($t | length)), stop: false} end)
            | .sel | reverse
            | to_entries | map((.key + 1 | tostring) + ". " + .value) | join("\n\n")' 2>/dev/null)
        if [ -n "$msgs" ]; then
            out="$out

## 直近のユーザーメッセージ（古い順）

$msgs"
        fi
    fi

    # --- 8. バックアップ導線（予算300文字） ---
    if [ -n "$newest_backup" ]; then
        bk="## 全文バックアップ導線
$newest_backup"
        if [ -f "$newest_backup/meta.json" ]; then
            # 値は「ルートがobjectかつ文字列」の場合のみ表示（それ以外・パース不能は空欄。
            # PS版と同一契約。旧 `.saved_at // ""` はルート配列でjqエラー、非文字列を
            # JSON表現のまま表示しPS版と分裂し得た）
            bk_saved_at=$(jq -r 'if (type == "object") and ((.saved_at | type) == "string") then .saved_at else "" end' "$newest_backup/meta.json" 2>/dev/null)
            bk_transcript=$(jq -r 'if (type == "object") and ((.items | type) == "object") and ((.items.transcript | type) == "string") then .items.transcript else "" end' "$newest_backup/meta.json" 2>/dev/null)
            bk="$bk
保存: ${bk_saved_at} / transcript: ${bk_transcript}"
        fi
        bk=$(printf '%s' "$bk" | jq -Rs 'if length <= 300 then . else .[0:300] + "\n...(切り詰め)" end' | jq -r .)
        out="$out

$bk"
    fi

    # --- 9. 出力（最終ガード10,000文字） ---
    printf '%s' "$out" | jq -Rs --argjson m "$TOTAL_MAX" 'if length <= $m then . else .[0:$m] end' | jq -r .

    # --- 10. ポインタの消費マーク（clearでポインタ経由の注入をした場合のみ）。
    #         dual-write（issue #34 — 設計文書4.2）: consumed=true と非空consumed_atを
    #         同一のatomic更新で書く（旧consumerはconsumed_atのみ読むため両方必要） ---
    if [ "$use_pointer" = "yes" ] && [ "$source_kind" = "clear" ] && [ "$gate" = "yes" ]; then
        # consumed_atは必ず非空にする（日時取得失敗で空を書くと旧consumerが未消費と読み
        # dual-writeの移行保証が破れる — レビュー1回目 M3）。失敗時は検証済み
        # now_epoch（ポインタ経路ではepoch検証で取得済み）のepoch表記へフォールバック
        _c=$(ho_now_display) || _c=""
        [ -n "$_c" ] || _c="epoch:${now_epoch}"
        jq --arg c "$_c" '. + {consumed: true, consumed_at: $c}' "$latest_path" 2>/dev/null \
            | ho_write_atomic "$latest_path"
    fi

    # --- 11. 状態ファイル削除 ---
    [ -n "$state_file" ] && rm -f "$state_file" 2>/dev/null
}

main
exit 0

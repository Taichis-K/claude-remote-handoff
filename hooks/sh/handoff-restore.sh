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
    ho_read_input || exit 0
    handoff_root=$(ho_handoff_root) || exit 0
    project_dir=$(ho_project_dir)

    source_kind=$(ho_field source)
    own_sid=$(ho_field session_id)
    ho_is_uuid "$own_sid" || own_sid=""

    state_file=""
    tp=$(ho_field transcript_path)
    [ -n "$tp" ] && state_file="$tp.handoff-state.json"

    # --- 1. ポインタ読込み（スキーマ・消費済み・有効期限を検証） ---
    latest_path="$handoff_root/latest.json"
    pointer_ok="no"
    if [ -f "$latest_path" ]; then
        pointer_ok=$(jq -r --argjson maxage "$POINTER_MAX_AGE_DAYS" --arg now "$(date +%s)" '
            if type == "object"
               and (.session_id | type == "string")
               and (.nonce | type == "string" and test("^[A-Za-z0-9-]{8,64}$"))
               and ((has("consumed_at") | not) or (.consumed_at == null) or (.consumed_at == ""))
            then "ok" else "no" end' "$latest_path" 2>/dev/null)
        if [ "$pointer_ok" = "ok" ]; then
            p_sid=$(jq -r '.session_id' "$latest_path")
            ho_is_uuid "$p_sid" || pointer_ok="no"
        fi
        if [ "$pointer_ok" = "ok" ]; then
            # 有効期限（date -dはGNU/BSDで差があるため日数はエポック秒で比較）。
            # **オフセット表記を正規化してから渡す** — PS版は `zzz` で `+09:00`、sh版は `%z` で
            # `+0900` を書くので、実装をまたぐと形式が違う。BSDの `%z` はコロン付きを解釈できず
            # （`Failed conversion` になる）、以前はそこで黙って期限判定ごと飛ばしていた＝
            # 他実装が書いたポインタでは有効期限が無効になっていた（macOSで実測）
            p_updated=$(jq -r '.updated_at // empty' "$latest_path")
            if [ -z "$p_updated" ]; then
                # **時刻が無いポインタは信用しない**（fail-closed）。欠落・null・空文字は
                # ここへ来る。producerは両実装とも必ず書くので、無いのは改変か壊れた記録。
                # 素通りさせると「updated_atを消すだけで期限を無期限に迂回できる」
                pointer_ok="no"
                ho_error "$handoff_root" "restore" "latest.jsonにupdated_atがありません。ポインタを無効として扱いました"
            else
                p_norm=$(printf '%s' "$p_updated" | sed 's/\([+-][0-9][0-9]\):\([0-9][0-9]\)$/\1\2/; s/[Zz]$/+0000/')
                p_epoch=$(date -d "$p_updated" +%s 2>/dev/null || date -j -f '%Y-%m-%dT%H:%M:%S%z' "$p_norm" +%s 2>/dev/null || echo "")
                if [ -n "$p_epoch" ]; then
                    now_epoch=$(date +%s)
                    age_limit=$((POINTER_MAX_AGE_DAYS * 86400))
                    [ $((now_epoch - p_epoch)) -gt "$age_limit" ] && pointer_ok="no"
                else
                    # **パースできない時刻も信用しない**（fail-closed）。ここを素通りさせると
                    # 「期限切れのはずの資料が注入される」ことに気づけない。ポインタは毎サイクル
                    # 書き直されるので、拒否しても次のhandoff作成で復帰する
                    pointer_ok="no"
                    ho_error "$handoff_root" "restore" "latest.jsonのupdated_atを解釈できません（${p_updated}）。ポインタを無効として扱いました"
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
        origin="latest.json経由（作成セッション: $p_sid / 更新: $(jq -r '.updated_at // ""' "$latest_path")）"
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
            # compactで自セッション参照時: 削除前の状態ファイル（completed済み）のnonceで検証
            verify_nonce=$(jq -r '
                if type == "object" and .completed == true
                   and (.nonce | type == "string" and test("^[A-Za-z0-9-]{8,64}$"))
                then .nonce else "" end' "$state_file" 2>/dev/null)
        fi
        if [ -n "$verify_nonce" ]; then
            if ho_test_complete "$current_md" "$verify_nonce"; then
                gate="yes"
                p_sha=$(jq -r '.sha256 // empty' "$latest_path" 2>/dev/null)
                if [ -n "$p_sha" ] && { [ "$use_pointer" = "yes" ] || [ "$p_sid" = "$resolved_sid" ]; }; then
                    h=$(ho_sha256 "$current_md")
                    if [ -z "$h" ] || [ "$h" != "$p_sha" ]; then
                        gate="no"
                        gate_note="SHA-256不一致（完了検証後にcurrent.mdが改変されている）"
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

    # --- 5. current.md（ゲート通過時のみ内容を注入） ---
    if [ -n "$current_md" ] && [ "$gate" = "yes" ]; then
        md_body=$(jq -Rs --argjson h "$BUDGET_CURRENT_HEAD" --argjson t "$BUDGET_CURRENT_TAIL" '
            if length <= ($h + $t) then .
            else .[0:$h] + "\n...(中略: 全" + (length | tostring) + "文字)...\n" + .[(length - $t):]
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
                elif type == "array" then ([ .[] | select(type == "object" and .type == "text") | .text ] | join("\n"))
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
            bk="$bk
保存: $(jq -r '.saved_at // ""' "$newest_backup/meta.json") / transcript: $(jq -r '.items.transcript // ""' "$newest_backup/meta.json")"
        fi
        bk=$(printf '%s' "$bk" | jq -Rs 'if length <= 300 then . else .[0:300] + "\n...(切り詰め)" end' | jq -r .)
        out="$out

$bk"
    fi

    # --- 9. 出力（最終ガード10,000文字） ---
    printf '%s' "$out" | jq -Rs --argjson m "$TOTAL_MAX" 'if length <= $m then . else .[0:$m] end' | jq -r .

    # --- 10. ポインタの消費マーク（clearでポインタ経由の注入をした場合のみ） ---
    if [ "$use_pointer" = "yes" ] && [ "$source_kind" = "clear" ] && [ "$gate" = "yes" ]; then
        jq --arg c "$(date +%Y-%m-%dT%H:%M:%S%z)" '. + {consumed_at: $c}' "$latest_path" 2>/dev/null \
            | ho_write_atomic "$latest_path"
    fi

    # --- 11. 状態ファイル削除 ---
    [ -n "$state_file" ] && rm -f "$state_file" 2>/dev/null
}

main
exit 0

#!/bin/sh
# handoff-check.sh - 層3: Stopフック（sh版・jq必須）
# PS版 handoff-check.ps1 と挙動一致必須。仕様はPS版ヘッダと HANDOFF.md「層3」参照
. "$(dirname "$0")/handoff-common.sh"

TAIL_LINES=500
MAX_ATTEMPTS=3

# transcript末尾からメインチェーン最後の完全なusage合算を返す（不正行は無視）
get_last_usage() {
    tail -n "$TAIL_LINES" "$1" 2>/dev/null | jq -rRn '
        [ inputs | fromjson? // empty
          | select(type == "object" and .type == "assistant" and (.isSidechain != true))
          | .message.usage? | select(type == "object")
          | [ .input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, .output_tokens ]
          | select(all(.[]; type == "number" and . == floor and . >= 0))
          | add | select(. > 0)
        ] | last // 0' 2>/dev/null || echo 0
}

# 指示文の共通部: $1=handoffMd $2=nonce
instruction_common() {
    cat <<EOF
書き先は次の絶対パス固定: $1 （このパス以外の既存ファイル、特にプロジェクトルートのHANDOFF.mdには書かないこと）。
記載セクション（この7見出しをすべて \`## 見出し名\` の形で含め、各セクションに本文を書くこと）: Goal / Completed / Not Yet Done / Failed Approaches / Key Decisions / Current State / Resume Instructions。
ファイルの最終行として完了マーカー行 <!-- handoff-complete: $2 --> を必ず書くこと。
恒久的な決定事項があればCLAUDE.mdへも反映すること。
完成したらユーザーへ「/clear の実行を推奨します（トークン消費ゼロでコンテキストをリセットでき、引き継ぎ資料は次のコンテキストに自動注入されます。Remote Control中はモバイル/Webからも実行可。放置してもauto compactが安全網として働きます）」と案内して停止すること。
EOF
}

# additionalContext出力: stdinに指示文
emit_context() {
    jq -Rs '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: .}}'
}

# ハード指示発行: $1=statePath $2=handoffMd $3=attempt
emit_hard() {
    mkdir -p "$(dirname "$2")" 2>/dev/null
    _n=$(ho_uuid)
    jq -n --arg n "$_n" --argjson a "$3" \
        '{mode: "hard", nonce: $n, attempts: $a, completed: false, failed: false}' | ho_write_atomic "$1"
    {
        printf 'コンテキスト使用量がハード閾値を超えました。auto compactで作業精度が落ちる前に、今の作業を一旦止めて引き継ぎ資料を作成してください。\n'
        if [ "$3" -gt 1 ]; then
            printf '（前回の指示では完了マーカー付きの完全な引き継ぎ資料を確認できなかった。今回は必ず全7セクション+最終行マーカーで完成させること。試行 %s/%s）\n' "$3" "$MAX_ATTEMPTS"
        fi
        instruction_common "$2" "$_n"
    } | emit_context
}

main() {
    ho_read_input || exit 0
    handoff_root=$(ho_handoff_root) || exit 0
    project_dir=$(ho_project_dir)

    transcript=$(ho_field transcript_path)
    [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
    session_id=$(ho_field session_id)
    ho_is_uuid "$session_id" || exit 0

    # --- 設定読込み（明示設定必須・値検証。不正は安全側に無効化） ---
    config_path="$project_dir/.claude/handoff-config.json"
    [ -f "$config_path" ] || exit 0
    config_ok=$(jq -r '
        if type == "object"
           and (.soft_threshold | type == "number" and . > 0)
           and (.hard_threshold | type == "number" and . > 0)
           and (.soft_threshold <= .hard_threshold)
           and ((has("min_margin") | not) or (.min_margin | type == "number" and . >= 0))
           and ((has("conservative_fire_pct") | not) or (.conservative_fire_pct | type == "number" and . >= 1 and . <= 100))
        then "ok" else "bad" end' "$config_path" 2>/dev/null)
    if [ "$config_ok" != "ok" ]; then
        ho_error "$handoff_root" "handoff-check" "handoff-config.jsonが不正。機能を無効化中"
        exit 0
    fi
    soft=$(jq -r '.soft_threshold' "$config_path")
    hard=$(jq -r '.hard_threshold' "$config_path")
    min_margin=$(jq -r '.min_margin // 10000' "$config_path")
    pct=$(jq -r '.conservative_fire_pct // 80' "$config_path")

    # 実行時best-effort再検証（環境変数が見える場合のみ）
    if [ -n "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" ] && printf '%s' "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" | grep -Eq '^[0-9]+$'; then
        w="$CLAUDE_CODE_AUTO_COMPACT_WINDOW"
        if [ -n "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" ] && printf '%s' "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" | grep -Eq '^[0-9]+$' \
            && [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -ge 1 ] && [ "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" -le 100 ]; then
            pct="$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"
        fi
        fire_point=$((w * pct / 100))
        if [ $((hard + min_margin)) -ge "$fire_point" ]; then
            ho_error "$handoff_root" "handoff-check" "実行時再検証NG: ハード閾値$hard+マージン$min_margin >= 発火点$fire_point（window=$w pct=$pct）。無効化中"
            exit 0
        fi
    fi

    # --- 状態ファイル読込み+スキーマ検証 ---
    state_path="$transcript.handoff-state.json"
    state_ok="none"
    if [ -f "$state_path" ]; then
        state_ok=$(jq -r '
            if type == "object"
               and (.mode == "soft" or .mode == "hard")
               and (.nonce | type == "string" and test("^[A-Za-z0-9-]{8,64}$"))
               and (.attempts | type == "number" and . == floor and . >= 1 and . <= 9)
               and ((has("completed") | not) or (.completed | type == "boolean"))
               and ((has("failed") | not) or (.failed | type == "boolean"))
            then "ok" else "bad" end' "$state_path" 2>/dev/null)
        if [ "$state_ok" != "ok" ]; then
            rm -f "$state_path" 2>/dev/null
            [ "$(ho_field stop_hook_active)" = "true" ] && exit 0
            state_ok="none"
        fi
    fi

    handoff_md="$handoff_root/$session_id/current.md"

    # --- 発行済み指示がある場合: 完了検証 ---
    if [ "$state_ok" = "ok" ]; then
        s_mode=$(jq -r '.mode' "$state_path")
        s_nonce=$(jq -r '.nonce' "$state_path")
        s_attempts=$(jq -r '.attempts' "$state_path")
        s_completed=$(jq -r '.completed // false' "$state_path")
        s_failed=$(jq -r '.failed // false' "$state_path")
        [ "$s_completed" = "true" ] && exit 0
        if ho_test_complete "$handoff_md" "$s_nonce"; then
            sha=$(ho_sha256 "$handoff_md")
            size=$(wc -c < "$handoff_md" | tr -d '[:space:]')
            jq -n --arg sid "$session_id" --arg hp "$handoff_md" --arg n "$s_nonce" \
                  --arg tp "$transcript" --arg ua "$(date +%Y-%m-%dT%H:%M:%S%z)" \
                  --arg sha "$sha" --argjson sz "$size" \
                '{session_id: $sid, handoff_path: $hp, nonce: $n, transcript_path: $tp,
                  updated_at: $ua, sha256: (if $sha == "" then null else $sha end), size: $sz}' \
                | ho_write_atomic "$handoff_root/latest.json"
            jq -n --arg m "$s_mode" --arg n "$s_nonce" --argjson a "$s_attempts" \
                '{mode: $m, nonce: $n, attempts: $a, completed: true, failed: false}' | ho_write_atomic "$state_path"
            exit 0
        fi
        if [ "$s_mode" = "hard" ]; then
            if [ "$s_attempts" -ge "$MAX_ATTEMPTS" ]; then
                if [ "$s_failed" != "true" ]; then
                    jq -n --arg n "$s_nonce" --argjson a "$s_attempts" \
                        '{mode: "hard", nonce: $n, attempts: $a, completed: false, failed: true}' | ho_write_atomic "$state_path"
                    ho_error "$handoff_root" "handoff-check" "ハードhandoffが${MAX_ATTEMPTS}回失敗して打ち切り（session=$session_id）"
                    jq -n --arg m "claude-remote-handoff: 引き継ぎ資料の作成が${MAX_ATTEMPTS}回失敗し打ち切りました。このまま/clearすると意味的な引き継ぎなしになります。原因（書き込み権限等）を確認し、必要なら手動でhandoff作成を指示してください。" '{systemMessage: $m}'
                fi
                exit 0
            fi
            emit_hard "$state_path" "$handoff_md" $((s_attempts + 1))
            exit 0
        fi
        # ソフト未完了は追わない。ただしハード閾値到達でエスカレーション
        tokens_now=$(get_last_usage "$transcript")
        if [ "$tokens_now" -ge "$hard" ] 2>/dev/null; then
            emit_hard "$state_path" "$handoff_md" 1
        fi
        exit 0
    fi

    # --- 未発行: usage実測 → 閾値判定 ---
    tokens=$(get_last_usage "$transcript")
    [ "$tokens" -ge "$soft" ] 2>/dev/null || exit 0

    if [ "$tokens" -ge "$hard" ] 2>/dev/null; then
        emit_hard "$state_path" "$handoff_md" 1
        exit 0
    fi

    # ソフト: 実行中バックグラウンドタスクがあれば見送り（session_cronsは判定に使わない）
    bg=$(printf '%s' "$HO_INPUT" | jq -r '.background_tasks | if type == "array" then length else 0 end' 2>/dev/null)
    [ "$bg" -gt 0 ] 2>/dev/null && exit 0

    mkdir -p "$(dirname "$handoff_md")" 2>/dev/null
    nonce=$(ho_uuid)
    jq -n --arg n "$nonce" '{mode: "soft", nonce: $n, attempts: 1, completed: false, failed: false}' | ho_write_atomic "$state_path"
    {
        printf 'コンテキスト使用量がソフト閾値を超えました。**作業が区切りの良いところまで来ていれば**、圧縮後も継続できるよう引き継ぎ資料を作成してください。中途半端な場合は今は作らなくてよい（次の区切りで作ること。ハード閾値到達時は強制になります）。\n作成する場合:\n'
        instruction_common "$handoff_md" "$nonce"
    } | emit_context
}

main
exit 0

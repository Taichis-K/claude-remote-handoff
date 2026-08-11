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
分量の目安: 全体で5000文字以内。長い資料は再注入時に中央（Failed Approaches / Key Decisions付近）から省略されるため、失敗した方法と決定理由ほど簡潔・確実に残すこと。
ファイルの最終行として完了マーカー行 <!-- handoff-complete: $2 --> を必ず書くこと。
恒久的な決定事項は反映先を選ぶこと: チーム共有すべき決定はCLAUDE.mdへ、このマシン・個人に固有の決定はCLAUDE.local.mdへ（無ければ作成し、.gitignoreへCLAUDE.local.mdを追加）。共有ファイルを編集してよいか判断できない場合は編集せず、本資料のKey Decisionsに記載するに留めること。
完成したらユーザーへ次を案内して停止すること:「引き継ぎ資料が完成しました。Remote Control中や会話ログを残したい場合はこのまま続行してください（放置すればauto compactが働き、資料は圧縮後のコンテキストへ自動注入されます）。トークン消費を節約したい場合は /clear を実行してください（消費ゼロで資料が自動注入されます。ただし会話ログは新しい空のセッションに切り替わり、次に一言送るまで作業は自動再開されません）」
EOF
}

# additionalContext出力: stdinに指示文
emit_context() {
    jq -Rs '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: .}}'
}

# ハード指示発行: $1=statePath $2=handoffMd $3=attempt [$4=前回の検証NG理由]
emit_hard() {
    mkdir -p "$(dirname "$2")" 2>/dev/null
    _n=$(ho_uuid)
    jq -n --arg n "$_n" --argjson a "$3" \
        '{schema_version: 1, mode: "hard", nonce: $n, attempts: $a, completed: false, failed: false}' | ho_write_atomic "$1"
    {
        printf 'コンテキスト使用量がハード閾値を超えました。auto compactで作業精度が落ちる前に、今の作業を一旦止めて引き継ぎ資料を作成してください。\n'
        if [ "$3" -gt 1 ]; then
            _rp=""
            [ -n "${4:-}" ] && _rp="前回の検証NG理由: ${4}。"
            printf '（%s完了マーカーのnonceは試行ごとに更新される — 必ず今回の指示にある値を使うこと。試行 %s/%s）\n' "$_rp" "$3" "$MAX_ATTEMPTS"
        fi
        instruction_common "$2" "$_n"
    } | emit_context
}

main() {
    ho_require_jq handoff-check || exit 0
    ho_read_input || exit 0
    handoff_root=$(ho_handoff_root) || exit 0
    project_dir=$(ho_project_dir)

    transcript=$(ho_path_field transcript_path)
    [ -n "$transcript" ] && [ -f "$transcript" ] || exit 0
    session_id=$(ho_string_field session_id)
    ho_is_uuid "$session_id" || exit 0

    # --- 設定読込み（明示設定必須・値検証。不正は安全側に無効化） ---
    config_path="$project_dir/.claude/handoff-config.json"
    [ -f "$config_path" ] || exit 0
    # 全数値項目を「JSON numberかつ整数かつ実用上限1e9以下」で検証（PS版Get-ConfigLongと同一契約。
    # codexレビュー3回目 Medium-3: 型・整数性・上限の検証分裂とオーバーフロー対策）
    # 閉じたスキーマ（issue #38 — 設計文書4.4）: 既知キー以外が1つでもあれば機能無効
    # （タイポで閾値が既定値に静かに落ちる事故と、未知キー経由の将来の解釈分裂を防ぐ。
    # 大小違いキーも未知キー — issue #37の契約と整合。PS版と同一契約）
    config_ok=$(jq -r --argjson known "$HO_CONFIG_KNOWN_KEYS" '
        def okint(min; max): type == "number" and . == floor and . >= min and . <= max;
        if type != "object" then "bad"
        elif ([keys_unsorted[] | select(. as $k | $known | index($k) | not)] | length) > 0 then "unknown"
        elif (.soft_threshold | okint(1; 1000000000))
           and (.hard_threshold | okint(1; 1000000000))
           and (.soft_threshold <= .hard_threshold)
           and ((has("min_margin") | not) or (.min_margin | okint(0; 1000000000)))
           and ((has("conservative_fire_pct") | not) or (.conservative_fire_pct | okint(1; 100)))
        then "ok" else "bad" end' "$config_path" 2>/dev/null)
    if [ "$config_ok" = "unknown" ]; then
        ho_error "$handoff_root" "handoff-check" "handoff-config.jsonに未知のキーがあります。機能を無効化中"
        exit 0
    elif [ "$config_ok" != "ok" ]; then
        ho_error "$handoff_root" "handoff-check" "handoff-config.jsonが不正。機能を無効化中"
        exit 0
    fi
    # autocompact_window は必須（issue #32: fire-point検証のfail-closed化。windowが解決
    # できないまま機能が有効になる「compactより確実に前で発火」の保証抜けを廃止。
    # setupは常に書くため、無いのは旧configか手書き漏れ — 無効化+診断で気づける）
    win_ok=$(jq -r '
        def okint(min; max): type == "number" and . == floor and . >= min and . <= max;
        if (type == "object") and (.autocompact_window | okint(1; 1000000000))
        then "ok" else "bad" end' "$config_path" 2>/dev/null)
    if [ "$win_ok" != "ok" ]; then
        ho_error "$handoff_root" "handoff-check" "autocompact_windowが無いか不正（v0.1.3から必須。/contextの総量に合わせて設定すること）。機能を無効化中"
        exit 0
    fi
    soft=$(jq -r '.soft_threshold' "$config_path")
    hard=$(jq -r '.hard_threshold' "$config_path")
    min_margin=$(jq -r '.min_margin // 10000' "$config_path")
    # 既定92はsetupと同一（config手書きで省略時に静かに無効化されないため。issue #8）
    pct=$(jq -r '.conservative_fire_pct // 92' "$config_path")

    # fire-point検証（常時実施 — fail-closed）: 環境変数を最優先、無効・未設定ならconfig。
    # 環境変数ゲート（issue #32）: 全体が1〜10桁のASCII数字のみ受理し、先頭ゼロ除去の
    # 10進解釈+範囲検査（先頭ゼロを残すと $(( )) が八進解釈するshellがあり、桁数無制限は
    # test の算術エラーになる）。違反は「未設定」扱いでconfigへフォールバック。
    # 検証はgrepでなくcaseで行う（grepは行単位一致のため改行混入値の1行が通ってしまう）
    check_window=$(jq -r '.autocompact_window' "$config_path")
    window_source="config"
    if ho_is_uint_token "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}"; then
        ev=$(printf '%s' "$CLAUDE_CODE_AUTO_COMPACT_WINDOW" | sed 's/^0*//')
        [ -n "$ev" ] || ev=0
        if [ "$ev" -ge 1 ] 2>/dev/null && [ "$ev" -le 1000000000 ] 2>/dev/null; then
            check_window="$ev"
            window_source="env"
        fi
    fi
    if ho_is_uint_token "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}"; then
        ep=$(printf '%s' "$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE" | sed 's/^0*//')
        [ -n "$ep" ] || ep=0
        if [ "$ep" -ge 1 ] 2>/dev/null && [ "$ep" -le 100 ] 2>/dev/null; then
            pct="$ep"
        fi
    fi
    # 発火点はfloor固定（$(( )) の整数除算=切り捨て。PS版も[Math]::Floorに統一 — issue #32）
    fire_point=$((check_window * pct / 100))
    if [ $((hard + min_margin)) -ge "$fire_point" ]; then
        ho_error "$handoff_root" "handoff-check" "実行時再検証NG: ハード閾値$hard+マージン$min_margin >= 発火点${fire_point}（window=$check_window source=$window_source pct=${pct}）。無効化中"
        exit 0
    fi

    # --- 状態ファイル読込み+スキーマ検証 ---
    # 状態ファイルの作成・削除はprojects_root配下の包含ゲートを通った場合のみ（issue #33）。
    # ゲートNGは状態管理不能のため診断を残して終了（PS版と同一契約）
    if ! state_path=$(ho_valid_state_path "$transcript" write); then
        # 非信頼パスは制御文字を?へ置換してから記録（改行入りパスによるログ行偽装・
        # 端末制御文字混入を防ぐ — codexレビュー#33-1 L5。PS版と同一契約）
        safe_tp=$(printf '%s' "$transcript" | LC_ALL=C tr '\000-\037\177' '?')
        ho_error "$handoff_root" "handoff-check" "transcript_pathがprojects_root配下の正規パスでないため状態ファイルを扱えません。機能を無効化中（path=${safe_tp}）"
        exit 0
    fi
    state_ok="none"
    if [ -f "$state_path" ]; then
        # 閉じたスキーマ（issue #38 — 設計文書4.3）: 未知キーが1つでもあればファイル無効。
        # schema_versionは現行producerが書くadditiveキー（欠落=旧バージョンは通す/
        # 存在時は数値比較で1のみ。PS版Test-HoStateClosedSchemaと同一契約）
        state_ok=$(jq -r --argjson known "$HO_STATE_KNOWN_KEYS" '
            if type == "object"
               and ([keys_unsorted[] | select(. as $k | $known | index($k) | not)] | length == 0)
               and ((has("schema_version") | not) or (.schema_version == 1))
               and (.mode == "soft" or .mode == "hard")
               and (.nonce | type == "string" and test("^[A-Za-z0-9-]{8,64}$"))
               and (.attempts | type == "number" and . == floor and . >= 1 and . <= 9)
               and ((has("completed") | not) or (.completed | type == "boolean"))
               and ((has("failed") | not) or (.failed | type == "boolean"))
            then "ok" else "bad" end' "$state_path" 2>/dev/null)
        if [ "$state_ok" != "ok" ]; then
            # 無言で消すと手がかりが残らない（issue #20）ためerror.logに記録する
            ho_error "$handoff_root" "handoff-check" "不正なhandoff-stateを破棄して再生成します（${state_path}）"
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
            # 完了確定: まずSHA-256を計算し、失敗時はポインタを更新しない（issue #31:
            # sha256=nullは「整合性ゲートの明示的無効化」経路でproducer失敗と改竄を
            # 区別できないため廃止）。stateはcompletedへ進める（指示ループ回避）。
            # 旧latest.jsonはそのまま残す: 他セッションのものなら正当な復元対象のまま、
            # 自セッション前サイクルのものは旧nonceの完了検証で拒否され、仮に通っても
            # 内容変更時はSHA不一致で拒否される（安全方向）
            sha=$(ho_sha256 "$handoff_md")
            # 鮮度判定の正になるupdated_epoch（UNIX秒整数。issue #34）。取得が失敗・
            # 非数値を返す場合はSHA計算失敗と同じ縮退（ポインタ非更新+通知）にする —
            # consumerはepoch無しをfail-closedで拒否するため、書いても使われない
            # （PS版と同一契約。実運用でdate +%sが失敗する環境は稀だがfail-closedを保つ）
            ue=$(ho_now_epoch) || ue=""
            case "$ue" in ''|*[!0-9]*) ue="" ;; esac
            if [ -z "$sha" ] || [ -z "$ue" ]; then
                if [ -z "$sha" ]; then
                    fail_kind="SHA-256計算"
                else
                    fail_kind="現在時刻(epoch)取得"
                fi
                # 通知はstate書き込み（completed遷移）の成功後のみ出す: 遷移前に通知すると
                # 次のStopでも完了検証から再突入して同じ通知を繰り返す（PS版と同一契約）
                if ! jq -n --arg m "$s_mode" --arg n "$s_nonce" --argjson a "$s_attempts" \
                    '{schema_version: 1, mode: $m, nonce: $n, attempts: $a, completed: true, failed: false}' | ho_write_atomic "$state_path"; then
                    ho_error "$handoff_root" "handoff-check" "${fail_kind}失敗後のstate書き込みにも失敗しました（session=${session_id}）"
                    exit 0
                fi
                ho_error "$handoff_root" "handoff-check" "${fail_kind}に失敗したためポインタ(latest.json)を更新しません（session=${session_id}）"
                jq -n --arg m "claude-remote-handoff: 引き継ぎ資料は完成しましたが、${fail_kind}に失敗したため復元用ポインタ(latest.json)を更新しませんでした。/clearでの自動復元は行われない可能性があります。資料: ${handoff_md}" '{systemMessage: $m}'
                exit 0
            fi
            size=$(wc -c < "$handoff_md" | tr -d '[:space:]')
            # updated_at/handoff_path/sizeは表示・移行用の併記（additive — 設計文書5章）
            ua=$(ho_now_display) || ua=""
            jq -n --arg sid "$session_id" --arg hp "$handoff_md" --arg n "$s_nonce" \
                  --arg tp "$transcript" --argjson ue "$ue" --arg ua "$ua" \
                  --arg sha "$sha" --argjson sz "$size" \
                '{schema_version: 1, session_id: $sid, handoff_path: $hp, nonce: $n, transcript_path: $tp,
                  updated_epoch: $ue, updated_at: $ua, consumed: false, sha256: $sha, size: $sz}' \
                | ho_write_atomic "$handoff_root/latest.json"
            jq -n --arg m "$s_mode" --arg n "$s_nonce" --argjson a "$s_attempts" \
                '{schema_version: 1, mode: $m, nonce: $n, attempts: $a, completed: true, failed: false}' | ho_write_atomic "$state_path"
            exit 0
        fi
        if [ "$s_mode" = "hard" ]; then
            if [ "$s_attempts" -ge "$MAX_ATTEMPTS" ]; then
                if [ "$s_failed" != "true" ]; then
                    jq -n --arg n "$s_nonce" --argjson a "$s_attempts" \
                        '{schema_version: 1, mode: "hard", nonce: $n, attempts: $a, completed: false, failed: true}' | ho_write_atomic "$state_path"
                    ho_error "$handoff_root" "handoff-check" "ハードhandoffが${MAX_ATTEMPTS}回失敗して打ち切り（session=${session_id}）"
                    jq -n --arg m "claude-remote-handoff: 引き継ぎ資料の作成が${MAX_ATTEMPTS}回失敗し打ち切りました。このまま/clearすると意味的な引き継ぎなしになります。原因（書き込み権限等）を確認し、必要なら手動でhandoff作成を指示してください。" '{systemMessage: $m}'
                fi
                exit 0
            fi
            # 検証NGの理由を次の指示文へ含める（同じ書き方の再試行で枠を浪費させない。issue #5）
            fail_reasons=$(ho_incomplete_reasons "$handoff_md" "$s_nonce")
            emit_hard "$state_path" "$handoff_md" $((s_attempts + 1)) "$fail_reasons"
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
    jq -n --arg n "$nonce" '{schema_version: 1, mode: "soft", nonce: $n, attempts: 1, completed: false, failed: false}' | ho_write_atomic "$state_path"
    {
        printf 'コンテキスト使用量がソフト閾値を超えました。**作業が区切りの良いところまで来ていれば**、圧縮後も継続できるよう引き継ぎ資料を作成してください。中途半端な場合は今は作らなくてよい（次の区切りで作ること。ハード閾値到達時は強制になります）。\n作成する場合:\n'
        instruction_common "$handoff_md" "$nonce"
    } | emit_context
}

main
exit 0

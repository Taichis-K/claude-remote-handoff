#!/bin/sh
# run-parity.sh - sh版フックに共有フィクスチャのケースを流し、正規化した結果行を出力する
# run-parity.ps1 と同一ケース・同一出力形式。CIは両者の出力をdiffして2系統一致を検証する
set -u

tests_dir=$(cd "$(dirname "$0")" && pwd)
hooks_dir="$tests_dir/../hooks/sh"
fixtures="$tests_dir/fixtures"
work="${1:-${TMPDIR:-/tmp}/handoff-parity-sh-$$}"
rm -rf "$work"
mkdir -p "$work/proj/.claude"
printf '%s' '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":80}' > "$work/proj/.claude/handoff-config.json"
export CLAUDE_PROJECT_DIR="$work/proj"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null || true
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 2>/dev/null || true

invoke_hook() { # $1=script $2=stdin-json
    printf '%s' "$2" | sh "$hooks_dir/$1"
}
stop_input() { # $1=sid $2=transcript
    jq -n --arg sid "$1" --arg tp "$2" --arg cwd "$work/proj" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false}'
}
get_state() { # $1=transcript
    _p="$1.handoff-state.json"
    [ -f "$_p" ] || { printf 'none'; return; }
    jq -r 'if .completed == true then "completed" else .mode + "/" + (.attempts | tostring) end' "$_p" 2>/dev/null || printf 'unreadable'
}
out_kind() { # $1=output
    _o="$1"
    if [ -z "$(printf '%s' "$_o" | tr -d '[:space:]')" ]; then printf 'none'; return; fi
    case "$_o" in
        *"試行 2/3"*) printf 'hard-retry'; return ;;
    esac
    # 注: ソフト指示文は「ハード閾値到達時は…」を含むため、ソフト判定を先に行う
    case "$_o" in
        *"ソフト閾値"*) printf 'soft'; return ;;
        *"ハード閾値"*) printf 'hard'; return ;;
        *"検証済み"*) printf 'injected'; return ;;
        *"検証に失敗"*) printf 'refused'; return ;;
    esac
    printf 'other'
}
usage_transcript() { # $1=path $2=tokens
    printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}\n' "$2" > "$1"
}

sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
t="$work/t.jsonl"

# C1: 閾値未満+ノイズ行（sidechain/部分行/型不正/壊れたJSON）は無発火
cp -f "$fixtures/transcripts/mixed-below.jsonl" "$t"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid" "$t")")
printf 'C1 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t")"

# C2: soft超過で提案
usage_transcript "$t" 250
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid" "$t")")
printf 'C2 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t")"

# C3: ソフト提案はサイクル1回
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid" "$t")")
printf 'C3 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t")"

# C4: hard超過でエスカレーション
usage_transcript "$t" 450
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid" "$t")")
printf 'C4 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t")"

# C5: 未完了リトライ
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid" "$t")")
printf 'C5 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t")"

# C6: 正しいmdで完了 → latest.json（nonce一致・sha付き）
nonce=$(jq -r '.nonce' "$t.handoff-state.json")
md_dir="$work/proj/.claude-handoff/$sid"
mkdir -p "$md_dir"
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid" "$t")")
latest="$work/proj/.claude-handoff/latest.json"
nonce_match="no"
[ "$(jq -r '.nonce' "$latest" 2>/dev/null)" = "$nonce" ] && nonce_match="yes"
sha_present="no"
[ -n "$(jq -r '.sha256 // empty' "$latest" 2>/dev/null)" ] && sha_present="yes"
printf 'C6 output=%s state=%s latest-nonce=%s sha=%s\n' "$(out_kind "$o")" "$(get_state "$t")" "$nonce_match" "$sha_present"

# C7: 敵対的md（## Not Goal・マーカー途中）は弾かれてリトライ
sid7="11111111-2222-3333-4444-555555555555"
t7="$work/t7.jsonl"
usage_transcript "$t7" 450
invoke_hook handoff-check.sh "$(stop_input "$sid7" "$t7")" > /dev/null
nonce7=$(jq -r '.nonce' "$t7.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid7"
sed "s/{{NONCE}}/$nonce7/" "$fixtures/md/bad-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid7/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid7" "$t7")")
printf 'C7 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t7")"

# C8: restore(clear) — 有効ポインタで注入+consumed
new_sid="99999999-8888-7777-6666-555555555555"
restore_in=$(jq -n --arg sid "$new_sid" --arg tp "$work/new.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore_in")
consumed="no"
[ -n "$(jq -r '.consumed_at // empty' "$latest" 2>/dev/null)" ] && consumed="yes"
goal="no"
case "$o" in *"機能Aの実装"*) goal="yes" ;; esac
printf 'C8 output=%s goal=%s consumed=%s\n' "$(out_kind "$o")" "$goal" "$consumed"

# C9: 消費済みポインタでは再注入しない
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C9 output=%s\n' "$(out_kind "$o")"

# C10: 改竄md（マーカー後に追記）は注入拒否
jq 'del(.consumed_at)' "$latest" > "$latest.new" && mv -f "$latest.new" "$latest"
printf 'TAMPERED\n' >> "$md_dir/current.md"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C10 output=%s\n' "$(out_kind "$o")"

# C11: **他実装が書いた形式**の期限切れポインタを拒否する（issue #1）
# 各実装は自分が書いた形式しか通らないため、C1〜C10 ではこの穴を検出できなかった。
# 固定リテラル（コロン付きオフセット・遠い過去）を使い、実装によらず同じ入力にする
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
jq --arg u '2020-01-02T03:04:05+09:00' 'del(.consumed_at) | .updated_at = $u' "$latest" > "$latest.new" \
    && mv -f "$latest.new" "$latest"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C11 output=%s\n' "$(out_kind "$o")"

# C12: updated_at が無いポインタは拒否（削るだけで期限を迂回できないこと）
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
jq 'del(.consumed_at) | del(.updated_at)' "$latest" > "$latest.new" && mv -f "$latest.new" "$latest"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C12 output=%s\n' "$(out_kind "$o")"

# C13: 解釈できない updated_at のポインタは拒否（両実装で同じ判定になること）
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
jq --arg u 'not-a-timestamp' 'del(.consumed_at) | .updated_at = $u' "$latest" > "$latest.new" \
    && mv -f "$latest.new" "$latest"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C13 output=%s\n' "$(out_kind "$o")"

rm -rf "$work"

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

# C14: 必須見出し直後の###小見出しを含む正常な資料が検証を通る（issue #4:
# 以前は###を本文終端と誤認して「本文が空」となり、検証が恒久的に失敗していた）
sid14="22222222-3333-4444-5555-666666666666"
t14="$work/t14.jsonl"
usage_transcript "$t14" 450
invoke_hook handoff-check.sh "$(stop_input "$sid14" "$t14")" > /dev/null
nonce14=$(jq -r '.nonce' "$t14.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid14"
sed "s/{{NONCE}}/$nonce14/" "$fixtures/md/good-handoff-subheadings.md.tmpl" > "$work/proj/.claude-handoff/$sid14/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid14" "$t14")")
printf 'C14 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t14")"

# C15/C16 は理由数のps/sh一致も見るため、検証関数を直接呼ぶ（codexレビュー3回目 High-1）
. "$hooks_dir/handoff-common.sh"
count_reasons() { # $1=file $2=nonce
    _cr=$(ho_incomplete_reasons "$1" "$2")
    if [ -z "$_cr" ]; then printf '0'; else printf '%s' "$_cr" | awk -F' / ' '{print NF}'; fi
}

# C15: 必須見出しをすべて###へ退避した資料は拒否される（h1/h2のみが必須見出しとして有効。
# サイズ・マーカーは正しいため、理由は「見出しが無い」×7 = 7件になるはず）
sid15="33333333-4444-5555-6666-777777777777"
t15="$work/t15.jsonl"
usage_transcript "$t15" 450
invoke_hook handoff-check.sh "$(stop_input "$sid15" "$t15")" > /dev/null
nonce15=$(jq -r '.nonce' "$t15.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid15"
sed "s/{{NONCE}}/$nonce15/" "$fixtures/md/bad-handoff-h3.md.tmpl" > "$work/proj/.claude-handoff/$sid15/current.md"
# 理由数は2回目のフック呼び出し前に数える（呼び出し後はnonceがローテートし件数が変わるため）
r15=$(count_reasons "$work/proj/.claude-handoff/$sid15/current.md" "$nonce15")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid15" "$t15")")
printf 'C15 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t15")" "$r15"

# C16: 各必須セクションが###小見出し1行だけ（実本文ゼロ）の資料は拒否される（見出し行は
# 本文に数えない。理由は「本文が空」×7 = 7件になるはず）
sid16="44444444-5555-6666-7777-888888888888"
t16="$work/t16.jsonl"
usage_transcript "$t16" 450
invoke_hook handoff-check.sh "$(stop_input "$sid16" "$t16")" > /dev/null
nonce16=$(jq -r '.nonce' "$t16.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid16"
sed "s/{{NONCE}}/$nonce16/" "$fixtures/md/bad-handoff-empty-sections.md.tmpl" > "$work/proj/.claude-handoff/$sid16/current.md"
r16=$(count_reasons "$work/proj/.claude-handoff/$sid16/current.md" "$nonce16")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid16" "$t16")")
printf 'C16 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t16")" "$r16"

# C17: 見出しの大文字小文字違い（## goal / ## KEY DECISIONS）と空白抜き（##Goal）は
# すべて拒否される（codexレビュー4回目 H1: PSの-matchの大小無視と\s*の空白ゼロ許容で
# ps/shの合否が分裂していた。理由は「見出しが無い」×7 = 7件になるはず）
sid17="55555555-6666-7777-8888-999999999999"
t17="$work/t17.jsonl"
usage_transcript "$t17" 450
invoke_hook handoff-check.sh "$(stop_input "$sid17" "$t17")" > /dev/null
nonce17=$(jq -r '.nonce' "$t17.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid17"
sed "s/{{NONCE}}/$nonce17/" "$fixtures/md/bad-handoff-casespace.md.tmpl" > "$work/proj/.claude-handoff/$sid17/current.md"
r17=$(count_reasons "$work/proj/.claude-handoff/$sid17/current.md" "$nonce17")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid17" "$t17")")
printf 'C17 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t17")" "$r17"

# C18: 最大サイズ（10MB）超過のcurrent.mdは内容を読まずに拒否される（codexレビュー4回目 M2:
# 巨大ファイルによるフックDoS対策。理由は「全体が最大サイズ（10MB）超過」の1件のみ）
sid18="66666666-7777-8888-9999-aaaaaaaaaaaa"
t18="$work/t18.jsonl"
usage_transcript "$t18" 450
invoke_hook handoff-check.sh "$(stop_input "$sid18" "$t18")" > /dev/null
nonce18=$(jq -r '.nonce' "$t18.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid18"
awk 'BEGIN { s = sprintf("%0100d", 0); gsub(/0/, "x", s); for (i = 0; i < 115344; i++) print s }' \
    > "$work/proj/.claude-handoff/$sid18/current.md"
r18=$(count_reasons "$work/proj/.claude-handoff/$sid18/current.md" "$nonce18")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid18" "$t18")")
printf 'C18 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t18")" "$r18"

# C19: 10MB未満でも行数（改行10万超）が多すぎるcurrent.mdは拒否される（codexレビュー5回目 M1:
# 改行密集ファイルによる走査コスト膨張の遮断。理由は「全体が最大行数（100000行）超過」の1件のみ）
sid19="77777777-8888-9999-aaaa-bbbbbbbbbbbb"
t19="$work/t19.jsonl"
usage_transcript "$t19" 450
invoke_hook handoff-check.sh "$(stop_input "$sid19" "$t19")" > /dev/null
nonce19=$(jq -r '.nonce' "$t19.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid19"
awk 'BEGIN { for (i = 0; i < 200001; i++) print "" }' > "$work/proj/.claude-handoff/$sid19/current.md"
r19=$(count_reasons "$work/proj/.claude-handoff/$sid19/current.md" "$nonce19")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid19" "$t19")")
printf 'C19 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t19")" "$r19"

# C20: 完了マーカーのnonceに\rを埋め込んだ資料は両実装とも拒否される（codexレビュー5回目 L3:
# sh版の tr -d '\r' が行中のCRまで削除して受理し、PS版と合否が分裂していた）
sid20="88888888-9999-aaaa-bbbb-cccccccccccc"
t20="$work/t20.jsonl"
usage_transcript "$t20" 450
invoke_hook handoff-check.sh "$(stop_input "$sid20" "$t20")" > /dev/null
nonce20=$(jq -r '.nonce' "$t20.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid20"
# nonceの5文字目に\rを埋め込む（index/substrで置換し、sedの\r移植性問題を回避）
bad20=$(printf '%s' "$nonce20" | awk '{ printf "%s\r%s", substr($0, 1, 4), substr($0, 5) }')
sed "s/{{NONCE}}/$nonce20/" "$fixtures/md/good-handoff.md.tmpl" \
    | awk -v old="$nonce20" -v bad="$bad20" \
        '{ i = index($0, old); if (i > 0) { $0 = substr($0, 1, i - 1) bad substr($0, i + length(old)) } print }' \
    > "$work/proj/.claude-handoff/$sid20/current.md"
r20=$(count_reasons "$work/proj/.claude-handoff/$sid20/current.md" "$nonce20")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid20" "$t20")")
printf 'C20 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t20")" "$r20"

# C21: 完了マーカー行の行末を\r\r（+改行）にした資料は両実装とも拒否される（codexレビュー
# 6回目 L1: PS版が`r?`n分割+末尾\r除去でCRを2個消し、1個しか消さないawkと合否が分裂していた。
# 契約は「行末の\r除去は1回だけ」。理由はマーカー不一致の1件のみ）
sid21="99999999-aaaa-bbbb-cccc-dddddddddddd"
t21="$work/t21.jsonl"
usage_transcript "$t21" 450
invoke_hook handoff-check.sh "$(stop_input "$sid21" "$t21")" > /dev/null
nonce21=$(jq -r '.nonce' "$t21.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid21"
sed "s/{{NONCE}}/$nonce21/" "$fixtures/md/good-handoff.md.tmpl" \
    | awk -v BINMODE=3 '{ if (index($0, "handoff-complete") > 0) printf "%s\r\r\n", $0; else print }' \
    > "$work/proj/.claude-handoff/$sid21/current.md"
r21=$(count_reasons "$work/proj/.claude-handoff/$sid21/current.md" "$nonce21")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid21" "$t21")")
printf 'C21 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t21")" "$r21"

# KEEP_WORK=1 で作業ディレクトリを残す（失敗ケースの成果物調査用。issue #16）
if [ -z "${KEEP_WORK:-}" ]; then
    rm -rf "$work"
else
    printf 'KEEP_WORK: 作業ディレクトリを残しました: %s\n' "$work" >&2
fi

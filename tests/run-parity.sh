#!/bin/sh
# run-parity.sh - sh版フックに共有フィクスチャのケースを流し、正規化した結果行を出力する
# run-parity.ps1 と同一ケース・同一出力形式。run-local-check.ps1 / .sh が両者の出力を
# 期待値と照合して2系統一致を検証する（ローカル実行）
# 使い方: sh run-parity.sh [作業ディレクトリ] [part]
#   part は all（既定・全ケース）/ 1（C1〜C50）/ 2（C51〜C75）/ 3（C76〜C92）。
#   パートは独立した作業ディレクトリで並列に実行し、出力を1〜3の順に連結すると
#   all と同じ92行になる（run-local-check.sh がそれを行い期待値と照合する）
set -u

tests_dir=$(cd "$(dirname "$0")" && pwd)
hooks_dir="$tests_dir/../hooks/sh"
fixtures="$tests_dir/fixtures"
# パート分割（シャーディング）。境界は「ケース間の依存が跨がないこと」と
# 「フック起動回数が揃うこと」（実測 55/56/53）で決めている:
#   C1〜C13 は既定transcriptを共有する連鎖 / C35以降は C34 が作るポインタ
#   （validptr.json）が土台で、C34 は全パート共通の前段として無条件に走る /
#   C67 の gatelog は C66 の診断を含めて数えるので両者は同じパートに置く /
#   C46-C47・C59-C60・C85〜C88 は変数を持ち越すので割らない
#   （`# C<番号>` で分割したセグメント間の持ち越しを機械抽出して確認した。
#   C74-C75 は以前から割らない扱いだが、今回の抽出では持ち越しを検出していない）
part="${2:-all}"
case "$part" in
    all|1|2|3) ;;
    *) printf 'NG: 第2引数（part）は all / 1 / 2 / 3 のいずれか: %s\n' "$part" >&2; exit 1 ;;
esac
work="${1:-}"
if [ -z "$work" ]; then
    # macOSのTMPDIRは末尾スラッシュ付き（…/T/）で、そのままmktempに渡すと作業パスに
    # 「//」が入り、包含ゲートの連続区切り拒否が全ケースを正当に拒否してしまう（実測）。
    # パス全体の圧縮（tr -s等）は先頭「//」（UNC）の意味を変えるため行わず、
    # TMPDIRの末尾スラッシュだけをmktemp前に除去する
    tmpbase="${TMPDIR:-/tmp}"
    while [ "${tmpbase%/}" != "$tmpbase" ]; do tmpbase="${tmpbase%/}"; done
    work=$(mktemp -d "$tmpbase/handoff-parity-sh-XXXXXX") || exit 1
else
    # 誤指定された既存ディレクトリを巻き添え削除しないため、新規作成のみ許可
    if [ -e "$work" ]; then
        printf 'NG: 作業ディレクトリには存在しないパスを指定すること: %s\n' "$work" >&2
        exit 1
    fi
fi
# Git Bash(MSYS): ネイティブjqの引数として渡す「/」始まりパスはMSYSがWindows形式へ
# 自動変換する一方、環境変数CLAUDE_CONFIG_DIRは変換されないため、包含判定でrootと
# transcriptの形式（/tmp/… と C:/…）が分裂する。最初からWindows形式へ揃えて統一する（issue #33）
if command -v cygpath >/dev/null 2>&1; then
    work=$(cygpath -m "$work")
fi
mkdir -p "$work/proj/.claude"
printf '%s' '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":80,"autocompact_window":100000}' > "$work/proj/.claude/handoff-config.json"
export CLAUDE_PROJECT_DIR="$work/proj"
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW 2>/dev/null || true
unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 2>/dev/null || true
# 包含ゲート（issue #33）: state操作はprojects_root配下のtranscriptのみ有効なため、
# CLAUDE_CONFIG_DIRを作業域内のfake設定ディレクトリへ向け、transcriptはその
# projects/proj/ 配下に置く（実運用の <config>/projects/<munged-project>/ と同じ形）
export CLAUDE_CONFIG_DIR="$work/claude-config"
troot="$work/claude-config/projects/proj"
mkdir -p "$troot"

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

# hardサイクル開始直後の状態ファイルを直接書く。「nonceを得るためだけ」のフック起動を
# 省くためで、内容は handoff-check.sh の hard発火が書く形と同じ。
# 「450トークンでhard発火して状態を作る」こと自体は C4/C5 が確かめている
seed_hard_state() { # $1=transcript $2=nonce
    jq -n --arg n "$2" \
        '{schema_version: 1, mode: "hard", nonce: $n, attempts: 1, completed: false, failed: false}' \
        > "$1.handoff-state.json"
}

sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
t="$troot/t.jsonl"

# フックの共通ヘルパー。C15/C16 は検証関数を直接呼ぶ。**パート分割で片方のパートに
# 閉じ込めない**ため、ケースの外側で読む。読む位置は上の自前関数より後
# （同名があれば従来どおりヘルパー側が勝つ順序を変えない）
. "$hooks_dir/handoff-common.sh"

if [ "$part" = all ] || [ "$part" = 1 ]; then
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
t7="$troot/t7.jsonl"
usage_transcript "$t7" 450
seed_hard_state "$t7" "nonce-t7-00000000"
nonce7=$(jq -r '.nonce' "$t7.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid7"
sed "s/{{NONCE}}/$nonce7/" "$fixtures/md/bad-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid7/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid7" "$t7")")
printf 'C7 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t7")"

# C8: restore(clear) — 有効ポインタで注入+consumed
new_sid="99999999-8888-7777-6666-555555555555"
restore_in=$(jq -n --arg sid "$new_sid" --arg tp "$troot/new.jsonl" --arg cwd "$work/proj" \
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
# （C8の消費はdual-writeでconsumed=trueも書く — issue #34。未消費へ戻して先のゲートを検証する）
jq 'del(.consumed_at) | .consumed = false' "$latest" > "$latest.new" && mv -f "$latest.new" "$latest"
printf 'TAMPERED\n' >> "$md_dir/current.md"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C10 output=%s\n' "$(out_kind "$o")"

# C11: 期限切れポインタ（updated_epochが7日超過去）を拒否する（issue #1/#34。
# 鮮度判定の正はupdated_epoch — 8日前の固定オフセットで実装によらず同じ入力にする）
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
jq --argjson now "$(date +%s)" \
    'del(.consumed_at) | .consumed = false | .updated_epoch = ($now - 691200)' "$latest" > "$latest.new" \
    && mv -f "$latest.new" "$latest"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C11 output=%s\n' "$(out_kind "$o")"

# C12: updated_epoch が無いポインタは拒否（旧producer形式=updated_atのみ。
# 削るだけで期限を迂回できないこと+移行fail-closedの検証 — issue #34）
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
jq 'del(.consumed_at) | .consumed = false | del(.updated_epoch)' "$latest" > "$latest.new" && mv -f "$latest.new" "$latest"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C12 output=%s\n' "$(out_kind "$o")"

# C13: 数値でないupdated_epoch（文字列）のポインタは拒否（両実装で同じ判定になること）
sed "s/{{NONCE}}/$nonce/" "$fixtures/md/good-handoff.md.tmpl" > "$md_dir/current.md"
jq 'del(.consumed_at) | .consumed = false | .updated_epoch = "not-an-epoch"' "$latest" > "$latest.new" \
    && mv -f "$latest.new" "$latest"
o=$(invoke_hook handoff-restore.sh "$restore_in")
printf 'C13 output=%s\n' "$(out_kind "$o")"

# C14: 必須見出し直後の###小見出しを含む正常な資料が検証を通る（issue #4:
# 以前は###を本文終端と誤認して「本文が空」となり、検証が恒久的に失敗していた）
sid14="22222222-3333-4444-5555-666666666666"
t14="$troot/t14.jsonl"
usage_transcript "$t14" 450
seed_hard_state "$t14" "nonce-t14-00000000"
nonce14=$(jq -r '.nonce' "$t14.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid14"
sed "s/{{NONCE}}/$nonce14/" "$fixtures/md/good-handoff-subheadings.md.tmpl" > "$work/proj/.claude-handoff/$sid14/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid14" "$t14")")
printf 'C14 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t14")"

# C15/C16 は理由数のps/sh一致も見るため、検証関数を直接呼ぶ（codexレビュー3回目 High-1。
# ヘルパーの読み込みは前段で済ませてある）
count_reasons() { # $1=file $2=nonce
    _cr=$(ho_incomplete_reasons "$1" "$2")
    if [ -z "$_cr" ]; then printf '0'; else printf '%s' "$_cr" | awk -F' / ' '{print NF}'; fi
}

# C15: 必須見出しをすべて###へ退避した資料は拒否される（h1/h2のみが必須見出しとして有効。
# サイズ・マーカーは正しいため、理由は「見出しが無い」×7 = 7件になるはず）
sid15="33333333-4444-5555-6666-777777777777"
t15="$troot/t15.jsonl"
usage_transcript "$t15" 450
seed_hard_state "$t15" "nonce-t15-00000000"
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
t16="$troot/t16.jsonl"
usage_transcript "$t16" 450
seed_hard_state "$t16" "nonce-t16-00000000"
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
t17="$troot/t17.jsonl"
usage_transcript "$t17" 450
seed_hard_state "$t17" "nonce-t17-00000000"
nonce17=$(jq -r '.nonce' "$t17.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid17"
sed "s/{{NONCE}}/$nonce17/" "$fixtures/md/bad-handoff-casespace.md.tmpl" > "$work/proj/.claude-handoff/$sid17/current.md"
r17=$(count_reasons "$work/proj/.claude-handoff/$sid17/current.md" "$nonce17")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid17" "$t17")")
printf 'C17 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t17")" "$r17"

# C18: 最大サイズ（10MB）超過のcurrent.mdは内容を読まずに拒否される（codexレビュー4回目 M2:
# 巨大ファイルによるフックDoS対策。理由は「全体が最大サイズ（10MB）超過」の1件のみ）
sid18="66666666-7777-8888-9999-aaaaaaaaaaaa"
t18="$troot/t18.jsonl"
usage_transcript "$t18" 450
seed_hard_state "$t18" "nonce-t18-00000000"
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
t19="$troot/t19.jsonl"
usage_transcript "$t19" 450
seed_hard_state "$t19" "nonce-t19-00000000"
nonce19=$(jq -r '.nonce' "$t19.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid19"
awk 'BEGIN { for (i = 0; i < 200001; i++) print "" }' > "$work/proj/.claude-handoff/$sid19/current.md"
r19=$(count_reasons "$work/proj/.claude-handoff/$sid19/current.md" "$nonce19")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid19" "$t19")")
printf 'C19 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t19")" "$r19"

# C20: 完了マーカーのnonceに\rを埋め込んだ資料は両実装とも拒否される（codexレビュー5回目 L3:
# sh版の tr -d '\r' が行中のCRまで削除して受理し、PS版と合否が分裂していた）
sid20="88888888-9999-aaaa-bbbb-cccccccccccc"
t20="$troot/t20.jsonl"
usage_transcript "$t20" 450
seed_hard_state "$t20" "nonce-t20-00000000"
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
t21="$troot/t21.jsonl"
usage_transcript "$t21" 450
seed_hard_state "$t21" "nonce-t21-00000000"
nonce21=$(jq -r '.nonce' "$t21.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid21"
sed "s/{{NONCE}}/$nonce21/" "$fixtures/md/good-handoff.md.tmpl" \
    | awk -v BINMODE=3 '{ if (index($0, "handoff-complete") > 0) printf "%s\r\r\n", $0; else print }' \
    > "$work/proj/.claude-handoff/$sid21/current.md"
r21=$(count_reasons "$work/proj/.claude-handoff/$sid21/current.md" "$nonce21")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid21" "$t21")")
printf 'C21 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t21")" "$r21"

# C22: マーカー行の先頭にU+00A0を前置した資料は両実装とも拒否される（契約: U+00A0は
# 空白として扱わない・マーカー照合はバイト列厳密。macOSのBWK awkはUTF-8ロケールで
# 文字列比較にstrcoll()を使いU+00A0を照合上無視して等価判定していた — LC_ALL=C固定の
# 回帰検出。CI実測）
sid22="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
t22="$troot/t22.jsonl"
usage_transcript "$t22" 450
seed_hard_state "$t22" "nonce-t22-00000000"
nonce22=$(jq -r '.nonce' "$t22.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid22"
nbsp22=$(printf '\302\240')
sed "s/{{NONCE}}/$nonce22/" "$fixtures/md/good-handoff.md.tmpl" \
    | awk -v BINMODE=3 -v nbsp="$nbsp22" '{ if (index($0, "handoff-complete") > 0) print nbsp $0; else print }' \
    > "$work/proj/.claude-handoff/$sid22/current.md"
r22=$(count_reasons "$work/proj/.claude-handoff/$sid22/current.md" "$nonce22")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid22" "$t22")")
printf 'C22 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t22")" "$r22"

# C23: 正常マーカーの後にU+00A0だけの行を追加した資料は両実装とも拒否される
# （契約: U+00A0だけの行は「非空行」— strcollでは空文字列と等価になり「最後の非空行」の
# 判定が分裂していた。C22とは独立の穴のため別ケースで検出する）
sid23="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
t23="$troot/t23.jsonl"
usage_transcript "$t23" 450
seed_hard_state "$t23" "nonce-t23-00000000"
nonce23=$(jq -r '.nonce' "$t23.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid23"
{
    sed "s/{{NONCE}}/$nonce23/" "$fixtures/md/good-handoff.md.tmpl"
    printf '%s\n' "$(printf '\302\240')"
} > "$work/proj/.claude-handoff/$sid23/current.md"
r23=$(count_reasons "$work/proj/.claude-handoff/$sid23/current.md" "$nonce23")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid23" "$t23")")
printf 'C23 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t23")" "$r23"

# C24: マーカー行の先頭にU+00AD（soft hyphen）を前置した資料は両実装とも拒否される
# （PSの-ceq/-cneはカルチャ比較でU+00AD等の照合上無視可能な文字を無視するため、
# StringComparison.Ordinalへ変更した回帰の検出。U+00A0はカルチャ比較で区別されるため
# C22ではこの穴を検出できない）
sid24="cccccccc-dddd-eeee-ffff-000000000000"
t24="$troot/t24.jsonl"
usage_transcript "$t24" 450
seed_hard_state "$t24" "nonce-t24-00000000"
nonce24=$(jq -r '.nonce' "$t24.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid24"
shy24=$(printf '\302\255')
sed "s/{{NONCE}}/$nonce24/" "$fixtures/md/good-handoff.md.tmpl" \
    | awk -v BINMODE=3 -v shy="$shy24" '{ if (index($0, "handoff-complete") > 0) print shy $0; else print }' \
    > "$work/proj/.claude-handoff/$sid24/current.md"
r24=$(count_reasons "$work/proj/.claude-handoff/$sid24/current.md" "$nonce24")
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid24" "$t24")")
printf 'C24 output=%s state=%s reasons=%s\n' "$(out_kind "$o")" "$(get_state "$t24")" "$r24"

# C25: transcriptのtypeにU+00ADを挿入した行（type="assis(U+00AD)tant"・9000トークン）は
# usage合算から除外され無発火（PSのOrdinal化回帰の検出。jqの==は元から厳密）
sid25="dddddddd-eeee-ffff-0000-111111111111"
t25="$troot/t25.jsonl"
shy25=$(printf '\302\255')
{
    printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}'
    printf '{"type":"assis%stant","isSidechain":false,"message":{"usage":{"input_tokens":9000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}\n' "$shy25"
} > "$t25"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid25" "$t25")")
printf 'C25 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t25")"

# C26: 状態ファイルのmodeにU+00ADを挿入した値（"ha(U+00AD)rd"）はスキーマ不正として破棄され、
# 新規hardサイクル（attempts=1）から開始する（PSのOrdinal化回帰の検出）
sid26="eeeeeeee-ffff-0000-1111-222222222222"
t26="$troot/t26.jsonl"
usage_transcript "$t26" 450
printf '{"mode":"ha%srd","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}\n' "$shy25" > "$t26.handoff-state.json"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid26" "$t26")")
printf 'C26 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t26")"

# C27: ポインタのsha256にU+00ADを挿入した値はSHA照合で拒否される（PSのOrdinal化回帰の検出）
sid27="ffffffff-0000-1111-2222-333333333333"
t27="$troot/t27.jsonl"
usage_transcript "$t27" 450
seed_hard_state "$t27" "nonce-t27-00000000"
nonce27=$(jq -r '.nonce' "$t27.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid27"
sed "s/{{NONCE}}/$nonce27/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid27/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid27" "$t27")" > /dev/null
jq --arg shy "$shy25" '.sha256 = (.sha256[:4] + $shy + .sha256[4:])' "$work/proj/.claude-handoff/latest.json" > "$work/latest27.tmp"
mv -f "$work/latest27.tmp" "$work/proj/.claude-handoff/latest.json"
restore27=$(jq -n --arg sid "00000000-1111-2222-3333-444444444444" --arg tp "$troot/new27.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore27")
printf 'C27 output=%s\n' "$(out_kind "$o")"

# C28: typeが1要素配列["assistant"]の行はusage合算から除外され無発火
# （PSの[string]キャスト縮退とjqの配列拒否の分裂 — -is [string] ガードの回帰検出）
sid28="22222222-0000-1111-3333-444444444444"
t28="$troot/t28.jsonl"
{
    printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}'
    printf '%s\n' '{"type":["assistant"],"isSidechain":false,"message":{"usage":{"input_tokens":9000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}'
} > "$t28"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid28" "$t28")")
printf 'C28 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t28")"

# C29: 状態ファイルのmodeが1要素配列["hard"]ならスキーマ不正として破棄され、
# 新規hardサイクル（attempts=1）から開始する（-is [string] ガードの回帰検出）
sid29="33333333-0000-1111-2222-444444444444"
t29="$troot/t29.jsonl"
usage_transcript "$t29" 450
printf '%s\n' '{"mode":["hard"],"nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t29.handoff-state.json"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid29" "$t29")")
printf 'C29 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t29")"

# C30: sourceにU+00ADを挿入した "cle(U+00AD)ar" はclearとして扱われない（PSのOrdinal化回帰の
# 検出。注入自体はゲート通過で行われるため、consumed_atの有無で判別する）
sha30=$(ho_sha256 "$work/proj/.claude-handoff/$sid27/current.md")
jq --arg sha "$sha30" '.sha256 = $sha | del(.consumed_at)' "$work/proj/.claude-handoff/latest.json" > "$work/latest30.tmp"
mv -f "$work/latest30.tmp" "$work/proj/.claude-handoff/latest.json"
restore30=$(jq -n --arg sid "11111111-0000-2222-3333-444444444444" --arg tp "$troot/new30.jsonl" --arg cwd "$work/proj" --arg src "cle$(printf '\302\255')ar" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: $src}')
o=$(invoke_hook handoff-restore.sh "$restore30")
consumed30=no
[ -n "$(jq -r '.consumed_at // empty' "$work/proj/.claude-handoff/latest.json" 2>/dev/null)" ] && consumed30=yes
printf 'C30 output=%s consumed=%s\n' "$(out_kind "$o")" "$consumed30"

# C31: 非clearソース時は他セッションを指すポインタより自セッションの資料が優先される
# （自セッションsid31の資料はGoalを「機能B」に変えてあり、どちらが注入されたか判別できる）
sid31="44444444-0000-1111-2222-555555555555"
t31="$troot/t31.jsonl"
cp "$work/proj/.claude-handoff/latest.json" "$work/pointer27.json"
usage_transcript "$t31" 450
seed_hard_state "$t31" "nonce-t31-00000000"
nonce31=$(jq -r '.nonce' "$t31.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid31"
sed -e "s/{{NONCE}}/$nonce31/" -e "s/機能Aの実装/機能Bの実装/" "$fixtures/md/good-handoff.md.tmpl" \
    > "$work/proj/.claude-handoff/$sid31/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid31" "$t31")" > /dev/null
cp "$work/pointer27.json" "$work/proj/.claude-handoff/latest.json"
restore31=$(jq -n --arg sid "$sid31" --arg tp "$t31" --arg cwd "$work/proj" --arg src "cle$(printf '\302\255')ar" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: $src}')
o=$(invoke_hook handoff-restore.sh "$restore31")
goalb31=no
case "$o" in *"機能Bの実装"*) goalb31=yes ;; esac
printf 'C31 output=%s goalB=%s\n' "$(out_kind "$o")" "$goalb31"

# C32: ポインタのsha256が1要素配列["正しいhash"]なら注入拒否（PSの型固定の回帰検出。
# jqは配列をJSON文字列化して不一致になる）
jq '.sha256 = [.sha256] | del(.consumed_at)' "$work/proj/.claude-handoff/latest.json" > "$work/latest32.tmp"
mv -f "$work/latest32.tmp" "$work/proj/.claude-handoff/latest.json"
restore32=$(jq -n --arg sid "55555555-0000-1111-2222-666666666666" --arg tp "$troot/new32.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore32")
printf 'C32 output=%s\n' "$(out_kind "$o")"

# C33: ポインタのsession_idが1要素配列["正しいUUID"]ならポインタ無効（注入対象なしで無出力）
jq '.session_id = [.session_id]' "$work/proj/.claude-handoff/latest.json" > "$work/latest33.tmp"
mv -f "$work/latest33.tmp" "$work/proj/.claude-handoff/latest.json"
restore33=$(jq -n --arg sid "66666666-0000-1111-2222-777777777777" --arg tp "$troot/new33.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore33")
printf 'C33 output=%s\n' "$(out_kind "$o")"
fi

# C34: compact経路の直近ユーザーメッセージ抽出で、typeが配列["user"]の行と
# contentパーツのtypeが配列["text"]の要素は除外される（PSの-is [string]ガードの回帰検出）
sid34="77777777-0000-1111-2222-888888888888"
t34="$troot/t34.jsonl"
usage_transcript "$t34" 450
{
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":"MARKER-VALID-USER"}}'
    printf '%s\n' '{"type":["user"],"isSidechain":false,"message":{"content":"MARKER-ARRTYPE-USER"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":[{"type":["text"],"text":"MARKER-ARRTEXT-PART"},{"type":"text","text":"MARKER-VALID-PART"},{"type":"text","text":["MARKER-ARRVAL-PART"]}]}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":[{"content":"MARKER-ARRMSG-USER"}]}'
} >> "$t34"
seed_hard_state "$t34" "nonce-t34-00000000"
nonce34=$(jq -r '.nonce' "$t34.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid34"
sed "s/{{NONCE}}/$nonce34/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid34/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid34" "$t34")" > /dev/null
restore34=$(jq -n --arg sid "$sid34" --arg tp "$t34" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}')
o=$(invoke_hook handoff-restore.sh "$restore34")
u1=no; case "$o" in *"MARKER-VALID-USER"*) u1=yes ;; esac
u2=no; case "$o" in *"MARKER-ARRTYPE-USER"*) u2=yes ;; esac
u3=no; case "$o" in *"MARKER-ARRTEXT-PART"*) u3=yes ;; esac
u4=no; case "$o" in *"MARKER-VALID-PART"*) u4=yes ;; esac
u5=no; case "$o" in *"MARKER-ARRVAL-PART"*) u5=yes ;; esac
u6=no; case "$o" in *"MARKER-ARRMSG-USER"*) u6=yes ;; esac
if [ "$part" = all ] || [ "$part" = 1 ]; then
printf 'C34 output=%s u1=%s u2=%s u3=%s u4=%s u5=%s u6=%s\n' "$(out_kind "$o")" "$u1" "$u2" "$u3" "$u4" "$u5" "$u6"
fi

# C35〜C37: 有効なポインタ（sid34・未消費）をベースに、ポインタのフィールド型破壊を検証する
# このポインタはパート2・3の土台でもあるため、part の指定に関わらず作る
cp "$work/proj/.claude-handoff/latest.json" "$work/validptr.json"

if [ "$part" = all ] || [ "$part" = 1 ]; then
# C35: sha256がboolean false → 非文字列は不一致として拒否（旧shは `// empty` でスキップし注入していた）
jq '.sha256 = false' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore35=$(jq -n --arg sid "88888888-0000-1111-2222-999999999999" --arg tp "$troot/new35.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore35")
printf 'C35 output=%s\n' "$(out_kind "$o")"

# C36: consumed_atが配列[""] → ポインタ無効（旧PSは空文字列へ縮退し未消費扱いで注入していた）
jq '.consumed_at = [""]' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore36=$(jq -n --arg sid "99999999-0000-1111-2222-aaaaaaaaaaaa" --arg tp "$troot/new36.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore36")
printf 'C36 output=%s\n' "$(out_kind "$o")"

# C37: updated_epochが配列[有効なepoch] → ポインタ無効（型固定 — PSの縮退で数値扱いに
# ならないこと・jqのtype検査と同一受否の回帰検出。issue #34でupdated_at契約から置換）
jq '.updated_epoch = [.updated_epoch]' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore37=$(jq -n --arg sid "aaaaaaaa-0000-1111-2222-bbbbbbbbbbbb" --arg tp "$troot/new37.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore37")
printf 'C37 output=%s\n' "$(out_kind "$o")"
fi

if [ "$part" = all ] || [ "$part" = 1 ]; then
# C38: isSidechainが文字列"false"の行は除外しない（除外はboolean trueのみ）
sid38="bbbbbbbb-0000-1111-2222-cccccccccccc"
t38="$troot/t38.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":"false","message":{"usage":{"input_tokens":450,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}' > "$t38"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid38" "$t38")")
printf 'C38 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t38")"

# C39: messageが配列の行と、行全体が配列のJSON行はusage合算から除外
# （jqのselect(type=="object")・配列への.usageアクセスエラーと同一の出力契約）
sid39="cccccccc-0000-1111-2222-dddddddddddd"
t39="$troot/t39.jsonl"
{
    printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}'
    printf '%s\n' '{"type":"assistant","isSidechain":false,"message":[{"usage":{"input_tokens":9000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}]}'
    printf '%s\n' '[{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":9000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}]'
} > "$t39"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid39" "$t39")")
printf 'C39 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t39")"

# C40: stop_hook_activeが文字列"false"はループ停止と扱わない（壊れたstateとの組合せで検証）
sid40="dddddddd-0000-1111-2222-eeeeeeeeeeee"
t40="$troot/t40.jsonl"
usage_transcript "$t40" 450
printf '%s' "{broken" > "$t40.handoff-state.json"
stop40=$(jq -n --arg sid "$sid40" --arg tp "$t40" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: "false"}')
o=$(invoke_hook handoff-check.sh "$stop40")
printf 'C40 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t40")"

# C41: background_tasksが非配列（文字列）なら0件扱いでソフト提案を見送らない
sid41="eeeeeeee-0000-1111-2222-ffffffffffff"
t41="$troot/t41.jsonl"
usage_transcript "$t41" 250
stop41=$(jq -n --arg sid "$sid41" --arg tp "$t41" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false, background_tasks: "busy"}')
o=$(invoke_hook handoff-check.sh "$stop41")
printf 'C41 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t41")"

# C42: ルートが配列のポインタ（[{有効なポインタ}]）は無効（pwshの縮退回帰の検出）
jq '[.]' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore42=$(jq -n --arg sid "ffffffff-0000-1111-2222-000000000000" --arg tp "$troot/new42.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore42")
printf 'C42 output=%s\n' "$(out_kind "$o")"

# C43: ルートが配列の状態ファイルはスキーマ不正として破棄され、新規hardサイクルから開始
sid43="00000000-1111-2222-3333-555555555555"
t43="$troot/t43.jsonl"
usage_transcript "$t43" 450
printf '%s\n' '[{"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}]' > "$t43.handoff-state.json"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid43" "$t43")")
printf 'C43 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t43")"

# C44: ルートが配列のconfig（[{有効な設定}]）は不正として機能無効（jq type=="object" 契約。
# 旧PSはパイプライン縮退で有効扱いになっていた — 罠9）
cp -f "$work/proj/.claude/handoff-config.json" "$work/config44.bak"
jq '[.]' "$work/config44.bak" > "$work/proj/.claude/handoff-config.json"
sid44="abababab-0000-1111-2222-343434343434"
t44="$troot/t44.jsonl"
usage_transcript "$t44" 450
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid44" "$t44")")
printf 'C44 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t44")"
cp -f "$work/config44.bak" "$work/proj/.claude/handoff-config.json"

# C45: ルートが配列のhook入力（[{有効なStop入力}]）は不正入力として無視
sid45="cdcdcdcd-0000-1111-2222-565656565656"
t45="$troot/t45.jsonl"
usage_transcript "$t45" 450
stop45=$(stop_input "$sid45" "$t45" | jq '[.]')
o=$(invoke_hook handoff-check.sh "$stop45")
printf 'C45 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t45")"

# C46: triggerが配列のsave入力 → meta.jsonのtriggerは空文字列（ho_string_field契約。
# 旧PSは配列のままmeta.jsonへ保存し分裂していた）。
# 完了済みhandoff（sid46）も作り、C47のバックアップ導線検証の土台にする
sid46="efefefef-0000-1111-2222-787878787878"
t46="$troot/t46.jsonl"
usage_transcript "$t46" 450
seed_hard_state "$t46" "nonce-t46-00000000"
nonce46=$(jq -r '.nonce' "$t46.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid46"
sed "s/{{NONCE}}/$nonce46/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid46/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid46" "$t46")" > /dev/null
save46=$(jq -n --arg sid "$sid46" --arg tp "$t46" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact", trigger: ["compact"]}')
invoke_hook handoff-save.sh "$save46" > /dev/null
bdir46=$(ls -1 "$work/proj/.claude-handoff/$sid46/backup" 2>/dev/null | sort -r | head -n 1)
tg46=$(jq -r 'if ((.trigger | type) == "string") and ((.trigger | length) == 0) then "empty" else "set" end' \
    "$work/proj/.claude-handoff/$sid46/backup/$bdir46/meta.json" 2>/dev/null)
[ -n "$tg46" ] || tg46="unreadable"
printf 'C46 trigger=%s\n' "$tg46"

# C47: ルートが配列のmeta.json → バックアップ導線の保存情報は空欄のまま行を付与
# （両実装同一契約。旧PSはパイプライン縮退で配列内の値を表示し得た — 罠9）
meta47="$work/proj/.claude-handoff/$sid46/backup/$bdir46/meta.json"
jq '[.]' "$meta47" > "$work/meta47.tmp"
mv -f "$work/meta47.tmp" "$meta47"
restore47=$(jq -n --arg sid "01010101-2323-4545-6767-898989898989" --arg tp "$troot/new47.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore47")
mk47="leaked"
case "$o" in *"保存:  / transcript: "*) mk47="empty" ;; esac
printf 'C47 output=%s meta=%s\n' "$(out_kind "$o")" "$mk47"

# C48: ISO日時形式だけのユーザーメッセージ（scalar contentとtextパーツ）は原表記のまま
# 引用される（pwshの[datetime]自動変換の回帰検出 — 罠9の原表記維持契約）
sid48="23232323-4545-6767-8989-010101010101"
t48="$troot/t48.jsonl"
usage_transcript "$t48" 450
{
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":"2026-01-02T03:04:05Z"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":[{"type":"text","text":"2026-01-02T03:04:05+09:00"}]}}'
} >> "$t48"
seed_hard_state "$t48" "nonce-t48-00000000"
nonce48=$(jq -r '.nonce' "$t48.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid48"
sed "s/{{NONCE}}/$nonce48/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid48/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid48" "$t48")" > /dev/null
restore48=$(jq -n --arg sid "$sid48" --arg tp "$t48" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}')
o=$(invoke_hook handoff-restore.sh "$restore48")
d1=no; case "$o" in *"2026-01-02T03:04:05Z"*) d1=yes ;; esac
d2=no; case "$o" in *"2026-01-02T03:04:05+09:00"*) d2=yes ;; esac
printf 'C48 output=%s d1=%s d2=%s\n' "$(out_kind "$o")" "$d1" "$d2"

# C49: ルートがスカラーのhook入力（数値0）は不正入力として無視され、saveが
# unknownセッションのバックアップを作らない（object必須契約の回帰検出）
invoke_hook handoff-save.sh '0' > /dev/null
ud49="absent"
[ -d "$work/proj/.claude-handoff/unknown" ] && ud49="present"
printf 'C49 unknown-dir=%s\n' "$ud49"

# C50: ルートがスカラーのhook入力（文字列"clear"）でrestoreは何も注入せず、
# 有効な未消費ポインタも消費しない（旧PSはポインタ経由の注入・消費まで進んでいた）
cp -f "$work/validptr.json" "$work/proj/.claude-handoff/latest.json"
o=$(invoke_hook handoff-restore.sh '"clear"')
c50=$(jq -r 'if has("consumed_at") and (.consumed_at != null) and (.consumed_at != "") then "yes" else "no" end' "$work/proj/.claude-handoff/latest.json" 2>/dev/null)
[ -n "$c50" ] || c50="unreadable"
printf 'C50 output=%s consumed=%s\n' "$(out_kind "$o")" "$c50"

fi

if [ "$part" = all ] || [ "$part" = 2 ]; then
# C51: ポインタのupdated_epochが0 → 契約（0 < v）違反でポインタ無効・無出力
# （UNIXエポック原点は「時刻なし」の典型的な偽値 — issue #34でupdated_at契約から置換)
jq '.updated_epoch = 0' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore51=$(jq -n --arg sid "45454545-6767-8989-0101-232323232323" --arg tp "$troot/new51.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore51")
printf 'C51 output=%s\n' "$(out_kind "$o")"

# C52: ポインタのupdated_epochが数字文字列（有効なepochのtostring）→ 型違いでfail-closed・
# 無出力（PSの[long]キャスト縮退・shの文字列比較で数値扱いになる退行の検出。issue #34）
jq '.updated_epoch = (.updated_epoch | tostring)' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore52=$(jq -n --arg sid "67676767-8989-0101-2323-454545454545" --arg tp "$troot/new52.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore52")
printf 'C52 output=%s\n' "$(out_kind "$o")"

# C53: PS版の旧pwsh相当経路（System.Text.Jsonフォールバック）検証ケース。
# sh版では環境変数は無効（通常経路）で、全実装が同一出力になることを検証する
export HANDOFF_TEST_FORCE_JSON_FALLBACK=1
sid53="34343434-5656-7878-9090-121212121212"
t53="$troot/t53.jsonl"
usage_transcript "$t53" 450
{
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":"2026-01-02T03:04:05Z"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":[{"type":"text","text":"2026-01-02T03:04:05+09:00"}]}}'
} >> "$t53"
seed_hard_state "$t53" "nonce-t53-00000000"
nonce53=$(jq -r '.nonce' "$t53.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid53"
sed "s/{{NONCE}}/$nonce53/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid53/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid53" "$t53")" > /dev/null
restore53=$(jq -n --arg sid "$sid53" --arg tp "$t53" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}')
o=$(invoke_hook handoff-restore.sh "$restore53")
unset HANDOFF_TEST_FORCE_JSON_FALLBACK
f1=no; case "$o" in *"2026-01-02T03:04:05Z"*) f1=yes ;; esac
f2=no; case "$o" in *"2026-01-02T03:04:05+09:00"*) f2=yes ;; esac
printf 'C53 output=%s d1=%s d2=%s\n' "$(out_kind "$o")" "$f1" "$f2"

# C54: updated_epochが未来skew上限超（now+2日 > now+86400）→ fail-closed・無出力
# （時計改変・偽装ポインタによる無期限延命の遮断 — issue #34の未来skew契約）
jq --argjson now "$(date +%s)" '.updated_epoch = ($now + 172800)' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore54=$(jq -n --arg sid "78787878-9090-1212-3434-565656565656" --arg tp "$troot/new54.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore54")
printf 'C54 output=%s\n' "$(out_kind "$o")"

# C55: updated_epochが整数でない数値（有効値+0.5）→ fail-closed・無出力
# （jqのfloor同値・PSのTruncate同値という整数値契約の回帰検出 — issue #34）
jq '.updated_epoch = (.updated_epoch + 0.5)' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore55=$(jq -n --arg sid "90909090-1212-3434-5656-787878787878" --arg tp "$troot/new55.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore55")
printf 'C55 output=%s\n' "$(out_kind "$o")"

# C56: resetのtranscript_pathが配列["path"]なら状態を削除しない（型固定 — PS版の
# -is [string]ガードと同一契約。文字列なら削除する正経路もあわせて検証）
sid56="56565656-7878-9090-1212-343434343434"
t56="$troot/t56.jsonl"
usage_transcript "$t56" 250
invoke_hook handoff-check.sh "$(stop_input "$sid56" "$t56")" > /dev/null
reset_arr56=$(jq -n --arg sid "$sid56" --arg tp "$t56" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: [$tp], cwd: $cwd, hook_event_name: "SessionStart", source: "resume"}')
invoke_hook handoff-reset.sh "$reset_arr56" > /dev/null
after56arr=$(get_state "$t56")
reset_str56=$(jq -n --arg sid "$sid56" --arg tp "$t56" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "resume"}')
invoke_hook handoff-reset.sh "$reset_str56" > /dev/null
after56str=$(get_state "$t56")
printf 'C56 arr=%s str=%s\n' "$after56arr" "$after56str"

# C57: user行に完全なusage構造があっても採用しない（usage走査はtype=="assistant"限定 —
# HANDOFF.md「usage走査対象行のpredicate」。採用されると450でhard発火してしまう）
sid57="89898989-0101-2323-4545-676767676767"
t57="$troot/t57.jsonl"
usage_transcript "$t57" 250
printf '%s\n' '{"type":"user","isSidechain":false,"message":{"usage":{"input_tokens":450,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}' >> "$t57"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid57" "$t57")")
printf 'C57 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t57")"

# C58: isMeta=trueのassistant行のusageは採用する（isMetaはusage走査では不問 —
# isMeta除外は引用処理のみ。誤って除外するとusage=0で無発火になる）
sid58="90909090-2121-4343-6565-878787878787"
t58="$troot/t58.jsonl"
printf '%s\n' '{"type":"assistant","isSidechain":false,"isMeta":true,"message":{"usage":{"input_tokens":450,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}' > "$t58"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid58" "$t58")")
printf 'C58 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t58")"

# C59: SHA計算失敗（テストシームで強制）→ ポインタ非更新（既存の他セッションポインタは
# バイト不変）・stateはcompleted・systemMessage（資料パス入り）とerror.log記録は1回だけ
# （旧実装はsha256=nullのポインタを書き、restoreが照合スキップで注入していた — issue #31）
sid59="12121212-3434-5656-7878-909090909090"
t59="$troot/t59.jsonl"
usage_transcript "$t59" 450
seed_hard_state "$t59" "nonce-t59-00000000"
nonce59=$(jq -r '.nonce' "$t59.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid59"
sed "s/{{NONCE}}/$nonce59/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid59/current.md"
# 既存の「他セッションの有効なポインタ」をproducerサイクルで実生成して配置し
# （新鮮なupdated_at・実SHA・注入可能なcurrent.md付き）、上書き・削除・tombstone化
# されないことをバイト比較+C59後の実注入（postrestore）で固定する
sid59o="77777777-6666-5555-4444-333333333333"
t59o="$troot/t59o.jsonl"
usage_transcript "$t59o" 450
seed_hard_state "$t59o" "nonce-t59o-00000000"
nonce59o=$(jq -r '.nonce' "$t59o.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid59o"
sed "s/{{NONCE}}/$nonce59o/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid59o/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid59o" "$t59o")" > /dev/null
before59=$(od -An -tx1 "$work/proj/.claude-handoff/latest.json" | tr -d ' \n')
HANDOFF_TEST_FORCE_SHA_FAIL=1
export HANDOFF_TEST_FORCE_SHA_FAIL
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid59" "$t59")")
o2=$(invoke_hook handoff-check.sh "$(stop_input "$sid59" "$t59")")
unset HANDOFF_TEST_FORCE_SHA_FAIL
after59=$(od -An -tx1 "$work/proj/.claude-handoff/latest.json" | tr -d ' \n')
latest59="changed"
[ "$before59" = "$after59" ] && latest59="intact"
msg59="no"
case "$o" in
    *systemMessage*)
        case "$o" in
            *"$sid59"*) case "$o" in *current.md*) msg59="yes" ;; esac ;;
        esac ;;
esac
log59=$(grep -c "SHA-256計算に失敗" "$work/proj/.claude-handoff/error.log" 2>/dev/null)
[ -n "$log59" ] || log59=0
# 生き残った他セッションポインタが実際に注入可能なことを確認（consumedになるのはこの検証時点）
restore59=$(jq -n --arg sid "18181818-2929-3040-4151-626262626262" --arg tp "$troot/new59.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o3=$(invoke_hook handoff-restore.sh "$restore59")
printf 'C59 output=%s msg=%s latest=%s state=%s log=%s second=%s postrestore=%s\n' "$(out_kind "$o")" "$msg59" "$latest59" "$(get_state "$t59")" "$log59" "$(out_kind "$o2")" "$(out_kind "$o3")"

# C60: sha256の無いポインタ（欠落・null・空文字列の3態）はいずれも注入拒否+専用note
# （照合スキップ縮退の廃止 — fail-closed。C59でcompleted済みのhandoffに新鮮な有効ポインタを手書き）
md60="$work/proj/.claude-handoff/$sid59/current.md"
size60=$(wc -c < "$md60" | tr -d '[:space:]')
results60=""
v=0
for variant in missing null empty; do
    case "$variant" in
        missing) shaexpr="{}" ;;
        null)    shaexpr='{sha256: null}' ;;
        empty)   shaexpr='{sha256: ""}' ;;
    esac
    jq -n --arg sid "$sid59" --arg hp "$md60" \
          --arg n "$nonce59" --arg tp "$t59" --argjson ue "$(date +%s)" \
          --arg ua "$(date +%Y-%m-%dT%H:%M:%S%z)" --argjson sz "$size60" \
        "{schema_version: 1, session_id: \$sid, handoff_path: \$hp, nonce: \$n, transcript_path: \$tp, updated_epoch: \$ue, updated_at: \$ua, consumed: false, size: \$sz} + $shaexpr" \
        > "$work/proj/.claude-handoff/latest.json"
    case "$v" in
        0) rsid60="13131313-2424-3535-4646-575757575757" ;;
        1) rsid60="14141414-2525-3636-4747-585858585858" ;;
        2) rsid60="15151515-2626-3737-4848-595959595959" ;;
    esac
    restore60=$(jq -n --arg sid "$rsid60" --arg tp "$troot/new60-$v.jsonl" --arg cwd "$work/proj" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
    o=$(invoke_hook handoff-restore.sh "$restore60")
    note60="no"
    case "$o" in
        *"SHA-256照合不可（ポインタにsha256が無い）"*) note60="yes" ;;
    esac
    results60="$results60 $variant=$(out_kind "$o")/$note60"
    v=$((v + 1))
done
printf 'C60%s\n' "$results60"

# C61: SHA計算失敗+state書き込み失敗（両シーム強制）→ 通知なし・stateは未完了のまま・
# 専用エラーをerror.logへ記録（通知はcompleted遷移の成功後のみ、の契約を固定）
sid61="16161616-2727-3838-4949-606060606060"
t61="$troot/t61.jsonl"
usage_transcript "$t61" 450
seed_hard_state "$t61" "nonce-t61-00000000"
nonce61=$(jq -r '.nonce' "$t61.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid61"
sed "s/{{NONCE}}/$nonce61/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid61/current.md"
HANDOFF_TEST_FORCE_SHA_FAIL=1
HANDOFF_TEST_FORCE_WRITE_FAIL=1
export HANDOFF_TEST_FORCE_SHA_FAIL HANDOFF_TEST_FORCE_WRITE_FAIL
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid61" "$t61")")
unset HANDOFF_TEST_FORCE_SHA_FAIL HANDOFF_TEST_FORCE_WRITE_FAIL
log61=$(grep -c "state書き込みにも失敗" "$work/proj/.claude-handoff/error.log" 2>/dev/null)
[ -n "$log61" ] || log61=0
printf 'C61 output=%s state=%s log=%s\n' "$(out_kind "$o")" "$(get_state "$t61")" "$log61"

# C62: autocompact_windowの無いconfigは機能無効（issue #32: fire-point検証のfail-closed化。
# 旧実装はwindow未解決のまま有効になり「compactより前に発火」の保証が抜けていた）。
# 2回のStopで診断も2件になること（頻度契約: Stopごと記録+ログ上限）まで固定する
cfg62="$work/proj/.claude/handoff-config.json"
cp -f "$cfg62" "$cfg62.bak62"
printf '%s' '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":80}' > "$cfg62"
sid62="19191919-3030-4141-5252-636363636363"
t62="$troot/t62.jsonl"
usage_transcript "$t62" 450
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid62" "$t62")")
o2=$(invoke_hook handoff-check.sh "$(stop_input "$sid62" "$t62")")
log62=$(grep -c "autocompact_windowが無いか不正" "$work/proj/.claude-handoff/error.log" 2>/dev/null)
[ -n "$log62" ] || log62=0
mv -f "$cfg62.bak62" "$cfg62"
printf 'C62 output=%s second=%s state=%s log=%s\n' "$(out_kind "$o")" "$(out_kind "$o2")" "$(get_state "$t62")" "$log62"

# C63: 環境変数windowのゲート。config window=500（発火点400 <= 410でフォールバック時は無効化）
# を使い、env採用/拒否/誤解釈を結果の違いで一意判別する:
#  a) "+100000"（符号付き）→ 拒否→config 500→無効化（旧実装なら100000採用でhard発火）
#  b) "0000000600"（先頭ゼロ）→ 10進600採用→発火点480 > 410でhard発火
#     （八進解釈384や拒否なら無効化になるため一意判別）
#  c) "\n600"（改行前置）→ 拒否→無効化（grepの行単位一致なら600採用でhard発火）
cfg63="$work/proj/.claude/handoff-config.json"
cp -f "$cfg63" "$cfg63.bak63"
printf '%s' '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":80,"autocompact_window":500}' > "$cfg63"
sid63="20202020-3131-4242-5353-646464646464"
t63="$troot/t63.jsonl"
usage_transcript "$t63" 450
CLAUDE_CODE_AUTO_COMPACT_WINDOW="+100000"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW
oa=$(invoke_hook handoff-check.sh "$(stop_input "$sid63" "$t63")")
sid63b="21212121-3232-4343-5454-656565656565"
t63b="$troot/t63b.jsonl"
usage_transcript "$t63b" 450
CLAUDE_CODE_AUTO_COMPACT_WINDOW="0000000600"
export CLAUDE_CODE_AUTO_COMPACT_WINDOW
ob=$(invoke_hook handoff-check.sh "$(stop_input "$sid63b" "$t63b")")
sid63c="23232323-3434-4545-5656-676767676767"
t63c="$troot/t63c.jsonl"
usage_transcript "$t63c" 450
CLAUDE_CODE_AUTO_COMPACT_WINDOW=$(printf '\n600')
export CLAUDE_CODE_AUTO_COMPACT_WINDOW
oc=$(invoke_hook handoff-check.sh "$(stop_input "$sid63c" "$t63c")")
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
mv -f "$cfg63.bak63" "$cfg63"
printf 'C63 plussign=%s/%s leadzero=%s/%s lfprefix=%s/%s\n' "$(out_kind "$oa")" "$(get_state "$t63")" "$(out_kind "$ob")" "$(get_state "$t63b")" "$(out_kind "$oc")" "$(get_state "$t63c")"

# C64: 発火点はfloor（window=2053×pct=20 → 410.6 → floor 410 <= 410 で無効化・無出力。
# 旧PSの[long]キャストは最近接丸めで411になり有効化 — .5以上の端数でps/shの合否が分裂していた）
cfg64="$work/proj/.claude/handoff-config.json"
cp -f "$cfg64" "$cfg64.bak64"
printf '%s' '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":20,"autocompact_window":2053}' > "$cfg64"
sid64="22222222-3333-4444-5555-666666666666"
t64="$troot/t64.jsonl"
usage_transcript "$t64" 450
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid64" "$t64")")
mv -f "$cfg64.bak64" "$cfg64"
printf 'C64 output=%s state=%s\n' "$(out_kind "$o")" "$(get_state "$t64")"

# C65: 環境変数pctのゲート。config {pct:20, window:2100}（発火点420 > 410で既定はhard発火）を
# 使い、pct採用/拒否を結果の違いで一意判別する:
#  a) "+19" → 拒否→pct 20のまま→hard発火（採用なら発火点399で無効化）
#  b) "019" → 10進19採用→発火点399 <= 410で無効化（拒否ならhard発火）
#  c) "0"（範囲外）→ 拒否→hard発火（範囲検査が抜けると発火点0で無効化）
#  d) "19\n"（改行後置）→ 拒否→hard発火（行単位一致・末尾LF許容の退行を検出）
cfg65="$work/proj/.claude/handoff-config.json"
cp -f "$cfg65" "$cfg65.bak65"
printf '%s' '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":20,"autocompact_window":2100}' > "$cfg65"
results65=""
v=0
for pv in "+19" "019" "0" "traillf"; do
    case "$v" in
        0) sid65="24242424-3535-4646-5757-686868686868"; name65="sign" ;;
        1) sid65="25252525-3636-4747-5858-696969696969"; name65="leadzero" ;;
        2) sid65="26262626-3737-4848-5959-707070707070"; name65="zero" ;;
        3) sid65="27272727-3838-4949-6060-717171717171"; name65="traillf" ;;
    esac
    t65="$troot/t65-$v.jsonl"
    usage_transcript "$t65" 450
    if [ "$pv" = "traillf" ]; then
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="19
"
    else
        CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="$pv"
    fi
    export CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    o=$(invoke_hook handoff-check.sh "$(stop_input "$sid65" "$t65")")
    unset CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    results65="$results65 $name65=$(out_kind "$o")/$(get_state "$t65")"
    v=$((v + 1))
done
mv -f "$cfg65.bak65" "$cfg65"
printf 'C65%s\n' "$results65"

# C66: 包含ゲート — projects_root外のtranscriptを拒否する（issue #33）。
#  a) check: root外transcript（usage 450）→ 旧実装はhard発火+state作成、新実装は無発火・state非作成
#  b) reset: root外に置いた本物のstateファイルは削除されず生き残る（旧実装は任意パス+
#     固定サフィックスを削除できた — 挙動変更の回帰検出）
mkdir -p "$work/outside"
sid66="28282828-3939-5050-6161-727272727272"
t66="$work/outside/t66.jsonl"
usage_transcript "$t66" 450
o66=$(invoke_hook handoff-check.sh "$(stop_input "$sid66" "$t66")")
t66b="$work/outside/t66b.jsonl"
printf '%s' '{"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t66b.handoff-state.json"
reset_in66=$(jq -n --arg sid "$sid66" --arg tp "$t66b" --arg cwd "$work/proj"     '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "resume"}')
invoke_hook handoff-reset.sh "$reset_in66" > /dev/null
surv66="no"
[ -f "$t66b.handoff-state.json" ] && surv66="yes"
printf 'C66 outside=%s/%s reset-outside=%s
' "$(out_kind "$o66")" "$(get_state "$t66")" "$surv66"

# C67: 包含ゲート — 字句検査（".."セグメント・要素境界）の回帰検出（issue #33）。
#  a) check: "$troot/../proj/…" は実体がroot配下でも「..」を含むため字句で拒否（無発火・state非作成）
#  b) check: rootの文字列前置だけ一致する隣接ディレクトリ projectsX 配下は要素境界で拒否
#     （"root+/"前方一致でなく"root"前方一致に退行すると通ってしまう）
#  c) reset: 「..」入りパスで解決先がroot外のstateは削除されない
#  d) checkのゲートNG診断はStopごとに記録される（a/bとC66aの計3回）
sid67="29292929-4040-5151-6262-737373737373"
t67a="$troot/t67a.jsonl"
usage_transcript "$t67a" 450
o67a=$(invoke_hook handoff-check.sh "$(stop_input "$sid67" "$troot/../proj/t67a.jsonl")")
sid67b="30303030-4141-5252-6363-747474747474"
mkdir -p "$work/claude-config/projectsX"
t67b="$work/claude-config/projectsX/t67b.jsonl"
usage_transcript "$t67b" 450
o67b=$(invoke_hook handoff-check.sh "$(stop_input "$sid67b" "$t67b")")
mkdir -p "$work/outside2"
printf '%s' '{"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$work/outside2/t67c.jsonl.handoff-state.json"
reset_in67=$(jq -n --arg sid "$sid67" --arg tp "$troot/../../../outside2/t67c.jsonl" --arg cwd "$work/proj"     '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "resume"}')
invoke_hook handoff-reset.sh "$reset_in67" > /dev/null
surv67="no"
[ -f "$work/outside2/t67c.jsonl.handoff-state.json" ] && surv67="yes"
gate_log=$(grep -c "transcript_pathがprojects_root配下の正規パスでないため" "$work/proj/.claude-handoff/error.log" 2>/dev/null)
[ -n "$gate_log" ] || gate_log=0
printf 'C67 dotdot=%s/%s boundary=%s/%s reset-dotdot=%s gatelog=%s
' "$(out_kind "$o67a")" "$(get_state "$t67a")" "$(out_kind "$o67b")" "$(get_state "$t67b")" "$surv67" "$gate_log"
fi

if [ "$part" = all ] || [ "$part" = 2 ]; then
# C68: 包含ゲート — restore・save 4c・バイト長上限の回帰検出（issue #33 レビュー1回目 M2/L4）。
#  a) restore: root外の実在stateはrestore後も生き残る（旧実装は最終削除で消していた）
#  b) restore: root内の実在stateは従来どおり削除される（ゲートが正常系を壊していない）
#  c) save 4c: root外ディレクトリの古い孤児stateは掃除されない
#  d) save 4c: root内の古い孤児stateは従来どおり掃除される
#  e) check: 派生パスのUTF-8バイト長>240は拒否（多バイト文字は文字数<240でもバイト長で
#     超過 — 文字数判定への退行は短い作業パスのCI環境でhard発火として検出される）
mkdir -p "$work/outside3"
t68a="$work/outside3/t68a.jsonl"
printf '%s' '{"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t68a.handoff-state.json"
restore_in68a=$(jq -n --arg sid "32323232-4343-5454-6565-767676767676" --arg tp "$t68a" --arg cwd "$work/proj"     '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
invoke_hook handoff-restore.sh "$restore_in68a" > /dev/null
r_out68="no"
[ -f "$t68a.handoff-state.json" ] && r_out68="yes"
t68b="$troot/t68b.jsonl"
printf '%s' '{"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t68b.handoff-state.json"
restore_in68b=$(jq -n --arg sid "33333333-4444-5555-6666-777777777777" --arg tp "$t68b" --arg cwd "$work/proj"     '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
invoke_hook handoff-restore.sh "$restore_in68b" > /dev/null
r_in68="no"
[ -f "$t68b.handoff-state.json" ] && r_in68="yes"
sid68="31313131-4242-5353-6464-757575757575"
printf '%s' '{}' > "$work/outside3/orphan68o.jsonl.handoff-state.json"
touch -t 202501010000 "$work/outside3/orphan68o.jsonl.handoff-state.json"
t68c="$work/outside3/t68c.jsonl"
usage_transcript "$t68c" 100
save_in68o=$(jq -n --arg sid "$sid68" --arg tp "$t68c" --arg cwd "$work/proj"     '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact", trigger: "manual"}')
invoke_hook handoff-save.sh "$save_in68o" > /dev/null
s_out68="no"
[ -f "$work/outside3/orphan68o.jsonl.handoff-state.json" ] && s_out68="yes"
printf '%s' '{}' > "$troot/orphan68i.jsonl.handoff-state.json"
touch -t 202501010000 "$troot/orphan68i.jsonl.handoff-state.json"
t68d="$troot/t68d.jsonl"
usage_transcript "$t68d" 100
save_in68i=$(jq -n --arg sid "$sid68" --arg tp "$t68d" --arg cwd "$work/proj"     '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact", trigger: "manual"}')
invoke_hook handoff-save.sh "$save_in68i" > /dev/null
s_in68="no"
[ -f "$troot/orphan68i.jsonl.handoff-state.json" ] && s_in68="yes"
# LC_ALL=C必須: gawkはUTF-8ロケールで8進エスケープを「文字」と解釈し、\343等を
# U+00E3のUTF-8（2バイト）で出力して二重エンコードになる（codexレビュー#33-2 M1実測）
name68="$(LC_ALL=C awk 'BEGIN{for(i=0;i<70;i++)printf "\343\201\202"}').jsonl"
t68e="$troot/$name68"
usage_transcript "$t68e" 450
# テスト前提の自己検証: 派生パスが「文字数<=240 かつ UTF-8バイト数>240」の境界にあること
# （文字数はバイト数-継続バイト数で決定的に計数。前提が崩れたらbytecheck=ngで検出）
d68="$t68e.handoff-state.json"
b68=$(printf '%s' "$d68" | LC_ALL=C wc -c | tr -d ' 	')
cont68=$(printf '%s' "$d68" | LC_ALL=C tr -dc '\200-\277' | LC_ALL=C wc -c | tr -d ' 	')
bc68=ng
[ -f "$t68e" ] && [ $((b68 - cont68)) -le 240 ] && [ "$b68" -gt 240 ] && bc68=ok
o68e=$(invoke_hook handoff-check.sh "$(stop_input "34343434-4545-5656-6767-787878787878" "$t68e")")
# f) projects_root環境変数の末尾LFは拒否（$( )の末尾LF剥がしでsh側だけ受理する分裂の回帰）
t68f="$troot/t68f.jsonl"
usage_transcript "$t68f" 450
CLAUDE_CONFIG_DIR="$work/claude-config
"
export CLAUDE_CONFIG_DIR
o68f=$(invoke_hook handoff-check.sh "$(stop_input "35353535-4646-5757-6868-797979797979" "$t68f")")
CLAUDE_CONFIG_DIR="$work/claude-config"
export CLAUDE_CONFIG_DIR
# g) 連続区切り（"//"）は拒否: shのIFS分割は末尾空フィールドを落とし、FSは"//"を
#    畳み込むため、空要素検査だけではsh側だけ受理する分裂があった（レビュー3回目 L2）
t68g="$troot/t68g.jsonl"
usage_transcript "$t68g" 450
o68g=$(invoke_hook handoff-check.sh "$(stop_input "36363636-4747-5858-6969-808080808080" "$troot//t68g.jsonl")")
# h) root部分の連続区切り: CLAUDE_CONFIG_DIR自体に"//"があるとPS版は空要素検査が
#    root以降しか見ず受理していた（レビュー4回目 M1 — 派生パス全域の"//"拒否で統一）
t68h="$troot/t68h.jsonl"
usage_transcript "$t68h" 450
CLAUDE_CONFIG_DIR="$work//claude-config"
export CLAUDE_CONFIG_DIR
o68h=$(invoke_hook handoff-check.sh "$(stop_input "37373737-4848-5959-7070-818181818181" "$work//claude-config/projects/proj/t68h.jsonl")")
CLAUDE_CONFIG_DIR="$work/claude-config"
export CLAUDE_CONFIG_DIR
# i) transcript_path末尾LF: コマンド置換の末尾LF剥がしでゲート前に消えて受理していた
#    （レビュー4回目 L2 — jq内の制御文字検査ho_path_fieldで遮断）
t68i="$troot/t68i.jsonl"
usage_transcript "$t68i" 450
lf68=$(printf '\nX'); lf68="${lf68%X}"
o68i=$(invoke_hook handoff-check.sh "$(stop_input "38383838-4949-6060-7171-828282828282" "$t68i$lf68")")
printf 'C68 restore-outside=%s restore-inside=%s save-outside=%s save-inside=%s longbytes=%s/%s bytecheck=%s cfglf=%s/%s dupsep=%s/%s dupsep2=%s/%s tplf=%s/%s\n' \
    "$r_out68" "$r_in68" "$s_out68" "$s_in68" "$(out_kind "$o68e")" "$(get_state "$t68e")" "$bc68" "$(out_kind "$o68f")" "$(get_state "$t68f")" "$(out_kind "$o68g")" "$(get_state "$t68g")" "$(out_kind "$o68h")" "$(get_state "$t68h")" "$(out_kind "$o68i")" "$(get_state "$t68i")"

# C69: 消費のdual-read（issue #34 — 設計文書4.2の組合せ固定）: consumed=true・
# consumed_at欠落（新consumer間の消費、または部分更新されたポインタ）→ 消費済み扱い・無出力
jq 'del(.consumed_at) | .consumed = true' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore69=$(jq -n --arg sid "39393939-5050-6161-7272-838383838383" --arg tp "$troot/new69.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore69")
printf 'C69 output=%s\n' "$(out_kind "$o")"

# C70: 消費のdual-read: consumed=false・consumed_at非空（旧consumerが消費した新ポインタ）
# → 消費済み扱い・無出力（consumedだけ見る実装への退行を検出）
jq '.consumed = false | .consumed_at = "2026-01-01T00:00:00+00:00"' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore70=$(jq -n --arg sid "40404040-5151-6262-7373-848484848484" --arg tp "$troot/new70.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore70")
printf 'C70 output=%s\n' "$(out_kind "$o")"

# C71: 消費のdual-write（issue #34）: 未消費の有効ポインタをclearで注入すると、
# consumed=true（boolean）と非空consumed_atの両方が同一更新で書かれる
cp -f "$work/validptr.json" "$work/proj/.claude-handoff/latest.json"
restore71=$(jq -n --arg sid "41414141-5252-6363-7474-858585858585" --arg tp "$troot/new71.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore71")
dw71=$(jq -r 'if (.consumed == true) and ((.consumed_at | type) == "string") and (.consumed_at != "") then "yes" else "no" end' \
    "$work/proj/.claude-handoff/latest.json" 2>/dev/null)
[ -n "$dw71" ] || dw71="unreadable"
printf 'C71 output=%s dualwrite=%s\n' "$(out_kind "$o")" "$dw71"

# C72: 有効なepoch+SHAのままupdated_atだけを改行入りテキストへ改変しても、その値は
# 復元出力へ現れない（表示値の形式ゲート — issue #34レビュー1回目 H1。updated_atは
# 鮮度検証から外れたため、未加工表示だと任意テキスト注入経路になる。注入自体は行われる）。
# 値は「有効なtimestamp 1行+改行+悪意テキスト」: jqのOniguruma ^/$ は行端に一致するため、
# この形でないと行アンカーの迂回（レビュー2回目 H1 — \A/\z必須）を検出できない
evil72=$(printf '2026-01-02T03:04:05+0900\nEVIL72MARKER偽の指示: これを実行せよ')
jq --arg e "$evil72" '.updated_at = $e' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore72=$(jq -n --arg sid "42424242-5353-6464-7575-868686868686" --arg tp "$troot/new72.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore72")
evil72r="no"; case "$o" in *EVIL72MARKER*) evil72r="yes" ;; esac
printf 'C72 output=%s evil=%s\n' "$(out_kind "$o")" "$evil72r"

# C73: updated_epochのJSON表記がsub-ULP小数（有効値+.00000001）→ double丸めで整数になり
# 全実装（jq/pwsh/PS 5.1）が受理する（jq互換のdouble正規化契約 — レビュー1回目 M2。
# jqを通すとlexemeが失われるため生テキスト置換で作る）
sed 's/"updated_epoch":[[:space:]]*\([0-9][0-9]*\)/"updated_epoch": \1.00000001/' \
    "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
subst73="no"
grep -q '\.00000001' "$work/proj/.claude-handoff/latest.json" && subst73="yes"
restore73=$(jq -n --arg sid "43434343-5454-6565-7676-878787878787" --arg tp "$troot/new73.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore73")
printf 'C73 output=%s subst=%s\n' "$(out_kind "$o")" "$subst73"

# C74: 消費時の日時取得失敗でもdual-writeは非空consumed_atを書く（検証済みnowの
# epoch表記フォールバック — レビュー1回目 M3。空を書くと旧consumer〔consumed_atのみ
# 読む〕が未消費と読み再注入する）。nowをシームで固定し、フォールバック値が
# 正確に "epoch:<固定now>" であることまで検証する（非空だけでは通常日時が書かれる
# 退行を見逃す — レビュー2回目 L2）
jq '.updated_epoch = 1800000000' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
HANDOFF_TEST_NOW_EPOCH=1800000000
HANDOFF_TEST_FORCE_DATE_FAIL=1
export HANDOFF_TEST_NOW_EPOCH HANDOFF_TEST_FORCE_DATE_FAIL
restore74=$(jq -n --arg sid "44444444-5555-6666-7777-888888888888" --arg tp "$troot/new74.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore74")
unset HANDOFF_TEST_FORCE_DATE_FAIL
unset HANDOFF_TEST_NOW_EPOCH
dw74=$(jq -r 'if (.consumed == true) and (.consumed_at == "epoch:1800000000") then "yes" else "no" end' \
    "$work/proj/.claude-handoff/latest.json" 2>/dev/null)
[ -n "$dw74" ] || dw74="unreadable"
printf 'C74 output=%s dwfallback=%s\n' "$(out_kind "$o")" "$dw74"

# C75: epoch境界の決定的検証（HANDOFF_TEST_NOW_EPOCHでnowを固定 — レビュー1回目 L）:
# v=now / now+86400（未来skew上限ちょうど）/ now-7日（期限ちょうど）は受理、
# now+86400+1 / now-7日-1 は拒否
HANDOFF_TEST_NOW_EPOCH=1800000000
export HANDOFF_TEST_NOW_EPOCH
r75=""
i75=0
for spec75 in fresh:0 skewmax:86400 skewover:86401 agemax:-604800 ageover:-604801; do
    k75="${spec75%%:*}"
    off75="${spec75#*:}"
    case "$i75" in
        0) rsid75="45454545-0101-2323-4545-676767676767" ;;
        1) rsid75="46464646-0202-2424-4646-686868686868" ;;
        2) rsid75="47474747-0303-2525-4747-696969696969" ;;
        3) rsid75="48484848-0404-2626-4848-707070707070" ;;
        *) rsid75="49494949-0505-2727-4949-717171717171" ;;
    esac
    jq --argjson v "$((1800000000 + off75))" '.updated_epoch = $v' "$work/validptr.json" \
        > "$work/proj/.claude-handoff/latest.json"
    restore75=$(jq -n --arg sid "$rsid75" --arg tp "$troot/new75-$i75.jsonl" --arg cwd "$work/proj" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
    o=$(invoke_hook handoff-restore.sh "$restore75")
    r75="$r75 $k75=$(out_kind "$o")"
    i75=$((i75 + 1))
done
unset HANDOFF_TEST_NOW_EPOCH
printf 'C75%s\n' "$r75"

fi

if [ "$part" = all ] || [ "$part" = 3 ]; then
# C76: restoreのnow取得失敗はfail-closed（有効な未消費ポインタでも注入しない —
# レビュー1回目 Lの失敗経路固定）
cp -f "$work/validptr.json" "$work/proj/.claude-handoff/latest.json"
HANDOFF_TEST_FORCE_NOW_FAIL=1
export HANDOFF_TEST_FORCE_NOW_FAIL
restore76=$(jq -n --arg sid "50505050-0606-2828-5050-727272727272" --arg tp "$troot/new76.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o=$(invoke_hook handoff-restore.sh "$restore76")
unset HANDOFF_TEST_FORCE_NOW_FAIL
printf 'C76 output=%s\n' "$(out_kind "$o")"

# C77: producerのepoch取得失敗はSHA計算失敗と同じ縮退: ポインタ非更新（byte一致）・
# state completed遷移・専用メッセージで1回通知（レビュー1回目 Lの失敗経路固定）
sid77="52525252-0707-2929-5151-737373737373"
t77="$troot/t77.jsonl"
usage_transcript "$t77" 450
seed_hard_state "$t77" "nonce-t77-00000000"
nonce77=$(jq -r '.nonce' "$t77.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid77"
sed "s/{{NONCE}}/$nonce77/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid77/current.md"
before77=$(od -An -tx1 "$work/proj/.claude-handoff/latest.json" | tr -d ' \n')
HANDOFF_TEST_FORCE_NOW_FAIL=1
export HANDOFF_TEST_FORCE_NOW_FAIL
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid77" "$t77")")
unset HANDOFF_TEST_FORCE_NOW_FAIL
after77=$(od -An -tx1 "$work/proj/.claude-handoff/latest.json" | tr -d ' \n')
latest77="changed"
[ "$before77" = "$after77" ] && latest77="intact"
msg77="no"
case "$o" in
    *systemMessage*) case "$o" in *"現在時刻(epoch)取得に失敗"*) msg77="yes" ;; esac ;;
esac
printf 'C77 output=%s msg=%s latest=%s state=%s\n' "$(out_kind "$o")" "$msg77" "$latest77" "$(get_state "$t77")"

# C78: HANDOFF_TEST_NOW_EPOCHシームの採用契約（先頭ゼロなし・18桁以下・完全一致）が
# 両実装で一致する（レビュー2回目 L1 — PSの$は末尾LFを受理・shは先頭ゼロがjqの
# --argjsonで不正JSONになる分裂があった）。判別設計（レビュー3回目 L1）:
# 形式外3値（末尾LF/先頭ゼロ/19桁）は**実時刻で新鮮なポインタ**を使い、実時刻へ
# フォールバックすれば注入される（誤採用するとnow=過去/巨大値になり拒否→none、
# fail-closed化してもnone — いずれの退行もnoneで区別できる）。
# 有効値のみポインタepoch=1000000000（2001年）+同値シームで、採用時だけ v==now で
# 注入される（シーム無視なら実時刻でexpired→none。実時刻は常に前進するため恒久安定）
jq '.updated_epoch = 1000000000' "$work/validptr.json" > "$work/p78.json"
lf78=$(printf '\nX'); lf78="${lf78%X}"
i78=0
r78=""
for spec78 in lf zeros digits19 valid; do
    case "$spec78" in
        lf) v78="1000000000${lf78}" ;;
        zeros) v78="01000000000" ;;
        digits19) v78="1000000000000000000" ;;
        *) v78="1000000000" ;;
    esac
    case "$i78" in
        0) rsid78="53535353-0808-3030-5252-747474747474" ;;
        1) rsid78="54545454-0909-3131-5353-757575757575" ;;
        2) rsid78="55555555-1010-3232-5454-767676767676" ;;
        *) rsid78="56565656-1111-3333-5555-777777777777" ;;
    esac
    if [ "$spec78" = "valid" ]; then
        cp -f "$work/p78.json" "$work/proj/.claude-handoff/latest.json"
    else
        cp -f "$work/validptr.json" "$work/proj/.claude-handoff/latest.json"
    fi
    HANDOFF_TEST_NOW_EPOCH="$v78"
    export HANDOFF_TEST_NOW_EPOCH
    restore78=$(jq -n --arg sid "$rsid78" --arg tp "$troot/new78-$i78.jsonl" --arg cwd "$work/proj" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
    o=$(invoke_hook handoff-restore.sh "$restore78")
    unset HANDOFF_TEST_NOW_EPOCH
    r78="$r78 $spec78=$(out_kind "$o")"
    i78=$((i78 + 1))
done
printf 'C78%s\n' "$r78"

# C79: JSON境界のプロパティ参照はcase-sensitive（issue #37 — jq準拠）。PSの
# PSObject.Properties[名前]/ドット参照は大小非区別で、大小違いキーに一致してjqと
# 受否が分裂していた（Test-HoPropで遮断）。4点で固定:
# a) ポインタのconsumedを削り "Consumed": true だけ置く → 大小違いキーはjq準拠で
#    consumedとは別キー（旧PSは消費済み扱いで無出力になり分裂していた）。issue #38の
#    閉じたスキーマ導入後は「未知キー」としてポインタごと無効=無出力（両実装一致）
jq 'del(.consumed) | .Consumed = true' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore79a=$(jq -n --arg sid "57575757-1212-3434-5656-787878787879" --arg tp "$troot/new79a.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
# 無出力の理由が「未知キーでファイル無効」であることをログ差分で固定する（旧PSの
# 「Consumedをconsumedとして誤読→消費済みで無出力」も同じnoneになり判別できないため）
errlog79="$work/proj/.claude-handoff/error.log"
n79=$(grep -c "latest.jsonに未知のキーがあります" "$errlog79" 2>/dev/null)
[ -n "$n79" ] || n79=0
o79a=$(invoke_hook handoff-restore.sh "$restore79a")
n79b=$(grep -c "latest.jsonに未知のキーがあります" "$errlog79" 2>/dev/null)
[ -n "$n79b" ] || n79b=0
d79a=$((n79b - n79))
# b) 状態ファイルのmodeを "MODE" だけにする → スキーマ不正で破棄→新規hardサイクル
#    （旧PSは"MODE"をmodeとして受理し既存サイクルを継続して分裂）
sid79="58585858-1313-3535-5757-797979797979"
t79="$troot/t79.jsonl"
usage_transcript "$t79" 450
printf '%s' '{"MODE":"hard","nonce":"abcdef1234567890","attempts":2,"completed":false,"failed":false}' > "$t79.handoff-state.json"
o79b=$(invoke_hook handoff-check.sh "$(stop_input "$sid79" "$t79")")
# c) restore入力のsourceを "Source" だけにする → 非clear扱い（ポインタ経由の注入は
#    行われるが消費されない。旧PSはclear扱いで消費まで進み分裂）
cp -f "$work/validptr.json" "$work/proj/.claude-handoff/latest.json"
restore79c=$(jq -n --arg sid "59595959-1414-3636-5858-808080808080" --arg tp "$troot/new79c.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", Source: "clear"}')
o79c=$(invoke_hook handoff-restore.sh "$restore79c")
c79=$(jq -r 'if (.consumed == true) or (has("consumed_at") and (.consumed_at != null) and (.consumed_at != "")) then "yes" else "no" end' \
    "$work/proj/.claude-handoff/latest.json" 2>/dev/null)
[ -n "$c79" ] || c79="unreadable"
# d) 直近ユーザーメッセージ抽出: message直下の "Content"（大小違い）は不採用
#    （旧PSはドット参照が大小非区別で拾い、jqの .content と分裂していた）。
#    dの完了チェックで状態がcompletedに変わるため、bの状態はここで先に捕捉する
state79b=$(get_state "$t79")
{
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"content":"MARKER-C79-VALID"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"Content":"MARKER-C79-WRONGCASE"}}'
} >> "$t79"
nonce79=$(jq -r '.nonce' "$t79.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid79"
sed "s/{{NONCE}}/$nonce79/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid79/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid79" "$t79")" > /dev/null
restore79d=$(jq -n --arg sid "$sid79" --arg tp "$t79" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}')
o79d=$(invoke_hook handoff-restore.sh "$restore79d")
d1=no; case "$o79d" in *"MARKER-C79-VALID"*) d1=yes ;; esac
d2=no; case "$o79d" in *"MARKER-C79-WRONGCASE"*) d2=yes ;; esac
printf 'C79 wrongcase-consumed=%s/%s wrongcase-mode=%s/%s wrongcase-source=%s consumed=%s content-valid=%s content-wrongcase=%s\n' \
    "$(out_kind "$o79a")" "$d79a" "$(out_kind "$o79b")" "$state79b" "$(out_kind "$o79c")" "$c79" "$d1" "$d2"

# C80: 完全性ファイルの閉じたスキーマ（issue #38 — 未知キー拒否+schema_version検証）。
# ログ検証は各サブケース前後の件数差分（他ケースの記録と干渉しないため）。
# サブケースの意図はPS版run-parity.ps1のC80コメント参照（a〜h）
errlog80="$work/proj/.claude-handoff/error.log"
count80() {
    _c80=$(grep -c "$1" "$errlog80" 2>/dev/null)
    [ -n "$_c80" ] || _c80=0
    printf '%s' "$_c80"
}
n0=$(count80 "latest.jsonに未知のキーがあります")
jq '.extra = 1' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore80a=$(jq -n --arg sid "60606060-1515-3737-5959-818181818181" --arg tp "$troot/new80a.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80a=$(invoke_hook handoff-restore.sh "$restore80a")
d80a=$(( $(count80 "latest.jsonに未知のキーがあります") - n0 ))
n0=$(count80 "latest.jsonにschema_versionがありません（旧形式のポインタ）")
jq 'del(.schema_version)' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore80b=$(jq -n --arg sid "62626262-1717-3939-6161-838383838383" --arg tp "$troot/new80b.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80b=$(invoke_hook handoff-restore.sh "$restore80b")
d80b=$(( $(count80 "latest.jsonにschema_versionがありません（旧形式のポインタ）") - n0 ))
n0=$(count80 "latest.jsonのschema_versionが1ではありません（未知の形式）")
jq '.schema_version = 2' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore80c=$(jq -n --arg sid "63636363-1818-4040-6262-848484848484" --arg tp "$troot/new80c.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80c=$(invoke_hook handoff-restore.sh "$restore80c")
d80c=$(( $(count80 "latest.jsonのschema_versionが1ではありません（未知の形式）") - n0 ))
jq '.SHA256 = "X"' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore80d=$(jq -n --arg sid "64646464-1919-4141-6363-858585858585" --arg tp "$troot/new80d.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80d=$(invoke_hook handoff-restore.sh "$restore80d")
sed 's/"schema_version"[[:space:]]*:[[:space:]]*1/"schema_version": 1.00/' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore80e=$(jq -n --arg sid "65656565-2020-4242-6464-868686868686" --arg tp "$troot/new80e.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80e=$(invoke_hook handoff-restore.sh "$restore80e")
sid80f="66666666-2121-4343-6565-878787878787"
t80f="$troot/t80f.jsonl"
usage_transcript "$t80f" 450
printf '%s' '{"schema_version":1,"mode":"hard","nonce":"abcdef1234567890","attempts":2,"completed":false,"failed":false,"extra":1}' > "$t80f.handoff-state.json"
n0=$(count80 "不正なhandoff-stateを破棄して再生成します")
o80f=$(invoke_hook handoff-check.sh "$(stop_input "$sid80f" "$t80f")")
d80f=$(( $(count80 "不正なhandoff-stateを破棄して再生成します") - n0 ))
sid80g="67676767-2222-4444-6666-888888888888"
t80g="$troot/t80g.jsonl"
usage_transcript "$t80g" 450
printf '%s' '{"schema_version":1,"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t80g.handoff-state.json"
o80g=$(invoke_hook handoff-check.sh "$(stop_input "$sid80g" "$t80g")")
cfgpath80="$work/proj/.claude/handoff-config.json"
cp -f "$cfgpath80" "$work/cfg80.bak"
jq '.extra = 1' "$work/cfg80.bak" > "$cfgpath80"
sid80h="68686868-2323-4545-6767-898989898989"
t80h="$troot/t80h.jsonl"
usage_transcript "$t80h" 450
n0=$(count80 "handoff-config.jsonに未知のキーがあります")
o80h=$(invoke_hook handoff-check.sh "$(stop_input "$sid80h" "$t80h")")
d80h=$(( $(count80 "handoff-config.jsonに未知のキーがあります") - n0 ))
cp -f "$work/cfg80.bak" "$cfgpath80"
# i) 旧バージョンのstate（schema_versionなし・既知キーのみ）→ 受理され継続（移行契約）
sid80i="69696969-2424-4646-6868-909090909090"
t80i="$troot/t80i.jsonl"
usage_transcript "$t80i" 450
printf '%s' '{"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t80i.handoff-state.json"
o80i=$(invoke_hook handoff-check.sh "$(stop_input "$sid80i" "$t80i")")
# j) stateのschema_version=2 → 破棄+再生成（新規hardサイクル）+診断1件
sid80j="70707070-2525-4747-6969-919191919191"
t80j="$troot/t80j.jsonl"
usage_transcript "$t80j" 450
printf '%s' '{"schema_version":2,"mode":"hard","nonce":"abcdef1234567890","attempts":1,"completed":false,"failed":false}' > "$t80j.handoff-state.json"
n0=$(count80 "不正なhandoff-stateを破棄して再生成します")
o80j=$(invoke_hook handoff-check.sh "$(stop_input "$sid80j" "$t80j")")
d80j=$(( $(count80 "不正なhandoff-stateを破棄して再生成します") - n0 ))
# k) producerが書くstateはschema_version==1。全5書込み箇所を固定する: f=破棄後の初回
#    hard生成・g=retry更新（同一関数）/ 新規softサイクル生成 / 通常完了（mの完了時に検証）/
#    SHA・epoch失敗後のcompleted遷移（p）/ hard打切りのfailed遷移（q）。
#    判定は「JSON numberかつ値1」の厳密検証（PS版のGet-SvStrict80と同一契約。
#    producerからの脱落はget_stateでは検出できない）
sv_strict80() {
    _sv=$(jq -r 'if (.schema_version | type) == "number" and (.schema_version == 1) then "yes" else "no" end' "$1" 2>/dev/null)
    [ -n "$_sv" ] || _sv="no"
    printf '%s' "$_sv"
}
sv80f=$(sv_strict80 "$t80f.handoff-state.json")
sv80g=$(sv_strict80 "$t80g.handoff-state.json")
sid80k="72727272-2727-4949-7171-939393939393"
t80k="$troot/t80k.jsonl"
usage_transcript "$t80k" 250
o80k=$(invoke_hook handoff-check.sh "$(stop_input "$sid80k" "$t80k")")
sv80k=$(sv_strict80 "$t80k.handoff-state.json")
# m) compact復元のstate nonce読取りにも閉じたスキーマ（欠落受理 / 未知キー拒否 / version拒否）。
#    完了済みhandoffを作り、ポインタを消してstate nonce経路を強制する（stateは復元ごとに
#    削除されるため変種ごとに書き直す）
sid80m="71717171-2626-4848-7070-929292929292"
t80m="$troot/t80m.jsonl"
usage_transcript "$t80m" 450
seed_hard_state "$t80m" "nonce-t80m-00000000"
nonce80m=$(jq -r '.nonce' "$t80m.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid80m"
sed "s/{{NONCE}}/$nonce80m/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid80m/current.md"
invoke_hook handoff-check.sh "$(stop_input "$sid80m" "$t80m")" > /dev/null
# 通常完了の書込み箇所もschema_version==1（変種で上書きする前にここで捕捉）
sv80m=$(sv_strict80 "$t80m.handoff-state.json")
restore80m=$(jq -n --arg sid "$sid80m" --arg tp "$t80m" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "compact"}')
rm -f "$work/proj/.claude-handoff/latest.json"
printf '%s' "{\"mode\":\"hard\",\"nonce\":\"$nonce80m\",\"attempts\":1,\"completed\":true,\"failed\":false}" > "$t80m.handoff-state.json"
o80m1=$(invoke_hook handoff-restore.sh "$restore80m")
printf '%s' "{\"mode\":\"hard\",\"nonce\":\"$nonce80m\",\"attempts\":1,\"completed\":true,\"failed\":false,\"extra\":1}" > "$t80m.handoff-state.json"
o80m2=$(invoke_hook handoff-restore.sh "$restore80m")
printf '%s' "{\"schema_version\":2,\"mode\":\"hard\",\"nonce\":\"$nonce80m\",\"attempts\":1,\"completed\":true,\"failed\":false}" > "$t80m.handoff-state.json"
o80m3=$(invoke_hook handoff-restore.sh "$restore80m")
# p) SHA/epoch失敗後のcompleted遷移の書込み箇所もschema_version==1（epoch失敗を強制）
sid80p="75757575-3030-5252-7474-969696969696"
t80p="$troot/t80p.jsonl"
usage_transcript "$t80p" 450
seed_hard_state "$t80p" "nonce-t80p-00000000"
nonce80p=$(jq -r '.nonce' "$t80p.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid80p"
sed "s/{{NONCE}}/$nonce80p/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid80p/current.md"
HANDOFF_TEST_FORCE_NOW_FAIL=1
export HANDOFF_TEST_FORCE_NOW_FAIL
invoke_hook handoff-check.sh "$(stop_input "$sid80p" "$t80p")" > /dev/null
unset HANDOFF_TEST_FORCE_NOW_FAIL
sv80p=$(sv_strict80 "$t80p.handoff-state.json")
# q) hard打切りのfailed遷移の書込み箇所もschema_version==1（attempts=3で打切りを強制）
sid80q="76767676-3131-5353-7575-979797979797"
t80q="$troot/t80q.jsonl"
usage_transcript "$t80q" 450
printf '%s' '{"schema_version":1,"mode":"hard","nonce":"abcdef1234567890","attempts":3,"completed":false,"failed":false}' > "$t80q.handoff-state.json"
invoke_hook handoff-check.sh "$(stop_input "$sid80q" "$t80q")" > /dev/null
sv80q=$(sv_strict80 "$t80q.handoff-state.json")
# n) ルート非objectのポインタ（文字列・数値）は静かに無効（schema系診断の増分ゼロ）
n0=$(( $(count80 "latest.jsonに未知のキーがあります") + $(count80 "latest.jsonにschema_versionがありません（旧形式のポインタ）") + $(count80 "latest.jsonのschema_versionが1ではありません（未知の形式）") ))
printf '%s' '"x"' > "$work/proj/.claude-handoff/latest.json"
restore80n1=$(jq -n --arg sid "73737373-2828-5050-7272-949494949494" --arg tp "$troot/new80n1.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80n1=$(invoke_hook handoff-restore.sh "$restore80n1")
printf '%s' '42' > "$work/proj/.claude-handoff/latest.json"
restore80n2=$(jq -n --arg sid "74747474-2929-5151-7373-959595959595" --arg tp "$troot/new80n2.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o80n2=$(invoke_hook handoff-restore.sh "$restore80n2")
n1=$(( $(count80 "latest.jsonに未知のキーがあります") + $(count80 "latest.jsonにschema_versionがありません（旧形式のポインタ）") + $(count80 "latest.jsonのschema_versionが1ではありません（未知の形式）") ))
d80n=$((n1 - n0))
printf 'C80 ptr-unknown=%s/%s ptr-oldform=%s/%s ptr-badver=%s/%s ptr-wrongcase-dup=%s ptr-verfloat=%s state-unknown=%s/%s/%s state-known=%s/%s config-unknown=%s/%s state-oldform=%s/%s state-badver=%s/%s/%s sv-f=%s sv-g=%s soft-new=%s/%s/%s sv-complete=%s sv-failpath=%s sv-failed=%s compact-oldform=%s compact-unknown=%s compact-badver=%s ptr-notobj=%s/%s/%s\n' \
    "$(out_kind "$o80a")" "$d80a" "$(out_kind "$o80b")" "$d80b" "$(out_kind "$o80c")" "$d80c" \
    "$(out_kind "$o80d")" "$(out_kind "$o80e")" \
    "$(out_kind "$o80f")" "$(get_state "$t80f")" "$d80f" \
    "$(out_kind "$o80g")" "$(get_state "$t80g")" \
    "$(out_kind "$o80h")" "$d80h" \
    "$(out_kind "$o80i")" "$(get_state "$t80i")" \
    "$(out_kind "$o80j")" "$(get_state "$t80j")" "$d80j" \
    "$sv80f" "$sv80g" \
    "$(out_kind "$o80k")" "$(get_state "$t80k")" "$sv80k" \
    "$sv80m" "$sv80p" "$sv80q" \
    "$(out_kind "$o80m1")" "$(out_kind "$o80m2")" "$(out_kind "$o80m3")" \
    "$(out_kind "$o80n1")" "$(out_kind "$o80n2")" "$d80n"

# C81: handoff-config.json が「1個のJSONオブジェクト」でない3態（JSON文が2つ / ルートが配列 /
# 壊れたJSON）。いずれも機能を無効化し、診断を1件残して正常終了する。
# 複数JSON文は、sh版のjqが各JSON文について出力するため統合パースの戻り値を先頭トークンだけで
# 判定すると検証を通してしまい算術展開でexit 1になる回帰の防止（2026-08-30 codexレビュー High-1）。
# 診断の文言も比較する（旧実装はsh版「不正」/PS版「パースに失敗」で分裂していた —
# HANDOFF.mdバックログ10。出力は純ASCIIに保つため、文言そのものではなく分類を出す）。
# ルート配列と壊れたJSONも見るのは、統合したparse経路のうち複数JSON文しか固定しておらず
# 非object経路だけ元に戻っても通ってしまうため（codexレビュー M2）
sid81="81818181-8181-8181-8181-818181818181"
t81="$troot/t81.jsonl"
usage_transcript "$t81" 450
cfg81="$work/proj/.claude/handoff-config.json"
cp -f "$cfg81" "$work/cfg81.bak"
errlog81="$work/proj/.claude-handoff/error.log"
# 文言は「[時刻] <source>: <本文>」の <本文> を**完全一致**で見る。部分一致や正規表現だと
# 片側だけ接頭辞が増えても、`.` が任意1文字として通っても、大小が変わっても素通りして
# 分裂の再発を見逃す（codexレビュー M1）
cfg_parse_msg81="handoff-check: handoff-config.jsonのパースに失敗。機能を無効化中"
cfg_case81() { # $1=configの内容 $2=session_id → "種別/rc/ログ差分/文言分類"
    printf '%s' "$1" > "$cfg81"
    _n81=0
    [ -f "$errlog81" ] && _n81=$(wc -l < "$errlog81" | tr -d ' 	')
    _o81=$(invoke_hook handoff-check.sh "$(stop_input "$2" "$t81")")
    _rc81=$?
    _a81=0
    [ -f "$errlog81" ] && _a81=$(wc -l < "$errlog81" | tr -d ' 	')
    _m81=other
    if [ "$((_a81 - _n81))" -eq 1 ]; then
        _last81=$(tail -n 1 "$errlog81")
        [ "${_last81#*] }" = "$cfg_parse_msg81" ] && _m81=parse
    fi
    printf '%s/%s/%s/%s' "$(out_kind "$_o81")" "$_rc81" "$((_a81 - _n81))" "$_m81"
}
cfg_orig81=$(cat "$work/cfg81.bak")
r81multi=$(cfg_case81 "$cfg_orig81$cfg_orig81" "$sid81")
r81arr=$(cfg_case81 "[$cfg_orig81]" "82828282-8181-8181-8181-828282828282")
r81broken=$(cfg_case81 '{"soft_threshold":' "83838383-8181-8181-8181-838383838383")
cp -f "$work/cfg81.bak" "$cfg81"
printf 'C81 multi=%s arr=%s broken=%s state=%s\n' "$r81multi" "$r81arr" "$r81broken" "$(get_state "$t81")"

# C82: session_id が「UUID + LF + 文字」のhook入力は、両実装とも何もしない
# （HANDOFF.mdバックログ11の回帰）。sh版の ho_is_uuid は grep -Eq の**行単位一致**
# だったため1行目のUUIDだけを見て受理し、PS版（-cmatch は非Multiline）は拒否していた。
# MSYSのgrepはCRも行末として落とすので、内部改行がCRLFへ化けるWindowsでも再現する。
# UUIDの形はcaseの全文一致で見る形に変えた。末尾LFだけの値は届く前に剥がれるため
# 両実装とも受理側で、ここでは分裂しない（PS版の ^…$ を \z へ締めると逆向きに割れる）
t82="$troot/t82.jsonl"
usage_transcript "$t82" 450
sidlf82=$(printf '82828282-8282-8282-8282-828282828282\nx')
o82=$(invoke_hook handoff-check.sh "$(stop_input "$sidlf82" "$t82")")
printf 'C82 output=%s state=%s\n' "$(out_kind "$o82")" "$(get_state "$t82")"

# C83: ポインタの文字列フィールドにNULを混ぜても両実装とも受理しない
# （HANDOFF.mdバックログ13の回帰）。sh版の生の `$(jq -r '.field' file)` はNULを
# シェルへ渡せず、Git shが「ignored null byte in input」としてNULを取り除いた値を
# 返すため、`<uuid>` + NUL が正規UUIDへ、`<sha>` + NUL が正しいSHAへ縮退して検証を
# 通っていた。PS版は.NET文字列としてNULを保持するので拒否側で、受否が分裂していた。
# transcript_path も同じ ho_json_str_field で守るが、restoreのポインタ引用は
# $HOME/.claude/projects を直接見ておりテストのfake設定ディレクトリ配下に無いため
# ここでは観測できない（HANDOFF.mdバックログ14）
jq '.session_id = (.session_id + "\u0000")' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore83a=$(jq -n --arg sid "83838383-8383-8383-8383-838383838383" --arg tp "$troot/new83a.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o83a=$(invoke_hook handoff-restore.sh "$restore83a")
c83a=$(jq -r 'if has("consumed_at") and (.consumed_at != null) and (.consumed_at != "") then "yes" else "no" end' "$work/proj/.claude-handoff/latest.json" 2>/dev/null)
[ -n "$c83a" ] || c83a="unreadable"
jq '.sha256 = (.sha256 + "\u0000")' "$work/validptr.json" > "$work/proj/.claude-handoff/latest.json"
restore83b=$(jq -n --arg sid "84848484-8383-8383-8383-848484848484" --arg tp "$troot/new83b.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o83b=$(invoke_hook handoff-restore.sh "$restore83b")
printf 'C83 nulsid=%s/%s nulsha=%s\n' "$(out_kind "$o83a")" "$c83a" "$(out_kind "$o83b")"

# C84: stdin側のNUL縮退（HANDOFF.mdバックログ13の回帰・その2。2026-08-30 codexレビュー Medium×2）
#
# a) stop_hook_active が "true" + NUL。旧sh版は ho_field の生のコマンド置換でNULが落ちて
#    "true" と完全一致し、破損stateを消した直後に無言終了していた。PS版はNULを保持して
#    一致せず、そのまま指示とstateを再生成する
t84="$troot/t84.jsonl"
usage_transcript "$t84" 450
printf '%s' '{"mode":"soft","nonce":"nonce-t84-00000000","bogus":1}' > "$t84.handoff-state.json"
in84a=$(jq -n --arg tp "$t84" --arg cwd "$work/proj" \
    '{session_id: "84848484-1111-1111-1111-848484848484", transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: "true\u0000"}')
o84a=$(invoke_hook handoff-check.sh "$in84a")
#
# b) session_id が <uuid> + NUL で、かつ別フィールド（trigger）に内部改行がある入力。
#    バックログ12より前は、内部改行があると**slow path**（フィールド別にjqを起こして
#    コマンド置換で受ける経路）へ落ち、そこでNULが消えて正規UUIDへ縮退し受理していた。
#    バックログ12でslow pathを廃止したので、いまは fast path 一本で、jqの @sh が
#    NULを**リテラルの `\0` 2文字**へ符号化するため受理されない。
#    trigger の内部改行は当時の再現条件をそのまま残してある（LFを生のまま持てることの
#    確認も兼ねる）。PS版はNULを保持して拒否する
t84b="$troot/t84b.jsonl"
usage_transcript "$t84b" 450
in84b=$(jq -n --arg tp "$t84b" --arg cwd "$work/proj" \
    '{session_id: "85858585-1111-1111-1111-858585858585\u0000", transcript_path: $tp, cwd: $cwd, hook_event_name: "Stop", stop_hook_active: false, trigger: "a\nb"}')
o84b=$(invoke_hook handoff-check.sh "$in84b")
printf 'C84 nulactive=%s/%s nulsid=%s/%s\n' "$(out_kind "$o84a")" "$(get_state "$t84")" "$(out_kind "$o84b")" "$(get_state "$t84b")"

# C85: ポインタ経由transcriptの引用がprojects_rootの解決関数を通ること
# （HANDOFF.mdバックログ14の回帰）。旧実装は sh版 "$HOME/.claude/projects" /
# PS版 UserProfile直下 の決め打ちで、CLAUDE_CONFIG_DIRを設定した環境では
# 包含判定が常に外れ「直近のユーザーメッセージ」が無言で落ちていた。
# この試験環境自体がCLAUDE_CONFIG_DIRを作業域へ向けているため、旧実装なら quote=no になる
sid85="12341234-5678-90ab-cdef-1234567890ab"
t85="$troot/t85.jsonl"
usage_transcript "$t85" 450
printf '%s' '{"type":"user","isSidechain":false,"message":{"content":"parity-c85-user-msg"}}' >> "$t85"
printf '\n' >> "$t85"
seed_hard_state "$t85" "nonce-t85-00000000"
nonce85=$(jq -r '.nonce' "$t85.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid85"
sed "s/{{NONCE}}/$nonce85/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid85/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid85" "$t85")")
restore85=$(jq -n --arg sid "56785678-90ab-cdef-1234-567890abcdef" --arg tp "$troot/new85.jsonl" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
o85=$(invoke_hook handoff-restore.sh "$restore85")
quote85="no"
case "$o85" in *"parity-c85-user-msg"*) quote85="yes" ;; esac
printf 'C85 output=%s quote=%s\n' "$(out_kind "$o85")" "$quote85"

# C86: 包含判定の大小の扱いが両実装で一致すること（HANDOFF.mdバックログ15の回帰）。
# sh版 ho_under_root は `cd`+`pwd`（論理パス）の結果をbyte比較するため、MSYSのpwdが畳む
# **ドライブレターだけ大小無視・残りは大小区別**になる。PS版 Test-PathUnderRoot が
# OrdinalIgnoreCase だと casevar でPS版だけが受理し、Ordinal だと drivevar で
# PS版だけが拒否する。どちらの向きも見るため2態を並べる。
# Windowsは大小非区別FSなのでどちらの綴りでもファイルは実在し、受否は包含判定だけで決まる。
# sh harnessは作業パスを cygpath -m でWindows形式へ揃えるので、drivevar もMSYSの
# ドライブ畳みを実際に通る。
# 大小区別FS（cygpathの無いLinux/macOS）では casevar のパスが実在せず、drivevar は
# 反転対象が無いので、同じ期待値に落ち着くだけの一致確認になる（回帰検出力は無い —
# codexレビュー Low。歯があるのはWindowsだけ）
sid86="13131313-2424-3535-4646-575757575757"
t86="$troot/t86.jsonl"
usage_transcript "$t86" 450
printf '%s' '{"type":"user","isSidechain":false,"message":{"content":"parity-c86-user-msg"}}' >> "$t86"
printf '\n' >> "$t86"
seed_hard_state "$t86" "nonce-t86-00000000"
nonce86=$(jq -r '.nonce' "$t86.handoff-state.json")
mkdir -p "$work/proj/.claude-handoff/$sid86"
sed "s/{{NONCE}}/$nonce86/" "$fixtures/md/good-handoff.md.tmpl" > "$work/proj/.claude-handoff/$sid86/current.md"
o=$(invoke_hook handoff-check.sh "$(stop_input "$sid86" "$t86")")
latest86="$work/proj/.claude-handoff/latest.json"
# 検証済みポインタのtranscript_pathだけを差し替えて未消費へ戻す（C10と同じ手口）
probe_ptr_quote() { # $1=差し替えるtranscript_path $2=restoreのsession_id $3=期待マーカー
    #                    → "種別/引用有無"
    jq --arg tp "$1" 'del(.consumed_at) | .consumed = false | .transcript_path = $tp' \
        "$latest86" > "$latest86.new" && mv -f "$latest86.new" "$latest86"
    _inp=$(jq -n --arg sid "$2" --arg tp "$troot/newprobe.jsonl" --arg cwd "$work/proj" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: "clear"}')
    _op=$(invoke_hook handoff-restore.sh "$_inp")
    _qp=no
    case "$_op" in *"$3"*) _qp=yes ;; esac
    printf '%s/%s' "$(out_kind "$_op")" "$_qp"
}
# a) root部分の要素だけ大小違い（projects → Projects）: 両実装とも引用しない
tp86case="$work/claude-config/Projects/proj/t86.jsonl"
r86case=$(probe_ptr_quote "$tp86case" "24242424-3535-4646-5757-686868686868" parity-c86-user-msg)
# b) ドライブレターだけ大小違い: 両実装とも引用する（先頭が「英字:」でなければ無変換）
tp86drive=$t86
case "$t86" in
    [A-Za-z]:*)
        d86=${t86%"${t86#?}"}
        rest86=${t86#?}
        case "$d86" in
            [A-Z]) d86=$(printf '%s' "$d86" | tr 'A-Z' 'a-z') ;;
            *) d86=$(printf '%s' "$d86" | tr 'a-z' 'A-Z') ;;
        esac
        tp86drive="$d86$rest86"
        ;;
esac
r86drive=$(probe_ptr_quote "$tp86drive" "35353535-4646-5757-6868-797979797979" parity-c86-user-msg)
printf 'C86 casevar=%s drivevar=%s\n' "$r86case" "$r86drive"

# C87: 経路にsymlink/junctionがあれば両実装とも拒否すること
# （HANDOFF.mdバックログ16の回帰）。以前は sh版の `cd`+`pwd` も PS版の GetFullPath も
# **字句解決のまま**（MSYSの pwd は既定で論理パス。物理解決は pwd -P）で、
# projects_root 配下に置かれたjunctionをどちらも受理していた。実測: 旧実装は
# sh/PSとも outlink=injected/yes inlink=injected/yes で、**root外のファイルを引用できた**。
# 分裂ではなく共通の穴だったので、両実装を「経路のsymlinkは拒否」へ揃えて塞いだ。
# リンクが作れない環境ではパスが実在せず、どちらの態も同じ `no` に落ち着く
# （期待値は安定するが歯は無くなる。作成手段は下の make_link を参照）
make_link() { # $1=作るリンク $2=リンク先ディレクトリ → 作れたら0
    if ln -s "$2" "$1" 2>/dev/null && [ -h "$1" ]; then return 0; fi
    # Git Bash の ln -s は Developer Mode/管理者でないと**コピー**を作る（実測）。
    # Windowsではjunctionで代替する（管理者不要。MSYSからは [ -h ] でsymlinkに見える）
    rm -rf "$1" 2>/dev/null
    command -v powershell.exe >/dev/null 2>&1 || return 1
    command -v cygpath >/dev/null 2>&1 || return 1
    _lw=$(cygpath -w "$1" 2>/dev/null) || return 1
    _tw=$(cygpath -w "$2" 2>/dev/null) || return 1
    powershell.exe -NoProfile -Command \
        "New-Item -ItemType Junction -Path '$_lw' -Target '$_tw' | Out-Null" >/dev/null 2>&1
    [ -h "$1" ]
}
proot87="$work/claude-config/projects"
mkdir -p "$work/outside87" "$proot87/real87"
printf '%s' '{"type":"user","isSidechain":false,"message":{"content":"parity-c87-outside"}}' > "$work/outside87/t87o.jsonl"
printf '\n' >> "$work/outside87/t87o.jsonl"
printf '%s' '{"type":"user","isSidechain":false,"message":{"content":"parity-c87-inside"}}' > "$proot87/real87/t87i.jsonl"
printf '\n' >> "$proot87/real87/t87i.jsonl"
printf '%s' '{"type":"user","isSidechain":false,"message":{"content":"parity-c87-leaf"}}' > "$work/outside87/t87l.jsonl"
printf '\n' >> "$work/outside87/t87l.jsonl"
mkdir -p "$proot87/leafdir87"
# リンクが作れたかは**stderrに出す**（stdoutへ出すと期待値が環境依存になる。
# Windowsはjunctionは作れてもファイルsymlinkはDeveloper Mode/管理者が要る）。
# 作れなかった態は「パスが実在しない」ので同じ no に落ち着き、期待値は安定するが
# 歯は無くなる。緑なのに空試験、という状態を見えるようにするための警告
warn_link87() { printf 'C87: リンクを作れませんでした（この態は空試験になります）: %s\n' "$1" >&2; }
make_link "$proot87/linkout87" "$work/outside87" || warn_link87 "outlink（ディレクトリ）"
make_link "$proot87/linkin87" "$proot87/real87" || warn_link87 "inlink（ディレクトリ）"
# c) 対象ファイル自身がsymlink（親ディレクトリはroot配下の実ディレクトリ）。
# 親までしか見ない実装ではここが素通りしてroot外を読めてしまう
make_link "$proot87/leafdir87/t87l.jsonl" "$work/outside87/t87l.jsonl" || warn_link87 "leaflink（ファイル）"
r87out=$(probe_ptr_quote "$proot87/linkout87/t87o.jsonl" "46464646-5757-6868-7979-808080808080" parity-c87-outside)
r87in=$(probe_ptr_quote "$proot87/linkin87/t87i.jsonl" "57575757-6868-7979-8080-919191919191" parity-c87-inside)
r87leaf=$(probe_ptr_quote "$proot87/leafdir87/t87l.jsonl" "68686868-7979-8080-9191-020202020202" parity-c87-leaf)
printf 'C87 outlink=%s inlink=%s leaflink=%s\n' "$r87out" "$r87in" "$r87leaf"

# C88: 文字列フィールドの末尾LFを剥がさないこと（HANDOFF.mdバックログ12の回帰）。
# 旧sh版は cwd / session_id / source / trigger の末尾LFをjq側で剥がしてから使い、
# PS版は生値を使っていたため、同じ入力で結果が割れていた。
# 旧実装での実測（このケースの観測値。3態とも旧shだけが違い、新実装は旧PSに揃った）:
#   sidlf  旧sh=hard/hard/1   旧PS=none/none     新=none/none
#   srclf  旧sh=injected/yes  旧PS=injected/no   新=injected/no
#   stoplf 旧sh=none/none     旧PS=hard/hard/1   新=hard/hard/1
# sidlf は「旧shが末尾LFを剥がして受理しハード指示まで進む / 旧PSは Test-Uuid を
# 通っても後段のパス検査で落ちて無出力」という受否の分裂だった（旧記述の
# 「受否は一致する」はこの経路では誤り）。
# いまは両実装とも「剥がさない＝一致しない」でfail-closedに揃っている
t88="$troot/t88.jsonl"
usage_transcript "$t88" 450
in88a=$(jq -n --arg tp "$t88" --arg cwd "$work/proj" \
    '{session_id: "88888888-1212-3434-5656-787878787878\n", transcript_path: $tp, cwd: $cwd,
      hook_event_name: "Stop", stop_hook_active: false}')
o88a=$(invoke_hook handoff-check.sh "$in88a")
# b) source が「clear + 末尾LF」。有効なポインタがあっても clear 扱いにしない
#    （C85〜C87で消費済みなので、未消費へ戻し transcript_path も実在するものへ戻す）
jq --arg tp "$t85" 'del(.consumed_at) | .consumed = false | .transcript_path = $tp' \
    "$latest86" > "$latest86.new" && mv -f "$latest86.new" "$latest86"
in88b=$(jq -n --arg tp "$troot/new88.jsonl" --arg cwd "$work/proj" \
    '{session_id: "79797979-1212-3434-5656-898989898989", transcript_path: $tp, cwd: $cwd,
      hook_event_name: "SessionStart", source: "clear\n"}')
o88b=$(invoke_hook handoff-restore.sh "$in88b")
# 注入の有無では差が出ない（clear以外でも有効ポインタがあれば注入する）。
# clearかどうかで変わるのは**ポインタの消費**なので、そちらを見る
cons88="no"
[ -n "$(jq -r '.consumed_at // empty' "$latest86" 2>/dev/null)" ] && cons88="yes"
# c) stop_hook_active が「true + 末尾LF」。破損stateを消した直後に無言終了しない
t88c="$troot/t88c.jsonl"
usage_transcript "$t88c" 450
printf '%s' '{"mode":"soft","nonce":"nonce-t88-00000000","bogus":1}' > "$t88c.handoff-state.json"
in88c=$(jq -n --arg tp "$t88c" --arg cwd "$work/proj" \
    '{session_id: "70707070-1212-3434-5656-909090909090", transcript_path: $tp, cwd: $cwd,
      hook_event_name: "Stop", stop_hook_active: "true\n"}')
o88c=$(invoke_hook handoff-check.sh "$in88c")
printf 'C88 sidlf=%s/%s srclf=%s/%s stoplf=%s/%s\n' \
    "$(out_kind "$o88a")" "$(get_state "$t88")" "$(out_kind "$o88b")" "$cons88" \
    "$(out_kind "$o88c")" "$(get_state "$t88c")"

# C89: strfieldの新契約（内部LFも末尾LFも生のまま持つ / CRを含む値は空）を、値が実際に
# ファイルへ落ちる `trigger` で観測する（HANDOFF.mdバックログ12の回帰）。
# C88は session_id / source / stop_hook_active しか見ておらず、strfieldがLF・CRの
# 扱いだけ元へ戻っても通ってしまう（2026-08-31 codexレビュー Low）。
# 旧実装での実測（このケースの観測値。cr は旧sh・旧PSの**両方**に歯がある）:
#   lf  旧sh=[man<CR><LF>ual]  旧PS=[man<LF>ual<LF>]  新=[man<LF>ual<LF>]
#   cr  旧sh=[a<CR>b]          旧PS=[a<CR>b]          新=[]
# meta.jsonのtriggerはそのままだと行を割るので、CRとLFを可視トークンへ置換して出す
sid89="89898989-1212-3434-5656-121212121212"
t89="$troot/t89.jsonl"
usage_transcript "$t89" 450
save_trigger89() { # $1=save入力JSON → 保存されたtriggerを可視化して返す
    invoke_hook handoff-save.sh "$1" > /dev/null
    _b89=$(ls -1 "$work/proj/.claude-handoff/$sid89/backup" 2>/dev/null | sort -r | head -n 1)
    _v89=$(jq -r 'if (.trigger | type) == "string"
            then "[" + (.trigger | split([13] | implode) | join("<CR>")
                                 | split([10] | implode) | join("<LF>")) + "]"
            else "notstring" end' \
        "$work/proj/.claude-handoff/$sid89/backup/$_b89/meta.json" 2>/dev/null)
    [ -n "$_v89" ] || _v89="unreadable"
    printf '%s' "$_v89"
}
in89a=$(jq -n --arg sid "$sid89" --arg tp "$t89" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact",
      trigger: (["man", "ual", ""] | join([10] | implode))}')
tg89a=$(save_trigger89 "$in89a")
in89b=$(jq -n --arg sid "$sid89" --arg tp "$t89" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact",
      trigger: (["a", "b"] | join([13] | implode))}')
tg89b=$(save_trigger89 "$in89b")
printf 'C89 lf=%s cr=%s\n' "$tg89a" "$tg89b"

# C90: 資料の書き直しと下書き（check 側。設計メモ docs/design/2026-09-13-refresh-and-freshness.md）。
# 指示の書き先は下書き draft.md。完了検証に通った下書きだけを current.md へ置き換える。
# ソフト閾値で作った資料は、ハード閾値を越えたら1度だけ書き直させる（mode soft の完了で、
# completed_tokens がハード閾値未満か、キーの無い旧形式のとき）。
#   a  : 完成250（soft）。使用量250のままなら何もしない / 450でハード指示＋書き直しの注記
#   b  : 完成450（hard）。900になっても何もしない
#   hh : 完成250（hard）。450でも何もしない（閾値をあとから上げた状況。hard の完了は書き直さない — I5）
#   c  : 完成420（soft指示だが完成がハード閾値以上）。450でも何もしない
#   ls : completed_tokens の無い soft 完了（v0.2.0以前が書いた状態）。450で書き直し
#   lh : completed_tokens の無い hard 完了。450でも何もしない
#   flt/exp: completed_tokens の表記が 250.0 / 2.5e2（整数値の number）。受理して書き直し（PS/sh同一）
#   bad: completed_tokens が文字列。状態は不正として破棄（error.log 1件）→ 450なので通常のハード指示
#   dr : 下書きが検証を通る → current.md が下書きの内容に置き換わり、下書きは消え、ポインタのSHAは current.md のもの
#   fb : 下書きが無く current.md が今回のnonceで通る（v0.2.0の指示を受けた途中のサイクル等）→ 完了（HEADと同じ）
#   mf : 下書きは通るが置き換えに失敗（current.md がディレクトリ）→ 完了にしない・soft なので指示も出さない・下書きはそのまま・error.log 1件
#   pr : 下書きと current.md の両方が今回のnonceで通る → 下書きが勝つ
#   ro : current.md が読み取り専用 → 置き換えて完了（PS も sh の mv -f と揃える）
#   mfh: hard で置き換えに失敗し続ける（試行ごとの新nonceで下書きを書き直しても通らない）→ 再試行に数え（理由を指示文に出す）、3回で打ち切り・通知。error.log は Stop ごとに1件
#   ch : 通し。soft完了 → 450で書き直し指示（旧資料の nonce・SHA・完成時の値を持ち越す）→ 書かずにStop
#        （指示文の書き先が draft.md であることも見る）→ 再試行（持ち越し維持）→ 新nonceの下書きを書いてStop → 完了（完成時の値450・持ち越しキーは消える・
#        current.md は新しい資料・ポインタは新nonce）→ 900でも何もしない
#   fl : 書き直し中に3回失敗して打ち切り（failed）になっても、持ち越した旧資料の情報は残る
seed_done90() { # $1=transcript $2=mode $3=completed_tokens（JSON表記。空なら書かない）
    if [ -n "$3" ]; then
        printf '{"schema_version":1,"mode":"%s","nonce":"nonce-t90-00000000","attempts":1,"completed":true,"failed":false,"completed_tokens":%s}' "$2" "$3" > "$1.handoff-state.json"
    else
        printf '{"schema_version":1,"mode":"%s","nonce":"nonce-t90-00000000","attempts":1,"completed":true,"failed":false}' "$2" > "$1.handoff-state.json"
    fi
}
note90() { # $1=output
    case "$1" in
        *"ハード閾値に達する前に作った引き継ぎ資料"*) printf 'note' ;;
        *) printf 'plain' ;;
    esac
}
check90() { # $1=transcript $2=mode $3=completed_tokens $4=usage → out_kind/note
    usage_transcript "$1" "$4"
    seed_done90 "$1" "$2" "$3"
    _o90=$(invoke_hook handoff-check.sh "$(stop_input "$sid90" "$1")")
    printf '%s/%s' "$(out_kind "$_o90")" "$(note90 "$_o90")"
}
doc90() { # $1=path $2=nonce。良い資料を書く
    mkdir -p "${1%/*}"
    sed "s/{{NONCE}}/$2/" "$fixtures/md/good-handoff.md.tmpl" > "$1"
}
soft_state90() { # $1=transcript $2=nonce。ソフト指示を出した直後の状態
    printf '{"schema_version":1,"mode":"soft","nonce":"%s","attempts":1,"completed":false,"failed":false}' "$2" > "$1.handoff-state.json"
}
carry90() { # $1=transcript → 「completed_nonce/completed_tokens/sha有無」（無ければ none / nosha）
    jq -r '(if has("completed_nonce") then .completed_nonce else "none" end) + "/"
           + (if has("completed_tokens") then (.completed_tokens | tostring) else "none" end) + "/"
           + (if has("completed_sha256") then "sha" else "nosha" end)' "$1.handoff-state.json" 2>/dev/null
}
errcount90() { # $1=pattern
    _n90=$(grep -c "$1" "$work/proj/.claude-handoff/error.log" 2>/dev/null)
    [ -n "$_n90" ] || _n90=0
    printf '%s' "$_n90"
}
sid90="90909090-1111-2222-3333-444444444444"
t90a="$troot/t90a.jsonl"
usage_transcript "$t90a" 250
seed_done90 "$t90a" soft 250
o90a1=$(invoke_hook handoff-check.sh "$(stop_input "$sid90" "$t90a")")
usage_transcript "$t90a" 450
o90a2=$(invoke_hook handoff-check.sh "$(stop_input "$sid90" "$t90a")")
a90="$(out_kind "$o90a1")/$(out_kind "$o90a2")/$(note90 "$o90a2")/$(get_state "$t90a")"
t90b="$troot/t90b.jsonl"
usage_transcript "$t90b" 900
seed_done90 "$t90b" hard 450
o90b=$(invoke_hook handoff-check.sh "$(stop_input "$sid90" "$t90b")")
b90="$(out_kind "$o90b")/$(get_state "$t90b")"
hh90=$(check90 "$troot/t90hh.jsonl" hard 250 450)
c90=$(check90 "$troot/t90c.jsonl" soft 420 450)
ls90=$(check90 "$troot/t90l.jsonl" soft "" 450)
lh90=$(check90 "$troot/t90h.jsonl" hard "" 450)
flt90=$(check90 "$troot/t90flt.jsonl" soft 250.0 450)
exp90=$(check90 "$troot/t90exp.jsonl" soft 2.5e2 450)
n90a=$(errcount90 "不正なhandoff-stateを破棄")
bad90=$(check90 "$troot/t90x.jsonl" soft '"250"' 450)
bad90="$bad90/$(( $(errcount90 "不正なhandoff-stateを破棄") - n90a ))"
# dr: 下書きの置き換え
sid90d="90909090-2222-3333-4444-555555555555"
t90d="$troot/t90d.jsonl"
dir90d="$work/proj/.claude-handoff/$sid90d"
usage_transcript "$t90d" 250
soft_state90 "$t90d" "nonce-t90d-00000000"
doc90 "$dir90d/current.md" "nonce-t90d-99999999"
doc90 "$dir90d/draft.md" "nonce-t90d-00000000"
invoke_hook handoff-check.sh "$(stop_input "$sid90d" "$t90d")" > /dev/null
dr90="$(get_state "$t90d")"
case "$(cat "$dir90d/current.md" 2>/dev/null)" in *"handoff-complete: nonce-t90d-00000000 -->"*) dr90="$dr90/moved" ;; *) dr90="$dr90/notmoved" ;; esac
[ -e "$dir90d/draft.md" ] && dr90="$dr90/draftleft" || dr90="$dr90/draftgone"
[ "$(jq -r '.sha256' "$work/proj/.claude-handoff/latest.json" 2>/dev/null)" = "$(ho_sha256 "$dir90d/current.md")" ] && dr90="$dr90/ptrsha" || dr90="$dr90/ptrstale"
# fb: current.md への直接書き込み
sid90b="90909090-3333-4444-5555-666666666666"
t90fb="$troot/t90fb.jsonl"
usage_transcript "$t90fb" 250
soft_state90 "$t90fb" "nonce-t90fb-00000000"
doc90 "$work/proj/.claude-handoff/$sid90b/current.md" "nonce-t90fb-00000000"
invoke_hook handoff-check.sh "$(stop_input "$sid90b" "$t90fb")" > /dev/null
fb90="$(get_state "$t90fb")"
# mf: 置き換えの失敗
sid90m="90909090-4444-5555-6666-777777777777"
t90m="$troot/t90m.jsonl"
dir90m="$work/proj/.claude-handoff/$sid90m"
usage_transcript "$t90m" 250
soft_state90 "$t90m" "nonce-t90m-00000000"
mkdir -p "$dir90m/current.md"
doc90 "$dir90m/draft.md" "nonce-t90m-00000000"
n90m=$(errcount90 "置き換えられませんでした")
o90m=$(invoke_hook handoff-check.sh "$(stop_input "$sid90m" "$t90m")")
mf90="$(out_kind "$o90m")/$(get_state "$t90m")"
[ -f "$dir90m/draft.md" ] && mf90="$mf90/draftleft" || mf90="$mf90/draftgone"
mf90="$mf90/$(( $(errcount90 "置き換えられませんでした") - n90m ))"
# pr: 下書きと current.md の両方が今回のnonceで通る → 下書きが勝つ（current.md を先に見る実装だと落ちる）
sid90p="90909090-6666-7777-8888-999999999999"
t90p="$troot/t90p.jsonl"
dir90p="$work/proj/.claude-handoff/$sid90p"
usage_transcript "$t90p" 250
soft_state90 "$t90p" "nonce-t90p-00000000"
doc90 "$dir90p/current.md" "nonce-t90p-00000000"
sed "s/機能Yの実装が残っている/CURRENT-DIRECT/" "$dir90p/current.md" > "$t90p.tmp" && mv -f "$t90p.tmp" "$dir90p/current.md"
doc90 "$dir90p/draft.md" "nonce-t90p-00000000"
invoke_hook handoff-check.sh "$(stop_input "$sid90p" "$t90p")" > /dev/null
pr90="$(get_state "$t90p")"
case "$(cat "$dir90p/current.md" 2>/dev/null)" in *"CURRENT-DIRECT"*) pr90="$pr90/curwon" ;; *) pr90="$pr90/draftwon" ;; esac
# ro: current.md が読み取り専用でも置き換える（sh の mv -f と PS の File.Replace で割れないこと）
sid90o="90909090-7777-8888-9999-aaaaaaaaaaaa"
t90o="$troot/t90o.jsonl"
dir90o="$work/proj/.claude-handoff/$sid90o"
usage_transcript "$t90o" 250
soft_state90 "$t90o" "nonce-t90o-00000000"
doc90 "$dir90o/current.md" "nonce-t90o-99999999"
chmod a-w "$dir90o/current.md"
doc90 "$dir90o/draft.md" "nonce-t90o-00000000"
chmod a-w "$dir90o/draft.md"
invoke_hook handoff-check.sh "$(stop_input "$sid90o" "$t90o")" > /dev/null
ro90="$(get_state "$t90o")"
case "$(cat "$dir90o/current.md" 2>/dev/null)" in *"handoff-complete: nonce-t90o-00000000 -->"*) ro90="$ro90/moved" ;; *) ro90="$ro90/notmoved" ;; esac
chmod u+w "$dir90o/current.md" 2>/dev/null
# mfh: hard で置き換えに失敗し続ける → 再試行に数え、理由を指示文に出し、3回で打ち切り（failed）
sid90h="90909090-8888-9999-aaaa-bbbbbbbbbbbb"
t90h="$troot/t90mh.jsonl"
dir90h="$work/proj/.claude-handoff/$sid90h"
usage_transcript "$t90h" 450
seed_hard_state "$t90h" "nonce-t90h-00000000"
mkdir -p "$dir90h/current.md"
doc90 "$dir90h/draft.md" "nonce-t90h-00000000"
n90h=$(errcount90 "置き換えられませんでした")
o90h1=$(invoke_hook handoff-check.sh "$(stop_input "$sid90h" "$t90h")")
rs90h="noreason"; case "$o90h1" in *"下書きは検証に通ったが current.md へ置き換えられない"*) rs90h="reason" ;; esac
mfh90="$(out_kind "$o90h1")/$rs90h/$(get_state "$t90h")"
doc90 "$dir90h/draft.md" "$(jq -r '.nonce' "$t90h.handoff-state.json" 2>/dev/null)"
invoke_hook handoff-check.sh "$(stop_input "$sid90h" "$t90h")" > /dev/null
doc90 "$dir90h/draft.md" "$(jq -r '.nonce' "$t90h.handoff-state.json" 2>/dev/null)"
o90h3=$(invoke_hook handoff-check.sh "$(stop_input "$sid90h" "$t90h")")
fl90h=$(jq -r 'if .failed == true then "failed" else "open" end' "$t90h.handoff-state.json" 2>/dev/null)
nt90h="nonotice"; case "$o90h3" in *"回失敗し打ち切りました"*) nt90h="notice" ;; esac
mfh90="$mfh90/$fl90h/$nt90h/$(( $(errcount90 "置き換えられませんでした") - n90h ))"
invoke_hook handoff-check.sh "$(stop_input "$sid90h" "$t90h")" > /dev/null
mfh90="$mfh90/$(( $(errcount90 "置き換えられませんでした") - n90h ))"
# ch: 通し
sid90r="90909090-5555-6666-7777-888888888888"
t90r="$troot/t90r.jsonl"
dir90r="$work/proj/.claude-handoff/$sid90r"
usage_transcript "$t90r" 250
soft_state90 "$t90r" "nonce-t90r-00000000"
doc90 "$dir90r/draft.md" "nonce-t90r-00000000"
invoke_hook handoff-check.sh "$(stop_input "$sid90r" "$t90r")" > /dev/null
usage_transcript "$t90r" 450
o90r1=$(invoke_hook handoff-check.sh "$(stop_input "$sid90r" "$t90r")")
cr90r1="drop"; [ "$(carry90 "$t90r")" = "nonce-t90r-00000000/250/sha" ] && cr90r1="keep"
o90r2=$(invoke_hook handoff-check.sh "$(stop_input "$sid90r" "$t90r")")
cr90r2="drop"; [ "$(carry90 "$t90r")" = "nonce-t90r-00000000/250/sha" ] && cr90r2="keep"
n90r=$(jq -r '.nonce' "$t90r.handoff-state.json")
doc90 "$dir90r/draft.md" "$n90r"
o90r3=$(invoke_hook handoff-check.sh "$(stop_input "$sid90r" "$t90r")")
st90r=$(jq -r '(if .completed == true then "completed" else "open" end) + "/"
               + (if has("completed_tokens") then (.completed_tokens | tostring) else "none" end) + "/"
               + (if has("completed_nonce") then "cn" else "nocn" end)' "$t90r.handoff-state.json" 2>/dev/null)
case "$(cat "$dir90r/current.md" 2>/dev/null)" in *"handoff-complete: $n90r -->"*) st90r="$st90r/newdoc" ;; *) st90r="$st90r/olddoc" ;; esac
ptr90r="stale"; [ "$(jq -r '.nonce' "$work/proj/.claude-handoff/latest.json" 2>/dev/null)" = "$n90r" ] && ptr90r="ptr"
usage_transcript "$t90r" 900
o90r4=$(invoke_hook handoff-check.sh "$(stop_input "$sid90r" "$t90r")")
dp90="nodraft"; case "$o90r1" in *"draft.md （完了検証に通ると自動で"*) dp90="draft" ;; esac
ch90="$(out_kind "$o90r1")/$(note90 "$o90r1")/$dp90/$cr90r1/$(out_kind "$o90r2")/$cr90r2/$(out_kind "$o90r3")/$st90r/$ptr90r/$(out_kind "$o90r4")"
# fl: 打ち切りでも持ち越しは残る（このセッションには下書きも資料も無いので完了検証は必ずNG）
sid90f="90909090-9999-aaaa-bbbb-cccccccccccc"
t90f="$troot/t90f.jsonl"
usage_transcript "$t90f" 450
printf '{"schema_version":1,"mode":"hard","nonce":"nonce-t90f-00000001","attempts":3,"completed":false,"failed":false,"completed_nonce":"nonce-t90f-00000000","completed_tokens":250,"completed_epoch":1700000000}' > "$t90f.handoff-state.json"
invoke_hook handoff-check.sh "$(stop_input "$sid90f" "$t90f")" > /dev/null
fl90=$(jq -r '(if .failed == true then "failed" else "open" end) + "/" + .completed_nonce + "/"
              + (.completed_tokens | tostring) + "/" + (.completed_epoch | tostring)' "$t90f.handoff-state.json" 2>/dev/null)
printf 'C90 a=%s b=%s hh=%s c=%s ls=%s lh=%s flt=%s exp=%s bad=%s dr=%s fb=%s mf=%s pr=%s ro=%s mfh=%s ch=%s fl=%s\n' "$a90" "$b90" "$hh90" "$c90" "$ls90" "$lh90" "$flt90" "$exp90" "$bad90" "$dr90" "$fb90" "$mf90" "$pr90" "$ro90" "$mfh90" "$ch90" "$fl90"

# C91: 復元の期待挙動の表（設計メモ §7 の案Cの列）と鮮度表示。
# 経路: R1=compact・ポインタが自セッション / R2=compact・ポインタが無効か別セッション（状態ファイルで検証）/
#       C1=clear・ポインタ経由。clear はポインタを消費するので、C1 のあとの compact は R2 になる。
# 各マスは「注入した資料（old=書き直し前 / new=書き直し後 / none=注入しない）+ 鮮度行の種類
# （full=経過と使用量 / time=経過のみ / nofresh）」。none のときは拒否理由（sha / marker / info / other）。
#   s1: 資料A完成・書き換えなし。R1 は鮮度行の全文と位置（見出し→鮮度行→本文・1回だけ）・状態ファイル削除も見る。
#       C1 は clear の文言（圧縮要約を含まない）の全文。R2 は C1 のあと
#   s2: 書き直し指示中・下書きは書きかけ（構造NG）。R1 / C1 / R2 とも old（S2とS3をまとめて見る）
#   s4: 書き直しの下書きは検証を通る状態だが、まだStopしていない。C1 / R2 とも old
#   s5: 書き直しが3回失敗して打ち切り（failed）。C1 / R2 とも old
#   s6: 書き直しが検証済み。C1 / R2 とも new
#   s7: 2サイクル目（圧縮で状態ファイルは削除済み）に新しい指示が出て下書きが書きかけ。R1 / C1 は old で、鮮度行は
#       ポインタの時刻から経過のみ。R2 は none（非目標: 信頼できる nonce 源が無い）
#   s8: 初回サイクル（前の資料が無い）でハード指示が出て下書きが書きかけ・current.md は無い・ポインタは別セッション。
#       R1/R2 とも他セッションの資料に置き換えず、自セッションに解決して「見つからない」＋自セッションのバックアップ導線（HEAD と同じ）。
#       PreCompact の保存ありとなしの2通り（なしでも無言にしない）
#   pe: 書き直し指示中にモデルが current.md を直接書き換えた（マーカーは旧nonceのまま）→ C1 / R2 とも none（SHA不一致）
#   ce: 完了状態のまま current.md を書き換えた → C1 / R2 とも none（SHA不一致。R2 は HEAD では注入していた — 意図的な変更）
#   other : R1（ポインタは自セッション）で、状態のnonceが資料のnonceと違う → old。鮮度行の値は状態から取らず、
#           ポインタの時刻から経過のみ（I4: 別の記録の値をこの資料の値として出さない）
#   legacy: 新キーの無い完了状態（v0.2.0以前）で R2（ポインタは別セッション）→ old・鮮度行なし
#   bs: 完了状態の completed_sha256 が形式外 → R2 で none:sha（キーがあるのに形式外なら照合を飛ばさない）
# 時刻はテスト用シーム HANDOFF_TEST_NOW_EPOCH で固定する
grow91() { # $1=transcript $2=tokens。usage行を追記する（checkは起動しない）
    printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}\n' "$2" >> "$1"
}
dir91() { # $1=sid
    printf '%s' "$work/proj/.claude-handoff/$1"
}
done91() { # $1=sid $2=transcript $3=nonce。ソフト指示の状態から、下書きを書いてStop（current.md へ置き換わって完了）
    usage_transcript "$2" 250
    soft_state90 "$2" "$3"
    doc90 "$(dir91 "$1")/draft.md" "$3"
    invoke_hook handoff-check.sh "$(stop_input "$1" "$2")" > /dev/null
}
refresh91() { # $1=sid $2=transcript。使用量450でStop（書き直し指示）。新しいnonceを出力する
    grow91 "$2" 450
    invoke_hook handoff-check.sh "$(stop_input "$1" "$2")" > /dev/null
    jq -r '.nonce' "$2.handoff-state.json" 2>/dev/null
}
partial91() { # $1=sid $2=nonce。構造NGの下書き（書きかけ）
    mkdir -p "$(dir91 "$1")"
    sed "s/{{NONCE}}/$2/" "$fixtures/md/bad-handoff.md.tmpl" > "$(dir91 "$1")/draft.md"
}
restore91() { # $1=sid $2=transcript $3=source
    invoke_hook handoff-restore.sh "$(jq -n --arg sid "$1" --arg tp "$2" --arg cwd "$work/proj" --arg src "$3" \
        '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "SessionStart", source: $src}')"
}
clear91() { # 新しいセッションとして clear
    restore91 "91919191-ffff-ffff-ffff-ffffffffffff" "$troot/new91.jsonl" clear
}
cell91() { # $1=output $2=旧資料のnonce $3=新資料のnonce
    _c91=$(printf '%s' "$1" | tr -d '\r')
    _d91="none"
    case "$_c91" in *"handoff-complete: $2 -->"*) _d91="old" ;; esac
    [ -n "$3" ] && case "$_c91" in *"handoff-complete: $3 -->"*) _d91="new" ;; esac
    if [ "$_d91" = "none" ]; then
        case "$_c91" in
            *"SHA-256不一致"*) printf 'none:sha' ;;
            *"完了検証NG"*) printf 'none:marker' ;;
            *"検証情報なし"*) printf 'none:info' ;;
            *) printf 'none:other' ;;
        esac
        return
    fi
    case "$_c91" in
        *"※ 資料の鮮度: "*"完成時の使用量"*) printf '%s+full' "$_d91" ;;
        *"※ 資料の鮮度: 完成から"*) printf '%s+time' "$_d91" ;;
        *) printf '%s+nofresh' "$_d91" ;;
    esac
}
layout91() { # $1=output $2=期待する鮮度行 → yes/no（見出し→鮮度行→本文の並びで、鮮度行はちょうど1回）
    # Windows の jq -r は行末をCRLFで出すので、CRを除いてから並びを見る（PS版はLFで連結済み）
    _o91=$(printf '%s' "$1" | tr -d '\r')
    _nl91='
'
    _rest91=${_o91#*資料の鮮度}
    case "$_rest91" in *"資料の鮮度"*) printf 'no'; return ;; esac
    case "$_o91" in
        *"検証済み）${_nl91}${_nl91}${2}${_nl91}${_nl91}# Handoff: parity test"*) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}
HANDOFF_TEST_NOW_EPOCH=1700000000
export HANDOFF_TEST_NOW_EPOCH
# s1
sid91a="91919191-1111-1111-1111-111111111111"; t91a="$troot/t91a.jsonl"
done91 "$sid91a" "$t91a" "nonce-t91a-00000000"
grow91 "$t91a" 380
HANDOFF_TEST_NOW_EPOCH=1700005430
o91=$(restore91 "$sid91a" "$t91a" compact)
s1r1=$(layout91 "$o91" "※ 資料の鮮度: 完成から1時間30分経過 / 完成時の使用量 250 → 復元直前 380（+130）。完成後に行った作業はこの資料に含まれていないため、圧縮要約・git状態・直近のユーザーメッセージと突き合わせて現状を確認すること。")
[ -f "$t91a.handoff-state.json" ] && s1r1="$s1r1/kept" || s1r1="$s1r1/deleted"
HANDOFF_TEST_NOW_EPOCH=1700000000
sid91b="91919191-2222-2222-2222-222222222222"; t91b="$troot/t91b.jsonl"
done91 "$sid91b" "$t91b" "nonce-t91b-00000000"
grow91 "$t91b" 300
HANDOFF_TEST_NOW_EPOCH=1700000300
o91=$(clear91)
s1c1=$(layout91 "$o91" "※ 資料の鮮度: 完成から5分経過 / 完成時の使用量 250 → 復元直前 300（+50）。完成後に行った作業はこの資料に含まれていないため、git状態・直近のユーザーメッセージと突き合わせて現状を確認すること。")
s1r2=$(cell91 "$(restore91 "$sid91b" "$t91b" compact)" "nonce-t91b-00000000" "")
# s2（S2+S3）
HANDOFF_TEST_NOW_EPOCH=1700000000
sid91c="91919191-3333-3333-3333-333333333333"; t91c="$troot/t91c.jsonl"
done91 "$sid91c" "$t91c" "nonce-t91c-00000000"
n91c=$(refresh91 "$sid91c" "$t91c")
partial91 "$sid91c" "$n91c"
s2r1=$(cell91 "$(restore91 "$sid91c" "$t91c" compact)" "nonce-t91c-00000000" "$n91c")
sid91d="91919191-4444-4444-4444-444444444444"; t91d="$troot/t91d.jsonl"
done91 "$sid91d" "$t91d" "nonce-t91d-00000000"
n91d=$(refresh91 "$sid91d" "$t91d")
partial91 "$sid91d" "$n91d"
s2c1=$(cell91 "$(clear91)" "nonce-t91d-00000000" "$n91d")
s2r2=$(cell91 "$(restore91 "$sid91d" "$t91d" compact)" "nonce-t91d-00000000" "$n91d")
# s4
sid91e="91919191-5555-5555-5555-555555555555"; t91e="$troot/t91e.jsonl"
done91 "$sid91e" "$t91e" "nonce-t91e-00000000"
n91e=$(refresh91 "$sid91e" "$t91e")
doc90 "$(dir91 "$sid91e")/draft.md" "$n91e"
s4c1=$(cell91 "$(clear91)" "nonce-t91e-00000000" "$n91e")
s4r2=$(cell91 "$(restore91 "$sid91e" "$t91e" compact)" "nonce-t91e-00000000" "$n91e")
# s5
sid91f="91919191-6666-6666-6666-666666666666"; t91f="$troot/t91f.jsonl"
done91 "$sid91f" "$t91f" "nonce-t91f-00000000"
refresh91 "$sid91f" "$t91f" > /dev/null
invoke_hook handoff-check.sh "$(stop_input "$sid91f" "$t91f")" > /dev/null
invoke_hook handoff-check.sh "$(stop_input "$sid91f" "$t91f")" > /dev/null
invoke_hook handoff-check.sh "$(stop_input "$sid91f" "$t91f")" > /dev/null
s5st=$(jq -r 'if .failed == true then "failed" else "open" end' "$t91f.handoff-state.json" 2>/dev/null)
s5c1=$(cell91 "$(clear91)" "nonce-t91f-00000000" "")
s5r2=$(cell91 "$(restore91 "$sid91f" "$t91f" compact)" "nonce-t91f-00000000" "")
# s6
sid91g="91919191-7777-7777-7777-777777777777"; t91g="$troot/t91g.jsonl"
done91 "$sid91g" "$t91g" "nonce-t91g-00000000"
n91g=$(refresh91 "$sid91g" "$t91g")
doc90 "$(dir91 "$sid91g")/draft.md" "$n91g"
invoke_hook handoff-check.sh "$(stop_input "$sid91g" "$t91g")" > /dev/null
grow91 "$t91g" 500
s6c1=$(cell91 "$(clear91)" "nonce-t91g-00000000" "$n91g")
s6r2=$(cell91 "$(restore91 "$sid91g" "$t91g" compact)" "nonce-t91g-00000000" "$n91g")
# s7: 1サイクル目を圧縮で終える → 新しいソフト指示 → 書きかけの下書き
sid91h="91919191-8888-8888-8888-888888888888"; t91h="$troot/t91h.jsonl"
done91 "$sid91h" "$t91h" "nonce-t91h-00000000"
restore91 "$sid91h" "$t91h" compact > /dev/null
usage_transcript "$t91h" 250
invoke_hook handoff-check.sh "$(stop_input "$sid91h" "$t91h")" > /dev/null
partial91 "$sid91h" "$(jq -r '.nonce' "$t91h.handoff-state.json" 2>/dev/null)"
HANDOFF_TEST_NOW_EPOCH=1700000600
s7r1=$(cell91 "$(restore91 "$sid91h" "$t91h" compact)" "nonce-t91h-00000000" "")
HANDOFF_TEST_NOW_EPOCH=1700000000
sid91i="91919191-9999-9999-9999-999999999999"; t91i="$troot/t91i.jsonl"
done91 "$sid91i" "$t91i" "nonce-t91i-00000000"
restore91 "$sid91i" "$t91i" compact > /dev/null
usage_transcript "$t91i" 250
invoke_hook handoff-check.sh "$(stop_input "$sid91i" "$t91i")" > /dev/null
partial91 "$sid91i" "$(jq -r '.nonce' "$t91i.handoff-state.json" 2>/dev/null)"
HANDOFF_TEST_NOW_EPOCH=1700000600
s7c1=$(cell91 "$(clear91)" "nonce-t91i-00000000" "")
s7r2=$(cell91 "$(restore91 "$sid91i" "$t91i" compact)" "nonce-t91i-00000000" "")
# pe / ce
HANDOFF_TEST_NOW_EPOCH=1700000000
sid91j="91919191-aaaa-aaaa-aaaa-aaaaaaaaaaaa"; t91j="$troot/t91j.jsonl"
done91 "$sid91j" "$t91j" "nonce-t91j-00000000"
refresh91 "$sid91j" "$t91j" > /dev/null
sed "s/機能Yの実装が残っている/PARTIAL-REWRITE/" "$(dir91 "$sid91j")/current.md" > "$t91j.tmp" && mv -f "$t91j.tmp" "$(dir91 "$sid91j")/current.md"
pec1=$(cell91 "$(clear91)" "nonce-t91j-00000000" "")
per2=$(cell91 "$(restore91 "$sid91j" "$t91j" compact)" "nonce-t91j-00000000" "")
sid91k="91919191-bbbb-bbbb-bbbb-bbbbbbbbbbbb"; t91k="$troot/t91k.jsonl"
done91 "$sid91k" "$t91k" "nonce-t91k-00000000"
sed "s/機能Yの実装が残っている/EDITED-AFTER-DONE/" "$(dir91 "$sid91k")/current.md" > "$t91k.tmp" && mv -f "$t91k.tmp" "$(dir91 "$sid91k")/current.md"
cec1=$(cell91 "$(clear91)" "nonce-t91k-00000000" "")
cer2=$(cell91 "$(restore91 "$sid91k" "$t91k" compact)" "nonce-t91k-00000000" "")
# other（R1）→ legacy（ポインタを別セッションにしてから R2）
sid91o="91919191-dddd-dddd-dddd-dddddddddddd"; t91o="$troot/t91o.jsonl"
done91 "$sid91o" "$t91o" "nonce-t91o-00000000"
jq '.nonce = "nonce-t91o-99999999"' "$t91o.handoff-state.json" > "$t91o.tmp" && mv -f "$t91o.tmp" "$t91o.handoff-state.json"
other91=$(cell91 "$(restore91 "$sid91o" "$t91o" compact)" "nonce-t91o-00000000" "")
sid91l="91919191-cccc-cccc-cccc-cccccccccccc"; t91l="$troot/t91l.jsonl"
done91 "$sid91l" "$t91l" "nonce-t91l-00000000"
jq 'del(.completed_tokens, .completed_epoch, .completed_sha256)' "$t91l.handoff-state.json" > "$t91l.tmp" && mv -f "$t91l.tmp" "$t91l.handoff-state.json"
done91 "91919191-eeee-eeee-eeee-eeeeeeeeeeee" "$troot/t91z.jsonl" "nonce-t91z-00000000"
legacy91=$(cell91 "$(restore91 "$sid91l" "$t91l" compact)" "nonce-t91l-00000000" "")
# s8: 初回サイクルの書きかけ（ポインタは直前の legacy で作った別セッションのもの）
HANDOFF_TEST_NOW_EPOCH=1700000000
s8cell91() { # $1=output $2=別セッション資料のnonce
    _c91=$(printf '%s' "$1" | tr -d '\r')
    case "$_c91" in
        *"handoff-complete: $2 -->"*) printf 'other' ;;
        *"current.md: 見つからない"*) printf 'missing' ;;
        *) [ -z "$(printf '%s' "$_c91" | tr -d '[:space:]')" ] && printf 'silent' || printf 'else' ;;
    esac
    case "$_c91" in *"## 全文バックアップ導線"*"$3"*) printf '+backup' ;; esac
}
sid91s="91919191-5858-5858-5858-585858585858"; t91s="$troot/t91s.jsonl"
usage_transcript "$t91s" 450
invoke_hook handoff-check.sh "$(stop_input "$sid91s" "$t91s")" > /dev/null
partial91 "$sid91s" "$(jq -r '.nonce' "$t91s.handoff-state.json" 2>/dev/null)"
invoke_hook handoff-save.sh "$(jq -n --arg sid "$sid91s" --arg tp "$t91s" --arg cwd "$work/proj" \
    '{session_id: $sid, transcript_path: $tp, cwd: $cwd, hook_event_name: "PreCompact", trigger: "auto"}')" > /dev/null
s8b91=$(s8cell91 "$(restore91 "$sid91s" "$t91s" compact)" "nonce-t91z-00000000" "$sid91s")
sid91t="91919191-5959-5959-5959-595959595959"; t91t="$troot/t91t.jsonl"
usage_transcript "$t91t" 450
invoke_hook handoff-check.sh "$(stop_input "$sid91t" "$t91t")" > /dev/null
partial91 "$sid91t" "$(jq -r '.nonce' "$t91t.handoff-state.json" 2>/dev/null)"
s8n91=$(s8cell91 "$(restore91 "$sid91t" "$t91t" compact)" "nonce-t91z-00000000" "$sid91t")
# bs: 完了状態の completed_sha256 が形式外（手で壊した）→ R2 で照合を飛ばさず拒否（sh/PS 同一）
sid91m="91919191-5a5a-5a5a-5a5a-5a5a5a5a5a5a"; t91m="$troot/t91m.jsonl"
done91 "$sid91m" "$t91m" "nonce-t91m-00000000"
jq '.completed_sha256 = "abc"' "$t91m.handoff-state.json" > "$t91m.tmp" && mv -f "$t91m.tmp" "$t91m.handoff-state.json"
done91 "91919191-eeee-eeee-eeee-eeeeeeeeeeee" "$troot/t91z.jsonl" "nonce-t91z-00000000"
bs91=$(cell91 "$(restore91 "$sid91m" "$t91m" compact)" "nonce-t91m-00000000" "")
unset HANDOFF_TEST_NOW_EPOCH
printf 'C91 s1=%s/%s/%s s2=%s/%s/%s s4=%s/%s s5=%s/%s/%s s6=%s/%s s7=%s/%s/%s s8=%s/%s pe=%s/%s ce=%s/%s legacy=%s other=%s bs=%s\n' \
    "$s1r1" "$s1c1" "$s1r2" "$s2r1" "$s2c1" "$s2r2" "$s4c1" "$s4r2" "$s5st" "$s5c1" "$s5r2" "$s6c1" "$s6r2" \
    "$s7r1" "$s7c1" "$s7r2" "$s8b91" "$s8n91" "$pec1" "$per2" "$cec1" "$cer2" "$legacy91" "$other91" "$bs91"

# C92: 鮮度行の整形の境界（共通ヘルパーを直接呼ぶ。v0.2.1）。
#   lt1/m59/h1: 59秒=1分未満 / 3599秒=59分 / 3600秒=1時間0分
#   past  : 現在時刻が完成時刻より前（時計のずれ）なら経過を出さない → 材料が無く空
#   shrink: 復元直前の使用量が完成時より小さければ伸びを出さない → 空
#   zero  : 復元直前の使用量が0（測れなかった）なら伸びを出さない → 空
#   huge  : 復元直前の使用量が上限（1,000,000,000）を超えたら伸びを出さない → 空
#   big   : 18桁のepochでも整数のまま割る（doubleを経由すると丸まってshと割れる）
#   compact/clear: 文言の全文一致（clearは「圧縮要約」を含まない）
exact92() { # $1=actual $2=expected
    if [ "$1" = "$2" ]; then printf 'yes'; else printf 'no'; fi
}
empty92() { # $1=actual
    if [ -z "$1" ]; then printf 'empty'; else printf 'nonempty'; fi
}
has92() { # $1=actual $2=needle
    case "$1" in *"$2"*) printf 'yes' ;; *) printf 'no' ;; esac
}
lt192=$(has92 "$(ho_freshness_line 1000 1059 "" "" compact)" "完成から1分未満経過")
m5992=$(has92 "$(ho_freshness_line 1000 4599 "" "" compact)" "完成から59分経過")
h192=$(has92 "$(ho_freshness_line 1000 4600 "" "" compact)" "完成から1時間0分経過")
past92=$(empty92 "$(ho_freshness_line 1000 999 "" "" compact)")
shrink92=$(empty92 "$(ho_freshness_line "" "" 500 400 compact)")
zero92=$(empty92 "$(ho_freshness_line "" "" 1 0 compact)")
huge92=$(empty92 "$(ho_freshness_line "" "" 1 1000000001 compact)")
big92=$(has92 "$(ho_freshness_line 1 999999999999999961 "" "" compact)" "完成から277777777777777時間46分経過")
compact92=$(exact92 "$(ho_freshness_line "" "" 250 380 compact)" "※ 資料の鮮度: 完成時の使用量 250 → 復元直前 380（+130）。完成後に行った作業はこの資料に含まれていないため、圧縮要約・git状態・直近のユーザーメッセージと突き合わせて現状を確認すること。")
clear92=$(exact92 "$(ho_freshness_line 1000 1300 250 300 clear)" "※ 資料の鮮度: 完成から5分経過 / 完成時の使用量 250 → 復元直前 300（+50）。完成後に行った作業はこの資料に含まれていないため、git状態・直近のユーザーメッセージと突き合わせて現状を確認すること。")
printf 'C92 lt1=%s m59=%s h1=%s past=%s shrink=%s zero=%s huge=%s big=%s compact=%s clear=%s\n' "$lt192" "$m5992" "$h192" "$past92" "$shrink92" "$zero92" "$huge92" "$big92" "$compact92" "$clear92"
fi

# KEEP_WORK=1 で作業ディレクトリを残す（失敗ケースの成果物調査用。issue #16）
if [ -z "${KEEP_WORK:-}" ]; then
    rm -rf "$work"
else
    printf 'KEEP_WORK: 作業ディレクトリを残しました: %s\n' "$work" >&2
fi

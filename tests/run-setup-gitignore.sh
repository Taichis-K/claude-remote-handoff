#!/bin/sh
# run-setup-gitignore.sh - setupの.gitignore追記の同値判定・冪等性を検証する（issue #25）
# run-setup-gitignore.ps1 と同一ケース・同一出力形式（詳細コメントはps版参照）
set -u

tests_dir=$(cd "$(dirname "$0")" && pwd)
setup="$tests_dir/../setup/setup.sh"
work="${1:-}"
if [ -z "$work" ]; then
    work=$(mktemp -d "${TMPDIR:-/tmp}/handoff-setupgi-sh-XXXXXX") || exit 1
else
    # 誤指定された既存ディレクトリを巻き添え削除しないため、新規作成のみ許可
    if [ -e "$work" ]; then
        printf 'NG: 作業ディレクトリには存在しないパスを指定すること: %s\n' "$work" >&2
        exit 1
    fi
    mkdir -p "$work" || exit 1
fi
export HANDOFF_SETUP_SKIP_CLAUDE_CHECK=1
NBSP=$(printf '\302\240')
BOM=$(printf '\357\273\277')

new_proj() { # $1=name $2=bom(1/0) 残り=gitignore行（無ければ.gitignoreなし）
    _d="$work/$1"; _bom="$2"; shift 2
    mkdir -p "$_d"
    git init -q "$_d"
    if [ "$#" -gt 0 ]; then
        : > "$_d/.gitignore"
        [ "$_bom" = "1" ] && printf '%s' "$BOM" >> "$_d/.gitignore"
        for _l in "$@"; do printf '%s\n' "$_l" >> "$_d/.gitignore"; done
    fi
    printf '%s' "$_d"
}
invoke_setup() { # $1=dir → "ok rec"
    if _out=$(sh "$setup" 160000 120000 135000 10000 92 "$1" 2>&1); then _ok=1; else _ok=0; fi
    # 推奨メッセージはsetupが付ける専用マーカーの固定文字列一致で検出（ps版と同一契約）
    if printf '%s\n' "$_out" | grep -F -q '[HANDOFF-RECOMMEND-GLOB]'; then
        _rec=1
    else
        _rec=0
    fi
    printf '%s %s' "$_ok" "$_rec"
}
report() { # $1=case $2=dir $3="ok rec"
    _gi="$2/.gitignore"
    _ok2=${3% *}; _rec2=${3#* }
    _count=0; _starred=0
    if [ -f "$_gi" ]; then
        _count=$(awk -v bom="$BOM" '{ t = $0; if (NR == 1 && index(t, bom) == 1) t = substr(t, length(bom) + 1); gsub(/^[ \t\r]+|[ \t\r]+$/, "", t); if (length(t) > 0) n++ } END { print n + 0 }' "$_gi")
        # LC_ALL=C: macOSのBWK awkの==はUTF-8ロケールでstrcoll()になり照合上無視可能な文字で誤一致する
        if LC_ALL=C awk -v bom="$BOM" '{ t = $0; if (NR == 1 && index(t, bom) == 1) t = substr(t, length(bom) + 1); gsub(/^[ \t\r]+|[ \t\r]+$/, "", t); if (t == ".claude/settings.local.json*") { found = 1; exit } } END { exit !found }' "$_gi"; then
            _starred=1
        fi
    fi
    _config=0
    [ -f "$2/.claude/handoff-config.json" ] && _config=1
    printf '%s exit=%s lines=%s starred=%s rec=%s config=%s\n' "$1" "$_ok2" "$_count" "$_starred" "$_rec2" "$_config"
    # 全行を順序込みで出力（非ASCIIは連続1回ごと ? へ正規化 — byte指向awkとchar指向の
    # PS/gawkで置換数が割れないよう、連続をまとめて置換する）
    if [ -f "$_gi" ]; then
        awk -v c="$1" -v bom="$BOM" '{ t = $0; if (NR == 1 && index(t, bom) == 1) t = substr(t, length(bom) + 1); gsub(/^[ \t\r]+|[ \t\r]+$/, "", t); gsub(/[^ -~]+/, "?", t); if (length(t) > 0) printf "%sL %s\n", c, t }' "$_gi"
    fi
}

# S1: .gitignoreなし → 4エントリすべて追記される
d1=$(new_proj s1 0)
report "S1" "$d1" "$(invoke_setup "$d1")"

# S2: 4エントリ完全一致が既にある → 追記なし（冪等）
d2=$(new_proj s2 0 ".claude-handoff/" ".claude/handoff-config.json" ".claude/hooks/claude-remote-handoff/" ".claude/settings.local.json*")
report "S2" "$d2" "$(invoke_setup "$d2")"

# S3: 同値形の既存行（dirの/なし・タブ囲みのdir/*・fileの*付き・globの*なし）→ 追記なし。
# 既存の*なしsettings行は書き換えない（*付きへの更新推奨のみ提示 → rec=1）ため starred=0 のまま
tab=$(printf '\t')
d3=$(new_proj s3 0 ".claude-handoff" "${tab}.claude/hooks/claude-remote-handoff/*${tab}" ".claude/handoff-config.json*" ".claude/settings.local.json")
report "S3" "$d3" "$(invoke_setup "$d3")"

# S4: 同値でない行（コメント・否定・大小違い・ファイル項目への末尾/・U+00A0前置・
# U+00AD前置）→ 4エントリすべて追記される（U+00A0は空白としてtrimしない契約。
# U+00ADはカルチャ比較/strcollだと無視されて誤同値になる罠の回帰検出。7行+4行=11行）
SHY=$(printf '\302\255')
d4=$(new_proj s4 0 "# .claude-handoff/" "!.claude-handoff/" ".CLAUDE-HANDOFF/" ".claude/settings.local.json/" ".claude/handoff-config.json/" "${NBSP}.claude-handoff/" "${SHY}.claude-handoff/")
report "S4" "$d4" "$(invoke_setup "$d4")"

# S5: S3のプロジェクトへ再実行 → 変化なし（冪等。推奨表示は再度出る → rec=1）
report "S5" "$d3" "$(invoke_setup "$d3")"

# S6: UTF-8 BOM付き.gitignore + 完全一致4行 → 追記なし（sh版のBOM除去の回帰を検出）
d6=$(new_proj s6 1 ".claude-handoff/" ".claude/handoff-config.json" ".claude/hooks/claude-remote-handoff/" ".claude/settings.local.json*")
report "S6" "$d6" "$(invoke_setup "$d6")"

# S7: HANDOFF_SETUP_SKIP_CLAUDE_CHECK が "1"+U+00AD ならバージョン確認はスキップされない
# （shのtestは元からバイト厳密。PS版Ordinal化との契約一致をここで固定する）。
# PATH先頭に旧バージョン(0.0.1)を返すclaudeシムを置き、確認が実行されれば最低要求未満で
# 失敗（exit=0・config/gitignore未生成）になることをclaude CLIの有無に依らず検証する
shim="$work/shim"
mkdir -p "$shim"
printf '#!/bin/sh\necho 0.0.1\n' > "$shim/claude"
chmod +x "$shim/claude"
d7=$(new_proj s7 0)
old_path=$PATH
PATH="$shim:$PATH"
HANDOFF_SETUP_SKIP_CLAUDE_CHECK="1$(printf '\302\255')"
export HANDOFF_SETUP_SKIP_CLAUDE_CHECK
report "S7" "$d7" "$(invoke_setup "$d7")"
PATH=$old_path
HANDOFF_SETUP_SKIP_CLAUDE_CHECK=1
export HANDOFF_SETUP_SKIP_CLAUDE_CHECK

# S8: floor境界（window=2053, pct=20 → 発火点410.6 → floor 410 <= hard 400+margin 10）は
# 静的検証NGで拒否・何も書かない（PS版setupの丸め退行を検出 — issue #32。詳細はps版参照）
d8=$(new_proj s8 0)
if _out8=$(sh "$setup" 2053 200 400 10 20 "$d8" 2>&1); then _ok8=1; else _ok8=0; fi
if printf '%s\n' "$_out8" | grep -F -q '[HANDOFF-RECOMMEND-GLOB]'; then _rec8=1; else _rec8=0; fi
report "S8" "$d8" "$_ok8 $_rec8"

if [ -z "${KEEP_WORK:-}" ]; then
    rm -rf "$work"
else
    printf 'KEEP_WORK: %s\n' "$work" >&2
fi

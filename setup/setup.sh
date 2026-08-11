#!/bin/sh
# setup.sh - インストール補助スクリプト（sh版・jq必須）。setup.ps1 と同一手順
# 使い方（対象プロジェクトのルートで実行）:
#   sh setup.sh [window] [soft] [hard] [min_margin] [pct] [project_dir]
#   例: sh setup.sh 160000 120000 135000
set -u

WINDOW="${1:-160000}"
SOFT="${2:-120000}"
HARD="${3:-135000}"
MARGIN="${4:-10000}"
PCT="${5:-92}"
PROJ="${6:-.}"
MIN_VERSION="2.1.163"
# 4エントリとも「マシン/環境固有」でコミット対象外（setup.ps1と同一。詳細はps版コメント参照）
IGNORE_ENTRIES=".claude-handoff/
.claude/handoff-config.json
.claude/hooks/claude-remote-handoff/
.claude/settings.local.json*"
# UTF-8 BOM（PS 5.1のSet-Content/Add-Content -Encoding UTF8が.gitignore作成時に付け得る）。
# PS版のGet-ContentはBOMを自動除去するため、sh版も先頭行から除去しないと判定が分裂し
# 重複追記が起きる（codexレビュー issue23-28 2回目 M2）
BOM_CHAR=$(printf '\357\273\277')

fail() { printf 'NG: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq が見つかりません。sh版はjq必須です（brew install jq / apt install jq 等）"
PROJ=$(cd "$PROJ" 2>/dev/null && pwd) || fail "プロジェクトディレクトリが見つかりません"
printf '対象プロジェクト: %s\n' "$PROJ"

# --- 1. Claude Codeバージョン確認 ---
if [ "${HANDOFF_SETUP_SKIP_CLAUDE_CHECK:-}" = "1" ]; then
    # テスト用（claude CLIが無い環境でgitignore/設定生成ロジックを試験するため）。通常は使わない
    printf 'SKIP: Claude Codeバージョン確認（HANDOFF_SETUP_SKIP_CLAUDE_CHECK=1）\n'
else
    ver=$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [ -n "$ver" ] || fail "claude コマンドが見つからないかバージョンを特定できません"
    newer=$(printf '%s\n%s\n' "$MIN_VERSION" "$ver" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
    [ "$newer" = "$ver" ] || fail "Claude Code $ver は最低要求 $MIN_VERSION 未満です。アップデートしてください"
    printf 'OK: Claude Code %s（>= %s）\n' "$ver" "$MIN_VERSION"
fi

# --- 2. 閾値ペアの静的検証 → handoff-config.json 書き込み ---
for v in "$WINDOW" "$SOFT" "$HARD" "$MARGIN" "$PCT"; do
    printf '%s' "$v" | grep -Eq '^[0-9]+$' || fail "数値でない引数があります: $v"
done
[ "$SOFT" -gt 0 ] && [ "$HARD" -gt 0 ] && [ "$SOFT" -le "$HARD" ] || fail "閾値が不正です: soft($SOFT) <= hard($HARD) かつ両方正の値にしてください"
[ "$PCT" -ge 1 ] && [ "$PCT" -le 100 ] || fail "発火%は1-100にしてください"
# フック側の実行時検証と同じ上限（1e9）。ここで通してもフックが設定全体を拒否するため、
# 生成側でも同じ契約で弾く（codexレビュー4回目 M3）
MAX_TOKEN=1000000000
[ "$WINDOW" -gt 0 ] 2>/dev/null || fail "windowは正の値にしてください"
for v in "$WINDOW" "$SOFT" "$HARD" "$MARGIN"; do
    [ "$v" -le "$MAX_TOKEN" ] 2>/dev/null || fail "数値が上限 $MAX_TOKEN を超えています: ${v}（フック側の実行時検証と同じ上限。超えた設定は実行時に全体が拒否されます）"
done
fire_point=$((WINDOW * PCT / 100))
if [ $((HARD + MARGIN)) -ge "$fire_point" ]; then
    printf '静的検証NG:\n  ハード閾値(%s) + 最低マージン(%s) >= 発火点(%s = window %s x %s%%)\n' "$HARD" "$MARGIN" "$fire_point" "$WINDOW" "$PCT" >&2
    printf '  この組合せではhandoff作成がauto compactに間に合わない可能性があるため、設定を書き込みません。\n' >&2
    printf '  閾値を下げるか、autocompact値を上げてください（例: /autocompact %s 以上）\n' "$((HARD * 125 / 100))" >&2
    printf '  この window(%s)・margin(%s)・pct(%s) のままなら、ハード閾値は最大 %s まで設定できます\n' "$WINDOW" "$MARGIN" "$PCT" "$((fire_point - MARGIN - 1))" >&2
    exit 1
fi
printf 'OK: 静的検証（hard %s + margin %s < 発火点 %s）\n' "$HARD" "$MARGIN" "$fire_point"
printf '  注意: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 環境変数で発火点は下がり得ます（フックは有効な環境変数、無ければ設定値で毎Stop再検証し、満たさない場合は機能を無効化します）\n'

mkdir -p "$PROJ/.claude" || fail ".claudeディレクトリを作成できません"
# 既存設定を直接truncateしない: 一時ファイルへ生成→JSON妥当性を再確認→atomic rename
# （jq失敗・容量不足・権限拒否で既存の有効な設定を壊さないため）
cfg_tmp="$PROJ/.claude/.handoff-config.$$.tmp"
if ! jq -n --argjson w "$WINDOW" --argjson s "$SOFT" --argjson h "$HARD" --argjson m "$MARGIN" --argjson p "$PCT" \
    '{autocompact_window: $w, soft_threshold: $s, hard_threshold: $h, min_margin: $m, conservative_fire_pct: $p}' \
    > "$cfg_tmp" 2>/dev/null; then
    rm -f "$cfg_tmp"
    fail "設定JSONの生成に失敗しました（jqエラーまたは書き込み失敗）"
fi
jq -e . "$cfg_tmp" >/dev/null 2>&1 || { rm -f "$cfg_tmp"; fail "生成した設定JSONが不正です"; }
mv -f "$cfg_tmp" "$PROJ/.claude/handoff-config.json" || { rm -f "$cfg_tmp"; fail "設定の書き込み（rename）に失敗しました"; }
printf 'OK: %s/.claude/handoff-config.json を書き込みました\n' "$PROJ"
printf '  Claude Code側でも autocompact を設定してください: /autocompact %s\n' "$WINDOW"

# --- 3. .gitignore追記（重複チェック・git未導入/リポジトリ外はスキップ） ---
if command -v git >/dev/null 2>&1 && git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    gi="$PROJ/.gitignore"
    printf '%s\n' "$IGNORE_ENTRIES" | while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        # 意味的に同値な既存行も「追記済み」と判定する（ps版と同一契約。issue #25）:
        #   dir/ は dir・dir/* も可 / file は file* も可 / file* は file〔*なし〕も可
        #   〔部分カバー → *付きへの更新を推奨表示〕。ファイル項目への末尾/は
        #   ディレクトリ専用パターンでファイルを無視しないため同値としない。
        # 比較は大小厳密（awkの==）・trimは[ \t\r]のみ（codexレビュー3回目 Low-7のCRLF対応含む）。
        # LC_ALL=C必須: macOSのBWK awkはUTF-8ロケールで==にstrcoll()を使い、U+00A0等の
        # 照合上無視可能な文字を無視して「NBSP前置行 == エントリ」が真になる（CI実測）
        c1=""; c2=""
        case "$entry" in
            */)  bare="${entry%/}"; c1="$bare"; c2="$bare/*" ;;
            *\*) c1="${entry%\*}" ;;
            *)   c1="$entry*" ;;
        esac
        matched=""
        if [ -f "$gi" ]; then
            matched=$(LC_ALL=C awk -v e="$entry" -v a="$c1" -v b="$c2" -v bom="$BOM_CHAR" \
                '{ t=$0; if (NR == 1 && index(t, bom) == 1) t = substr(t, length(bom) + 1); gsub(/^[ \t\r]+|[ \t\r]+$/, "", t); if (t == e || (a != "" && t == a) || (b != "" && t == b)) { print t; exit } }' "$gi")
        fi
        if [ -n "$matched" ]; then
            printf 'OK: .gitignore に %s は追記済み（既存行: %s）\n' "$entry" "$matched"
            # 末尾の [HANDOFF-RECOMMEND-GLOB] はテスト用の機械可読マーカー（ps版と同一契約）
            case "$entry" in
                *\*) [ "$matched" = "$entry" ] || printf '  推奨: 既存行を %s に更新すると、編集時に生成される .bak もカバーされます [HANDOFF-RECOMMEND-GLOB]\n' "$entry" ;;
            esac
        else
            # 末尾に改行が無い場合に備えて追記前に改行を保証する
            [ -f "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ] && printf '\n' >> "$gi"
            printf '%s\n' "$entry" >> "$gi"
            printf 'OK: .gitignore に %s を追記しました\n' "$entry"
        fi
    done
    # 既にtrackedなファイルはgitignoreだけでは外れないため警告（git rm --cached等は自動では行わない）
    for target in .claude-handoff .claude/handoff-config.json .claude/hooks/claude-remote-handoff .claude/settings.local.json; do
        if [ -n "$(git -C "$PROJ" ls-files -- "$target" 2>/dev/null)" ]; then
            extra=""
            [ "$target" = ".claude-handoff" ] && extra="（trackedのままだとバックアップ保存が無効化されます）"
            printf '警告: %s がgit trackedです。gitignoreだけでは外れないため git rm --cached で整理してください%s\n' "$target" "$extra" >&2
        fi
    done
else
    printf 'SKIP: gitリポジトリではない（または git 未導入）ため .gitignore 追記をスキップ\n'
fi

printf '\nセットアップ完了。残りの手動確認:\n'
printf '  1. Claude Codeで /autocompact %s を設定\n' "$WINDOW"
printf '  2. permissions.allow に "Edit(.claude-handoff/**)" を追加（実質必須: 無いとhandoff作成のたびに許可プロンプトで中断。チームで共有するなら .claude/settings.json、共有しないなら .claude/settings.local.json）\n'
printf '  3. このプロジェクトで一度Claude Codeを対話起動しtrustを承認（未trustだと許可ルールが無視されます）\n'
printf '  4. /hooks で5エントリ（PreCompact / SessionStart x3 / Stop）の登録を確認（見えなければClaude Codeを再起動）\n'
exit 0

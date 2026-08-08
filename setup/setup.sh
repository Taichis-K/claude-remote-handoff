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
IGNORE_ENTRY=".claude-handoff/"

fail() { printf 'NG: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq が見つかりません。sh版はjq必須です（brew install jq / apt install jq 等）"
PROJ=$(cd "$PROJ" 2>/dev/null && pwd) || fail "プロジェクトディレクトリが見つかりません"
printf '対象プロジェクト: %s\n' "$PROJ"

# --- 1. Claude Codeバージョン確認 ---
ver=$(claude --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
[ -n "$ver" ] || fail "claude コマンドが見つからないかバージョンを特定できません"
newer=$(printf '%s\n%s\n' "$MIN_VERSION" "$ver" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
[ "$newer" = "$ver" ] || fail "Claude Code $ver は最低要求 $MIN_VERSION 未満です。アップデートしてください"
printf 'OK: Claude Code %s（>= %s）\n' "$ver" "$MIN_VERSION"

# --- 2. 閾値ペアの静的検証 → handoff-config.json 書き込み ---
for v in "$WINDOW" "$SOFT" "$HARD" "$MARGIN" "$PCT"; do
    printf '%s' "$v" | grep -Eq '^[0-9]+$' || fail "数値でない引数があります: $v"
done
[ "$SOFT" -gt 0 ] && [ "$HARD" -gt 0 ] && [ "$SOFT" -le "$HARD" ] || fail "閾値が不正です: soft($SOFT) <= hard($HARD) かつ両方正の値にしてください"
[ "$PCT" -ge 1 ] && [ "$PCT" -le 100 ] || fail "発火%は1-100にしてください"
fire_point=$((WINDOW * PCT / 100))
if [ $((HARD + MARGIN)) -ge "$fire_point" ]; then
    printf '静的検証NG:\n  ハード閾値(%s) + 最低マージン(%s) >= 発火点(%s = window %s x %s%%)\n' "$HARD" "$MARGIN" "$fire_point" "$WINDOW" "$PCT" >&2
    printf '  この組合せではhandoff作成がauto compactに間に合わない可能性があるため、設定を書き込みません。\n' >&2
    exit 1
fi
printf 'OK: 静的検証（hard %s + margin %s < 発火点 %s）\n' "$HARD" "$MARGIN" "$fire_point"
printf '  注意: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 環境変数で発火点は下がり得ます（実行時にもbest-effort再検証されます）\n'

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
    if [ -f "$gi" ] && grep -Eq '^[[:space:]]*\.claude-handoff/?[[:space:]]*$' "$gi"; then
        printf 'OK: .gitignore に %s は追記済み\n' "$IGNORE_ENTRY"
    else
        # 末尾に改行が無い場合に備えて追記前に改行を保証する
        [ -f "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ] && printf '\n' >> "$gi"
        printf '%s\n' "$IGNORE_ENTRY" >> "$gi"
        printf 'OK: .gitignore に %s を追記しました\n' "$IGNORE_ENTRY"
    fi
    if [ -n "$(git -C "$PROJ" ls-files -- .claude-handoff 2>/dev/null)" ]; then
        printf '警告: .claude-handoff 配下にgit trackedなファイルがあります。バックアップが無効化されるため整理してください\n' >&2
    fi
else
    printf 'SKIP: gitリポジトリではない（または git 未導入）ため .gitignore 追記をスキップ\n'
fi

printf '\nセットアップ完了。残りの手動確認:\n'
printf '  1. Claude Codeで /autocompact %s を設定\n' "$WINDOW"
printf '  2. .claude/settings.json の permissions.allow に "Edit(.claude-handoff/**)" を追加推奨\n'
printf '  3. このプロジェクトで一度Claude Codeを対話起動しtrustを承認（未trustだと許可ルールが無視されます）\n'
exit 0

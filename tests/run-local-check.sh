#!/bin/sh
# run-local-check.sh - ローカル検証の一括実行+厳密判定（sh系。要jq）
# GitHub Actions撤去（2026-08-09 ユーザー指示）に伴い、旧ci.ymlにあった期待値照合を
# ローカルへ移植したもの。sh構文検査 / パリティ / setup試験 を実行し、期待値比較は
# EOL（CR）だけ正規化した行単位のbyte厳密比較（diff）。いずれか失敗で exit 1。
# PS系は run-local-check.ps1（PS 5.1 / pwsh の両方）で実行する
# 使い方: sh dist/tests/run-local-check.sh
set -u
tests_dir=$(cd "$(dirname "$0")" && pwd)
fail=0

# 1. sh構文検査
for f in "$tests_dir"/../hooks/sh/*.sh "$tests_dir"/run-parity.sh "$tests_dir"/run-setup-gitignore.sh; do
    if sh -n "$f"; then :; else
        printf 'NG sh -n: %s\n' "$f"
        fail=$((fail + 1))
    fi
done
[ "$fail" -eq 0 ] && printf 'OK sh -n（hooks+runners）\n'

# 出力置き場（TMPDIRの末尾スラッシュはmktemp前に除去 — run-parity.shと同じ理由）。
# cleanupはEXIT trapに集約し、INT/TERMは非0で終了する（削除だけしてシグナルを
# 握り潰すと割り込まれた検証がALL OKで終わり得る — codexレビュー#33追補3回目）
tmpbase="${TMPDIR:-/tmp}"
while [ "${tmpbase%/}" != "$tmpbase" ]; do tmpbase="${tmpbase%/}"; done
tmp=$(mktemp -d "$tmpbase/handoff-localcheck-XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# EOL正規化は「行末のCRのみ」除去する（tr -d は行中のCRまで消し byte厳密でなくなる —
# codexレビュー#33追補2回目 M2）。awkのsub(/\r$/)は行末1個だけを対象にする
normalize_eol() { # $1=in $2=out
    LC_ALL=C awk '{ sub(/\r$/, ""); print }' "$1" > "$2"
}

# awkのprintは終端LFが無い入力にもLFを付けるため、終端改行の有無は正規化前の
# 生ファイルで別途比較する（codexレビュー#33追補3回目）。CRLF終端もLF終端も「1」
ends_lf() { # $1=file → 非空かつ最終バイトがLFなら1、それ以外は0
    if [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \t\n')" = "0a" ]; then
        printf '1'
    else
        printf '0'
    fi
}

check_expected() { # $1=name $2=runner $3=expected
    sh "$2" > "$tmp/$1.out" 2> "$tmp/$1.err"
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
        printf 'NG %s: ランナーがexit %s。stderr:\n' "$1" "$_rc"
        sed 's/^/  /' "$tmp/$1.err" 2>/dev/null | head -50
        fail=$((fail + 1))
        return
    fi
    # 正規化の失敗（awk不在・I/Oエラー等で空ファイル化→diff偽成功）も検出する
    if ! normalize_eol "$3" "$tmp/$1.exp" || ! normalize_eol "$tmp/$1.out" "$tmp/$1.act"; then
        printf 'NG %s: EOL正規化に失敗\n' "$1"
        fail=$((fail + 1))
        return
    fi
    if [ "$(ends_lf "$3")" != "$(ends_lf "$tmp/$1.out")" ]; then
        printf 'NG %s: 終端改行の有無が不一致\n' "$1"
        fail=$((fail + 1))
        return
    fi
    if diff "$tmp/$1.exp" "$tmp/$1.act"; then
        printf 'OK %s\n' "$1"
    else
        printf 'NG %s: 期待値と不一致（上のdiff参照。< 期待値 / > 実測）\n' "$1"
        fail=$((fail + 1))
    fi
}

# 2. パリティ（80ケース） / 3. setup試験（S1〜S8）
check_expected "parity-sh" "$tests_dir/run-parity.sh" "$tests_dir/fixtures/expected/parity-expected.txt"
check_expected "setup-gitignore-sh" "$tests_dir/run-setup-gitignore.sh" "$tests_dir/fixtures/expected/setup-gitignore-expected.txt"

if [ "$fail" -gt 0 ]; then
    printf 'run-local-check(sh): %s 件失敗\n' "$fail"
    exit 1
fi
printf 'run-local-check(sh): ALL OK（PS側は run-local-check.ps1 をPS 5.1/pwshの両方で実行すること）\n'
exit 0

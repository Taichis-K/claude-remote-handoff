# lint-sh.ps1 - sh版の静的検査: 非ASCII文字の直前の裸の変数展開を禁止する
# bash 3.2（macOSの/bin/sh）は `$var` の直後に全角文字等の非ASCII文字が続くと
# 変数値が消えて文字化けする（issue #2で実測）。`${var}` で囲めば発生しない。
# パリティ試験は出力を injected/refused/none 等へ正規化するため本文の破損を検出できず、
# この検査で構造的に再発を防ぐ。行頭コメント行は実行に影響しないため対象外。
# 使い方: pwsh -NoProfile -File dist/tests/lint-sh.ps1  （PS 5.1でも可）
param([string]$DistRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = "Stop"
# $名前 または $数字（位置パラメータ）の直後に非ASCII文字が続くパターン
$pattern = [regex]'\$([A-Za-z_][A-Za-z0-9_]*|[0-9])(?=\P{IsBasicLatin})'
$bad = @()
Get-ChildItem -Path $DistRoot -Recurse -Filter *.sh | ForEach-Object {
    $file = $_.FullName
    $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }
        foreach ($m in $pattern.Matches($line)) {
            $bad += ("{0}:{1}: {2}" -f $file, ($i + 1), $line.Trim())
        }
    }
}
if ($bad.Count -gt 0) {
    Write-Host "NG: 非ASCII文字の直前に裸の変数展開があります。bash 3.2で値が消えるため `${var} で囲んでください（issue #2）"
    $bad | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "lint-sh OK: 非ASCII直前の裸の変数展開なし"
exit 0

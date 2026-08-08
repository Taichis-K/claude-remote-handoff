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

# .ps1にも同型の罠がある: PowerShellは変数名にCJK等のUnicode文字・数字を許すため、
# "$var直後に非ASCIIの文字/数字" は変数名の一部と解釈され、未定義変数=空文字に
# サイレント展開される（実測: "$reasonPart完了..." が丸ごと消えた）。`${var}` で囲めば安全。
# `）` `。` 等の記号（punctuation）は変数名に含まれないため対象外
$badPs = @()
$psPattern = [regex]'\$[A-Za-z_][A-Za-z0-9_]*'
Get-ChildItem -Path $DistRoot -Recurse -Filter *.ps1 | ForEach-Object {
    $file = $_.FullName
    $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }
        foreach ($m in $psPattern.Matches($line)) {
            $next = $m.Index + $m.Length
            if ($next -lt $line.Length -and [int]$line[$next] -gt 127 -and
                [char]::IsLetterOrDigit($line[$next])) {
                $badPs += ("{0}:{1}: {2}" -f $file, ($i + 1), $line.Trim())
            }
        }
    }
}
if ($badPs.Count -gt 0) {
    Write-Host "NG: .ps1で非ASCII文字の直前に裸の変数展開があります。PSは非ASCIIを変数名の一部と解釈し空文字に化けるため `${var} で囲んでください"
    $badPs | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "lint-sh OK: 非ASCII直前の裸の変数展開なし（sh/ps1とも）"
exit 0

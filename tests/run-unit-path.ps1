# run-unit-path.ps1 - 包含ゲート（issue #33）のPS実装単体試験
# 対象: Test-HandoffPathToken / Get-ValidStateFilePath / Test-RegularFile
# パリティ試験ではOS依存で固定できない分岐（ADS/予約名/バイト長境界/特殊ファイル/junction）を
# ここで固定する（codexレビュー#33-2 L3）。自己判定型: FAILが1件でもあればexit 1。
# 実行環境: PS 5.1 / pwsh（run-local-check.ps1 から実行される）。Unix特殊ファイル分岐は
# Unix pwshのみ・junction分岐はWindowsのみ実行し、他環境はSKIP表示する
$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path $PSScriptRoot -Parent) "hooks/ps/handoff-common.ps1")

$script:fail = 0
$script:executed = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
function Assert-Case([string]$Id, [bool]$Cond, [string]$Desc) {
    $null = $script:executed.Add($Id)
    if ($Cond) { Write-Output "$Id PASS $Desc" }
    else { Write-Output "$Id FAIL $Desc"; $script:fail++ }
}

$isCore = ($PSVersionTable.PSEdition -eq "Core")
$onWindows = $true
if ($isCore) { $onWindows = $IsWindows }

# --- P1〜P8: 字句検査（プラットフォーム非依存） ---
Assert-Case "P1" (Test-HandoffPathToken "C:\devhome\.claude\projects\d--x\t.jsonl") "Windows形式の正規パスを受理"
Assert-Case "P2" (Test-HandoffPathToken "/home/user/.claude/projects/d--x/t.jsonl") "Unix形式の正規パスを受理"
Assert-Case "P3" (-not (Test-HandoffPathToken "C:/a/../b/t.jsonl")) "「..」セグメントを拒否"
Assert-Case "P4" (-not (Test-HandoffPathToken "C:/a/t.jsonl:ads")) "ドライブ位置以外のコロン（ADS）を拒否"
Assert-Case "P5" ((-not (Test-HandoffPathToken "C:/a/CON.jsonl")) -and (-not (Test-HandoffPathToken "/a/lpt3.log"))) "予約デバイス名（拡張子付き・大小混在）を拒否"
Assert-Case "P6" ((-not (Test-HandoffPathToken "\\server\share\t.jsonl")) -and (-not (Test-HandoffPathToken "projects/t.jsonl"))) "UNC・相対パスを拒否"
Assert-Case "P7" ((-not (Test-HandoffPathToken "C:/a/t`n.jsonl")) -and (-not (Test-HandoffPathToken ("C:/a/t" + [string][char]0x7F + ".jsonl")))) "制御文字（LF・DEL）を拒否"
Assert-Case "P8" (-not (Test-HandoffPathToken "C:/a/./t.jsonl")) "「.」セグメントを拒否"

# --- P9〜P11: Get-ValidStateFilePath（一時projects_rootで実ファイル検査） ---
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("handoff-unitpath-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force "$work/cc/projects/proj" | Out-Null
$oldCfg = $env:CLAUDE_CONFIG_DIR
$env:CLAUDE_CONFIG_DIR = "$work/cc"
try {
    $tp = "$work/cc/projects/proj/t.jsonl"
    Set-Content -LiteralPath "$tp.handoff-state.json" -Value '{}' -Encoding UTF8
    Assert-Case "P9" ($null -ne (Get-ValidStateFilePath -TranscriptPath $tp -Mode "delete")) "root配下の実在stateはdelete可"
    # バイト長境界: 多バイト文字でUTF-16 unit数<=240でもUTF-8バイト数>240なら拒否
    $longName = ([string][char]0x3042) * 80 + ".jsonl"
    $tpLong = "$work/cc/projects/proj/$longName"
    $dLong = $tpLong.Replace("\", "/") + ".handoff-state.json"
    $boundaryOk = ($dLong.Length -le 240) -and ([System.Text.Encoding]::UTF8.GetByteCount($dLong) -gt 240)
    Assert-Case "P10" ($boundaryOk -and ($null -eq (Get-ValidStateFilePath -TranscriptPath $tpLong -Mode "write"))) "UTF-8バイト長>240を拒否（unit数<=240でも）"
    Assert-Case "P11" ($null -eq (Get-ValidStateFilePath -TranscriptPath "$work/cc/projectsX/t.jsonl" -Mode "write")) "rootの文字列前置だけ一致する隣接ディレクトリを拒否（要素境界）"

    # --- P12: junction構成要素の拒否（Windowsのみ。reparse walk検査） ---
    if ($onWindows) {
        New-Item -ItemType Directory -Force "$work/realtarget" | Out-Null
        Set-Content -LiteralPath "$work/realtarget/x.jsonl.handoff-state.json" -Value '{}' -Encoding UTF8
        $null = New-Item -ItemType Junction -Path "$work/cc/projects/jdir" -Target "$work/realtarget"
        Assert-Case "P12" ($null -eq (Get-ValidStateFilePath -TranscriptPath "$work/cc/projects/jdir/x.jsonl" -Mode "delete")) "junction構成要素を拒否"
    } else {
        $null = $script:executed.Add("P12")
        Write-Output "P12 SKIP junctionはWindows専用（Unixのsymlinkは P13〜P16 で検証）"
    }

    # --- P13〜P16: Unixの特殊ファイル判定（Unix pwshのみ。Test-RegularFile） ---
    if ($isCore -and -not $onWindows) {
        $reg = "$work/cc/projects/proj/reg.txt"
        Set-Content -LiteralPath $reg -Value "x" -Encoding UTF8
        Assert-Case "P13" (Test-RegularFile $reg) "通常ファイルはtrue"
        & /bin/ln -s $reg "$work/cc/projects/proj/lnk.txt"
        Assert-Case "P14" (-not (Test-RegularFile "$work/cc/projects/proj/lnk.txt")) "symlinkはfalse"
        & /bin/ln -s "$work/cc/projects/proj/nonexistent" "$work/cc/projects/proj/dangling.txt"
        Assert-Case "P15" (-not (Test-RegularFile "$work/cc/projects/proj/dangling.txt")) "宙吊りsymlinkはfalse"
        # mkfifoの場所はmacOS(/usr/bin)とLinux(/usr/bin or /bin)で異なるためPATH解決に任せる。
        # Test-RegularFileはstat系判定のみでFIFOをopenしない（openはブロックする）
        & mkfifo "$work/cc/projects/proj/fifo.jsonl.handoff-state.json"
        Assert-Case "P16" (-not (Test-RegularFile "$work/cc/projects/proj/fifo.jsonl.handoff-state.json")) "FIFOはfalse"
        Assert-Case "P17" ($null -eq (Get-ValidStateFilePath -TranscriptPath "$work/cc/projects/proj/fifo.jsonl" -Mode "delete")) "FIFOのleafはdelete不可（ゲート統合）"
        # 中間ディレクトリsymlinkのwalk統合検査（P12のjunction版と対）: Unixだけ
        # Test-NotReparsePointがsymlinkを通す退行を検出する（レビュー3回目 L3）
        New-Item -ItemType Directory -Force "$work/realtarget" | Out-Null
        Set-Content -LiteralPath "$work/realtarget/y.jsonl.handoff-state.json" -Value '{}' -Encoding UTF8
        & /bin/ln -s "$work/realtarget" "$work/cc/projects/ldir"
        Assert-Case "P18" ($null -eq (Get-ValidStateFilePath -TranscriptPath "$work/cc/projects/ldir/y.jsonl" -Mode "delete")) "中間ディレクトリsymlinkを拒否（walk統合）"
    } else {
        foreach ($id in @("P13", "P14", "P15", "P16", "P17", "P18")) { $null = $script:executed.Add($id) }
        Write-Output "P13-P18 SKIP Unixの特殊ファイル判定はUnix pwsh専用"
    }
} finally {
    if ($null -eq $oldCfg) { Remove-Item "Env:CLAUDE_CONFIG_DIR" -ErrorAction SilentlyContinue }
    else { $env:CLAUDE_CONFIG_DIR = $oldCfg }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 実行済みID集合の完全性（アサーション削除の退行を検出） ---
$expectedIds = @("P1","P2","P3","P4","P5","P6","P7","P8","P9","P10","P11","P12","P13","P14","P15","P16","P17","P18")
$missing = @($expectedIds | Where-Object { -not $script:executed.Contains($_) })
if ($missing.Count -gt 0) {
    Write-Output "FAIL 実行されなかったケース: $($missing -join ', ')"
    $script:fail++
}

$total = $script:executed.Count
if ($script:fail -gt 0) {
    Write-Output "unit-path: $($script:fail) FAIL / $total cases (edition=$($PSVersionTable.PSEdition))"
    exit 1
}
Write-Output "unit-path: ALL PASS ($total cases, edition=$($PSVersionTable.PSEdition))"
exit 0

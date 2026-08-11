# run-setup-gitignore.ps1 - setupの.gitignore追記の同値判定・冪等性を検証する（issue #25）
# run-setup-gitignore.sh と同一ケース・同一出力形式。run-local-check.ps1 / .sh が
# 両者の出力を fixtures/expected/setup-gitignore-expected.txt と照合する（ローカル実行）。
# 出力はASCIIのみ（CI WindowsのコンソールコードページでJP文言が化けるため）。
# 行リスト（SxL）は全ケースでtrim後の`.gitignore`全行を順序込みで出力する。
# 非ASCII（S4のU+00A0等）は連続1回ごと `?` へ正規化する（byte指向awkとchar指向の
# PS/gawkで置換数が割れないよう、1文字単位でなく連続まとめて置換する）。
# 推奨メッセージ（*付きへの更新提案）は、setupが文言末尾に付ける専用ASCIIマーカー
# [HANDOFF-RECOMMEND-GLOB] の完全一致で検出し rec=0/1 として出力する
# （JP文言はCI Windowsのコードページで化け、パス断片の部分一致はPOSIXの `*` 入り
# パス名等で偽陽性になり得るため — codexレビュー4〜5回目）
param([string]$WorkDir = "")

$ErrorActionPreference = "Stop"
$testsDir = $PSScriptRoot
$setup = Join-Path (Split-Path $testsDir -Parent) "setup/setup.ps1"
if ([string]::IsNullOrEmpty($WorkDir)) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("handoff-setupgi-ps-" + [guid]::NewGuid().ToString("N"))
}
# 誤指定された既存ディレクトリを巻き添え削除しないため、新規作成のみ許可
if (Test-Path -LiteralPath $WorkDir) {
    [Console]::Error.WriteLine("NG: WorkDirには存在しないパスを指定すること: $WorkDir")
    exit 1
}
New-Item -ItemType Directory -Force $WorkDir | Out-Null
$env:HANDOFF_SETUP_SKIP_CLAUDE_CHECK = "1"

$psExe = "powershell.exe"
if ($PSVersionTable.PSEdition -eq "Core") { $psExe = "pwsh" }
$NBSP = [string][char]0x00A0

function New-Proj([string]$Name, [string[]]$GitignoreLines, [bool]$WithBom = $false) {
    $d = Join-Path $WorkDir $Name
    New-Item -ItemType Directory -Force $d | Out-Null
    git init -q $d
    if ($null -ne $GitignoreLines) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($GitignoreLines -join "`n") + "`n")
        if ($WithBom) { $bytes = [byte[]](0xEF, 0xBB, 0xBF) + $bytes }
        [System.IO.File]::WriteAllBytes((Join-Path $d ".gitignore"), $bytes)
    }
    return $d
}
function Invoke-Setup([string]$Dir) {
    $out = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $setup -ProjectDir $Dir 2>&1) -join "`n"
    $ok = 0
    if ($LASTEXITCODE -eq 0) { $ok = 1 }
    $rec = 0
    if ($out.Contains("[HANDOFF-RECOMMEND-GLOB]")) { $rec = 1 }
    return @($ok, $rec)
}
function Report([string]$Case, [string]$Dir, $SetupResult) {
    $gi = Join-Path $Dir ".gitignore"
    $count = 0
    $starred = 0
    $trimmed = @()
    if (Test-Path -LiteralPath $gi) {
        foreach ($l in (Get-Content -LiteralPath $gi -Encoding UTF8)) {
            $t = $l.Trim(' ', "`t", "`r")
            if ($t.Length -gt 0) { $count++; $trimmed += [regex]::Replace($t, '[^\x20-\x7E]+', '?') }
            if ([string]::Equals($t, ".claude/settings.local.json*", [System.StringComparison]::Ordinal)) { $starred = 1 }
        }
    }
    $config = 0
    if (Test-Path -LiteralPath (Join-Path $Dir ".claude/handoff-config.json")) { $config = 1 }
    Write-Output "$Case exit=$($SetupResult[0]) lines=$count starred=$starred rec=$($SetupResult[1]) config=$config"
    foreach ($t in $trimmed) { Write-Output "${Case}L $t" }
}

# S1: .gitignoreなし → 4エントリすべて追記される
$d1 = New-Proj "s1" $null
Report "S1" $d1 (Invoke-Setup $d1)

# S2: 4エントリ完全一致が既にある → 追記なし（冪等）
$d2 = New-Proj "s2" @(".claude-handoff/", ".claude/handoff-config.json", ".claude/hooks/claude-remote-handoff/", ".claude/settings.local.json*")
Report "S2" $d2 (Invoke-Setup $d2)

# S3: 同値形の既存行（dirの/なし・タブ囲みのdir/*・fileの*付き・globの*なし）→ 追記なし。
# 既存の*なしsettings行は書き換えない（*付きへの更新推奨のみ提示 → rec=1）ため starred=0 のまま
$d3 = New-Proj "s3" @(".claude-handoff", "`t.claude/hooks/claude-remote-handoff/*`t", ".claude/handoff-config.json*", ".claude/settings.local.json")
Report "S3" $d3 (Invoke-Setup $d3)

# S4: 同値でない行（コメント・否定・大小違い・ファイル項目への末尾/・U+00A0前置・
# U+00AD前置）→ 4エントリすべて追記される。U+00A0は空白としてtrimしない契約
# （PS側を.Trim()に戻す回帰を検出）。U+00AD（soft hyphen）はカルチャ比較（-ceq/-eq）だと
# 無視されて誤同値になるため、ordinal比較への回帰をここで検出する。7行+4行=11行
$SHY = [string][char]0x00AD
$d4 = New-Proj "s4" @("# .claude-handoff/", "!.claude-handoff/", ".CLAUDE-HANDOFF/", ".claude/settings.local.json/", ".claude/handoff-config.json/", ($NBSP + ".claude-handoff/"), ($SHY + ".claude-handoff/"))
Report "S4" $d4 (Invoke-Setup $d4)

# S5: S3のプロジェクトへ再実行 → 変化なし（冪等。推奨表示は再度出る → rec=1）
Report "S5" $d3 (Invoke-Setup $d3)

# S6: UTF-8 BOM付き.gitignore + 完全一致4行 → 追記なし
# （PS 5.1のSet-Content/Add-Contentが生成し得る形。sh版のBOM除去の回帰をここで検出する）
$d6 = New-Proj "s6" @(".claude-handoff/", ".claude/handoff-config.json", ".claude/hooks/claude-remote-handoff/", ".claude/settings.local.json*") $true
Report "S6" $d6 (Invoke-Setup $d6)

# S7: HANDOFF_SETUP_SKIP_CLAUDE_CHECK が "1"+U+00AD ならバージョン確認はスキップされない
# （PSの-eqはカルチャ比較で"1"と等価判定しスキップしていた — Ordinal化の回帰検出）。
# PATH先頭に旧バージョン(0.0.1)を返すclaudeシムを置き、確認が実行されれば最低要求未満で
# 失敗（exit=0・config/gitignore未生成）になることをclaude CLIの有無に依らず検証する
$shimDir = Join-Path $WorkDir "shim"
New-Item -ItemType Directory -Force $shimDir | Out-Null
if ($PSVersionTable.PSEdition -eq "Core" -and -not $IsWindows) {
    Set-Content -LiteralPath (Join-Path $shimDir "claude") -Value "#!/bin/sh`necho 0.0.1" -Encoding UTF8
    & chmod +x (Join-Path $shimDir "claude")
} else {
    Set-Content -LiteralPath (Join-Path $shimDir "claude.cmd") -Value "@echo 0.0.1" -Encoding Ascii
}
$d7 = New-Proj "s7" $null
$oldPath = $env:PATH
$env:PATH = $shimDir + [System.IO.Path]::PathSeparator + $oldPath
$env:HANDOFF_SETUP_SKIP_CLAUDE_CHECK = "1" + [string][char]0x00AD
Report "S7" $d7 (Invoke-Setup $d7)
$env:PATH = $oldPath
$env:HANDOFF_SETUP_SKIP_CLAUDE_CHECK = "1"

# S8: floor境界（window=2053, pct=20 → 発火点410.6 → floor 410 <= hard 400+margin 10）は
# 静的検証NGで拒否・何も書かない（PS版setupの[long]最近接丸め〔411で受理〕への退行を検出。
# 両フック・sh版setupの切り捨てと合否が分裂し、setupが受理した設定を実行時に拒否する — issue #32）
$d8 = New-Proj "s8" $null
$out8 = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $setup -ProjectDir $d8 -AutocompactWindow 2053 -SoftThreshold 200 -HardThreshold 400 -MinMargin 10 -ConservativeFirePct 20 2>&1) -join "`n"
$ok8 = 0
if ($LASTEXITCODE -eq 0) { $ok8 = 1 }
$rec8 = 0
if ($out8.Contains("[HANDOFF-RECOMMEND-GLOB]")) { $rec8 = 1 }
Report "S8" $d8 @($ok8, $rec8)

if ([string]::IsNullOrEmpty($env:KEEP_WORK)) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    [Console]::Error.WriteLine("KEEP_WORK: $WorkDir")
}

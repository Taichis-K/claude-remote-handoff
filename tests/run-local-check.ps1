# run-local-check.ps1 - ローカル検証の一括実行+厳密判定（PS系）
# GitHub Actions撤去（2026-08-09 ユーザー指示）に伴い、旧ci.ymlにあった期待値照合を
# ローカルへ移植したもの。現在のPSエディションで BOM検査 / lint-sh / パリティ /
# setup試験 / unit-json / unit-path を実行し、期待値比較は大小・順序・行数まで厳密な
# ordinal（行単位・EOL非依存）。いずれか失敗で exit 1（成功と誤認しない）。
# **PS 5.1（powershell.exe）と pwsh の両方で実行すること**。sh版は run-local-check.sh
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File dist\tests\run-local-check.ps1
$ErrorActionPreference = "Stop"
$testsDir = $PSScriptRoot
$distDir = Split-Path $testsDir -Parent
$psExe = "powershell.exe"
if ($PSVersionTable.PSEdition -eq "Core") { $psExe = "pwsh" }
$script:fail = 0

function Compare-ExpectedLines([string]$Name, [string[]]$Actual, [string]$ExpectedPath) {
    $exp = @(Get-Content -LiteralPath $ExpectedPath -Encoding UTF8)
    # 行数はそれ自体を厳密比較する（欠落行と空行をどちらも""へ写像すると、末尾の
    # 空行増減を見逃す — codexレビュー#33追補2回目 M1）
    $diff = 0
    if ($Actual.Count -ne $exp.Count) {
        Write-Output "NG ${Name}: 行数不一致（got=$($Actual.Count)行 exp=$($exp.Count)行）"
        $diff++
    }
    for ($i = 0; $i -lt [Math]::Max($Actual.Count, $exp.Count); $i++) {
        $g = "<missing>"
        if ($i -lt $Actual.Count) { $g = $Actual[$i] }
        $e = "<missing>"
        if ($i -lt $exp.Count) { $e = $exp[$i] }
        if (-not [string]::Equals($g, $e, [System.StringComparison]::Ordinal)) {
            if ($diff -eq 0) { Write-Output "NG ${Name}: 期待値と不一致" }
            $diff++
            Write-Output "  DIFF line $($i + 1):"
            Write-Output "    got: $g"
            Write-Output "    exp: $e"
        }
    }
    if ($diff -eq 0) { Write-Output "OK ${Name}" } else { $script:fail++ }
}

# 1. BOM検査（全.ps1。PS 5.1はBOMなしUTF-8をcp932誤読しサイレントに壊れる）
$bad = @()
Get-ChildItem $distDir -Recurse -Filter *.ps1 | ForEach-Object {
    $b = [System.IO.File]::ReadAllBytes($_.FullName)
    if ($b.Length -lt 3 -or $b[0] -ne 0xEF -or $b[1] -ne 0xBB -or $b[2] -ne 0xBF) { $bad += $_.FullName }
}
if ($bad.Count -gt 0) { Write-Output "NG BOM: $($bad -join ', ')"; $script:fail++ } else { Write-Output "OK BOM（.ps1全数）" }

# 2. lint-sh（$var直後の非ASCII検査。sh/ps1両方）
$null = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsDir "lint-sh.ps1")
if ($LASTEXITCODE -ne 0) { Write-Output "NG lint-sh"; $script:fail++ } else { Write-Output "OK lint-sh" }

# 3. パリティ（80ケース）
$out = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsDir "run-parity.ps1"))
if ($LASTEXITCODE -ne 0) { Write-Output "NG parity: ランナーがexit $LASTEXITCODE"; $script:fail++ }
Compare-ExpectedLines "parity($psExe)" $out (Join-Path $testsDir "fixtures/expected/parity-expected.txt")

# 4. setup試験（S1〜S8）
$out2 = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsDir "run-setup-gitignore.ps1"))
if ($LASTEXITCODE -ne 0) { Write-Output "NG setup-gitignore: ランナーがexit $LASTEXITCODE"; $script:fail++ }
Compare-ExpectedLines "setup-gitignore($psExe)" $out2 (Join-Path $testsDir "fixtures/expected/setup-gitignore-expected.txt")

# 5. 単体試験（自己判定型: FAILがあればランナー自身がexit 1）
foreach ($unit in @("run-unit-json.ps1", "run-unit-path.ps1")) {
    $u = @(& $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $testsDir $unit))
    if ($LASTEXITCODE -ne 0) {
        Write-Output "NG ${unit}:"
        $u | ForEach-Object { Write-Output "  $_" }
        $script:fail++
    } else {
        Write-Output "OK ${unit}（$($u[-1])）"
    }
}

if ($script:fail -gt 0) {
    Write-Output "run-local-check: $($script:fail) 件失敗（edition=$($PSVersionTable.PSEdition)）"
    exit 1
}
Write-Output "run-local-check: ALL OK（edition=$($PSVersionTable.PSEdition)。PS 5.1/pwshの両方+run-local-check.shでの確認を忘れないこと）"
exit 0

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

# 連結結果の自己検査。期待値の全文照合とは別に「パートが担当ケースを過不足なく1回ずつ
# 出したか」をケース番号列だけで見る。どのパートが壊れたかが81行の差分より先に分かる
function Test-ShardLines([string]$Name, [string[]]$Lines, [string[]]$Expected, [string]$Counts) {
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $l = $Lines[$i]
        # パートの出力はリダイレクト経由でファイルに落ちる。ケース行が純ASCIIであることが
        # 文字化けしない前提なので、非ASCIIが混じったら黙って通さない
        if ($l -cmatch '[^\x20-\x7E]') {
            Write-Output "NG ${Name}: 連結結果の $($i + 1) 行目に非ASCII文字がある（パートの出力が文字化けした可能性）"
            return $false
        }
        if ($l -cnotmatch '^C[0-9]+ ') {
            Write-Output "NG ${Name}: 連結結果の $($i + 1) 行目がC番号で始まらない（各パートの行数: $Counts）"
            return $false
        }
    }
    # 番号の昇順だけでは**中抜け**（part1がC20だけ出さない等）を検出できないため、
    # 期待値のケース番号列とそのまま突き合わせる（codexレビュー1回目 Low）
    $actIds = @($Lines | ForEach-Object { $_.Substring(0, $_.IndexOf(" ")) })
    $expIds = @($Expected | ForEach-Object {
        $sp = $_.IndexOf(" ")
        if ($sp -ge 0) { $_.Substring(0, $sp) } else { $_ }
    })
    if ($actIds.Count -ne $expIds.Count) {
        Write-Output "NG ${Name}: ケース数が期待値と違う（got=$($actIds.Count) exp=$($expIds.Count)。各パートの行数: $Counts）"
        return $false
    }
    for ($i = 0; $i -lt $expIds.Count; $i++) {
        if (-not [string]::Equals($actIds[$i], $expIds[$i], [System.StringComparison]::Ordinal)) {
            Write-Output "NG ${Name}: $($i + 1) 番目のケース番号が期待値と違う（got=$($actIds[$i]) exp=$($expIds[$i])。各パートの行数: $Counts）"
            return $false
        }
    }
    return $true
}

# パリティは3パートを並列実行し、1→2→3の順に連結してから照合する。
# パートは互いに独立した作業ディレクトリで動く（run-parity.ps1 が新規作成する）
function Invoke-ParitySharded([string]$Name, [string]$ExpectedPath) {
    $runner = Join-Path $testsDir "run-parity.ps1"
    $base = Join-Path ([System.IO.Path]::GetTempPath()) ("handoff-parity-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $base | Out-Null
    $jobs = @()
    $bad = 0
    try {
        # 子はStart-Processで起動するため親の環境をそのまま継承する。pwshから
        # powershell.exeを起動するとPS 7向けのPSModulePathが渡り、PS 5.1がCore専用の
        # Microsoft.PowerShell.Utilityを掴んでGet-FileHashを見失う（実測。フックの
        # SHA-256計算が全滅してポインタが書かれなくなる）。変数ごと消して起動すれば、
        # 各エディションが自分の既定のモジュールパスを組み立て直す
        $savedPmp = $env:PSModulePath
        $pmpRemoved = $false
        try {
        if (Test-Path env:PSModulePath) { Remove-Item env:PSModulePath; $pmpRemoved = $true }
        foreach ($p in @("1", "2", "3")) {
            $o = Join-Path $base "part$p.out"
            $e = Join-Path $base "part$p.err"
            $w = Join-Path $base "work$p"
            # Start-ProcessのArgumentListは配列を空白で連結するだけで引用符を足さない。
            # 空白を含むパス（"Program Files"配下など）で壊れるため自分で囲む
            $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $runner + '"'),
                         "-WorkDir", ('"' + $w + '"'), "-Part", $p)
            $proc = Start-Process -FilePath $psExe -ArgumentList $argList `
                -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
            if ($null -eq $proc) {
                Write-Output "NG ${Name}: part ${p} の起動に失敗しました"
                $script:fail++
                return
            }
            # PS 5.1の罠: -PassThru で返るProcessは、先にハンドルを触っておかないと
            # 終了後のExitCodeがnullになる。参照するだけでハンドルがキャッシュされる
            $null = $proc.Handle
            $jobs += [pscustomobject]@{ Part = $p; Proc = $proc; Out = $o; Err = $e }
        }
        } finally {
            if ($pmpRemoved) { $env:PSModulePath = $savedPmp }
        }
        foreach ($j in $jobs) {
            $j.Proc.WaitForExit()
            if ($j.Proc.ExitCode -ne 0) {
                Write-Output "NG ${Name}: part $($j.Part) がexit $($j.Proc.ExitCode)。stderr:"
                if (Test-Path -LiteralPath $j.Err) {
                    @(Get-Content -LiteralPath $j.Err -Encoding UTF8) | Select-Object -First 50 | ForEach-Object { Write-Output "  $_" }
                }
                $bad++
            }
        }
    } finally {
        # 中断や例外で親だけ抜けると子が残り、次回実行と競合する
        foreach ($j in $jobs) {
            if ($null -ne $j -and $null -ne $j.Proc) {
                try { if (-not $j.Proc.HasExited) { $j.Proc.Kill() } } catch { }
            }
        }
    }
    if ($bad -gt 0) {
        $script:fail++
        Write-Output "  ログ: $base"
        return
    }
    $parts = @()
    foreach ($j in $jobs) { $parts += , @(Get-Content -LiteralPath $j.Out -Encoding UTF8) }
    $counts = ($parts | ForEach-Object { $_.Count }) -join " / "
    $all = @()
    foreach ($pl in $parts) { $all += $pl }
    $expected = @(Get-Content -LiteralPath $ExpectedPath -Encoding UTF8)
    if (-not (Test-ShardLines $Name $all $expected $counts)) {
        $script:fail++
        Write-Output "  ログ: $base"
        return
    }
    $before = $script:fail
    Compare-ExpectedLines $Name $all $ExpectedPath
    if ($script:fail -ne $before) {
        Write-Output "  ログ: $base"
        return
    }
    # 作業ディレクトリの後始末: run-parity.ps1 は KEEP_WORK=1 のとき自分の作業域を残す。
    # ここで $base ごと消すとそれが黙って効かなくなるため、KEEP_WORK 指定時は残す
    if ([string]::IsNullOrEmpty($env:KEEP_WORK)) {
        Remove-Item -Recurse -Force $base -ErrorAction SilentlyContinue
    } else {
        Write-Output "  KEEP_WORK: パートの作業ディレクトリを残しました: $base"
    }
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

# 3. パリティ（81ケース・3パート並列）
Invoke-ParitySharded "parity($psExe)" (Join-Path $testsDir "fixtures/expected/parity-expected.txt")

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

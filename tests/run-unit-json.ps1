# run-unit-json.ps1 - ConvertFrom-JsonPreserve の単体検証（issue #30）
# ＋ Test-HoProp / Get-HoProp のcase-sensitive契約（issue #37。D節）
# パリティ試験（run-parity）はフック単位の入出力しか見ないため、以下はここで固定する:
#   A) 経路選択フラグ HoJsonDateKindString の環境変数判定（ordinal "1" のみ強制）
#   B) フォールバック経路（旧pwsh相当 = System.Text.Json + Convert-JsonElementToPS）の
#      経路接続・重複キー処理・深度境界（JsonDocumentOptions.MaxDepth=1024）・型契約
#   C) 主経路（-DateKind String / PS 5.1 JavaScriptSerializer）の同一契約のサニティ
# 出力: "U<番号> PASS|FAIL|SKIP <説明>"。FAILが1件でもあれば exit 1。
# ケース数だけでなく実行済みID集合も終了前に検証する（アサーション削除・ID重複の退行検出）。
# 深度境界の規範は経路依存: Core(STJ/Newtonsoft)は1024受理/1025拒否、
# PS 5.1(JSS)はRecursionLimitにより深度100前後で拒否（実測。拒否側=安全方向のため
# Desktopの深度規範は65受理までに留める。ps51-compat.md 罠9参照）
# PS 5.1互換文法のみ使用。UTF-8 BOM付きで保存すること
$ErrorActionPreference = "Stop"
$commonPath = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) "hooks/ps") "handoff-common.ps1"
$isCore = ($PSVersionTable.PSEdition -eq "Core")

$script:failCount = 0
$script:executedIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
function Assert-True {
    param([string]$Id, [bool]$Cond, [string]$Desc)
    if (-not $script:executedIds.Add($Id)) {
        Write-Output ("$Id FAIL ケースIDが重複している（ランナー自体の欠陥）")
        $script:failCount++
        return
    }
    if ($Cond) {
        Write-Output ("$Id PASS " + $Desc)
    } else {
        Write-Output ("$Id FAIL " + $Desc)
        $script:failCount++
    }
}
function Test-Throws {
    param([scriptblock]$Body)
    try { $null = & $Body; return $false } catch { return $true }
}
function New-DepthJson {
    param([int]$Depth)
    return ("[" * $Depth) + "0" + ("]" * $Depth)
}
# フラグは「boolean型で、かつ期待値」を要求する（文字列"False"等のtruthy縮退を弾く）
function Test-FlagIs {
    param([bool]$Expected)
    if (-not ($script:HoJsonDateKindString -is [bool])) { return $false }
    return $script:HoJsonDateKindString -eq $Expected
}

$origEnv = $env:HANDOFF_TEST_FORCE_JSON_FALLBACK
try {
    # ---- A) 経路選択フラグ（全エディション） ----
    # baseline = 環境変数以外の条件（Core かつ ConvertFrom-Json に -DateKind がある）
    $baseline = [bool]($isCore -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind"))

    # 注意: pwshでは `$env:VAR = ""` は変数を削除しない（空文字列の環境変数が残る）。
    # U1は「空文字列」ケースとして扱い、「真の未設定」はC節（Remove-Item後）のU18〜U23で検証する
    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = ""
    . $commonPath
    Assert-True "U1" (Test-FlagIs $baseline) "env=`"`"（空文字列）: 強制しない（フラグはboolean型でbaseline=$baseline）"

    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = "1"
    . $commonPath
    Assert-True "U2" (Test-FlagIs $false) 'env="1": フォールバック強制でフラグはFalse'

    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = "01"
    . $commonPath
    Assert-True "U3" (Test-FlagIs $baseline) 'env="01": ordinal完全一致のみ強制（baselineのまま）'

    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = "true"
    . $commonPath
    Assert-True "U4" (Test-FlagIs $baseline) 'env="true": 強制しない（baselineのまま）'

    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = "1 "
    . $commonPath
    Assert-True "U5" (Test-FlagIs $baseline) 'env="1 "（末尾空白）: 強制しない（baselineのまま）'

    # "1"+U+00AD: カルチャ比較（-eq/-ceq）はU+00ADを照合上無視して"1"と等価にするため
    # 強制されてしまう。ordinal比較なら不一致=強制しない（罠8の退行検出）
    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = ("1" + [char]0x00AD)
    . $commonPath
    Assert-True "U6" (Test-FlagIs $baseline) 'env="1"+U+00AD: ordinal比較なら強制しない（カルチャ比較退行の検出）'

    # ---- B) フォールバック経路（Coreのみ。DesktopはSTJ経路に入らないためSKIP） ----
    if ($isCore) {
        $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = "1"
        . $commonPath

        # 経路接続の直接確認: 強制時にSTJ変換関数が実際に呼ばれること
        # （両経路は挙動を揃えているため、結果比較だけでは分岐の断線を検出できない）
        $script:stjProbeCalled = $false
        $script:stjOrigDef = ${function:Convert-JsonElementToPS}
        function Convert-JsonElementToPS {
            param($El)
            $script:stjProbeCalled = $true
            return & $script:stjOrigDef $El
        }
        try {
            $null = ConvertFrom-JsonPreserve '{"probe":1}'
        } finally {
            ${function:Convert-JsonElementToPS} = $script:stjOrigDef
        }
        Assert-True "U7" $script:stjProbeCalled "強制時にConvert-JsonElementToPSが実際に呼ばれる（経路接続の確認）"

        $r = ConvertFrom-JsonPreserve '{"a":"first","a":"last"}'
        Assert-True "U8" (($r.a -is [string]) -and (Test-OrdinalEqual $r.a "last")) "同綴り重複キーは後勝ちの単一文字列（jq / PS 5.1 と同じ）"

        Assert-True "U9" (Test-Throws { ConvertFrom-JsonPreserve '{"a":1,"A":2}' }) "大小違い重複キーは例外（入力全体を不正とする）"

        Assert-True "U10" (-not (Test-Throws { ConvertFrom-JsonPreserve (New-DepthJson 64) })) "深度64を受理"
        Assert-True "U11" (-not (Test-Throws { ConvertFrom-JsonPreserve (New-DepthJson 65) })) "深度65を受理（MaxDepth=1024指定の退行検出: 既定64に戻ると失敗）"
        Assert-True "U12" (-not (Test-Throws { ConvertFrom-JsonPreserve (New-DepthJson 1024) })) "深度1024を受理（ConvertFrom-Json既定と同じ）"
        Assert-True "U13" (Test-Throws { ConvertFrom-JsonPreserve (New-DepthJson 1025) }) "深度1025を拒否"

        $r = ConvertFrom-JsonPreserve '[{"x":1}]'
        Assert-True "U14" (($r -is [System.Array]) -and ($r.Count -eq 1)) "ルート1要素配列が配列のまま（関数境界の縮退なし）"

        $r = ConvertFrom-JsonPreserve '{"t":"2026-01-02T03:04:05+09:00"}'
        Assert-True "U15" (($r.t -is [string]) -and (Test-OrdinalEqual $r.t "2026-01-02T03:04:05+09:00")) "ISO日時形式のJSON文字列が原表記のString（[datetime]化・表記正規化しない）"

        $r = ConvertFrom-JsonPreserve '{"n":1}'
        Assert-True "U16" ($r.n -is [long]) "整数はInt64"

        $r = ConvertFrom-JsonPreserve '{"o":{"k":[1,"x",true,null,1.5]}}'
        $k = $r.o.k
        $ok = ($r -is [System.Management.Automation.PSCustomObject]) -and
            ($r.o -is [System.Management.Automation.PSCustomObject]) -and
            ($k -is [System.Array]) -and ($k.Count -eq 5) -and
            ($k[0] -is [long]) -and ($k[0] -eq 1) -and
            ($k[1] -is [string]) -and (Test-OrdinalEqual $k[1] "x") -and
            ($k[2] -is [bool]) -and $k[2] -and ($null -eq $k[3]) -and
            ($k[4] -is [double]) -and ($k[4] -eq 1.5)
        Assert-True "U17" $ok "ネスト構造の型変換（PSCustomObject/array/Int64/string/bool/null/double）"
    } else {
        Write-Output "U7-U17 SKIP フォールバック経路はCore専用（DesktopはJSS経路のためSTJに入らない）"
    }

    # ---- C) 主経路のサニティ（全エディション、envを真に削除した未設定状態） ----
    if (Test-Path "Env:HANDOFF_TEST_FORCE_JSON_FALLBACK") {
        Remove-Item "Env:HANDOFF_TEST_FORCE_JSON_FALLBACK"
    }
    . $commonPath

    $r = ConvertFrom-JsonPreserve '[{"x":1}]'
    Assert-True "U18" (($r -is [System.Array]) -and ($r.Count -eq 1)) "主経路: ルート1要素配列が配列のまま"

    $r = ConvertFrom-JsonPreserve '{"t":"2026-01-02T03:04:05+09:00"}'
    Assert-True "U19" (($r.t -is [string]) -and (Test-OrdinalEqual $r.t "2026-01-02T03:04:05+09:00")) "主経路: ISO日時形式が原表記のString"

    $r = ConvertFrom-JsonPreserve '{"a":"first","a":"last"}'
    Assert-True "U20" (($r.a -is [string]) -and (Test-OrdinalEqual $r.a "last")) "主経路: 同綴り重複キーは後勝ちの単一文字列"

    Assert-True "U21" (Test-Throws { ConvertFrom-JsonPreserve '{"a":1,"A":2}' }) "主経路: 大小違い重複キーは例外（実測: 両エディションとも組み込みが拒否）"

    Assert-True "U22" (-not (Test-Throws { ConvertFrom-JsonPreserve (New-DepthJson 65) })) "主経路: 深度65を受理（実測: 両エディションともOK）"

    # 経路接続の鏡像確認: env未設定時にSTJ変換関数が「呼ばれない」こと
    # （分岐を常にフォールバック化する断線はU7では検出できない）。
    # 期待値は「呼ばれる = Coreかつ-DateKindなし（旧pwsh相当）のみ」:
    # 新しいpwsh（baseline=true）とPS 5.1（JSS経路）はともに呼ばれない
    $script:stjProbeCalled = $false
    $script:stjOrigDef = ${function:Convert-JsonElementToPS}
    function Convert-JsonElementToPS {
        param($El)
        $script:stjProbeCalled = $true
        return & $script:stjOrigDef $El
    }
    try {
        $null = ConvertFrom-JsonPreserve '{"probe":1}'
    } finally {
        ${function:Convert-JsonElementToPS} = $script:stjOrigDef
    }
    $expectStj = $isCore -and (-not $baseline)
    Assert-True "U23" ($script:stjProbeCalled -eq $expectStj) "env真の未設定（削除済み）時の経路: STJ変換関数の呼び出し有無が期待どおり（期待=$expectStj）"

    # ---- D) Test-HoProp / Get-HoProp のcase-sensitive契約（issue #37、全エディション） ----
    # パリティ試験（C79）はフック単位の分裂しか見ないため、ヘルパ固有の契約はここで固定する
    $r = ConvertFrom-JsonPreserve '{"cwd":"/x"}'
    Assert-True "U24" ((Test-HoProp $r "cwd") -and ((Get-HoProp $r "cwd") -is [string]) -and (Test-OrdinalEqual (Get-HoProp $r "cwd") "/x")) "正しい大小: Test-HoProp=true / Get-HoPropが値を返す"

    $r = ConvertFrom-JsonPreserve '{"CWD":"/x"}'
    Assert-True "U25" ((-not (Test-HoProp $r "cwd")) -and ($null -eq (Get-HoProp $r "cwd"))) "大小違いキーのみ: Test-HoProp=false / Get-HoProp=null（PSObject.Properties[名前]の大小非区別への退行検出）"

    $r = ConvertFrom-JsonPreserve '{"cwd":null}'
    Assert-True "U26" ((Test-HoProp $r "cwd") -and ($null -eq (Get-HoProp $r "cwd"))) "null値: Test-HoProp=true（存在はする）/ Get-HoProp=null"

    $r = ConvertFrom-JsonPreserve '{"cwd":["/x"]}'
    $v = Get-HoProp $r "cwd"
    Assert-True "U27" (($v -is [System.Array]) -and ($v.Count -eq 1)) "1要素配列の値: Get-HoPropが配列型のまま返す（単項カンマ削除で文字列へ縮退する退行の検出）"
} finally {
    $env:HANDOFF_TEST_FORCE_JSON_FALLBACK = $origEnv
}

# ---- 実行済みID集合の完全性検証（アサーション削除・欠落の退行検出） ----
$expectedIds = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
foreach ($i in 1..27) {
    if ((-not $isCore) -and ($i -ge 7) -and ($i -le 17)) { continue }
    $null = $expectedIds.Add("U" + $i)
}
$setOk = ($script:executedIds.Count -eq $expectedIds.Count)
foreach ($e in $expectedIds) {
    if (-not $script:executedIds.Contains($e)) {
        Write-Output ("CASE-SET FAIL 未実行: " + $e)
        $setOk = $false
    }
}
if (-not $setOk) {
    Write-Output ("CASE-SET FAIL 実行済みID集合が期待と不一致（実行=" + $script:executedIds.Count + " 期待=" + $expectedIds.Count + "）")
    $script:failCount++
}

$passCount = $script:executedIds.Count - $script:failCount
Write-Output ("unit-json: " + $passCount + "/" + $script:executedIds.Count + " PASS (edition=" + $PSVersionTable.PSEdition + ")")
if ($script:failCount -gt 0) { exit 1 }
exit 0

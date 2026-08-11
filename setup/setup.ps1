# setup.ps1 - インストール補助スクリプト（プラグインで賄えない部分のみ）
#  1. claude --version が最低要求 v2.1.163 以上か確認（未満なら警告して中断）
#  2. autocompact値と閾値（ソフト/ハード）のペアを静的検証し .claude/handoff-config.json へ書き込む
#     （検証NGなら書き込まない = 機能は無効のまま）
#  3. .gitignore にマシン/環境固有の4エントリを追記（重複チェック・git未導入/リポジトリ外はスキップ）
# 使い方（対象プロジェクトのルートで実行）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup.ps1 `
#     [-AutocompactWindow 160000] [-SoftThreshold 120000] [-HardThreshold 135000] [-MinMargin 10000]
# PS 5.1互換文法・UTF-8 BOM付きで保存すること
param(
    [long]$AutocompactWindow = 160000,
    [long]$SoftThreshold = 120000,
    [long]$HardThreshold = 135000,
    [long]$MinMargin = 10000,
    [int]$ConservativeFirePct = 92,
    [string]$ProjectDir = "."
)

$ErrorActionPreference = "Stop"
$MIN_CLAUDE_VERSION = [version]"2.1.163"

function Fail([string]$Message) {
    Write-Host "NG: $Message" -ForegroundColor Red
    exit 1
}

$ProjectDir = (Resolve-Path $ProjectDir).Path
Write-Host "対象プロジェクト: $ProjectDir"

# --- 1. Claude Codeバージョン確認 ---
if ([string]::Equals($env:HANDOFF_SETUP_SKIP_CLAUDE_CHECK, "1", [System.StringComparison]::Ordinal)) {
    # テスト用（claude CLIが無い環境でgitignore/設定生成ロジックを試験するため）。通常は使わない
    Write-Host "SKIP: Claude Codeバージョン確認（HANDOFF_SETUP_SKIP_CLAUDE_CHECK=1）"
} else {
    $verText = ""
    try { $verText = (& claude --version) 2>$null | Out-String } catch { }
    if ([string]::IsNullOrWhiteSpace($verText)) {
        Fail "claude コマンドが見つかりません。Claude Codeをインストールし、PATHを通してください"
    }
    $m = [regex]::Match($verText, '(\d+\.\d+\.\d+)')
    if (-not $m.Success) {
        Fail "claude --version の出力からバージョンを特定できません: $($verText.Trim())"
    }
    $ver = [version]$m.Groups[1].Value
    if ($ver -lt $MIN_CLAUDE_VERSION) {
        Fail "Claude Code $ver は最低要求 $MIN_CLAUDE_VERSION 未満です（StopフックのadditionalContext非対応）。アップデートしてください"
    }
    Write-Host "OK: Claude Code $ver（>= $MIN_CLAUDE_VERSION）"
}

# --- 2. 閾値ペアの静的検証 → handoff-config.json 書き込み ---
# 発火点 = window × 保守的発火%。ハード閾値+最低マージンがこれを下回らなければ
# handoffがauto compactに間に合わない可能性があるため書き込まない（機能無効のまま）
if ($SoftThreshold -le 0 -or $HardThreshold -le 0 -or $SoftThreshold -gt $HardThreshold) {
    Fail "閾値が不正です: soft($SoftThreshold) <= hard($HardThreshold) かつ両方正の値にしてください"
}
if ($MinMargin -lt 0) { Fail "MinMarginは0以上にしてください" }
if ($ConservativeFirePct -lt 1 -or $ConservativeFirePct -gt 100) { Fail "ConservativeFirePctは1-100にしてください" }
# フック側の実行時検証と同じ上限（1e9）。ここで通してもフックが設定全体を拒否するため、
# 生成側でも同じ契約で弾く（codexレビュー4回目 M3）
$MAX_TOKEN_VALUE = [long]1000000000
if ($AutocompactWindow -le 0) { Fail "AutocompactWindowは正の値にしてください" }
foreach ($pair in @(@("AutocompactWindow", $AutocompactWindow), @("SoftThreshold", $SoftThreshold), @("HardThreshold", $HardThreshold), @("MinMargin", $MinMargin))) {
    if ($pair[1] -gt $MAX_TOKEN_VALUE) {
        Fail "$($pair[0])($($pair[1])) が上限 $MAX_TOKEN_VALUE を超えています（フック側の実行時検証と同じ上限。超えた設定は実行時に全体が拒否されます）"
    }
}
# floorに統一（[long]キャストは最近接丸めのため、.5以上の端数でsh版setup・両フックの
# 切り捨てと合否が分裂し、setupが受理した設定を実行時に拒否し得る — issue #32）
$firePoint = [long][Math]::Floor(([double]$AutocompactWindow) * $ConservativeFirePct / 100)
if (($HardThreshold + $MinMargin) -ge $firePoint) {
    Write-Host "静的検証NG:" -ForegroundColor Red
    Write-Host "  ハード閾値($HardThreshold) + 最低マージン($MinMargin) >= 発火点($firePoint = window $AutocompactWindow x $ConservativeFirePct%)"
    Write-Host "  この組合せではhandoff作成がauto compactに間に合わない可能性があるため、設定を書き込みません。"
    Write-Host "  閾値を下げるか、autocompact値を上げてください（例: /autocompact $([long]($HardThreshold * 1.25)) 以上）"
    Write-Host "  この window($AutocompactWindow)・margin($MinMargin)・pct($ConservativeFirePct) のままなら、ハード閾値は最大 $($firePoint - $MinMargin - 1) まで設定できます"
    exit 1
}
Write-Host "OK: 静的検証（hard $HardThreshold + margin $MinMargin < 発火点 $firePoint）"
Write-Host "  注意: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 環境変数で発火点は下がり得ます（フックは有効な環境変数、無ければ設定値で毎Stop再検証し、満たさない場合は機能を無効化します）"

$claudeDir = Join-Path $ProjectDir ".claude"
if (-not (Test-Path -LiteralPath $claudeDir)) { New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null }
$configPath = Join-Path $claudeDir "handoff-config.json"
$config = @{
    autocompact_window    = $AutocompactWindow
    soft_threshold        = $SoftThreshold
    hard_threshold        = $HardThreshold
    min_margin            = $MinMargin
    conservative_fire_pct = $ConservativeFirePct
}
Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json) -Encoding UTF8
Write-Host "OK: $configPath を書き込みました"
Write-Host "  Claude Code側でも autocompact を設定してください: /autocompact $AutocompactWindow"

# --- 3. .gitignore追記（重複チェック・git未導入/リポジトリ外はスキップ） ---
# 4エントリとも「マシン/環境固有」でコミット対象外:
#   .claude-handoff/                     … 保存データ（transcript等の機密を含み得る）
#   .claude/handoff-config.json         … 閾値は実効コンテキスト総量（/context表示）とマシンのautocompact設定に依存
#   .claude/hooks/claude-remote-handoff/ … 手動導入時のフック本体（OSごとにps/shを選ぶ）
#   .claude/settings.local.json*        … 手動導入のフック登録先（.bak含む。端末固有パスを含み得る）
$IGNORE_ENTRIES = @(".claude-handoff/", ".claude/handoff-config.json", ".claude/hooks/claude-remote-handoff/", ".claude/settings.local.json*")
$gitOk = $false
try {
    $null = & git -C $ProjectDir rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -eq 0) { $gitOk = $true }
} catch { }
if (-not $gitOk) {
    Write-Host "SKIP: gitリポジトリではない（または git 未導入）ため .gitignore 追記をスキップ"
} else {
    $giPath = Join-Path $ProjectDir ".gitignore"
    $lines = @()
    if (Test-Path -LiteralPath $giPath) { $lines = @(Get-Content -LiteralPath $giPath -Encoding UTF8) }
    foreach ($entry in $IGNORE_ENTRIES) {
        # 意味的に同値な既存行も「追記済み」と判定する（issue #25: *なしの
        # settings.local.json既存行に*付きが二重追記されていた）。同値形は対象の種類ごとに列挙:
        #   ディレクトリ項目 dir/ : dir・dir/* も可（gitはディレクトリ自体を追跡しないため実質同値）
        #   ファイル項目 file    : file* も可（より広くカバー）
        #   グロブ項目 file*     : file〔*なし〕も可（部分カバー → *付きへの更新を推奨表示）
        #   ファイル項目への末尾/はディレクトリ専用パターンでファイルを無視しないため同値としない
        # 比較はordinal厳密（[string]::Equals + StringComparison.Ordinal）・trimは[ \t\r]のみ。
        # -eq/.Trim()は大小無視・Unicode空白を含み、-ceqもカルチャ比較でU+00AD等の
        # 照合上無視可能な文字を無視するため、LC_ALL=C awk（strcmp）のsh版と判定が分裂する
        $candidates = @($entry)
        if ($entry.EndsWith("/", [System.StringComparison]::Ordinal)) {
            $bare = $entry.TrimEnd('/')
            $candidates += $bare
            $candidates += "$bare/*"
        } elseif ($entry.EndsWith("*", [System.StringComparison]::Ordinal)) {
            $candidates += $entry.TrimEnd('*')
        } else {
            $candidates += "$entry*"
        }
        $matched = $null
        foreach ($l in $lines) {
            $t = $l.Trim(' ', "`t", "`r")
            foreach ($c in $candidates) {
                if ([string]::Equals($t, $c, [System.StringComparison]::Ordinal)) { $matched = $t; break }
            }
            if ($null -ne $matched) { break }
        }
        if ($null -ne $matched) {
            Write-Host "OK: .gitignore に $entry は追記済み（既存行: ${matched}）"
            if ($entry.EndsWith("*", [System.StringComparison]::Ordinal) -and -not $matched.EndsWith("*", [System.StringComparison]::Ordinal)) {
                # 末尾の [HANDOFF-RECOMMEND-GLOB] はテストが提示有無を検出するための
                # 機械可読マーカー（JP文言はCI Windowsのコードページで化け、パス断片の
                # 部分一致検出はパス名次第で偽陽性になるため、専用トークンで完全一致検出する）
                Write-Host "  推奨: 既存行を $entry に更新すると、編集時に生成される .bak もカバーされます [HANDOFF-RECOMMEND-GLOB]" -ForegroundColor Yellow
            }
        } else {
            Add-Content -LiteralPath $giPath -Value $entry -Encoding UTF8
            $lines += $entry
            Write-Host "OK: .gitignore に $entry を追記しました"
        }
    }
    # 既にtrackedなファイルはgitignoreだけでは外れないため警告（git rm --cached等は自動では行わない）
    foreach ($target in @(".claude-handoff", ".claude/handoff-config.json", ".claude/hooks/claude-remote-handoff", ".claude/settings.local.json")) {
        $tracked = & git -C $ProjectDir ls-files -- $target 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($tracked | Out-String))) {
            $extra = ""
            if ($target -eq ".claude-handoff") { $extra = "（trackedのままだとバックアップ保存が無効化されます）" }
            Write-Host "警告: $target がgit trackedです。gitignoreだけでは外れないため git rm --cached で整理してください$extra" -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "セットアップ完了。残りの手動確認:"
Write-Host "  1. Claude Codeで /autocompact $AutocompactWindow を設定"
Write-Host "  2. permissions.allow に `"Edit(.claude-handoff/**)`" を追加（実質必須: 無いとhandoff作成のたびに許可プロンプトで中断。チームで共有するなら .claude/settings.json、共有しないなら .claude/settings.local.json）"
Write-Host "  3. このプロジェクトで一度Claude Codeを対話起動しtrustを承認（未trustだと許可ルールが無視されます）"
Write-Host "  4. /hooks で5エントリ（PreCompact / SessionStart x3 / Stop）の登録を確認（見えなければClaude Codeを再起動）"
exit 0



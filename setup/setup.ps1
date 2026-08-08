# setup.ps1 - インストール補助スクリプト（プラグインで賄えない部分のみ）
#  1. claude --version が最低要求 v2.1.163 以上か確認（未満なら警告して中断）
#  2. autocompact値と閾値（ソフト/ハード）のペアを静的検証し .claude/handoff-config.json へ書き込む
#     （検証NGなら書き込まない = 機能は無効のまま）
#  3. .gitignore に .claude-handoff/ を追記（重複チェック・git未導入/リポジトリ外はスキップ）
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

# --- 2. 閾値ペアの静的検証 → handoff-config.json 書き込み ---
# 発火点 = window × 保守的発火%。ハード閾値+最低マージンがこれを下回らなければ
# handoffがauto compactに間に合わない可能性があるため書き込まない（機能無効のまま）
if ($SoftThreshold -le 0 -or $HardThreshold -le 0 -or $SoftThreshold -gt $HardThreshold) {
    Fail "閾値が不正です: soft($SoftThreshold) <= hard($HardThreshold) かつ両方正の値にしてください"
}
if ($MinMargin -lt 0) { Fail "MinMarginは0以上にしてください" }
if ($ConservativeFirePct -lt 1 -or $ConservativeFirePct -gt 100) { Fail "ConservativeFirePctは1-100にしてください" }
$firePoint = [long]($AutocompactWindow * $ConservativeFirePct / 100)
if (($HardThreshold + $MinMargin) -ge $firePoint) {
    Write-Host "静的検証NG:" -ForegroundColor Red
    Write-Host "  ハード閾値($HardThreshold) + 最低マージン($MinMargin) >= 発火点($firePoint = window $AutocompactWindow x $ConservativeFirePct%)"
    Write-Host "  この組合せではhandoff作成がauto compactに間に合わない可能性があるため、設定を書き込みません。"
    Write-Host "  閾値を下げるか、autocompact値を上げてください（例: /autocompact $([long]($HardThreshold * 1.25)) 以上）"
    exit 1
}
Write-Host "OK: 静的検証（hard $HardThreshold + margin $MinMargin < 発火点 $firePoint）"
Write-Host "  注意: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE 環境変数で発火点は下がり得ます（実行時にもbest-effort再検証されます）"

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
$IGNORE_ENTRY = ".claude-handoff/"
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
    $exists = $false
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq $IGNORE_ENTRY -or $t -eq ".claude-handoff") { $exists = $true; break }
    }
    if ($exists) {
        Write-Host "OK: .gitignore に $IGNORE_ENTRY は追記済み"
    } else {
        Add-Content -LiteralPath $giPath -Value $IGNORE_ENTRY -Encoding UTF8
        Write-Host "OK: .gitignore に $IGNORE_ENTRY を追記しました"
    }
    # 既にtrackedなファイルがある場合は警告（保存側でも自動検出して無効化される）
    $tracked = & git -C $ProjectDir ls-files -- .claude-handoff 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($tracked | Out-String))) {
        Write-Host "警告: .claude-handoff 配下にgit trackedなファイルがあります。バックアップが無効化されるため整理してください（git rm --cached等は自動では行いません）" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "セットアップ完了。残りの手動確認:"
Write-Host "  1. Claude Codeで /autocompact $AutocompactWindow を設定"
Write-Host "  2. .claude/settings.json の permissions.allow に `"Edit(.claude-handoff/**)`" を追加推奨（handoff書き込みの自動許可）"
Write-Host "  3. このプロジェクトで一度Claude Codeを対話起動しtrustを承認（未trustだと許可ルールが無視されます）"
exit 0



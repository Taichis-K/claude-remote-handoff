# run-parity.ps1 - PS版フックに共有フィクスチャのケースを流し、正規化した結果行を出力する
# run-parity.sh と同一ケース・同一出力形式。CIは両者の出力をdiffして2系統一致を検証する
# 出力形式: "C<番号> <key>=<value> ..."（1ケース1行）
param([string]$WorkDir = "")

$ErrorActionPreference = "Stop"
$testsDir = $PSScriptRoot
$hooksDir = Join-Path (Split-Path $testsDir -Parent) "hooks/ps"
$fixtures = Join-Path $testsDir "fixtures"
if ([string]::IsNullOrEmpty($WorkDir)) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("handoff-parity-ps-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
}
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude" | Out-Null
Set-Content "$WorkDir/proj/.claude/handoff-config.json" -Value '{"soft_threshold":200,"hard_threshold":400,"min_margin":10,"conservative_fire_pct":80}' -Encoding UTF8
$env:CLAUDE_PROJECT_DIR = "$WorkDir/proj"
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = ""
$env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = ""

$psExe = "powershell.exe"
if ($PSVersionTable.PSEdition -eq "Core") { $psExe = "pwsh" }

function Invoke-Hook([string]$Script, $StdinObj) {
    $json = $StdinObj | ConvertTo-Json -Depth 5
    return ($json | & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $hooksDir $Script)) -join "`n"
}
function Get-State([string]$Transcript) {
    $p = "$Transcript.handoff-state.json"
    if (-not (Test-Path -LiteralPath $p)) { return "none" }
    try {
        $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s.completed) { return "completed" }
        return "$($s.mode)/$($s.attempts)"
    } catch { return "unreadable" }
}
function Get-OutKind([string]$Out) {
    if ([string]::IsNullOrWhiteSpace($Out)) { return "none" }
    if ($Out -match '試行\s2/3') { return "hard-retry" }
    # 注: ソフト指示文は「ハード閾値到達時は…」を含むため、ソフト判定を先に行う
    if ($Out -match 'ソフト閾値') { return "soft" }
    if ($Out -match 'ハード閾値') { return "hard" }
    if ($Out -match '検証済み') { return "injected" }
    if ($Out -match '検証に失敗') { return "refused" }
    return "other"
}
function New-UsageTranscript([string]$Path, [int]$Tokens) {
    Set-Content -LiteralPath $Path -Value ('{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":' + $Tokens + ',"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}') -Encoding UTF8
}

$sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
$t = "$WorkDir/t.jsonl"
$stopIn = @{ session_id = $sid; transcript_path = $t; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }

# C1: 閾値未満+ノイズ行（sidechain/部分行/型不正/壊れたJSON）は無発火
Copy-Item (Join-Path $fixtures "transcripts/mixed-below.jsonl") $t -Force
$o = Invoke-Hook "handoff-check.ps1" $stopIn
Write-Output "C1 output=$(Get-OutKind $o) state=$(Get-State $t)"

# C2: soft超過で提案
New-UsageTranscript $t 250
$o = Invoke-Hook "handoff-check.ps1" $stopIn
Write-Output "C2 output=$(Get-OutKind $o) state=$(Get-State $t)"

# C3: ソフト提案はサイクル1回
$o = Invoke-Hook "handoff-check.ps1" $stopIn
Write-Output "C3 output=$(Get-OutKind $o) state=$(Get-State $t)"

# C4: hard超過でエスカレーション
New-UsageTranscript $t 450
$o = Invoke-Hook "handoff-check.ps1" $stopIn
Write-Output "C4 output=$(Get-OutKind $o) state=$(Get-State $t)"

# C5: 未完了リトライ
$o = Invoke-Hook "handoff-check.ps1" $stopIn
Write-Output "C5 output=$(Get-OutKind $o) state=$(Get-State $t)"

# C6: 正しいmdで完了 → latest.json（nonce一致・sha付き）
$st = Get-Content -LiteralPath "$t.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$mdDir = "$WorkDir/proj/.claude-handoff/$sid"
New-Item -ItemType Directory -Force $mdDir | Out-Null
$md = (Get-Content -LiteralPath (Join-Path $fixtures "md/good-handoff.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st.nonce
Set-Content -LiteralPath "$mdDir/current.md" -Value $md -Encoding UTF8
$o = Invoke-Hook "handoff-check.ps1" $stopIn
$latest = Get-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$nonceMatch = "no"
if ($latest.nonce -eq $st.nonce) { $nonceMatch = "yes" }
$shaPresent = "no"
if (-not [string]::IsNullOrEmpty($latest.sha256)) { $shaPresent = "yes" }
Write-Output "C6 output=$(Get-OutKind $o) state=$(Get-State $t) latest-nonce=$nonceMatch sha=$shaPresent"

# C7: 敵対的md（## Not Goal・マーカー途中）は弾かれてリトライ
$sid7 = "11111111-2222-3333-4444-555555555555"
$t7 = "$WorkDir/t7.jsonl"
$stopIn7 = @{ session_id = $sid7; transcript_path = $t7; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t7 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn7
$st7 = Get-Content -LiteralPath "$t7.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid7" | Out-Null
$bad = (Get-Content -LiteralPath (Join-Path $fixtures "md/bad-handoff.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st7.nonce
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid7/current.md" -Value $bad -Encoding UTF8
$o = Invoke-Hook "handoff-check.ps1" $stopIn7
Write-Output "C7 output=$(Get-OutKind $o) state=$(Get-State $t7)"

# C8: restore(clear) — 有効ポインタで注入+consumed
$newSid = "99999999-8888-7777-6666-555555555555"
$restoreIn = @{ session_id = $newSid; transcript_path = "$WorkDir/new.jsonl"; cwd = "$WorkDir/proj"; hook_event_name = "SessionStart"; source = "clear" }
$o = Invoke-Hook "handoff-restore.ps1" $restoreIn
$latest2 = Get-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$consumed = "no"
if (-not [string]::IsNullOrEmpty($latest2.consumed_at)) { $consumed = "yes" }
$goal = "no"
if ($o -match '機能Aの実装') { $goal = "yes" }
Write-Output "C8 output=$(Get-OutKind $o) goal=$goal consumed=$consumed"

# C9: 消費済みポインタでは再注入しない
$o = Invoke-Hook "handoff-restore.ps1" $restoreIn
Write-Output "C9 output=$(Get-OutKind $o)"

# C10: 改竄md（マーカー後に追記）は注入拒否
$latest2.PSObject.Properties.Remove("consumed_at")
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Value ($latest2 | ConvertTo-Json) -Encoding UTF8
Add-Content -LiteralPath "$mdDir/current.md" -Value "TAMPERED" -Encoding UTF8
$o = Invoke-Hook "handoff-restore.ps1" $restoreIn
Write-Output "C10 output=$(Get-OutKind $o)"

# C11: **他実装が書いた形式**の期限切れポインタを拒否する（issue #1）
# 各実装は自分が書いた形式しか通らないため、C1〜C10 ではこの穴を検出できなかった。
# 固定リテラル（コロン付きオフセット・遠い過去）を使い、実装によらず同じ入力にする
Set-Content -LiteralPath "$mdDir/current.md" -Value $md -Encoding UTF8
$latest3 = Get-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$latest3.PSObject.Properties.Remove("consumed_at")
$latest3 | Add-Member -NotePropertyName updated_at -NotePropertyValue "2020-01-02T03:04:05+09:00" -Force
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Value ($latest3 | ConvertTo-Json) -Encoding UTF8
$o = Invoke-Hook "handoff-restore.ps1" $restoreIn
Write-Output "C11 output=$(Get-OutKind $o)"

# C12: updated_at が無いポインタは拒否（削るだけで期限を迂回できないこと）
Set-Content -LiteralPath "$mdDir/current.md" -Value $md -Encoding UTF8
$latest4 = Get-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$latest4.PSObject.Properties.Remove("consumed_at")
$latest4.PSObject.Properties.Remove("updated_at")
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Value ($latest4 | ConvertTo-Json) -Encoding UTF8
$o = Invoke-Hook "handoff-restore.ps1" $restoreIn
Write-Output "C12 output=$(Get-OutKind $o)"

# C13: 解釈できない updated_at のポインタは拒否（両実装で同じ判定になること）
Set-Content -LiteralPath "$mdDir/current.md" -Value $md -Encoding UTF8
$latest5 = Get-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$latest5.PSObject.Properties.Remove("consumed_at")
$latest5 | Add-Member -NotePropertyName updated_at -NotePropertyValue "not-a-timestamp" -Force
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/latest.json" -Value ($latest5 | ConvertTo-Json) -Encoding UTF8
$o = Invoke-Hook "handoff-restore.ps1" $restoreIn
Write-Output "C13 output=$(Get-OutKind $o)"

Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue




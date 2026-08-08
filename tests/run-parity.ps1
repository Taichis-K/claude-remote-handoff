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

# C14: 必須見出し直後の###小見出しを含む正常な資料が検証を通る（issue #4:
# 以前は###を本文終端と誤認して「本文が空」となり、検証が恒久的に失敗していた）
$sid14 = "22222222-3333-4444-5555-666666666666"
$t14 = "$WorkDir/t14.jsonl"
$stopIn14 = @{ session_id = $sid14; transcript_path = $t14; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t14 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn14
$st14 = Get-Content -LiteralPath "$t14.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid14" | Out-Null
$md14 = (Get-Content -LiteralPath (Join-Path $fixtures "md/good-handoff-subheadings.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st14.nonce
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid14/current.md" -Value $md14 -Encoding UTF8
$o = Invoke-Hook "handoff-check.ps1" $stopIn14
Write-Output "C14 output=$(Get-OutKind $o) state=$(Get-State $t14)"

# C15/C16 は理由数のps/sh一致も見るため、検証関数を直接呼ぶ（codexレビュー3回目 High-1）
. (Join-Path $hooksDir "handoff-common.ps1")

# C15: 必須見出しをすべて###へ退避した資料は拒否される（h1/h2のみが必須見出しとして有効。
# サイズ・マーカーは正しいため、理由は「見出しが無い」×7 = 7件になるはず）
$sid15 = "33333333-4444-5555-6666-777777777777"
$t15 = "$WorkDir/t15.jsonl"
$stopIn15 = @{ session_id = $sid15; transcript_path = $t15; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t15 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn15
$st15 = Get-Content -LiteralPath "$t15.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid15" | Out-Null
$md15 = (Get-Content -LiteralPath (Join-Path $fixtures "md/bad-handoff-h3.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st15.nonce
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid15/current.md" -Value $md15 -Encoding UTF8
# 理由数は2回目のフック呼び出し前に数える（呼び出し後はnonceがローテートし件数が変わるため）
$r15 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid15/current.md" -Nonce $st15.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn15
Write-Output "C15 output=$(Get-OutKind $o) state=$(Get-State $t15) reasons=$r15"

# C16: 各必須セクションが###小見出し1行だけ（実本文ゼロ）の資料は拒否される（見出し行は
# 本文に数えない。理由は「本文が空」×7 = 7件になるはず）
$sid16 = "44444444-5555-6666-7777-888888888888"
$t16 = "$WorkDir/t16.jsonl"
$stopIn16 = @{ session_id = $sid16; transcript_path = $t16; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t16 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn16
$st16 = Get-Content -LiteralPath "$t16.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid16" | Out-Null
$md16 = (Get-Content -LiteralPath (Join-Path $fixtures "md/bad-handoff-empty-sections.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st16.nonce
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid16/current.md" -Value $md16 -Encoding UTF8
$r16 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid16/current.md" -Nonce $st16.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn16
Write-Output "C16 output=$(Get-OutKind $o) state=$(Get-State $t16) reasons=$r16"

# C17: 見出しの大文字小文字違い（## goal / ## KEY DECISIONS）と空白抜き（##Goal）は
# すべて拒否される（codexレビュー4回目 H1: PSの-matchの大小無視と\s*の空白ゼロ許容で
# ps/shの合否が分裂していた。理由は「見出しが無い」×7 = 7件になるはず）
$sid17 = "55555555-6666-7777-8888-999999999999"
$t17 = "$WorkDir/t17.jsonl"
$stopIn17 = @{ session_id = $sid17; transcript_path = $t17; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t17 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn17
$st17 = Get-Content -LiteralPath "$t17.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid17" | Out-Null
$md17 = (Get-Content -LiteralPath (Join-Path $fixtures "md/bad-handoff-casespace.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st17.nonce
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid17/current.md" -Value $md17 -Encoding UTF8
$r17 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid17/current.md" -Nonce $st17.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn17
Write-Output "C17 output=$(Get-OutKind $o) state=$(Get-State $t17) reasons=$r17"

# C18: 最大サイズ（10MB）超過のcurrent.mdは内容を読まずに拒否される（codexレビュー4回目 M2:
# 巨大ファイルによるフックDoS対策。理由は「全体が最大サイズ（10MB）超過」の1件のみ）
$sid18 = "66666666-7777-8888-9999-aaaaaaaaaaaa"
$t18 = "$WorkDir/t18.jsonl"
$stopIn18 = @{ session_id = $sid18; transcript_path = $t18; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t18 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn18
$st18 = Get-Content -LiteralPath "$t18.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid18" | Out-Null
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid18/current.md" -Value ("x" * 11534336) -Encoding UTF8
$r18 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid18/current.md" -Nonce $st18.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn18
Write-Output "C18 output=$(Get-OutKind $o) state=$(Get-State $t18) reasons=$r18"

# C19: 10MB未満でも行数（改行10万超）が多すぎるcurrent.mdは拒否される（codexレビュー5回目 M1:
# 改行密集ファイルによる走査コスト膨張の遮断。理由は「全体が最大行数（100000行）超過」の1件のみ）
$sid19 = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
$t19 = "$WorkDir/t19.jsonl"
$stopIn19 = @{ session_id = $sid19; transcript_path = $t19; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t19 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn19
$st19 = Get-Content -LiteralPath "$t19.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid19" | Out-Null
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid19/current.md" -Value ("`n" * 200000) -Encoding UTF8
$r19 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid19/current.md" -Nonce $st19.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn19
Write-Output "C19 output=$(Get-OutKind $o) state=$(Get-State $t19) reasons=$r19"

# C20: 完了マーカーのnonceに\rを埋め込んだ資料は両実装とも拒否される（codexレビュー5回目 L3:
# sh版の tr -d '\r' が行中のCRまで削除して受理し、PS版と合否が分裂していた）
$sid20 = "88888888-9999-aaaa-bbbb-cccccccccccc"
$t20 = "$WorkDir/t20.jsonl"
$stopIn20 = @{ session_id = $sid20; transcript_path = $t20; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t20 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn20
$st20 = Get-Content -LiteralPath "$t20.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid20" | Out-Null
$badNonce20 = $st20.nonce.Substring(0, 4) + "`r" + $st20.nonce.Substring(4)
$md20 = (Get-Content -LiteralPath (Join-Path $fixtures "md/good-handoff.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $badNonce20
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid20/current.md" -Value $md20 -Encoding UTF8
$r20 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid20/current.md" -Nonce $st20.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn20
Write-Output "C20 output=$(Get-OutKind $o) state=$(Get-State $t20) reasons=$r20"

# C21: 完了マーカー行の行末を\r\r（+改行）にした資料は両実装とも拒否される（codexレビュー
# 6回目 L1: PS版が`r?`n分割+末尾\r除去でCRを2個消し、1個しか消さないawkと合否が分裂していた。
# 契約は「行末の\r除去は1回だけ」。理由はマーカー不一致の1件のみ）
$sid21 = "99999999-aaaa-bbbb-cccc-dddddddddddd"
$t21 = "$WorkDir/t21.jsonl"
$stopIn21 = @{ session_id = $sid21; transcript_path = $t21; cwd = "$WorkDir/proj"; hook_event_name = "Stop"; stop_hook_active = $false }
New-UsageTranscript $t21 450
$null = Invoke-Hook "handoff-check.ps1" $stopIn21
$st21 = Get-Content -LiteralPath "$t21.handoff-state.json" -Raw -Encoding UTF8 | ConvertFrom-Json
New-Item -ItemType Directory -Force "$WorkDir/proj/.claude-handoff/$sid21" | Out-Null
$md21 = (Get-Content -LiteralPath (Join-Path $fixtures "md/good-handoff.md.tmpl") -Raw -Encoding UTF8) -replace '\{\{NONCE\}\}', $st21.nonce
$md21 = $md21.Replace("$($st21.nonce) -->", "$($st21.nonce) -->`r`r")
Set-Content -LiteralPath "$WorkDir/proj/.claude-handoff/$sid21/current.md" -Value $md21 -Encoding UTF8
$r21 = (@(Get-HandoffIncompleteReasons -HandoffPath "$WorkDir/proj/.claude-handoff/$sid21/current.md" -Nonce $st21.nonce)).Count
$o = Invoke-Hook "handoff-check.ps1" $stopIn21
Write-Output "C21 output=$(Get-OutKind $o) state=$(Get-State $t21) reasons=$r21"

# KEEP_WORK=1 で作業ディレクトリを残す（失敗ケースの成果物調査用。issue #16）
if ([string]::IsNullOrEmpty($env:KEEP_WORK)) {
    Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    [Console]::Error.WriteLine("KEEP_WORK: 作業ディレクトリを残しました: $WorkDir")
}




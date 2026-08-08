# handoff-check.ps1 - 層3: Stopフック
# transcript末尾からコンテキスト使用量を実測し、2段階閾値でhandoff作成を指示する。
#   ソフト閾値: 提案のみ（区切りが良ければ作成・延期可。圧縮サイクルあたり1回）
#   ハード閾値: 強制発動（完了検証+有限リトライ attempts<3。打ち切り時はユーザーへ通知）
# 完了検証は共通の Test-HandoffComplete（nonceマーカー最終行+7見出し+本文非空）。
# 検証成功時に latest.json（ポインタ。SHA-256/サイズ込み）を更新する。
# 閾値はインストール時の明示設定必須（.claude/handoff-config.json）。設定が無ければ何もしない。
# ロジック仕様: docs/reference/handoff-check-reference.py + HANDOFF.md「層3」
# PS 5.1互換文法・UTF-8 BOM付きで保存すること

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "handoff-common.ps1")

$TAIL_LINES = 500           # usage探索でtranscript末尾から読む行数（全行走査の回避）
$MAX_ATTEMPTS = 3           # 初回1回+リトライ最大2回（ハードのみ）
$USAGE_KEYS = @("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")

function Get-UsageTotal {
    param($Usage)
    # 4キーがすべて非負整数で揃った「完全なusage」のみ合算を返す。それ以外は0（不採用）
    if ($null -eq $Usage) { return 0 }
    $total = [long]0
    foreach ($k in $USAGE_KEYS) {
        if (-not $Usage.PSObject.Properties[$k]) { return 0 }
        $v = $Usage.$k
        # boolや小数・文字列は不採用（型不正の部分行で実測値を上書きしないため）
        if ($v -is [bool]) { return 0 }
        if (-not ($v -is [int] -or $v -is [long])) { return 0 }
        if ($v -lt 0) { return 0 }
        $total = $total + [long]$v
    }
    return $total
}

function Get-LastUsageFromTranscript {
    param([string]$TranscriptPath, [int]$TailLines)
    # メインチェーン（isSidechainでない）assistant行のうち、最後の完全なusageの合算を返す
    $tokens = [long]0
    $lines = Get-Content -LiteralPath $TranscriptPath -Tail $TailLines -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        try {
            $e = $line | ConvertFrom-Json
            if ($null -eq $e -or -not $e.PSObject.Properties["type"]) { continue }
            if ($e.type -ne "assistant") { continue }
            if ($e.PSObject.Properties["isSidechain"] -and $e.isSidechain) { continue }
            if (-not $e.PSObject.Properties["message"]) { continue }
            $u = $null
            if ($null -ne $e.message -and $e.message.PSObject.Properties["usage"]) { $u = $e.message.usage }
            $t = Get-UsageTotal $u
            if ($t -gt 0) { $tokens = $t }
        } catch { }
    }
    return $tokens
}

function Test-ValidState {
    param($State)
    # 状態ファイルのスキーマ検証。JSONとして読めてもスキーマ不正なら破棄する
    # （例: completed="false"（文字列）はtruthyで恒久停止を招く）
    if ($null -eq $State) { return $false }
    if (-not $State.PSObject.Properties["mode"]) { return $false }
    if (@("soft", "hard") -notcontains $State.mode) { return $false }
    if (-not $State.PSObject.Properties["nonce"]) { return $false }
    if (-not ($State.nonce -is [string]) -or $State.nonce -notmatch '^[A-Za-z0-9-]{8,64}$') { return $false }
    if (-not $State.PSObject.Properties["attempts"]) { return $false }
    if (-not ($State.attempts -is [int] -or $State.attempts -is [long])) { return $false }
    if ($State.attempts -lt 1 -or $State.attempts -gt 9) { return $false }
    if ($State.PSObject.Properties["completed"] -and -not ($State.completed -is [bool])) { return $false }
    if ($State.PSObject.Properties["failed"] -and -not ($State.failed -is [bool])) { return $false }
    return $true
}

function New-InstructionText {
    param([string]$Mode, [string]$HandoffMd, [string]$Nonce, [int]$Attempt, [int]$MaxAttempts)
    $common = @(
        "書き先は次の絶対パス固定: $HandoffMd （このパス以外の既存ファイル、特にプロジェクトルートのHANDOFF.mdには書かないこと）。",
        "記載セクション（この7見出しをすべて `## 見出し名` の形で含め、各セクションに本文を書くこと）: Goal / Completed / Not Yet Done / Failed Approaches / Key Decisions / Current State / Resume Instructions。",
        "ファイルの最終行として完了マーカー行 <!-- handoff-complete: $Nonce --> を必ず書くこと。",
        "恒久的な決定事項があればCLAUDE.mdへも反映すること。",
        "完成したらユーザーへ「/clear の実行を推奨します（トークン消費ゼロでコンテキストをリセットでき、引き継ぎ資料は次のコンテキストに自動注入されます。Remote Control中はモバイル/Webからも実行可。放置してもauto compactが安全網として働きます）」と案内して停止すること。"
    ) -join "`n"
    if ($Mode -eq "hard") {
        $retryNote = ""
        if ($Attempt -gt 1) {
            $retryNote = "（前回の指示では完了マーカー付きの完全な引き継ぎ資料を確認できなかった。今回は必ず全7セクション+最終行マーカーで完成させること。試行 $Attempt/$MaxAttempts）`n"
        }
        return "コンテキスト使用量がハード閾値を超えました。auto compactで作業精度が落ちる前に、今の作業を一旦止めて引き継ぎ資料を作成してください。`n$retryNote$common"
    }
    return "コンテキスト使用量がソフト閾値を超えました。**作業が区切りの良いところまで来ていれば**、圧縮後も継続できるよう引き継ぎ資料を作成してください。中途半端な場合は今は作らなくてよい（次の区切りで作ること。ハード閾値到達時は強制になります）。`n作成する場合:`n$common"
}

function Write-HardInstruction {
    param([string]$StatePath, [string]$HandoffMd, [int]$Attempt, [int]$MaxAttempts)
    # 新しいnonceでハード指示を発行し、状態ファイルを原子的に更新する
    New-Item -ItemType Directory -Force -Path (Split-Path $HandoffMd -Parent) | Out-Null
    $nonce = [guid]::NewGuid().ToString()
    Write-FileAtomic -Path $StatePath -Content (@{ mode = "hard"; nonce = $nonce; attempts = $Attempt; completed = $false; failed = $false } | ConvertTo-Json)
    $text = New-InstructionText -Mode "hard" -HandoffMd $HandoffMd -Nonce $nonce -Attempt $Attempt -MaxAttempts $MaxAttempts
    Write-Output (@{ hookSpecificOutput = @{ hookEventName = "Stop"; additionalContext = $text } } | ConvertTo-Json -Depth 4)
}

$handoffRoot = $null
try {
    $inp = Read-HookInput
    if ($null -eq $inp) { exit 0 }
    $handoffRoot = Get-HandoffRoot $inp
    if ($null -eq $handoffRoot) { exit 0 }
    $projectDir = Get-ProjectDir $inp

    $transcript = $null
    if ($inp.PSObject.Properties["transcript_path"]) { $transcript = $inp.transcript_path }
    if ([string]::IsNullOrEmpty($transcript) -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }
    # session_idはパス結合に使うためUUID形式のみ許可（root外書込み防止）
    $sessionId = $null
    if ($inp.PSObject.Properties["session_id"] -and (Test-Uuid $inp.session_id)) {
        $sessionId = $inp.session_id
    }
    if ($null -eq $sessionId) { exit 0 }

    # --- 設定読込み（明示設定必須。無ければ機能無効。値も検証し不正は安全側に無効化） ---
    $configPath = Join-Path $projectDir ".claude/handoff-config.json"
    if (-not (Test-Path -LiteralPath $configPath)) { exit 0 }
    $config = $null
    try { $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $config = $null }
    if ($null -eq $config) {
        Write-HandoffError $handoffRoot "handoff-check" "handoff-config.jsonのパースに失敗。機能を無効化中"
        exit 0
    }
    $softThreshold = [long]0
    $hardThreshold = [long]0
    try {
        if ($config.PSObject.Properties["soft_threshold"]) { $softThreshold = [long]$config.soft_threshold }
        if ($config.PSObject.Properties["hard_threshold"]) { $hardThreshold = [long]$config.hard_threshold }
    } catch { }
    if ($softThreshold -le 0 -or $hardThreshold -le 0 -or $softThreshold -gt $hardThreshold) {
        Write-HandoffError $handoffRoot "handoff-check" "閾値設定が不正（soft=$softThreshold hard=$hardThreshold）。機能を無効化中"
        exit 0
    }
    # min_margin / conservative_fire_pct も範囲検証（不正値で実行時安全検査を無効化させない）
    $minMargin = [long]10000
    if ($config.PSObject.Properties["min_margin"]) {
        $mm = [long]-1
        try { $mm = [long]$config.min_margin } catch { $mm = [long]-1 }
        if ($mm -ge 0) { $minMargin = $mm } else {
            Write-HandoffError $handoffRoot "handoff-check" "min_marginが不正（$($config.min_margin)）。機能を無効化中"
            exit 0
        }
    }
    $conservativePct = 80
    if ($config.PSObject.Properties["conservative_fire_pct"]) {
        $cp = 0
        try { $cp = [int]$config.conservative_fire_pct } catch { $cp = 0 }
        if ($cp -ge 1 -and $cp -le 100) { $conservativePct = $cp } else {
            Write-HandoffError $handoffRoot "handoff-check" "conservative_fire_pctが不正（$($config.conservative_fire_pct)）。機能を無効化中"
            exit 0
        }
    }

    # 実行時best-effort再検証: 環境変数が見える場合のみ（静的検証の限界への緩和策）
    $envWindow = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW
    if (-not [string]::IsNullOrEmpty($envWindow)) {
        $w = [long]0
        if ([long]::TryParse($envWindow, [ref]$w) -and $w -gt 0) {
            $pct = $conservativePct
            $envPct = $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
            if (-not [string]::IsNullOrEmpty($envPct)) {
                $p = 0
                if ([int]::TryParse($envPct, [ref]$p) -and $p -ge 1 -and $p -le 100) { $pct = $p }
            }
            $firePoint = [long]($w * $pct / 100)
            if (($hardThreshold + $minMargin) -ge $firePoint) {
                Write-HandoffError $handoffRoot "handoff-check" "実行時再検証NG: ハード閾値$hardThreshold+マージン$minMargin >= 発火点$firePoint（window=$w pct=$pct）。handoffがcompactに間に合わないため無効化中"
                exit 0
            }
        }
    }

    # --- 状態ファイル読込み+スキーマ検証（一次判定。stop_hook_activeは異常時フォールバック） ---
    $statePath = "$transcript.handoff-state.json"
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
        if (-not (Test-ValidState $state)) {
            # 破損・スキーマ不正は削除して再生成（実装時判断メモ）。ループ防止はstop_hook_activeで代替
            $state = $null
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            if ($inp.PSObject.Properties["stop_hook_active"] -and $inp.stop_hook_active) { exit 0 }
        }
    }

    $handoffMd = Join-Path $handoffRoot "$sessionId/current.md"

    # --- 発行済みhandoff指示がある場合: 完了検証 ---
    if ($null -ne $state) {
        if ($state.PSObject.Properties["completed"] -and $state.completed) { exit 0 }
        if (Test-HandoffComplete -HandoffPath $handoffMd -Nonce $state.nonce) {
            # 完了確定: ポインタlatest.jsonを更新（restoreの必須ゲート用にSHA-256/サイズも記録）
            $pointer = @{
                session_id      = $sessionId
                handoff_path    = $handoffMd
                nonce           = $state.nonce
                transcript_path = $transcript
                updated_at      = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
                sha256          = Get-FileSha256 -Path $handoffMd
                size            = (Get-Item -LiteralPath $handoffMd).Length
            }
            Write-FileAtomic -Path (Join-Path $handoffRoot "latest.json") -Content ($pointer | ConvertTo-Json)
            Write-FileAtomic -Path $statePath -Content (@{ mode = $state.mode; nonce = $state.nonce; attempts = $state.attempts; completed = $true; failed = $false } | ConvertTo-Json)
            exit 0
        }
        # 未完了の場合
        if ($state.mode -eq "hard") {
            $attempts = [int]$state.attempts
            if ($attempts -ge $MAX_ATTEMPTS) {
                # 打ち切り。無言で止めず、初回のみユーザーへ通知する（failed遷移を記録）
                if (-not ($state.PSObject.Properties["failed"] -and $state.failed)) {
                    Write-FileAtomic -Path $statePath -Content (@{ mode = "hard"; nonce = $state.nonce; attempts = $attempts; completed = $false; failed = $true } | ConvertTo-Json)
                    Write-HandoffError $handoffRoot "handoff-check" "ハードhandoffが${MAX_ATTEMPTS}回失敗して打ち切り（session=$sessionId）"
                    Write-Output (@{ systemMessage = "claude-remote-handoff: 引き継ぎ資料の作成が${MAX_ATTEMPTS}回失敗し打ち切りました。このまま/clearすると意味的な引き継ぎなしになります。原因（書き込み権限等）を確認し、必要なら手動でhandoff作成を指示してください。" } | ConvertTo-Json)
                }
                exit 0
            }
            Write-HardInstruction -StatePath $statePath -HandoffMd $handoffMd -Attempt ($attempts + 1) -MaxAttempts $MAX_ATTEMPTS
            exit 0
        }
        # ソフト未完了は追わない（提案のみ）。ただしハード閾値到達ならエスカレーション
        $tokensNow = Get-LastUsageFromTranscript -TranscriptPath $transcript -TailLines $TAIL_LINES
        if ($tokensNow -ge $hardThreshold) {
            Write-HardInstruction -StatePath $statePath -HandoffMd $handoffMd -Attempt 1 -MaxAttempts $MAX_ATTEMPTS
        }
        exit 0
    }

    # --- 未発行: usage実測 → 閾値判定 ---
    $tokens = Get-LastUsageFromTranscript -TranscriptPath $transcript -TailLines $TAIL_LINES
    if ($tokens -lt $softThreshold) { exit 0 }

    if ($tokens -ge $hardThreshold) {
        # ハード: background_tasksが非空でも発火（これ以上待つとcompactに間に合わないため）
        Write-HardInstruction -StatePath $statePath -HandoffMd $handoffMd -Attempt 1 -MaxAttempts $MAX_ATTEMPTS
        exit 0
    }

    # ソフト: 実行中のバックグラウンドタスクがあれば見送り
    # （session_cronsは登録済み定期スケジュールを含む配列のため判定に使わない）
    if ($inp.PSObject.Properties["background_tasks"] -and $null -ne $inp.background_tasks -and
        @($inp.background_tasks).Count -gt 0) {
        exit 0
    }
    # ソフト提案は圧縮サイクルあたり1回（状態ファイルはcompact/clear/resumeのrestoreが削除する）
    New-Item -ItemType Directory -Force -Path (Split-Path $handoffMd -Parent) | Out-Null
    $nonce = [guid]::NewGuid().ToString()
    Write-FileAtomic -Path $statePath -Content (@{ mode = "soft"; nonce = $nonce; attempts = 1; completed = $false; failed = $false } | ConvertTo-Json)
    $text = New-InstructionText -Mode "soft" -HandoffMd $handoffMd -Nonce $nonce -Attempt 1 -MaxAttempts $MAX_ATTEMPTS
    Write-Output (@{ hookSpecificOutput = @{ hookEventName = "Stop"; additionalContext = $text } } | ConvertTo-Json -Depth 4)
} catch {
    Write-HandoffError $handoffRoot "handoff-check" "$($_.Exception.GetType().Name): $($_.Exception.Message)"
}
exit 0



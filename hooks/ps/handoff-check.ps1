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
$MAX_TOKEN_VALUE = [long]1000000000   # 設定値の実用上限（オーバーフロー・非現実値の排除）
$USAGE_KEYS = @("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")

function Get-ConfigLong {
    # config数値の共通検証: JSON number（文字列・bool不可）かつ整数かつ範囲内のみ通す。
    # sh版のjq検証（type=="number" and .==floor and 範囲）と同一契約
    # （codexレビュー3回目 Medium-3: 型・整数性・上限の検証がps/shで分裂していた）
    param($Value, [long]$Min, [long]$Max)
    if ($null -eq $Value) { return $null }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $null }
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    if ($d -ne [math]::Floor($d)) { return $null }
    if ($d -lt $Min -or $d -gt $Max) { return $null }
    return [long]$d
}

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
    param([string]$Mode, [string]$HandoffMd, [string]$Nonce, [int]$Attempt, [int]$MaxAttempts, [string]$FailReasons = "")
    $common = @(
        "書き先は次の絶対パス固定: $HandoffMd （このパス以外の既存ファイル、特にプロジェクトルートのHANDOFF.mdには書かないこと）。",
        "記載セクション（この7見出しをすべて `## 見出し名` の形で含め、各セクションに本文を書くこと）: Goal / Completed / Not Yet Done / Failed Approaches / Key Decisions / Current State / Resume Instructions。",
        "分量の目安: 全体で5000文字以内。長い資料は再注入時に中央（Failed Approaches / Key Decisions付近）から省略されるため、失敗した方法と決定理由ほど簡潔・確実に残すこと。",
        "ファイルの最終行として完了マーカー行 <!-- handoff-complete: $Nonce --> を必ず書くこと。",
        "恒久的な決定事項は反映先を選ぶこと: チーム共有すべき決定はCLAUDE.mdへ、このマシン・個人に固有の決定はCLAUDE.local.mdへ（無ければ作成し、.gitignoreへCLAUDE.local.mdを追加）。共有ファイルを編集してよいか判断できない場合は編集せず、本資料のKey Decisionsに記載するに留めること。",
        "完成したらユーザーへ次を案内して停止すること:「引き継ぎ資料が完成しました。Remote Control中や会話ログを残したい場合はこのまま続行してください（放置すればauto compactが働き、資料は圧縮後のコンテキストへ自動注入されます）。トークン消費を節約したい場合は /clear を実行してください（消費ゼロで資料が自動注入されます。ただし会話ログは新しい空のセッションに切り替わり、次に一言送るまで作業は自動再開されません）」"
    ) -join "`n"
    if ($Mode -eq "hard") {
        $retryNote = ""
        if ($Attempt -gt 1) {
            # ⚠️ PSは変数名にCJK文字が続くと変数名の一部と解釈する（bash 3.2の全角バグのPS版）。
            #    非ASCIIが直後に来る展開は必ず ${var} で囲むこと
            $reasonPart = ""
            if (-not [string]::IsNullOrEmpty($FailReasons)) { $reasonPart = "前回の検証NG理由: ${FailReasons}。" }
            $retryNote = "（${reasonPart}完了マーカーのnonceは試行ごとに更新される — 必ず今回の指示にある値を使うこと。試行 $Attempt/$MaxAttempts）`n"
        }
        return "コンテキスト使用量がハード閾値を超えました。auto compactで作業精度が落ちる前に、今の作業を一旦止めて引き継ぎ資料を作成してください。`n$retryNote$common"
    }
    return "コンテキスト使用量がソフト閾値を超えました。**作業が区切りの良いところまで来ていれば**、圧縮後も継続できるよう引き継ぎ資料を作成してください。中途半端な場合は今は作らなくてよい（次の区切りで作ること。ハード閾値到達時は強制になります）。`n作成する場合:`n$common"
}

function Write-HardInstruction {
    param([string]$StatePath, [string]$HandoffMd, [int]$Attempt, [int]$MaxAttempts, [string]$FailReasons = "")
    # 新しいnonceでハード指示を発行し、状態ファイルを原子的に更新する
    New-Item -ItemType Directory -Force -Path (Split-Path $HandoffMd -Parent) | Out-Null
    $nonce = [guid]::NewGuid().ToString()
    Write-FileAtomic -Path $StatePath -Content (@{ mode = "hard"; nonce = $nonce; attempts = $Attempt; completed = $false; failed = $false } | ConvertTo-Json)
    $text = New-InstructionText -Mode "hard" -HandoffMd $HandoffMd -Nonce $nonce -Attempt $Attempt -MaxAttempts $MaxAttempts -FailReasons $FailReasons
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
    $softThreshold = $null
    if ($config.PSObject.Properties["soft_threshold"]) { $softThreshold = Get-ConfigLong $config.soft_threshold 1 $MAX_TOKEN_VALUE }
    $hardThreshold = $null
    if ($config.PSObject.Properties["hard_threshold"]) { $hardThreshold = Get-ConfigLong $config.hard_threshold 1 $MAX_TOKEN_VALUE }
    if ($null -eq $softThreshold -or $null -eq $hardThreshold -or $softThreshold -gt $hardThreshold) {
        Write-HandoffError $handoffRoot "handoff-check" "閾値設定が不正（数値型・整数・範囲・soft<=hardを満たさない）。機能を無効化中"
        exit 0
    }
    # min_margin / conservative_fire_pct も範囲検証（不正値で実行時安全検査を無効化させない）
    $minMargin = [long]10000
    if ($config.PSObject.Properties["min_margin"]) {
        $minMargin = Get-ConfigLong $config.min_margin 0 $MAX_TOKEN_VALUE
        if ($null -eq $minMargin) {
            Write-HandoffError $handoffRoot "handoff-check" "min_marginが不正（$($config.min_margin)）。機能を無効化中"
            exit 0
        }
    }
    $conservativePct = 92   # setupの既定値と揃える（config手書きで省略時に静かに無効化されないため。issue #8）
    if ($config.PSObject.Properties["conservative_fire_pct"]) {
        $cp = Get-ConfigLong $config.conservative_fire_pct 1 100
        if ($null -eq $cp) {
            Write-HandoffError $handoffRoot "handoff-check" "conservative_fire_pctが不正（$($config.conservative_fire_pct)）。機能を無効化中"
            exit 0
        }
        $conservativePct = [int]$cp
    }
    # autocompact_window（任意項目）も存在するなら検証する（不正はfail closed。実行時再検証に使うため）
    $configWindow = $null
    if ($config.PSObject.Properties["autocompact_window"]) {
        $configWindow = Get-ConfigLong $config.autocompact_window 1 $MAX_TOKEN_VALUE
        if ($null -eq $configWindow) {
            Write-HandoffError $handoffRoot "handoff-check" "autocompact_windowが不正（$($config.autocompact_window)）。機能を無効化中"
            exit 0
        }
    }

    # 実行時best-effort再検証: 環境変数を最優先、見えない場合はconfigのautocompact_windowで
    # 同じ検証を行う（env不可視環境で検証が丸ごとスキップされる穴を塞ぐ。issue #9。
    # configの値は「ユーザーの申告」だが、少なくとも閾値ペアの自己矛盾は常時検出できる）
    $checkWindow = [long]0
    $windowSource = ""
    $envWindow = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW
    if (-not [string]::IsNullOrEmpty($envWindow)) {
        $w = [long]0
        if ([long]::TryParse($envWindow, [ref]$w) -and $w -gt 0 -and $w -le $MAX_TOKEN_VALUE) { $checkWindow = $w; $windowSource = "env" }
    }
    if ($checkWindow -le 0 -and $null -ne $configWindow) {
        $checkWindow = $configWindow
        $windowSource = "config"
    }
    if ($checkWindow -gt 0) {
        $pct = $conservativePct
        $envPct = $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
        if (-not [string]::IsNullOrEmpty($envPct)) {
            $p = 0
            if ([int]::TryParse($envPct, [ref]$p) -and $p -ge 1 -and $p -le 100) { $pct = $p }
        }
        $firePoint = [long]($checkWindow * $pct / 100)
        if (($hardThreshold + $minMargin) -ge $firePoint) {
            Write-HandoffError $handoffRoot "handoff-check" "実行時再検証NG: ハード閾値$hardThreshold+マージン$minMargin >= 発火点$firePoint（window=$checkWindow source=$windowSource pct=$pct）。handoffがcompactに間に合わないため無効化中"
            exit 0
        }
    }

    # --- 状態ファイル読込み+スキーマ検証（一次判定。stop_hook_activeは異常時フォールバック） ---
    $statePath = "$transcript.handoff-state.json"
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
        if (-not (Test-ValidState $state)) {
            # 破損・スキーマ不正は削除して再生成（実装時判断メモ）。ループ防止はstop_hook_activeで代替。
            # 無言で消すと手がかりが残らない（issue #20）ためerror.logに記録する
            $state = $null
            Write-HandoffError $handoffRoot "handoff-check" "不正なhandoff-stateを破棄して再生成します（$statePath）"
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
            # 検証NGの理由を次の指示文へ含める（同じ書き方の再試行で枠を浪費させない。issue #5）
            $failReasons = (@(Get-HandoffIncompleteReasons -HandoffPath $handoffMd -Nonce $state.nonce)) -join " / "
            Write-HardInstruction -StatePath $statePath -HandoffMd $handoffMd -Attempt ($attempts + 1) -MaxAttempts $MAX_ATTEMPTS -FailReasons $failReasons
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



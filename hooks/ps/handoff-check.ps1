# handoff-check.ps1 - 層3: Stopフック
# transcript末尾からコンテキスト使用量を実測し、2段階閾値でhandoff作成を指示する。
#   ソフト閾値: 提案のみ（区切りが良ければ作成・延期可。圧縮サイクルあたり1回）
#   ハード閾値: 強制発動（完了検証+有限リトライ attempts<3。打ち切り時はユーザーへ通知）
# 完了検証は共通の Test-HandoffComplete（nonceマーカー最終行+7見出し+本文非空）。
# 検証成功時に latest.json（ポインタ。SHA-256/サイズ込み）を更新する。
# 閾値はインストール時の明示設定必須（.claude/handoff-config.json）。設定が無ければ何もしない。
# ロジック仕様: docs/reference/handoff-check-reference.py + HANDOFF.md「層3」
# PS 5.1互換文法・UTF-8 BOM付きで保存すること
# 配布元: https://github.com/Taichis-K/claude-remote-handoff （導入済みバージョンは ../VERSION）

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "handoff-common.ps1")

$TAIL_LINES = 500           # usage探索でtranscript末尾から読む行数（全行走査の回避）
$MAX_ATTEMPTS = 3           # 初回1回+リトライ最大2回（ハードのみ）
$MAX_TOKEN_VALUE = [long]1000000000   # 設定値の実用上限（オーバーフロー・非現実値の排除）
# usage計測（Get-UsageTotal / Get-LastUsageFromTranscript）は restore も使うので common にある

function Get-ConfigLong {
    # config数値の共通検証: JSON number（文字列・bool不可）かつ整数かつ範囲内のみ通す。
    # sh版のjq検証（type=="number" and .==floor and 範囲）と同一契約
    # （codexレビュー3回目 Medium-3: 型・整数性・上限の検証がps/shで分裂していた）
    param($Value, [long]$Min, [long]$Max)
    # 実装は状態ファイルの数値キーと共通（common の ConvertTo-HoStateLong）。1本にしておく
    return ConvertTo-HoStateLong $Value $Min $Max
}

function Test-ValidState {
    param($State)
    # 状態ファイルのスキーマ検証。JSONとして読めてもスキーマ不正なら破棄する
    # （例: completed="false"（文字列）はtruthyで恒久停止を招く）
    if ($null -eq $State) { return $false }
    if ($State -is [System.Array]) { return $false }
    # 閉じたスキーマ（issue #38 — 設計文書4.3）: 未知キーが1つでもあればファイル無効。
    # schema_versionの検証（欠落=旧バージョンは通す/存在時は整数1のみ）もここで行う
    if (-not (Test-HoStateClosedSchema $State)) { return $false }
    if (-not (Test-HoProp $State "mode")) { return $false }
    # 型も固定する: 1要素配列["hard"]等は[string]キャストで文字列に縮退して通ってしまう（jqは拒否）
    if (-not ($State.mode -is [string])) { return $false }
    if (-not ((Test-OrdinalEqual $State.mode "soft") -or (Test-OrdinalEqual $State.mode "hard"))) { return $false }
    if (-not (Test-HoProp $State "nonce")) { return $false }
    if (-not ($State.nonce -is [string]) -or $State.nonce -cnotmatch '^[A-Za-z0-9-]{8,64}$') { return $false }
    if (-not (Test-HoProp $State "attempts")) { return $false }
    if (-not ($State.attempts -is [int] -or $State.attempts -is [long])) { return $false }
    if ($State.attempts -lt 1 -or $State.attempts -gt 9) { return $false }
    if ((Test-HoProp $State "completed") -and -not ($State.completed -is [bool])) { return $false }
    if ((Test-HoProp $State "failed") -and -not ($State.failed -is [bool])) { return $false }
    # v0.2.1の additive キー。無い（旧版が書いた状態）のは通し、あるなら型・範囲を検証する
    # （数値は「JSON number・整数値・範囲内」。1.0 / 1e3 も通す — sh版の jq と同一契約）
    if ((Test-HoProp $State "completed_tokens") -and $null -eq (ConvertTo-HoStateLong $State.completed_tokens 1 $HO_TOKENS_MAX)) { return $false }
    if ((Test-HoProp $State "completed_epoch") -and $null -eq (ConvertTo-HoStateLong $State.completed_epoch 1 $HO_EPOCH_MAX)) { return $false }
    if ((Test-HoProp $State "completed_nonce") -and
        (-not ($State.completed_nonce -is [string]) -or $State.completed_nonce -cnotmatch '\A[A-Za-z0-9-]{8,64}\z')) { return $false }
    if ((Test-HoProp $State "completed_sha256") -and
        (-not ($State.completed_sha256 -is [string]) -or $State.completed_sha256 -cnotmatch '\A[0-9A-F]{64}\z')) { return $false }
    return $true
}

function Get-CompletionCarry {
    # 状態を書き換えるときに持ち越す「直近に完成した資料」の情報（v0.2.1）。
    # 完了状態からの書き直し指示なら、その資料（nonce）が持ち越し元。書き直し中の再試行・打ち切りなら、
    # すでに持ち越している completed_nonce をそのまま引き継ぐ。無ければ $null
    param($State)
    $info = Get-HoCompletionInfo $State
    if ($null -eq $info) { return $null }
    $c = @{ completed_nonce = $info.nonce }
    if ($null -ne $info.tokens) { $c.completed_tokens = $info.tokens }
    if ($null -ne $info.epoch) { $c.completed_epoch = $info.epoch }
    if ($null -ne $info.sha) { $c.completed_sha256 = $info.sha }
    return $c
}

function New-CompletedState {
    param($State, [string]$TranscriptPath, $Epoch, $Sha)
    # 完了時に書く状態。完了時点の使用量と時刻を併記する（v0.2.1）。
    # 使用量は「資料を書き終えた直後のStop」で測る＝資料が覆っている会話の量。
    # どちらも取れない・範囲外なら**キーごと書かない**（書いた値が検証で弾かれると、
    # 状態ファイルが破棄されて指示が出直すため。sh版と同一契約）
    $s = @{ schema_version = 1; mode = $State.mode; nonce = $State.nonce; attempts = $State.attempts; completed = $true; failed = $false }
    $ct = Get-LastUsageFromTranscript -TranscriptPath $TranscriptPath -TailLines $TAIL_LINES
    if ($ct -ge 1 -and $ct -le $MAX_TOKEN_VALUE) { $s.completed_tokens = [long]$ct }
    if ($null -ne $Epoch -and $Epoch -ge 1 -and $Epoch -le $HO_EPOCH_MAX) { $s.completed_epoch = [long]$Epoch }
    # 完成した資料のSHA-256（ポインタに書くものと同じ値）。restoreが状態ファイルのnonceで検証するとき、
    # 資料が完成後に書き換えられていないことの照合に使う（書き直し指示の途中の資料を「検証済み」にしないため）
    if (($Sha -is [string]) -and $Sha -cmatch '\A[0-9A-F]{64}\z') { $s.completed_sha256 = $Sha }
    return $s
}

function Get-DraftPath {
    param([string]$HandoffMd)
    # current.md と同じディレクトリの draft.md。区切り文字は current.md のパスの表記に合わせる（sh版 ${1%/*}/draft.md 相当）
    $i = [Math]::Max($HandoffMd.LastIndexOf([char]47), $HandoffMd.LastIndexOf([char]92))
    return ($HandoffMd.Substring(0, $i + 1) + "draft.md")
}

function Move-HandoffDraft {
    # 完了検証に通った下書きを current.md へ置き換える（設計メモ 2026-09-13 §10.2。sh版は mv -f）。
    # current.md があれば File.Replace（NTFS の ReplaceFile で置き換えが1操作）。Move-Item -Force は宛先を
    # 消してから移すので、その間に restore が読むと「資料が見つからない」になり得る。
    # 第3引数（バックアップ先）に $null を渡すと PS が空文字へ変換して ArgumentException になるため
    # [NullString]::Value を渡す（PS 5.1 で実測）。読み取り専用の current.md / draft.md は Replace が
    # UnauthorizedAccessException になるが sh の mv -f は置き換えるので、両方の属性を外してから置き換える。
    # 失敗は例外のまま呼び出し側へ返す（呼び出し側は未完了として扱う）
    param([string]$Draft, [string]$Current)
    if (Test-Path -LiteralPath $Current -PathType Container) { throw "current.md is a directory" }
    if (-not (Test-Path -LiteralPath $Current)) {
        [System.IO.File]::Move($Draft, $Current)
        return
    }
    $ro = [System.IO.FileAttributes]::ReadOnly
    foreach ($p in @($Current, $Draft)) {
        $attr = [System.IO.File]::GetAttributes($p)
        if (($attr -band $ro) -eq $ro) { [System.IO.File]::SetAttributes($p, ($attr -bxor $ro)) }
    }
    [System.IO.File]::Replace($Draft, $Current, [NullString]::Value)
}

function New-InstructionText {
    param([string]$Mode, [string]$HandoffMd, [string]$Nonce, [int]$Attempt, [int]$MaxAttempts, [string]$FailReasons = "", [switch]$Refresh)
    # 書き先は下書き（current.md と同じディレクトリの draft.md）。完了検証に通った下書きだけを check が
    # current.md へ置き換えるので、書いている途中・検証NGの間も current.md は直前の検証済み資料のまま
    # （設計メモ docs/design/2026-09-13-refresh-and-freshness.md。sh版と同一文言）
    $draftMd = Get-DraftPath $HandoffMd
    $common = @(
        "書き先は次の絶対パス固定: ${draftMd} （完了検証に通ると自動で ${HandoffMd} に置き換わる。このパス以外の既存ファイル、特にプロジェクトルートのHANDOFF.mdには書かないこと）。",
        "記載セクション（この7見出しをすべて `## 見出し名` の形で含め、各セクションに本文を書くこと）: Goal / Completed / Not Yet Done / Failed Approaches / Key Decisions / Current State / Resume Instructions。",
        "分量の目安: 全体で5000文字以内。長い資料は再注入時に中央（Failed Approaches / Key Decisions付近）から省略されるため、失敗した方法と決定理由ほど簡潔・確実に残すこと。",
        "ファイルの最終行として完了マーカー行 <!-- handoff-complete: $Nonce --> を必ず書くこと。",
        "恒久的な決定事項は反映先を選ぶこと: チーム共有すべき決定はCLAUDE.mdへ、このマシン・個人に固有の決定はCLAUDE.local.mdへ（無ければ作成し、.gitignoreへCLAUDE.local.mdを追加）。共有ファイルを編集してよいか判断できない場合は編集せず、本資料のKey Decisionsに記載するに留めること。",
        "完成したらユーザーへ次を案内して停止すること:「引き継ぎ資料が完成しました。Remote Control中や会話ログを残したい場合はこのまま続行してください（放置すればauto compactが働き、資料は圧縮後のコンテキストへ自動注入されます）。トークン消費を節約したい場合は /clear を実行してください（消費ゼロで資料が自動注入されます。ただし会話ログは新しい空のセッションに切り替わり、次に一言送るまで作業は自動再開されません）」"
    ) -join "`n"
    if (Test-OrdinalEqual $Mode "hard") {
        $retryNote = ""
        if ($Attempt -gt 1) {
            # ⚠️ PSは変数名にCJK文字が続くと変数名の一部と解釈する（bash 3.2の全角バグのPS版）。
            #    非ASCIIが直後に来る展開は必ず ${var} で囲むこと
            $reasonPart = ""
            if (-not [string]::IsNullOrEmpty($FailReasons)) { $reasonPart = "前回の検証NG理由: ${FailReasons}。" }
            $retryNote = "（${reasonPart}完了マーカーのnonceは試行ごとに更新される — 必ず今回の指示にある値を使うこと。試行 $Attempt/$MaxAttempts）`n"
        }
        $refreshNote = ""
        if ($Refresh) {
            $refreshNote = "（この会話にはハード閾値に達する前に作った引き継ぎ資料 ${HandoffMd} がありますが、その後の作業が反映されていません。それを読み、いまの状態に合わせて書き直したものを下記の書き先へ書いてください）`n"
        }
        return "コンテキスト使用量がハード閾値を超えました。auto compactで作業精度が落ちる前に、今の作業を一旦止めて引き継ぎ資料を作成してください。`n$retryNote$refreshNote$common"
    }
    return "コンテキスト使用量がソフト閾値を超えました。**作業が区切りの良いところまで来ていれば**、圧縮後も継続できるよう引き継ぎ資料を作成してください。中途半端な場合は今は作らなくてよい（次の区切りで作ること。ハード閾値到達時は強制になります）。`n作成する場合:`n$common"
}

function Write-HardInstruction {
    param([string]$StatePath, [string]$HandoffMd, [int]$Attempt, [int]$MaxAttempts, [string]$FailReasons = "", [switch]$Refresh, $Carry = $null)
    # 新しいnonceでハード指示を発行し、状態ファイルを原子的に更新する。
    # $Carry は直近に完成した資料の情報（Get-CompletionCarry）。書き直しの指示中も旧資料を
    # restoreが検証・鮮度表示できるよう、新しい状態へ持ち越す
    New-Item -ItemType Directory -Force -Path (Split-Path $HandoffMd -Parent) | Out-Null
    $nonce = [guid]::NewGuid().ToString()
    $newState = @{ schema_version = 1; mode = "hard"; nonce = $nonce; attempts = $Attempt; completed = $false; failed = $false }
    if ($null -ne $Carry) { foreach ($k in $Carry.Keys) { $newState[$k] = $Carry[$k] } }
    Write-FileAtomic -Path $StatePath -Content ($newState | ConvertTo-Json)
    $text = New-InstructionText -Mode "hard" -HandoffMd $HandoffMd -Nonce $nonce -Attempt $Attempt -MaxAttempts $MaxAttempts -FailReasons $FailReasons -Refresh:$Refresh
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
    if ((Test-HoProp $inp "transcript_path") -and ($inp.transcript_path -is [string])) { $transcript = $inp.transcript_path }
    if ([string]::IsNullOrEmpty($transcript) -or -not (Test-Path -LiteralPath $transcript)) { exit 0 }
    # session_idはパス結合に使うためUUID形式のみ許可（root外書込み防止）
    $sessionId = $null
    if ((Test-HoProp $inp "session_id") -and (Test-Uuid $inp.session_id)) {
        $sessionId = $inp.session_id
    }
    if ($null -eq $sessionId) { exit 0 }

    # --- 設定読込み（明示設定必須。無ければ機能無効。値も検証し不正は安全側に無効化） ---
    $configPath = Join-Path $projectDir ".claude/handoff-config.json"
    if (-not (Test-Path -LiteralPath $configPath)) { exit 0 }
    $config = $null
    try { $config = ConvertFrom-JsonPreserve (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8) } catch { $config = $null }
    # ルートがobject以外（配列・スカラー）は不正（shのjq `type == "object"` と同一契約。
    # パイプラインのConvertFrom-Jsonはpwshで1要素ルート配列がオブジェクトへ縮退し
    # 不正configが有効扱いになっていた — 罠9）
    if (-not ($config -is [System.Management.Automation.PSCustomObject])) { $config = $null }
    if ($null -eq $config) {
        Write-HandoffError $handoffRoot "handoff-check" "handoff-config.jsonのパースに失敗。機能を無効化中"
        exit 0
    }
    # 閉じたスキーマ（issue #38 — 設計文書4.4）: 既知キー以外が1つでもあれば機能無効
    # （タイポで閾値が既定値に静かに落ちる事故と、未知キー経由の将来の解釈分裂を防ぐ）
    if (-not (Test-HoOnlyKnownKeys $config $HO_CONFIG_KNOWN_KEYS)) {
        Write-HandoffError $handoffRoot "handoff-check" "handoff-config.jsonに未知のキーがあります。機能を無効化中"
        exit 0
    }
    $softThreshold = $null
    if ((Test-HoProp $config "soft_threshold")) { $softThreshold = Get-ConfigLong $config.soft_threshold 1 $MAX_TOKEN_VALUE }
    $hardThreshold = $null
    if ((Test-HoProp $config "hard_threshold")) { $hardThreshold = Get-ConfigLong $config.hard_threshold 1 $MAX_TOKEN_VALUE }
    if ($null -eq $softThreshold -or $null -eq $hardThreshold -or $softThreshold -gt $hardThreshold) {
        Write-HandoffError $handoffRoot "handoff-check" "閾値設定が不正（数値型・整数・範囲・soft<=hardを満たさない）。機能を無効化中"
        exit 0
    }
    # min_margin / conservative_fire_pct も範囲検証（不正値で実行時安全検査を無効化させない）
    $minMargin = [long]10000
    if ((Test-HoProp $config "min_margin")) {
        $minMargin = Get-ConfigLong $config.min_margin 0 $MAX_TOKEN_VALUE
        if ($null -eq $minMargin) {
            Write-HandoffError $handoffRoot "handoff-check" "min_marginが不正（$($config.min_margin)）。機能を無効化中"
            exit 0
        }
    }
    $conservativePct = 92   # setupの既定値と揃える（config手書きで省略時に静かに無効化されないため。issue #8）
    if ((Test-HoProp $config "conservative_fire_pct")) {
        $cp = Get-ConfigLong $config.conservative_fire_pct 1 100
        if ($null -eq $cp) {
            Write-HandoffError $handoffRoot "handoff-check" "conservative_fire_pctが不正（$($config.conservative_fire_pct)）。機能を無効化中"
            exit 0
        }
        $conservativePct = [int]$cp
    }
    # autocompact_window は必須（issue #32: fire-point検証のfail-closed化。windowが解決
    # できないまま機能が有効になる「compactより確実に前で発火」の保証抜けを廃止。
    # setupは常に書くため、無いのは旧configか手書き漏れ — 無効化+診断で気づける）
    $configWindow = $null
    if ((Test-HoProp $config "autocompact_window")) {
        $configWindow = Get-ConfigLong $config.autocompact_window 1 $MAX_TOKEN_VALUE
    }
    if ($null -eq $configWindow) {
        Write-HandoffError $handoffRoot "handoff-check" "autocompact_windowが無いか不正（v0.1.3から必須。/contextの総量に合わせて設定すること）。機能を無効化中"
        exit 0
    }

    # fire-point検証（常時実施 — fail-closed）: 環境変数を最優先、無効・未設定ならconfig。
    # 環境変数ゲート（issue #32）: ^[0-9]{1,10}$ のみ受理し、先頭ゼロ除去の10進解釈+範囲検査。
    # 違反は「未設定」扱いでconfigへフォールバック（TryParse直渡しは空白・符号に寛容 — 罠8と同型）
    # アンカーは \A..\z（^$ は末尾LF・行単位一致を許すため、改行混入値が通る — 全文一致で遮断）
    $checkWindow = $configWindow
    $windowSource = "config"
    $envWindow = $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW
    if (-not [string]::IsNullOrEmpty($envWindow) -and $envWindow -cmatch '\A[0-9]{1,10}\z') {
        $t = $envWindow.TrimStart("0")
        if ($t.Length -eq 0) { $t = "0" }
        $w = [long]0
        if ([long]::TryParse($t, [ref]$w) -and $w -ge 1 -and $w -le $MAX_TOKEN_VALUE) { $checkWindow = $w; $windowSource = "env" }
    }
    $pct = $conservativePct
    $envPct = $env:CLAUDE_AUTOCOMPACT_PCT_OVERRIDE
    if (-not [string]::IsNullOrEmpty($envPct) -and $envPct -cmatch '\A[0-9]{1,10}\z') {
        $tp = $envPct.TrimStart("0")
        if ($tp.Length -eq 0) { $tp = "0" }
        $p = 0
        if ([int]::TryParse($tp, [ref]$p) -and $p -ge 1 -and $p -le 100) { $pct = $p }
    }
    # 発火点はfloor固定（[long]キャストは最近接丸めのため、shの整数除算〔切り捨て〕と
    # .5以上の端数で合否が分裂していた — issue #32で floor に統一）
    $firePoint = [long][Math]::Floor(([double]$checkWindow) * $pct / 100)
    if (($hardThreshold + $minMargin) -ge $firePoint) {
        Write-HandoffError $handoffRoot "handoff-check" "実行時再検証NG: ハード閾値$hardThreshold+マージン$minMargin >= 発火点$firePoint（window=$checkWindow source=$windowSource pct=$pct）。handoffがcompactに間に合わないため無効化中"
        exit 0
    }

    # --- 状態ファイル読込み+スキーマ検証（一次判定。stop_hook_activeは異常時フォールバック） ---
    # 状態ファイルの作成・削除はprojects_root配下の包含ゲートを通った場合のみ（issue #33）。
    # ゲートNGは状態管理不能のため診断を残して終了（transcriptは実在してここまで来ている
    # ため、通常運用でNGになるのはprojects_root外・UNCプロファイル等に限られる）
    $statePath = Get-ValidStateFilePath -TranscriptPath $transcript -Mode "write"
    if ($null -eq $statePath) {
        # 非信頼パスは制御文字を?へ置換してから記録（改行入りパスによるログ行偽装・
        # 端末制御文字混入を防ぐ — codexレビュー#33-1 L5）
        $safeTp = [regex]::Replace([string]$transcript, '[\x00-\x1F\x7F]', '?')
        Write-HandoffError $handoffRoot "handoff-check" "transcript_pathがprojects_root配下の正規パスでないため状態ファイルを扱えません。機能を無効化中（path=$safeTp）"
        exit 0
    }
    $state = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $state = ConvertFrom-JsonPreserve (Get-Content -LiteralPath $statePath -Raw -Encoding UTF8) } catch { $state = $null }
        if (-not (Test-ValidState $state)) {
            # 破損・スキーマ不正は削除して再生成（実装時判断メモ）。ループ防止はstop_hook_activeで代替。
            # 無言で消すと手がかりが残らない（issue #20）ためerror.logに記録する
            $state = $null
            Write-HandoffError $handoffRoot "handoff-check" "不正なhandoff-stateを破棄して再生成します（$statePath）"
            Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
            # 有効扱いはboolean trueか文字列"true"のみ（sh版の `jq -r … = "true"` と同一契約。
            # 文字列"false"はtruthyのため旧実装は誤ってループ停止していた — 罠8の型固定）
            $shv = $null
            if ((Test-HoProp $inp "stop_hook_active")) { $shv = $inp.stop_hook_active }
            if (($shv -is [bool] -and $shv) -or (($shv -is [string]) -and (Test-OrdinalEqual $shv "true"))) { exit 0 }
        }
    }

    $handoffMd = Join-Path $handoffRoot "$sessionId/current.md"

    # --- 発行済みhandoff指示がある場合: 完了検証 ---
    if ($null -ne $state) {
        if ((Test-HoProp $state "completed") -and $state.completed) {
            # 完了済み。原則はこのサイクルで何もしない（状態ファイルはcompact/clear/resumeの
            # restoreが消す）が、**ソフト閾値で作った資料は、ハード閾値を越えたら1度だけ
            # 書き直させる**（v0.2.1）。以前は完了した時点で以後の指示が一切出ず、
            # ソフト段階で資料を作ったあとも作業を続けると、その作業が資料に無いまま圧縮に入っていた。
            # 対象は mode が soft の完了だけ。hard の完了は（閾値の設定をあとから変えても）書き直さない。
            # soft でも完成時の使用量（completed_tokens）がハード閾値以上なら書き直さない。
            # completed_tokens が無いのは v0.2.0 以前が書いた状態で、そのときは書き直す
            # （完成がハード閾値以上だった場合に1回余計に書くことがあるが、安全側）。
            # 書き直しは**ハード閾値の時点に限る**: そこはmin_marginを残して圧縮より前に
            # 書き終えられる地点として検証済みで、それより後で指示を出すと書いている最中に圧縮が来得る。
            # 書き直しの指示中に圧縮されても旧資料を復元できるよう、旧資料の nonce と値を
            # 新しい状態へ持ち越す（Get-CompletionCarry。restoreがそれで検証する）
            $needMeasure = $false
            if (Test-OrdinalEqual ([string]$state.mode) "soft") {
                $doneTokens = $null
                if ((Test-HoProp $state "completed_tokens")) { $doneTokens = ConvertTo-HoStateLong $state.completed_tokens 1 $HO_TOKENS_MAX }
                if ($null -eq $doneTokens -or $doneTokens -lt $hardThreshold) { $needMeasure = $true }
            }
            if ($needMeasure) {
                $tokensNow = Get-LastUsageFromTranscript -TranscriptPath $transcript -TailLines $TAIL_LINES
                if ($tokensNow -ge $hardThreshold) {
                    Write-HardInstruction -StatePath $statePath -HandoffMd $handoffMd -Attempt 1 -MaxAttempts $MAX_ATTEMPTS -Refresh -Carry (Get-CompletionCarry $state)
                }
            }
            exit 0
        }
        # 完了判定（設計メモ §10.1）: まず下書きを検証し、通れば current.md へ置き換えてから完了にする。
        # 下書きが通らなくても current.md が今回の nonce で通れば完了（v0.2.0 の指示を受けた途中のサイクルと、
        # モデルが current.md へ直接書いた場合。HEAD と同じ扱い。書き直し指示中の current.md は旧 nonce なので通らない）
        $draftMd = Get-DraftPath $handoffMd
        $completeNow = $false
        $replaceFailed = $false
        if (Test-HandoffComplete -HandoffPath $draftMd -Nonce $state.nonce) {
            try {
                Move-HandoffDraft -Draft $draftMd -Current $handoffMd
                $completeNow = $true
            } catch {
                # 完了にしない。未完了として下へ進む（hard は再試行に数えて打ち切り・通知の経路に乗せる。
                # soft は追わない）。current.md は置き換え前の検証済み資料のまま。打ち切り（failed）後は Stop ごとに増えるので記録しない
                $replaceFailed = $true
                if (-not ((Test-HoProp $state "failed") -and $state.failed)) { Write-HandoffError $handoffRoot "handoff-check" "検証済みの下書きをcurrent.mdへ置き換えられませんでした（session=$sessionId / $($_.Exception.GetBaseException().GetType().Name)）" }
            }
        } elseif (Test-HandoffComplete -HandoffPath $handoffMd -Nonce $state.nonce) {
            $completeNow = $true
        }
        if ($completeNow) {
            # 完了確定: まずSHA-256を計算し、失敗時はポインタを更新しない（issue #31:
            # sha256=nullは「整合性ゲートの明示的無効化」経路でproducer失敗と改竄を
            # 区別できないため廃止）。stateはcompletedへ進める（AVロック等は再試行しても
            # 解けないことが多く、指示ループを避ける）。旧latest.jsonはそのまま残す:
            # 他セッションのものなら正当な復元対象のまま、自セッション前サイクルのものは
            # 旧nonceの完了検証で拒否され、仮に通っても内容変更時はSHA不一致で拒否される（安全方向）
            $sha = Get-FileSha256 -Path $handoffMd
            # 鮮度判定の正になるupdated_epoch（UNIX秒整数。issue #34）。取得失敗は
            # SHA計算失敗と同じ縮退（ポインタ非更新+通知） — consumerはepoch無しを
            # fail-closedで拒否するため、書いても使われない
            $ue = Get-HoNowEpoch
            $shaOk = ($sha -is [string]) -and $sha.Length -gt 0
            if (-not $shaOk -or $null -eq $ue) {
                $failKind = "SHA-256計算"
                if ($shaOk) { $failKind = "現在時刻(epoch)取得" }
                # 通知はstate書き込み（completed遷移）の成功後のみ出す: 遷移前に通知すると
                # 次のStopでも完了検証から再突入して同じ通知を繰り返す（sh版と同一契約）
                try {
                    Write-FileAtomic -Path $statePath -Content ((New-CompletedState -State $state -TranscriptPath $transcript -Epoch $ue -Sha $sha) | ConvertTo-Json)
                } catch {
                    Write-HandoffError $handoffRoot "handoff-check" "${failKind}失敗後のstate書き込みにも失敗しました（session=$sessionId）"
                    exit 0
                }
                Write-HandoffError $handoffRoot "handoff-check" "${failKind}に失敗したためポインタ(latest.json)を更新しません（session=$sessionId）"
                Write-Output (@{ systemMessage = "claude-remote-handoff: 引き継ぎ資料は完成しましたが、${failKind}に失敗したため復元用ポインタ(latest.json)を更新しませんでした。/clearでの自動復元は行われない可能性があります。資料: $handoffMd" } | ConvertTo-Json)
                exit 0
            }
            # ポインタlatest.jsonを更新（restoreの必須ゲート用にSHA-256/サイズも記録）。
            # 鮮度判定の正はupdated_epoch（UNIX秒整数。issue #34）。updated_at/handoff_path/
            # sizeは表示・移行用の併記（additive — 設計文書5章。ダウングレード窓のため当面維持）
            $ua = Get-HoNowDisplay
            if ($null -eq $ua) { $ua = "" }
            $pointer = @{
                schema_version  = 1
                session_id      = $sessionId
                handoff_path    = $handoffMd
                nonce           = $state.nonce
                transcript_path = $transcript
                updated_epoch   = $ue
                updated_at      = $ua
                consumed        = $false
                sha256          = $sha
                size            = (Get-Item -LiteralPath $handoffMd).Length
            }
            Write-FileAtomic -Path (Join-Path $handoffRoot "latest.json") -Content ($pointer | ConvertTo-Json)
            Write-FileAtomic -Path $statePath -Content ((New-CompletedState -State $state -TranscriptPath $transcript -Epoch $ue -Sha $sha) | ConvertTo-Json)
            exit 0
        }
        # 未完了の場合
        if (Test-OrdinalEqual ([string]$state.mode) "hard") {
            $attempts = [int]$state.attempts
            if ($attempts -ge $MAX_ATTEMPTS) {
                # 打ち切り。無言で止めず、初回のみユーザーへ通知する（failed遷移を記録）
                if (-not ((Test-HoProp $state "failed") -and $state.failed)) {
                    $failedState = @{ schema_version = 1; mode = "hard"; nonce = $state.nonce; attempts = $attempts; completed = $false; failed = $true }
                    $carry = Get-CompletionCarry $state
                    if ($null -ne $carry) { foreach ($k in $carry.Keys) { $failedState[$k] = $carry[$k] } }
                    Write-FileAtomic -Path $statePath -Content ($failedState | ConvertTo-Json)
                    Write-HandoffError $handoffRoot "handoff-check" "ハードhandoffが${MAX_ATTEMPTS}回失敗して打ち切り（session=$sessionId）"
                    Write-Output (@{ systemMessage = "claude-remote-handoff: 引き継ぎ資料の作成が${MAX_ATTEMPTS}回失敗し打ち切りました。このまま/clearすると意味的な引き継ぎなしになります。原因（書き込み権限等）を確認し、必要なら手動でhandoff作成を指示してください。" } | ConvertTo-Json)
                }
                exit 0
            }
            # 検証NGの理由を次の指示文へ含める（同じ書き方の再試行で枠を浪費させない。issue #5）
            # 理由は指示の書き先（下書き）について出す。下書きが通っていて置き換えだけ失敗した場合はその旨を出す
            if ($replaceFailed) {
                $failReasons = "下書きは検証に通ったが current.md へ置き換えられない（current.md が他のプロセスに開かれている・権限が無い等を確認すること）"
            } else {
                $failReasons = (@(Get-HandoffIncompleteReasons -HandoffPath $draftMd -Nonce $state.nonce)) -join " / "
            }
            Write-HardInstruction -StatePath $statePath -HandoffMd $handoffMd -Attempt ($attempts + 1) -MaxAttempts $MAX_ATTEMPTS -FailReasons $failReasons -Carry (Get-CompletionCarry $state)
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
    if ((Test-HoProp $inp "background_tasks") -and ($inp.background_tasks -is [System.Array]) -and
        @($inp.background_tasks).Count -gt 0) {
        # 配列以外は0件扱い（sh版の `if type == "array" then length else 0 end` と同一契約）
        exit 0
    }
    # ソフト提案は圧縮サイクルあたり1回（状態ファイルはcompact/clear/resumeのrestoreが削除する）
    New-Item -ItemType Directory -Force -Path (Split-Path $handoffMd -Parent) | Out-Null
    $nonce = [guid]::NewGuid().ToString()
    Write-FileAtomic -Path $statePath -Content (@{ schema_version = 1; mode = "soft"; nonce = $nonce; attempts = 1; completed = $false; failed = $false } | ConvertTo-Json)
    $text = New-InstructionText -Mode "soft" -HandoffMd $handoffMd -Nonce $nonce -Attempt 1 -MaxAttempts $MAX_ATTEMPTS
    Write-Output (@{ hookSpecificOutput = @{ hookEventName = "Stop"; additionalContext = $text } } | ConvertTo-Json -Depth 4)
} catch {
    Write-HandoffError $handoffRoot "handoff-check" "$($_.Exception.GetType().Name): $($_.Exception.Message)"
}
exit 0



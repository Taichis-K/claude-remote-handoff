# handoff-restore.ps1 - 層1: SessionStartフック（matcher: compact / clear）
# 機械的合成の再注入文をstdoutへ出力する（LLM不使用・意味的要約はしない）。
# 本文予算9,000文字（current.md 5,500〔先頭3,500+末尾2,000〕/ git 2,000 /
# 直近ユーザーメッセージ 1,200 / バックアップ導線 300）+ 見出し等で合計10,000文字以内。
#
# handoff解決（codex敵対的レビュー1回目の反映）:
#  - compact: 自session_idの直接参照を最優先（並行セッションのポインタ誤注入を回避）
#  - clear: ポインタ latest.json（session_idが変わるため）。ただし
#    * ポインタ内のパスは信用せず、検証済みUUIDのsession_idからroot配下にパスを再構築する
#    * 完了検証（nonceマーカー+構造）+ SHA-256照合を必須ゲートとし、
#      失敗時はcurrent.mdの内容を一切注入しない（警告と導線のみ）
#    * 消費済み（dual-read: consumed==true または consumed_at非空）と、updated_epoch
#      （鮮度判定の唯一の正）が無い/不正/未来skew超/7日超のポインタは使わない
#  - バックアップ導線は解決したセッションのものに限定（セッション間の情報混入防止）
# 処理順序: 状態読取り → current.md検証 → 合成 → stdout出力 → 状態削除
# PS 5.1互換文法・UTF-8 BOM付きで保存すること。HANDOFF.md「層1」参照

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "handoff-common.ps1")

$BUDGET_CURRENT_HEAD = 3500
$BUDGET_CURRENT_TAIL = 2000
$BUDGET_GIT = 2000
$BUDGET_MSGS_TOTAL = 1200
$BUDGET_MSG_EACH = 300
$MSG_MAX_COUNT = 5
$BUDGET_BACKUP = 300
$TOTAL_MAX = 10000
$GIT_TIMEOUT_MS = 10000
$POINTER_MAX_AGE_DAYS = 7
$POINTER_FUTURE_SKEW_SEC = 86400

$handoffRoot = $null
try {
    $inp = Read-HookInput
    if ($null -eq $inp) { exit 0 }
    $handoffRoot = Get-HandoffRoot $inp
    if ($null -eq $handoffRoot) { exit 0 }
    $projectDir = Get-ProjectDir $inp

    $source = ""
    if ((Test-HoProp $inp "source") -and ($inp.source -is [string])) { $source = $inp.source }
    $ownSessionId = $null
    if ((Test-HoProp $inp "session_id") -and (Test-Uuid $inp.session_id)) {
        $ownSessionId = $inp.session_id
    }

    # --- 状態ファイル削除の共通処理（出力の有無に関わらず最後に実行する） ---
    $stateFileToDelete = $null
    if ((Test-HoProp $inp "transcript_path")) {
        # 削除・参照対象はprojects_root配下の包含ゲートを通った実在通常ファイルのみ
        # （issue #33 — 挙動変更）。ゲートNG・不存在はnull＝従来の「stateなし」と同じ扱い
        $stateFileToDelete = Get-ValidStateFilePath -TranscriptPath $inp.transcript_path -Mode "delete"
    }

    # --- 1. ポインタ読込み（スキーマ・鮮度・消費済みを検証） ---
    $pointer = $null
    $latestPath = Join-Path $handoffRoot "latest.json"
    if (Test-Path -LiteralPath $latestPath) {
        try { $pointer = ConvertFrom-JsonPreserve (Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8) } catch { $pointer = $null }
        # ルートがobject以外（配列・スカラー）は無効（jqのtype=="object"検証と同一契約 — 罠8。
        # 非objectは診断なしの静かな無効: sh版のnotobj分岐と同一。またPSObject.Propertiesが
        # 型固有プロパティ（string.Length等）を列挙して未知キー誤検出するため先に落とす）
        if (-not ($pointer -is [System.Management.Automation.PSCustomObject])) { $pointer = $null }
    }
    if ($null -ne $pointer) {
        # session_id（UUID）とnonceの形式検証。パスはポインタから採らない
        $ok = $true
        # 閉じたスキーマ（issue #38 — 設計文書4.2）: 既知キー以外が1つでもあればファイル無効。
        # schema_versionは必須の整数1（欠落=旧形式 / 不一致=未知の形式でログ文言を区別 —
        # 旧producerのポインタは次のhandoffサイクルで再生成される）。判定はjqの
        # `.schema_version == 1`（数値比較）と同一契約: 数値型のみ受理しdoubleへ正規化して比較
        if (-not (Test-HoOnlyKnownKeys $pointer $HO_POINTER_KNOWN_KEYS)) {
            $ok = $false
            Write-HandoffError $handoffRoot "restore" "latest.jsonに未知のキーがあります。ポインタを無効として扱いました"
        }
        if ($ok) {
            if (-not (Test-HoProp $pointer "schema_version")) {
                $ok = $false
                Write-HandoffError $handoffRoot "restore" "latest.jsonにschema_versionがありません（旧形式のポインタ）。ポインタを無効として扱いました"
            } else {
                $sv = $pointer.schema_version
                $svOk = (($sv -is [int]) -or ($sv -is [long]) -or ($sv -is [double]) -or ($sv -is [decimal])) -and
                    (([double]$sv) -eq 1)
                if (-not $svOk) {
                    $ok = $false
                    Write-HandoffError $handoffRoot "restore" "latest.jsonのschema_versionが1ではありません（未知の形式）。ポインタを無効として扱いました"
                }
            }
        }
        if ($ok -and ((-not (Test-HoProp $pointer "session_id")) -or -not (Test-Uuid $pointer.session_id))) { $ok = $false }
        if ($ok -and (-not (Test-HoProp $pointer "nonce") -or
            -not ($pointer.nonce -is [string]) -or $pointer.nonce -cnotmatch '^[A-Za-z0-9-]{8,64}$')) { $ok = $false }
        # 消費済みポインタは使わない（古いhandoffの無期限再生を防ぐ）。dual-read（issue #34 —
        # 設計文書4.2）: consumed == true または consumed_at が非空文字列 なら消費済み。
        # consumedは存在するならbooleanのみ許可（型固定 — 罠8。"true"等の文字列縮退で
        # sh版jqと受否が分裂しないよう、非booleanはポインタごと無効にする）
        if ($ok -and (Test-HoProp $pointer "consumed")) {
            if (-not ($pointer.consumed -is [bool]) -or $pointer.consumed) { $ok = $false }
        }
        # consumed_atで許可するのは欠落・null・空文字列のみで型も固定する（配列[""]等はPSの
        # 文字列縮退で未消費扱いになり、ポインタごと拒否するsh版jqと分裂する — 罠8）
        if ($ok -and (Test-HoProp $pointer "consumed_at") -and $null -ne $pointer.consumed_at) {
            if (-not ($pointer.consumed_at -is [string]) -or $pointer.consumed_at.Length -gt 0) { $ok = $false }
        }
        # 有効期限。鮮度判定の唯一の正はupdated_epoch＝UNIX秒の整数（issue #34 — 挙動変更）。
        # 人間可読日時のパース（TryParseExact/date）は判定経路から排除し、updated_atは表示専用。
        # 契約: 数値型かつ整数値・0 < v・v ≤ now+86400（未来skew上限1日）・now-v ≤ 7日。
        # 旧producerのポインタ（updated_epochなし）はfail-closed → 次サイクルで再生成される。
        # 整数値判定はjqの `. == floor` と同一契約: 型はJSONパーサ依存（int/long/double/decimal）
        # のため整数値の数値のみ受理し、文字列・配列等は拒否。比較はPSの数値昇格に任せる
        # （範囲検証が2^53超のdoubleを先に落とすので[long]キャストによるオーバーフローはない）
        if ($ok) {
            $nowEpoch = Get-HoNowEpoch
            if ($null -eq $nowEpoch) {
                # nowを取得できなければ鮮度を判定できない（fail-closed。sh版と同一契約）
                $ok = $false
                Write-HandoffError $handoffRoot "restore" "現在時刻(epoch)を取得できないため鮮度判定できません。ポインタを無効として扱いました"
            } else {
                $epochState = "bad"
                if ((Test-HoProp $pointer "updated_epoch")) {
                    $v = $pointer.updated_epoch
                    if (($v -is [int]) -or ($v -is [long]) -or ($v -is [double]) -or ($v -is [decimal])) {
                        # jq互換: パーサ表現によらずdoubleへ正規化してから整数値判定・範囲比較する
                        # （PS 5.1のdecimalはsub-ULP小数を保持し、doubleへ丸めるpwsh/jqと受否が
                        # 分裂する — レビュー1回目 M2。契約は「double化された値が整数」）
                        $d = [double]$v
                        if (($d -eq [math]::Truncate($d)) -and ($d -gt 0) -and
                            ($d -le ($nowEpoch + $POINTER_FUTURE_SKEW_SEC))) {
                            # 契約内の値: 期限超過のみ静かに無効（毎回の復元でerror.logを
                            # 埋めない — 旧updated_at時代の期限切れと同じ扱い）
                            if (($nowEpoch - $d) -le ($POINTER_MAX_AGE_DAYS * 86400)) { $epochState = "ok" }
                            else { $epochState = "expired" }
                        }
                    }
                }
                if ($epochState -ne "ok") {
                    $ok = $false
                    if ($epochState -eq "bad") {
                        Write-HandoffError $handoffRoot "restore" "latest.jsonのupdated_epochが無いか不正です。ポインタを無効として扱いました"
                    }
                }
            }
        }
        if (-not $ok) { $pointer = $null }
    }

    # --- 2. handoff解決: compactは自session直接参照を最優先、clearはポインタ ---
    $resolvedSessionId = $null   # current.md/バックアップ導線を読むセッション
    $handoffOrigin = ""
    $usePointer = $false
    if (-not (Test-OrdinalEqual $source "clear") -and $null -ne $ownSessionId -and
        (Test-Path -LiteralPath (Join-Path $handoffRoot "$ownSessionId/current.md"))) {
        $resolvedSessionId = $ownSessionId
        $handoffOrigin = "セッションディレクトリ直接参照（$ownSessionId）"
    } elseif ($null -ne $pointer) {
        $resolvedSessionId = $pointer.session_id
        $usePointer = $true
        # updated_atは非信頼の表示値（鮮度検証から外れた — issue #34）。producer形式の
        # 1行に一致する場合のみ表示する（改行入り指示や巨大文字列が有効なepoch+SHAの
        # ままで復元出力へ注入される経路を遮断 — レビュー1回目 H1。sh版と同一契約）。
        # アンカーは \A/\z（文字列端）: .NET/Onigurumaとも $ は末尾改行の手前に一致し得る
        # ため、^/$ では改行入り値が一致・混入する（レビュー2回目 H1）
        $updDisp = "?"
        if ((Test-HoProp $pointer "updated_at") -and ($pointer.updated_at -is [string]) -and
            $pointer.updated_at -cmatch '\A[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([+-]((0[0-9]|1[0-3]):?[0-5][0-9]|14:?00)|[Zz])\z') {
            $updDisp = $pointer.updated_at
        }
        $handoffOrigin = "latest.json経由（作成セッション: $($pointer.session_id) / 更新: $updDisp）"
    } elseif ($null -ne $ownSessionId -and
        (Test-Path -LiteralPath (Join-Path $handoffRoot "$ownSessionId/current.md"))) {
        # clearでポインタ不在でも、稀にsession_idが維持される環境に備えたフォールバック
        $resolvedSessionId = $ownSessionId
        $handoffOrigin = "セッションディレクトリ直接参照（$ownSessionId）"
    }

    # パスは検証済みUUIDから再構築し、root配下であることも確認（ポインタのパスは信用しない）
    $currentMdPath = $null
    if ($null -ne $resolvedSessionId) {
        $candidate = Join-Path $handoffRoot "$resolvedSessionId/current.md"
        if ((Test-PathUnderRoot -Root $handoffRoot -Candidate $candidate) -and
            (Test-Path -LiteralPath $candidate)) {
            $currentMdPath = $candidate
        }
    }

    # --- 3. 必須ゲート: 完了検証 + SHA-256照合（有効なポインタが関与する場合のみ） ---
    $gatePassed = $false
    $gateNote = ""
    if ($null -ne $currentMdPath) {
        $verifyNonce = $null
        if ($usePointer) { $verifyNonce = $pointer.nonce }
        elseif ($null -ne $pointer -and (Test-OrdinalEqual ([string]$pointer.session_id) ([string]$resolvedSessionId))) { $verifyNonce = $pointer.nonce }
        elseif (-not (Test-OrdinalEqual $source "clear") -and $null -ne $stateFileToDelete -and
                (Test-Path -LiteralPath $stateFileToDelete)) {
            # compactで自セッション参照時: 削除前の状態ファイル（completed済み）のnonceで検証できる
            # （並行セッションがポインタを上書きしていても自分のhandoffを検証可能にする）
            try {
                $ownState = ConvertFrom-JsonPreserve (Get-Content -LiteralPath $stateFileToDelete -Raw -Encoding UTF8)
                # 閉じたスキーマ（issue #38）: 未知キー入り・schema_version不正のstateは
                # nonce源として使わない（check側の破棄契約と同一の受否 — sh版と同一契約）
                if ($null -ne $ownState -and -not ($ownState -is [System.Array]) -and
                    (Test-HoStateClosedSchema $ownState) -and
                    (Test-HoProp $ownState "completed") -and
                    ($ownState.completed -is [bool]) -and $ownState.completed -and
                    (Test-HoProp $ownState "nonce") -and ($ownState.nonce -is [string]) -and
                    $ownState.nonce -cmatch '^[A-Za-z0-9-]{8,64}$') {
                    $verifyNonce = $ownState.nonce
                }
            } catch { }
        }
        if ($null -ne $verifyNonce) {
            if (Test-HandoffComplete -HandoffPath $currentMdPath -Nonce $verifyNonce) {
                $gatePassed = $true
                # ポインタのSHA-256で「検証時点から改変されていない」ことも照合する。
                # 照合するのはポインタ経由時か、ポインタが解決先セッション自身のものの場合のみ
                # （自セッション直接参照時に他セッションのポインタと照合すると誤拒否になる —
                # sh版と同一契約）。sha256は必須（issue #31: 欠落・null・空文字列の照合スキップ
                # 縮退を廃止 — fail-closed。producerはSHA計算失敗時にポインタを書かなくなった
                # ため、無いのは旧形式か改変）。型も固定: 文字列以外（配列等）は不一致として拒否
                # （jqの-r出力が配列をJSON文字列にして不一致になるのと同じ失敗方向）
                if ($null -ne $pointer -and
                    ($usePointer -or (Test-OrdinalEqual ([string]$pointer.session_id) ([string]$resolvedSessionId)))) {
                    $pSha = $null
                    if ((Test-HoProp $pointer "sha256")) { $pSha = $pointer.sha256 }
                    if ($null -eq $pSha -or (($pSha -is [string]) -and $pSha.Length -eq 0)) {
                        $gatePassed = $false
                        $gateNote = "SHA-256照合不可（ポインタにsha256が無い）"
                    } elseif (-not ($pSha -is [string])) {
                        $gatePassed = $false
                        $gateNote = "SHA-256不一致（ポインタのsha256が文字列でない）"
                    } else {
                        $h = Get-FileSha256 -Path $currentMdPath
                        if ($null -eq $h -or -not (Test-OrdinalEqual $h $pSha)) {
                            $gatePassed = $false
                            $gateNote = "SHA-256不一致（完了検証後にcurrent.mdが改変されている）"
                        }
                    }
                }
            } else {
                $gateNote = "完了検証NG（マーカー/構造が不正 — 未完成か改変の可能性）"
            }
        } else {
            $gateNote = "検証情報なし（ポインタが無くnonceを確認できない）"
        }
    }

    # --- 4. バックアップ導線（解決したセッションのもののみ。セッション間の混入防止） ---
    $newestBackup = $null
    if ($null -ne $resolvedSessionId) {
        $backupDir = Join-Path $handoffRoot "$resolvedSessionId/backup"
        if (Test-Path -LiteralPath $backupDir) {
            $newestBackup = Get-ChildItem -LiteralPath $backupDir -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending | Select-Object -First 1
        }
    }

    # 注入すべきものが何も無ければ無言で終了する（状態ファイルの削除だけ行う）
    if ($null -eq $currentMdPath -and $null -eq $newestBackup) {
        if ($null -ne $stateFileToDelete -and (Test-Path -LiteralPath $stateFileToDelete)) {
            Remove-Item -LiteralPath $stateFileToDelete -Force -ErrorAction SilentlyContinue
        }
        exit 0
    }

    $sections = New-Object System.Collections.Generic.List[string]
    $sections.Add("# 引き継ぎコンテキスト自動再注入（claude-remote-handoff / source: $source）")

    # ポインタ経由で自分以外のセッションの資料を注入する場合は冒頭で明示する
    # （同一プロジェクトで複数セッションを並行させると他セッションの資料が来得る。issue #19）
    if ($usePointer -and ($null -eq $ownSessionId -or -not (Test-OrdinalEqual ([string]$pointer.session_id) ([string]$ownSessionId)))) {
        $sections.Add("※ この資料は別セッション（$($pointer.session_id)）で作成されたものです。同一プロジェクトで複数のセッションを併用している場合は、現在の作業に対応する内容か確認してから使うこと。")
    }

    # --- 5. current.md（検証ゲートを通過した場合のみ内容を注入する） ---
    if ($null -ne $currentMdPath -and $gatePassed) {
        $mdText = Get-Content -LiteralPath $currentMdPath -Raw -Encoding UTF8
        $sections.Add("## 引き継ぎ資料 current.md（$handoffOrigin / 検証済み）")
        $sections.Add((Limit-TextHeadTail -Text $mdText -Head $BUDGET_CURRENT_HEAD -Tail $BUDGET_CURRENT_TAIL))
    } elseif ($null -ne $currentMdPath) {
        $sections.Add("## 引き継ぎ資料 current.md: ⚠️ 検証に失敗したため注入しない（$gateNote）。必要なら下記バックアップから状況を確認すること")
    } else {
        $sections.Add("## 引き継ぎ資料 current.md: 見つからない（下記バックアップ導線から復元を検討すること）")
    }

    # --- 6. git状態（--stat要約のみ。予算2,000文字） ---
    if ($null -ne $projectDir -and (Test-GitRepo -WorkDir $projectDir -TmpDir $handoffRoot)) {
        $gitParts = New-Object System.Collections.Generic.List[string]
        $gitCmds = @(
            @{ Label = "status --porcelain"; GitArgs = @("status", "--porcelain") },
            @{ Label = "diff --stat";        GitArgs = @("diff", "--no-ext-diff", "--stat") },
            @{ Label = "diff --cached --stat"; GitArgs = @("diff", "--cached", "--no-ext-diff", "--stat") }
        )
        foreach ($cmd in $gitCmds) {
            $tmpOut = New-TempPath -Dir $handoffRoot -Prefix "restore-git"
            $r = Invoke-GitCapture -GitArgs $cmd.GitArgs -OutFile $tmpOut -WorkDir $projectDir `
                -TimeoutMs $GIT_TIMEOUT_MS -MaxBytes 65536
            $txt = ""
            if (Test-Path -LiteralPath $tmpOut) {
                $txt = Get-Content -LiteralPath $tmpOut -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
            }
            if ($null -ne $txt -and $txt.Trim().Length -gt 0) {
                $gitParts.Add("### git $($cmd.Label)")
                $gitParts.Add($txt.Trim())
            } elseif ($r -ne "ok") {
                $gitParts.Add("### git $($cmd.Label): 取得失敗（$r）")
            }
        }
        if ($gitParts.Count -gt 0) {
            $sections.Add("## git状態")
            $sections.Add((Limit-Text -Text ($gitParts -join "`n") -MaxChars $BUDGET_GIT))
        }
    }

    # --- 7. 直近ユーザーメッセージ（text contentのみ・最大5件・合計1,200文字） ---
    # compact: 自transcript / clear: ポインタ記録の旧transcript
    # （ポインタのtranscript_pathは ~/.claude/projects 配下であることを検証してから読む）
    $srcTranscript = $null
    if (Test-OrdinalEqual $source "clear") {
        if ($usePointer -and (Test-HoProp $pointer "transcript_path") -and
            ($pointer.transcript_path -is [string]) -and
            -not [string]::IsNullOrEmpty($pointer.transcript_path)) {
            # $env:USERPROFILEはLinux/macOSに存在しない（CI実測でJoin-Pathが例外→出力中断）
            $projectsRoot = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".claude/projects"
            if ((Test-PathUnderRoot -Root $projectsRoot -Candidate $pointer.transcript_path) -and
                (Test-Path -LiteralPath $pointer.transcript_path)) {
                $srcTranscript = $pointer.transcript_path
            }
        }
    } else {
        if ((Test-HoProp $inp "transcript_path") -and ($inp.transcript_path -is [string]) -and
            -not [string]::IsNullOrEmpty($inp.transcript_path) -and
            (Test-Path -LiteralPath $inp.transcript_path)) {
            $srcTranscript = $inp.transcript_path
        }
    }
    if ($null -ne $srcTranscript) {
        $userTexts = New-Object System.Collections.Generic.List[string]
        # 末尾2,000行だけ読む（O(n)全走査の回避と読取り競合の軽減）
        $lines = Get-Content -LiteralPath $srcTranscript -Tail 2000 -Encoding UTF8 -ErrorAction SilentlyContinue
        foreach ($line in $lines) {
            try {
                # 行全体が配列のJSONは不正行として無視（jqのselect(type=="object")と同一契約）
                $e = ConvertFrom-JsonPreserve $line
                if ($null -eq $e -or ($e -is [System.Array])) { continue }
                if (-not (Test-HoProp $e "type")) { continue }
                if (-not ($e.type -is [string]) -or -not (Test-OrdinalEqual $e.type "user")) { continue }
                # 除外はboolean trueのみ（jqの `!= true` と同一契約 — 罠8の型固定）
                if ((Test-HoProp $e "isSidechain") -and ($e.isSidechain -is [bool]) -and $e.isSidechain) { continue }
                if ((Test-HoProp $e "isMeta") -and ($e.isMeta -is [bool]) -and $e.isMeta) { continue }
                if (-not (Test-HoProp $e "message")) { continue }
                if ($e.message -is [System.Array]) { continue }
                $content = Get-HoProp $e.message "content"
                $text = ""
                if ($content -is [string]) {
                    # 日時形式の文字列もそのまま（ConvertFrom-JsonPreserveが全実装で原表記の
                    # 文字列を返す契約 — [datetime]は現れない。罠9）
                    $text = $content
                } elseif ($content -is [System.Array]) {
                    # 構造化content: type=textのみ採用（tool_result等は除外）
                    $parts = @()
                    foreach ($c in $content) {
                        if ($null -ne $c -and (Test-HoProp $c "type") -and ($c.type -is [string]) -and (Test-OrdinalEqual $c.type "text") -and
                            (Test-HoProp $c "text")) {
                            if ($c.text -is [string]) { $parts += $c.text }
                        }
                    }
                    $text = $parts -join "`n"
                }
                if ([string]::IsNullOrWhiteSpace($text)) { continue }
                # ローカルコマンド結果・コマンドマークアップ・システム注入を除外
                if ($text -match '^\s*<') { continue }
                if ($text.Length -gt $BUDGET_MSG_EACH) { $text = $text.Substring(0, $BUDGET_MSG_EACH) + "..." }
                $userTexts.Add($text)
            } catch { }
        }
        if ($userTexts.Count -gt 0) {
            # 新しいものを優先し、超過分は古いものから削る（表示は時系列順）
            $selected = New-Object System.Collections.Generic.List[string]
            $total = 0
            for ($i = $userTexts.Count - 1; $i -ge 0; $i--) {
                if ($selected.Count -ge $MSG_MAX_COUNT) { break }
                $t = $userTexts[$i]
                if (($total + $t.Length) -gt $BUDGET_MSGS_TOTAL) { break }
                $selected.Insert(0, $t)
                $total = $total + $t.Length
            }
            if ($selected.Count -gt 0) {
                $sections.Add("## 直近のユーザーメッセージ（古い順）")
                $n = 0
                foreach ($t in $selected) {
                    $n++
                    $sections.Add("$n. $t")
                }
            }
        }
    }

    # --- 8. バックアップ導線（予算300文字。絶対パスを最優先で残す） ---
    if ($null -ne $newestBackup) {
        $bkInfo = "## 全文バックアップ導線`n$($newestBackup.FullName)"
        $metaPath = Join-Path $newestBackup.FullName "meta.json"
        if (Test-Path -LiteralPath $metaPath) {
            # meta.jsonが存在すれば行自体は常に付与し、値は「ルートがobjectかつ文字列」の
            # 場合のみ表示（それ以外は空欄）。sh版のjq型分岐と同一契約（罠8/罠9 —
            # 旧実装はパイプラインConvertFrom-Jsonでルート配列が縮退し、型も不問だった）
            $bkSavedAt = ""
            $bkTranscript = ""
            try {
                $bkMeta = ConvertFrom-JsonPreserve (Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8)
                if ($bkMeta -is [System.Management.Automation.PSCustomObject]) {
                    if ((Test-HoProp $bkMeta "saved_at")) {
                        if ($bkMeta.saved_at -is [string]) { $bkSavedAt = $bkMeta.saved_at }
                    }
                    if ((Test-HoProp $bkMeta "items") -and
                        ($bkMeta.items -is [System.Management.Automation.PSCustomObject]) -and
                        (Test-HoProp $bkMeta.items "transcript") -and
                        ($bkMeta.items.transcript -is [string])) {
                        $bkTranscript = $bkMeta.items.transcript
                    }
                }
            } catch { }
            $bkInfo = "$bkInfo`n保存: $bkSavedAt / transcript: $bkTranscript"
        }
        $sections.Add((Limit-Text -Text $bkInfo -MaxChars $BUDGET_BACKUP))
    }

    # --- 9. 合成・出力（最終ガード10,000文字） ---
    $final = $sections -join "`n`n"
    if ($final.Length -gt $TOTAL_MAX) { $final = $final.Substring(0, $TOTAL_MAX) }
    Write-Output $final

    # --- 10. ポインタの消費マーク（clearでポインタ経由の注入をした場合のみ）。
    #         dual-write（issue #34 — 設計文書4.2）: consumed=true と非空consumed_atを
    #         同一のatomic更新で書く（旧consumerはconsumed_atのみ読むため両方必要） ---
    if ($usePointer -and (Test-OrdinalEqual $source "clear") -and $gatePassed) {
        try {
            # consumed_atは必ず非空にする（日時取得失敗で空を書くと旧consumerが未消費と
            # 読みdual-writeの移行保証が破れる — レビュー1回目 M3）。失敗時は検証済み
            # now（ポインタ経路ではepoch検証で取得済み）のepoch表記へフォールバック
            $cAt = Get-HoNowDisplay
            if (($null -eq $cAt) -or ($cAt.Length -eq 0)) { $cAt = "epoch:$nowEpoch" }
            $pointer | Add-Member -NotePropertyName "consumed" -NotePropertyValue $true -Force
            $pointer | Add-Member -NotePropertyName "consumed_at" -NotePropertyValue $cAt -Force
            Write-FileAtomic -Path $latestPath -Content ($pointer | ConvertTo-Json)
        } catch { }
    }

    # --- 11. 状態ファイル削除（現transcript_path基準。clear後の旧状態ファイルは
    #         削除機会がなく孤児化する → save側のretentionが日数基準で掃除する） ---
    if ($null -ne $stateFileToDelete -and (Test-Path -LiteralPath $stateFileToDelete)) {
        Remove-Item -LiteralPath $stateFileToDelete -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-HandoffError $handoffRoot "handoff-restore" "$($_.Exception.GetType().Name): $($_.Exception.Message)"
}
exit 0




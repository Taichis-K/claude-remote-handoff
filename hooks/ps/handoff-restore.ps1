# handoff-restore.ps1 - 層1: SessionStartフック（matcher: compact / clear）
# 機械的合成の再注入文をstdoutへ出力する（LLM不使用・意味的要約はしない）。
# 本文予算9,000文字（current.md 5,500〔先頭3,500+末尾2,000〕/ git 2,000 /
# 直近ユーザーメッセージ 1,200 / バックアップ導線 300）+ 見出し等で合計10,000文字以内。
#
# handoff解決（codex敵対的レビュー1回目の反映）:
#  - compact: 自session_idの直接参照を最優先（並行セッションのポインタ誤注入を回避）
#  - clear: ポインタ latest.json（session_idが変わるため）。ただし
#    * ポインタ内のパスは信用せず、検証済みUUIDのsession_idからroot配下にパスを再構築する
#    * 完了検証（nonceマーカー+構造）+ SHA-256/サイズ照合を必須ゲートとし、
#      失敗時はcurrent.mdの内容を一切注入しない（警告と導線のみ）
#    * consumed_at（消費済み）と有効期限7日を超えたポインタは使わない
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

$handoffRoot = $null
try {
    $inp = Read-HookInput
    if ($null -eq $inp) { exit 0 }
    $handoffRoot = Get-HandoffRoot $inp
    if ($null -eq $handoffRoot) { exit 0 }
    $projectDir = Get-ProjectDir $inp

    $source = ""
    if ($inp.PSObject.Properties["source"]) { $source = $inp.source }
    $ownSessionId = $null
    if ($inp.PSObject.Properties["session_id"] -and (Test-Uuid $inp.session_id)) {
        $ownSessionId = $inp.session_id
    }

    # --- 状態ファイル削除の共通処理（出力の有無に関わらず最後に実行する） ---
    $stateFileToDelete = $null
    if ($inp.PSObject.Properties["transcript_path"] -and -not [string]::IsNullOrEmpty($inp.transcript_path)) {
        $stateFileToDelete = "$($inp.transcript_path).handoff-state.json"
    }

    # --- 1. ポインタ読込み（スキーマ・鮮度・消費済みを検証） ---
    $pointer = $null
    $latestPath = Join-Path $handoffRoot "latest.json"
    if (Test-Path -LiteralPath $latestPath) {
        try { $pointer = Get-Content -LiteralPath $latestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $pointer = $null }
    }
    if ($null -ne $pointer) {
        # session_id（UUID）とnonceの形式検証。パスはポインタから採らない
        $ok = $true
        if (-not $pointer.PSObject.Properties["session_id"] -or -not (Test-Uuid $pointer.session_id)) { $ok = $false }
        if ($ok -and (-not $pointer.PSObject.Properties["nonce"] -or
            -not ($pointer.nonce -is [string]) -or $pointer.nonce -notmatch '^[A-Za-z0-9-]{8,64}$')) { $ok = $false }
        # 消費済みポインタは使わない（古いhandoffの無期限再生を防ぐ）
        if ($ok -and $pointer.PSObject.Properties["consumed_at"] -and
            -not [string]::IsNullOrEmpty($pointer.consumed_at)) { $ok = $false }
        # 有効期限。**時刻が無い/解釈できないポインタは信用しない**（fail-closed。sh版と同一契約）。
        # producerは両実装とも必ずupdated_atを書くので、無い・読めないのは改変か壊れた記録。
        # 素通りさせると「updated_atを消す/壊すだけで期限を無期限に迂回できる」
        if ($ok) {
            $rawUpdated = ""
            if ($pointer.PSObject.Properties["updated_at"]) { $rawUpdated = [string]$pointer.updated_at }
            if ([string]::IsNullOrEmpty($rawUpdated)) {
                $ok = $false
                Write-HandoffError $handoffRoot "restore" "latest.jsonにupdated_atがありません。ポインタを無効として扱いました"
            }
            else {
                $ts = [datetime]::MinValue
                if ([datetime]::TryParse($rawUpdated, [ref]$ts)) {
                    if ($ts -lt (Get-Date).AddDays(-$POINTER_MAX_AGE_DAYS)) { $ok = $false }
                }
                else {
                    $ok = $false
                    Write-HandoffError $handoffRoot "restore" "latest.jsonのupdated_atを解釈できません（$rawUpdated）。ポインタを無効として扱いました"
                }
            }
        }
        if (-not $ok) { $pointer = $null }
    }

    # --- 2. handoff解決: compactは自session直接参照を最優先、clearはポインタ ---
    $resolvedSessionId = $null   # current.md/バックアップ導線を読むセッション
    $handoffOrigin = ""
    $usePointer = $false
    if ($source -ne "clear" -and $null -ne $ownSessionId -and
        (Test-Path -LiteralPath (Join-Path $handoffRoot "$ownSessionId/current.md"))) {
        $resolvedSessionId = $ownSessionId
        $handoffOrigin = "セッションディレクトリ直接参照（$ownSessionId）"
    } elseif ($null -ne $pointer) {
        $resolvedSessionId = $pointer.session_id
        $usePointer = $true
        $handoffOrigin = "latest.json経由（作成セッション: $($pointer.session_id) / 更新: $($pointer.updated_at)）"
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

    # --- 3. 必須ゲート: 完了検証 + SHA-256/サイズ照合（ポインタ経由時） ---
    $gatePassed = $false
    $gateNote = ""
    if ($null -ne $currentMdPath) {
        $verifyNonce = $null
        if ($usePointer) { $verifyNonce = $pointer.nonce }
        elseif ($null -ne $pointer -and $pointer.session_id -eq $resolvedSessionId) { $verifyNonce = $pointer.nonce }
        elseif ($source -ne "clear" -and $null -ne $stateFileToDelete -and
                (Test-Path -LiteralPath $stateFileToDelete)) {
            # compactで自セッション参照時: 削除前の状態ファイル（completed済み）のnonceで検証できる
            # （並行セッションがポインタを上書きしていても自分のhandoffを検証可能にする）
            try {
                $ownState = Get-Content -LiteralPath $stateFileToDelete -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($null -ne $ownState -and $ownState.PSObject.Properties["completed"] -and
                    ($ownState.completed -is [bool]) -and $ownState.completed -and
                    $ownState.PSObject.Properties["nonce"] -and ($ownState.nonce -is [string]) -and
                    $ownState.nonce -match '^[A-Za-z0-9-]{8,64}$') {
                    $verifyNonce = $ownState.nonce
                }
            } catch { }
        }
        if ($null -ne $verifyNonce) {
            if (Test-HandoffComplete -HandoffPath $currentMdPath -Nonce $verifyNonce) {
                $gatePassed = $true
                # ポインタにSHA-256があれば「検証時点から改変されていない」ことも照合
                if ($pointer.PSObject.Properties["sha256"] -and -not [string]::IsNullOrEmpty($pointer.sha256)) {
                    $h = Get-FileSha256 -Path $currentMdPath
                    if ($null -eq $h -or $h -ne $pointer.sha256) {
                        $gatePassed = $false
                        $gateNote = "SHA-256不一致（完了検証後にcurrent.mdが改変されている）"
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
    if ($usePointer -and ($null -eq $ownSessionId -or $pointer.session_id -ne $ownSessionId)) {
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
    if ($source -eq "clear") {
        if ($usePointer -and $pointer.PSObject.Properties["transcript_path"] -and
            -not [string]::IsNullOrEmpty($pointer.transcript_path)) {
            # $env:USERPROFILEはLinux/macOSに存在しない（CI実測でJoin-Pathが例外→出力中断）
            $projectsRoot = Join-Path ([Environment]::GetFolderPath("UserProfile")) ".claude/projects"
            if ((Test-PathUnderRoot -Root $projectsRoot -Candidate $pointer.transcript_path) -and
                (Test-Path -LiteralPath $pointer.transcript_path)) {
                $srcTranscript = $pointer.transcript_path
            }
        }
    } else {
        if ($inp.PSObject.Properties["transcript_path"] -and
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
                $e = $line | ConvertFrom-Json
                if ($null -eq $e) { continue }
                if (-not $e.PSObject.Properties["type"]) { continue }
                if ($e.type -ne "user") { continue }
                if ($e.PSObject.Properties["isSidechain"] -and $e.isSidechain) { continue }
                if ($e.PSObject.Properties["isMeta"] -and $e.isMeta) { continue }
                if (-not $e.PSObject.Properties["message"]) { continue }
                $content = $e.message.content
                $text = ""
                if ($content -is [string]) {
                    $text = $content
                } elseif ($content -is [System.Array]) {
                    # 構造化content: type=textのみ採用（tool_result等は除外）
                    $parts = @()
                    foreach ($c in $content) {
                        if ($null -ne $c -and $c.PSObject.Properties["type"] -and $c.type -eq "text") {
                            $parts += $c.text
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
            try {
                $bkMeta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $bkInfo = "$bkInfo`n保存: $($bkMeta.saved_at) / transcript: $($bkMeta.items.transcript)"
            } catch { }
        }
        $sections.Add((Limit-Text -Text $bkInfo -MaxChars $BUDGET_BACKUP))
    }

    # --- 9. 合成・出力（最終ガード10,000文字） ---
    $final = $sections -join "`n`n"
    if ($final.Length -gt $TOTAL_MAX) { $final = $final.Substring(0, $TOTAL_MAX) }
    Write-Output $final

    # --- 10. ポインタの消費マーク（clearでポインタ経由の注入をした場合のみ） ---
    if ($usePointer -and $source -eq "clear" -and $gatePassed) {
        try {
            $pointer | Add-Member -NotePropertyName "consumed_at" `
                -NotePropertyValue ((Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")) -Force
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




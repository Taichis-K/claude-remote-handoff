# handoff-save.ps1 - 層1: PreCompactフック
# transcript JSONL全文とgit状態（status/diff/diff --cached/untrackedを区別）を
# .claude/handoff/<session_id>/backup/<timestamp>/ へ世代管理付きで保存する。
# エラー時も作業を妨げない（常にexit 0）が、error.logへbest-effortで記録する。
# PS 5.1互換文法・UTF-8 BOM付きで保存すること。HANDOFF.md「層1」参照

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "handoff-common.ps1")

# 上限・保持の既定値
$GIT_TIMEOUT_MS = 10000
$GIT_MAX_BYTES = 2000000           # gitコマンド毎の出力上限（約2MB）
$KEEP_GENERATIONS = 3               # セッション毎のバックアップ世代数
$RETENTION_DAYS = 30                # セッションディレクトリ・孤児状態ファイルの保持日数
$MAX_TRANSCRIPT_BYTES = 200MB       # transcriptコピーの上限（超過時はコピーせず記録のみ）
$MAX_TOTAL_BYTES = 500MB            # 全セッション横断の合計容量上限

$handoffRoot = $null
try {
    $inp = Read-HookInput
    if ($null -eq $inp) { exit 0 }
    $handoffRoot = Get-HandoffRoot $inp
    if ($null -eq $handoffRoot) { exit 0 }
    $projectDir = Get-ProjectDir $inp

    # session_idはパス結合に使うためUUID形式のみ許可（不正値は定数"unknown"に落とす）
    $sessionId = "unknown"
    if ($inp.PSObject.Properties["session_id"] -and (Test-Uuid $inp.session_id)) {
        $sessionId = $inp.session_id
    }
    $transcript = $null
    if ($inp.PSObject.Properties["transcript_path"]) { $transcript = $inp.transcript_path }

    if (-not (Test-Path $handoffRoot)) {
        New-Item -ItemType Directory -Force -Path $handoffRoot | Out-Null
    }

    $isRepo = Test-GitRepo -WorkDir $projectDir -TmpDir $handoffRoot

    # 保存先配下にtrackedファイルがある場合は保存を無効化（バックアップ自身がdiffに入り
    # 再帰的に肥大化するため。勝手にgit rm --cachedはしない）
    if ($isRepo) {
        $trackedProbe = New-TempPath -Dir $handoffRoot -Prefix "tracked-probe"
        $r = Invoke-GitCapture -GitArgs @("ls-files", "--", ".claude-handoff") -OutFile $trackedProbe `
            -WorkDir $projectDir -TimeoutMs $GIT_TIMEOUT_MS -MaxBytes 65536
        $tracked = ""
        if (Test-Path -LiteralPath $trackedProbe) {
            $tracked = (Get-Content -LiteralPath $trackedProbe -Raw -ErrorAction SilentlyContinue)
            Remove-Item -LiteralPath $trackedProbe -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $tracked -and $tracked.Trim().Length -gt 0) {
            Write-HandoffError $handoffRoot "handoff-save" ".claude-handoff配下にgit trackedなファイルがあるため保存を無効化しました。.gitignoreに .claude-handoff/ を追加し、trackedファイルを整理してください"
            exit 0
        }
    }

    $stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $destDir = Join-Path $handoffRoot "$sessionId/backup/$stamp"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null

    $items = @{}

    # 1. transcript全文コピー（非同期書き込み中でもCopy-Itemはその時点のスナップショットを取る）
    #    サイズ上限と空きディスク容量をbest-effortで事前確認（1回の保存でディスクフルにしない）
    if ($null -ne $transcript -and (Test-Path -LiteralPath $transcript)) {
        try {
            $tSize = (Get-Item -LiteralPath $transcript).Length
            $freeOk = $true
            try {
                $qualifier = [System.IO.Path]::GetPathRoot($destDir)
                $drive = New-Object System.IO.DriveInfo($qualifier)
                if ($drive.AvailableFreeSpace -lt ($tSize * 2)) { $freeOk = $false }
            } catch { }
            if ($tSize -gt $MAX_TRANSCRIPT_BYTES) {
                $items["transcript"] = "skipped-too-large($tSize bytes)"
            } elseif (-not $freeOk) {
                $items["transcript"] = "skipped-low-disk-space"
                Write-HandoffError $handoffRoot "handoff-save" "空きディスク容量不足のためtranscriptコピーを見送り（size=$tSize）"
            } else {
                Copy-Item -LiteralPath $transcript -Destination (Join-Path $destDir "transcript.jsonl") -Force
                $items["transcript"] = "ok"
            }
        } catch {
            $items["transcript"] = "error: $($_.Exception.Message)"
        }
    } else {
        $items["transcript"] = "missing"
    }

    # 2. git状態（status / diff / diff --cached / untracked を区別して保存）
    if ($isRepo) {
        $gitCmds = @(
            @{ Name = "git-status";      GitArgs = @("status", "--porcelain") },
            @{ Name = "git-diff";        GitArgs = @("diff", "--no-ext-diff", "--no-textconv") },
            @{ Name = "git-diff-cached"; GitArgs = @("diff", "--cached", "--no-ext-diff", "--no-textconv") },
            @{ Name = "git-untracked";   GitArgs = @("ls-files", "--others", "--exclude-standard") }
        )
        foreach ($cmd in $gitCmds) {
            $outFile = Join-Path $destDir "$($cmd.Name).txt"
            $items[$cmd.Name] = Invoke-GitCapture -GitArgs $cmd.GitArgs -OutFile $outFile `
                -WorkDir $projectDir -TimeoutMs $GIT_TIMEOUT_MS -MaxBytes $GIT_MAX_BYTES
        }
    } else {
        $items["git"] = "not-a-repo-or-git-missing"
    }

    # 3. メタデータ（原子的書き込み）
    $trigger = ""
    if ($inp.PSObject.Properties["trigger"]) { $trigger = $inp.trigger }
    $meta = @{
        saved_at        = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        session_id      = $sessionId
        trigger         = $trigger
        transcript_path = $transcript
        items           = $items
    }
    Write-FileAtomic -Path (Join-Path $destDir "meta.json") -Content ($meta | ConvertTo-Json -Depth 5)

    # 4. retention
    # 4a. セッション毎の世代数上限
    $backupRoot = Join-Path $handoffRoot "$sessionId/backup"
    $gens = @(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($gens.Count -gt $KEEP_GENERATIONS) {
        $gens | Select-Object -Skip $KEEP_GENERATIONS | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # 4b. 全セッション横断の日数上限（更新が$RETENTION_DAYSを超えたセッションディレクトリを削除）
    $cutoff = (Get-Date).AddDays(-$RETENTION_DAYS)
    Get-ChildItem -LiteralPath $handoffRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $newest = Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $newest -and $newest.LastWriteTime -lt $cutoff) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # 4c. 孤児状態ファイルの掃除（自ツールのファイル名パターンに完全一致するもののみ）
    if ($null -ne $transcript) {
        $tdir = Split-Path $transcript -Parent
        if (Test-Path -LiteralPath $tdir) {
            Get-ChildItem -LiteralPath $tdir -Filter "*.handoff-state.json" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff } | ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
        }
    }
    # 4d. 全セッション横断の合計容量上限。超過時は古いセッション（現セッション以外）から削除
    $total = [long]0
    $files = Get-ChildItem -LiteralPath $handoffRoot -Recurse -File -ErrorAction SilentlyContinue
    if ($null -ne $files) { $total = ($files | Measure-Object -Sum Length).Sum }
    if ($total -gt $MAX_TOTAL_BYTES) {
        $sessionDirs = Get-ChildItem -LiteralPath $handoffRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $sessionId } | Sort-Object LastWriteTime
        foreach ($s in $sessionDirs) {
            if ($total -le $MAX_TOTAL_BYTES) { break }
            $sz = [long]0
            $sf = Get-ChildItem -LiteralPath $s.FullName -Recurse -File -ErrorAction SilentlyContinue
            if ($null -ne $sf) { $sz = ($sf | Measure-Object -Sum Length).Sum }
            Remove-Item -LiteralPath $s.FullName -Recurse -Force -ErrorAction SilentlyContinue
            $total = $total - $sz
            Write-HandoffError $handoffRoot "handoff-save" "容量上限超過のため旧セッション $($s.Name) を削除（$sz bytes回収）"
        }
        # それでも超過する場合は現セッションの古い世代を削除
        if ($total -gt $MAX_TOTAL_BYTES) {
            $gens2 = @(Get-ChildItem -LiteralPath $backupRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
            foreach ($g in ($gens2 | Select-Object -Skip 1)) {
                if ($total -le $MAX_TOTAL_BYTES) { break }
                $sz = [long]0
                $gf = Get-ChildItem -LiteralPath $g.FullName -Recurse -File -ErrorAction SilentlyContinue
                if ($null -ne $gf) { $sz = ($gf | Measure-Object -Sum Length).Sum }
                Remove-Item -LiteralPath $g.FullName -Recurse -Force -ErrorAction SilentlyContinue
                $total = $total - $sz
            }
        }
    }
} catch {
    Write-HandoffError $handoffRoot "handoff-save" "$($_.Exception.GetType().Name): $($_.Exception.Message)"
}
exit 0





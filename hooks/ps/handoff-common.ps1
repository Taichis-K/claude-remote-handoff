# handoff-common.ps1 - フック共通ヘルパー（各フックから dot-source される。単体実行しない）
# PS 5.1互換文法のみ使用（三項演算子・??・&&/|| 禁止）。UTF-8 BOM付きで保存すること

# PS 5.1はstdin/stdoutを既定でANSIコードページ（日本語環境はcp932）として扱うため、
# 日本語を含むフック入出力が文字化けする（実測）。両方向をUTF-8へ強制する
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Read-HookInput {
    # stdinのJSONをUTF-8で読んでパースして返す。失敗時は$null（フックは常に作業を妨げない）
    try {
        $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-ProjectDir {
    param($HookInput)
    # CLAUDE_PROJECT_DIR優先、無ければフック入力のcwd（セッション中のcd影響に注意）
    $dir = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrEmpty($dir) -and $null -ne $HookInput) {
        if ($HookInput.PSObject.Properties["cwd"]) { $dir = $HookInput.cwd }
    }
    if ([string]::IsNullOrEmpty($dir)) { return $null }
    return $dir
}

function Get-HandoffRoot {
    param($HookInput)
    # ⚠️ .claude/ 配下は使わない: Claude Codeが .claude/ 配下を「sensitive file」として保護し、
    # LLMによるcurrent.md書き込みが許可ルールでも自動承認されない（2026-08-08実測）。
    # このためhandoffデータはプロジェクト直下の .claude-handoff/ に置く（gitignore必須）
    $dir = Get-ProjectDir $HookInput
    if ($null -eq $dir) { return $null }
    return (Join-Path $dir ".claude-handoff")
}

function Write-HandoffError {
    param([string]$HandoffRoot, [string]$Source, [string]$Message)
    # best-effortのエラー記録。サイズ上限256KB（超過時は末尾500行だけ残す）
    try {
        if ([string]::IsNullOrEmpty($HandoffRoot)) { return }
        if (-not (Test-Path $HandoffRoot)) {
            New-Item -ItemType Directory -Force -Path $HandoffRoot | Out-Null
        }
        $log = Join-Path $HandoffRoot "error.log"
        if ((Test-Path $log) -and ((Get-Item $log).Length -gt 262144)) {
            $tail = Get-Content $log -Tail 500 -Encoding UTF8
            Set-Content -Path $log -Value $tail -Encoding UTF8
        }
        $stamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        Add-Content -Path $log -Value "[$stamp] ${Source}: $Message" -Encoding UTF8
    } catch { }
}

function Write-FileAtomic {
    param([string]$Path, [string]$Content)
    # tmp→renameの原子的書き込み。tmp名はランダム値で一意化（並行セッションの衝突対策）。
    # ⚠️ tmp名は元ファイル名に連結せず短い固定形にする: transcriptパスは既に250文字近く、
    # PS 5.1(非長パス対応)のMAX_PATH 260を超えるとDirectoryNotFoundExceptionになる（実測）
    # Split-Path -LiteralPath はPS 5.1に無い（PS6+）ため.NET APIを使う
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    $tmp = Join-Path $dir ("~ho." + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp")
    try {
        Set-Content -LiteralPath $tmp -Value $Content -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-Uuid {
    param([string]$Value)
    # session_idの検証（パス結合に使うため。不正値による root外書込み/読込みを防ぐ）
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    return ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
}

function New-TempPath {
    param([string]$Dir, [string]$Prefix)
    # 並行実行で衝突しない一時ファイルパス
    return (Join-Path $Dir ("$Prefix.$PID." + [guid]::NewGuid().ToString("N") + ".tmp"))
}

function Test-PathUnderRoot {
    param([string]$Root, [string]$Candidate)
    # 正規化後にRoot配下であることを確認（..\ やUNC等によるroot外参照を防ぐ）
    try {
        $r = [System.IO.Path]::GetFullPath($Root)
        $c = [System.IO.Path]::GetFullPath($Candidate)
        $sep = [System.IO.Path]::DirectorySeparatorChar
        if (-not $r.EndsWith($sep)) { $r = "$r$sep" }
        return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-FileSha256 {
    param([string]$Path)
    # 書き込み直後はAVスキャン等の一時ロックで失敗し得るため短いリトライを入れる
    # （それでも失敗したらnull。restore側はnull時にハッシュ照合をスキップする縮退設計）
    for ($i = 0; $i -lt 3; $i++) {
        try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    return $null
}

$script:HANDOFF_REQUIRED_SECTIONS = @(
    "Goal", "Completed", "Not Yet Done", "Failed Approaches",
    "Key Decisions", "Current State", "Resume Instructions")

function Test-HandoffComplete {
    # 完了検証: check(発行後の完了判定)とrestore(注入前の必須ゲート)で共用する。
    #  1) 最小サイズ
    #  2) 完了マーカーが「最後の非空行」に完全一致（途中コピペ・末尾偽装を弾く）
    #  3) コードフェンス内を除外した上で、7必須見出しの完全一致と各セクション本文の非空
    param([string]$HandoffPath, [string]$Nonce, [int]$MinChars = 300)
    if (-not (Test-Path -LiteralPath $HandoffPath)) { return $false }
    $text = Get-Content -LiteralPath $HandoffPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $text -or $text.Length -lt $MinChars) { return $false }
    $rawLines = $text -split "`r?`n"
    $lastNonEmpty = ""
    for ($i = $rawLines.Count - 1; $i -ge 0; $i--) {
        if ($rawLines[$i].Trim().Length -gt 0) { $lastNonEmpty = $rawLines[$i].Trim(); break }
    }
    if ($lastNonEmpty -ne "<!-- handoff-complete: $Nonce -->") { return $false }
    $lines = @()
    $inFence = $false
    foreach ($ln in $rawLines) {
        if ($ln -match '^\s*```') { $inFence = -not $inFence; continue }
        if (-not $inFence) { $lines += $ln }
    }
    foreach ($name in $script:HANDOFF_REQUIRED_SECTIONS) {
        $idx = -1
        $pattern = '^#{1,3}\s*' + [regex]::Escape($name) + '\s*$'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $pattern) { $idx = $i; break }
        }
        if ($idx -lt 0) { return $false }
        $hasBody = $false
        for ($j = $idx + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match '^#{1,3}\s') { break }
            $t = $lines[$j].Trim()
            if ($t.Length -gt 0 -and $t -notmatch '^<!--') { $hasBody = $true; break }
        }
        if (-not $hasBody) { return $false }
    }
    return $true
}

function Invoke-GitCapture {
    # gitコマンドをtimeout・出力バイト上限付きで実行し、標準出力を$OutFileへ保存する。
    # 戻り値: "ok" / "truncated" / "timeout" / "exit=N" / "error: ..."
    # （同期フックが固まると圧縮自体が止まるため、ハング・肥大対策は必須要件）
    param([string[]]$GitArgs, [string]$OutFile, [string]$WorkDir, [int]$TimeoutMs, [int]$MaxBytes)
    $errFile = "$OutFile.stderr"
    try {
        $p = Start-Process -FilePath "git" -ArgumentList $GitArgs -WorkingDirectory $WorkDir `
            -NoNewWindow -PassThru -RedirectStandardOutput $OutFile -RedirectStandardError $errFile
        # PS 5.1の罠: プロセス終了前に.Handleへ触れておかないとExitCodeが$nullになる
        $null = $p.Handle
        if (-not $p.WaitForExit($TimeoutMs)) {
            try { $p.Kill() } catch { }
            return "timeout"
        }
        $status = "ok"
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt $MaxBytes)) {
            $bytes = [System.IO.File]::ReadAllBytes($OutFile)
            [System.IO.File]::WriteAllBytes($OutFile, $bytes[0..($MaxBytes - 1)])
            Add-Content -Path $OutFile -Value "`n...(truncated at $MaxBytes bytes)" -Encoding UTF8
            $status = "truncated"
        }
        if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) { $status = "exit=$($p.ExitCode)" }
        return $status
    } catch {
        return "error: $($_.Exception.Message)"
    } finally {
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-GitRepo {
    param([string]$WorkDir, [string]$TmpDir)
    # git導入済み かつ WorkDirがリポジトリ内ならtrue
    $probe = New-TempPath -Dir $TmpDir -Prefix "git-probe"
    $r = Invoke-GitCapture -GitArgs @("rev-parse", "--is-inside-work-tree") -OutFile $probe `
        -WorkDir $WorkDir -TimeoutMs 5000 -MaxBytes 1024
    $inside = $false
    if ($r -eq "ok" -and (Test-Path -LiteralPath $probe)) {
        $txt = (Get-Content -LiteralPath $probe -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $txt -and $txt.Trim() -eq "true") { $inside = $true }
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    return $inside
}

function Limit-Text {
    param([string]$Text, [int]$MaxChars)
    # 単純な先頭優先の切り詰め
    if ($null -eq $Text) { return "" }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars) + "`n...(切り詰め)"
}

function Limit-TextHeadTail {
    param([string]$Text, [int]$Head, [int]$Tail)
    # 上限超過時は先頭Head+末尾Tailを残す（current.md用: Resume Instructionsが後半にあるため）
    if ($null -eq $Text) { return "" }
    if ($Text.Length -le ($Head + $Tail)) { return $Text }
    $h = $Text.Substring(0, $Head)
    $t = $Text.Substring($Text.Length - $Tail)
    return "$h`n...(中略: 全$($Text.Length)文字)...`n$t"
}









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
    return ((@(Get-HandoffIncompleteReasons -HandoffPath $HandoffPath -Nonce $Nonce -MinChars $MinChars)).Count -eq 0)
}

function Get-HandoffIncompleteReasons {
    # 完了検証の失敗理由の配列を返す（空配列=検証合格）。文言はsh版と同一（挙動一致）。
    # 理由をモデルへ返し、同じ書き方の再試行で試行枠を浪費させないため（issue #5）
    param([string]$HandoffPath, [string]$Nonce, [int]$MinChars = 300)
    if (-not (Test-Path -LiteralPath $HandoffPath)) { return @("ファイルが存在しない") }
    # 最大サイズ（10MB）超過は読み込む前に弾く: 巨大current.mdによるStop/SessionStartフックの
    # CPU・メモリ枯渇を防ぐ（codexレビュー4回目 M2。文言・閾値はsh版と同一）
    try {
        if ((Get-Item -LiteralPath $HandoffPath).Length -gt 10485760) { return @("全体が最大サイズ（10MB）超過") }
    } catch { }
    $text = Get-Content -LiteralPath $HandoffPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $text) { return @("ファイルが存在しない") }
    # 最大行数: 改行の数が100000を超える資料も弾く（codexレビュー5回目 M1: 10MB未満でも
    # 改行密集ファイルで走査コストを膨らませられる。IndexOfループは上限到達で打ち切るため
    # 爆弾サイズに依存しない。文言・閾値はsh版 wc -l と同一契約=\nの個数）
    $nl = 0
    $pos = -1
    while (($pos = $text.IndexOf("`n", $pos + 1)) -ge 0) {
        $nl++
        if ($nl -gt 100000) { return @("全体が最大行数（100000行）超過") }
    }
    $reasons = @()
    if ($text.Length -lt $MinChars) { $reasons += "全体が最小文字数（$MinChars）未満" }
    # 空白の契約はASCIIの [ \t]（+行末の\r除去1回）のみ: PSの.Trim()/\sはU+00A0等の
    # Unicode空白も含み、awkの[[:space:]]（Cロケール）と分裂する（codexレビュー5回目 L2）。
    # 行中に埋め込まれた\rは除去しない=マーカー不一致として拒否（sh版と同一。5回目 L3）。
    # 分割は\nのみ+各行の末尾\rを1回だけ除去: `r?`nで分割するとEndsWith除去と合わせて
    # \r\r\n行末のCRを2個消してしまい、1個しか消さないawkと合否が分裂する（6回目 L1）
    $rawLines = $text -split "`n"
    $lastNonEmpty = ""
    for ($i = $rawLines.Count - 1; $i -ge 0; $i--) {
        $s = $rawLines[$i]
        if ($s.EndsWith("`r")) { $s = $s.Substring(0, $s.Length - 1) }
        $s = $s.Trim(' ', "`t")
        if ($s.Length -gt 0) { $lastNonEmpty = $s; break }
    }
    # -cne: PSの-ne/-eqは大文字小文字を無視するため、nonce照合はケース厳密にする（sh版と一致）
    if ($lastNonEmpty -cne "<!-- handoff-complete: $Nonce -->") {
        $reasons += "完了マーカーが最後の非空行に無い、またはnonceが今回の指示の値と一致しない"
    }
    # 状態機械で走査する（sh版awkと同一セマンティクス。codexレビュー3回目 High-1:
    # per-section走査だとps/shで合否が分裂し、###への必須見出し退避も通ってしまう）
    # - 必須見出しはh1/h2のみ（###に書いた必須見出しは「無い」扱い）
    # - 見出し行（###含む）自体は本文に数えない（###1行だけの空セクションを許さない）
    # - h1/h2の非必須見出しで本文の帰属を打ち切る。###以深は帰属を維持（issue #4）
    # - 中間配列を作らない単一パス（codexレビュー5回目 M1: 配列+=は二次時間になる）
    $found = @{}
    $body = @{}
    foreach ($name in $script:HANDOFF_REQUIRED_SECTIONS) { $found[$name] = $false; $body[$name] = $false }
    $cur = $null
    $inFence = $false
    foreach ($ln0 in $rawLines) {
        $ln = $ln0
        if ($ln.EndsWith("`r")) { $ln = $ln.Substring(0, $ln.Length - 1) }
        if ($ln -cmatch '^[ \t]*```') { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($ln -match '^#') {
            $matched = $false
            foreach ($name in $script:HANDOFF_REQUIRED_SECTIONS) {
                # -cmatch + [ \t]+ 必須: PSの-matchは大文字小文字を無視し\s*は空白ゼロを許すため、
                # 「## goal」「##Goal」が通ってsh版と合否が分裂していた（codexレビュー4回目 H1）
                if ($ln -cmatch ('^#{1,2}[ \t]+' + [regex]::Escape($name) + '[ \t]*$')) {
                    $found[$name] = $true; $cur = $name; $matched = $true; break
                }
            }
            # 帰属打ち切りも [ \t] に限定（\sはU+00A0等も含みsh版[[:space:]]と分裂するため）
            if (-not $matched -and $ln -cmatch '^#{1,2}[ \t]') { $cur = $null }
            continue
        }
        if ($null -eq $cur) { continue }
        $t = $ln.Trim(' ', "`t")
        if ($t.Length -gt 0 -and $t -notmatch '^<!--') { $body[$cur] = $true }
    }
    foreach ($name in $script:HANDOFF_REQUIRED_SECTIONS) {
        if (-not $found[$name]) { $reasons += "見出しが無い: $name" }
        elseif (-not $body[$name]) { $reasons += "本文が空: $name" }
    }
    return $reasons
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
    # 上限超過時は先頭Head+末尾Tailを残す（current.md用: Resume Instructionsが後半にあるため）。
    # 中略行に省略区間の見出し名を含め、読み手が「何が欠けたか」を認識できるようにする（issue #6）
    if ($null -eq $Text) { return "" }
    if ($Text.Length -le ($Head + $Tail)) { return $Text }
    $h = $Text.Substring(0, $Head)
    $t = $Text.Substring($Text.Length - $Tail)
    $omitted = $Text.Substring($Head, $Text.Length - $Tail - $Head)
    # 既知の7必須見出しのみを、正順・重複なしで表示する（codexレビュー3回目 High-2:
    # 任意の見出し文字列を無制限に載せると、省略部の敵対的見出しが注入文へ復活し、
    # かつ長さ暴走で末尾予算〔Resume Instructions等〕を押し出せる）。
    # 任意見出しは配列に収集せず必須名ごとの-cmatch走査にする（codexレビュー4回目 M2:
    # 大量見出しでの二次的な配列再生成と、-containsの大小無視によるsh版との分裂を排除）
    $present = @()
    foreach ($rn in $script:HANDOFF_REQUIRED_SECTIONS) {
        if ($omitted -cmatch ('(?m)^## ' + [regex]::Escape($rn) + '[ \t]*\r?$')) { $present += $rn }
    }
    $info = "全$($Text.Length)文字"
    if ($present.Count -gt 0) { $info = "$info。省略区間の見出し: " + ($present -join ", ") }
    return "$h`n...(中略: $info)...`n$t"
}









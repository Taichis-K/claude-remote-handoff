# handoff-common.ps1 - フック共通ヘルパー（各フックから dot-source される。単体実行しない）
# PS 5.1互換文法のみ使用（三項演算子・??・&&/|| 禁止）。UTF-8 BOM付きで保存すること

# PS 5.1はstdin/stdoutを既定でANSIコードページ（日本語環境はcp932）として扱うため、
# 日本語を含むフック入出力が文字化けする（実測）。両方向をUTF-8へ強制する
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# 外部入力（hook JSON・状態ファイル・ポインタ・transcript）由来の文字列と固定値の等価照合は
# 必ずこの関数で行う: PSの -eq/-ne は大小無視、-ceq/-cne もカルチャ比較でU+00AD等の
# 「照合上無視可能」な文字を無視するため、偽装値が等価判定される（ps51-compat.md 罠8。
# sh版のawk/jq/testはバイト厳密のため、放置するとps/shの合否が分裂する）
function Test-OrdinalEqual {
    param([string]$A, [string]$B)
    return [string]::Equals($A, $B, [System.StringComparison]::Ordinal)
}

# JSONを「ルート配列を配列のまま」パースする。パイプラインの `| ConvertFrom-Json` は
# pwsh 7がルート配列を列挙するため1要素配列がオブジェクトへ縮退し、配列を拒否する
# jq / PS 5.1 と分裂する（実測）。pwshは -NoEnumerate で列挙を止める（PS 5.1に同スイッチは
# 無いが、元からルート配列を配列のまま返す）。加えて関数のreturn自体もパイプラインで
# 配列を列挙するため、単項カンマで包んで関数境界の縮退を防ぐ（実測: カンマなしだと
# 1要素配列が両エディションでオブジェクトへ縮退）。呼び出し側は -is [System.Array] で拒否すること
#
# 日時文字列の契約は「原表記維持」: pwshのConvertFrom-JsonはISO日時形式のJSON文字列を
# [datetime]へ自動変換し、jq / PS 5.1（原文のまま）と分裂するため、-DateKind String
# （pwsh 7.5+）で変換を止める。-DateKind が無い旧pwsh（7.2〜7.4）は変換を止められないため、
# System.Text.Json（JsonDocumentは日時変換を一切しない）による自前変換で代替する。
# これによりJSON境界の日時は全実装で常に「文字列」であり、[datetime]は現れない。
# HANDOFF_TEST_FORCE_JSON_FALLBACK=1 はテスト用（-DateKindのある環境でも自前変換経路を
# 通し、旧pwsh相当の挙動をパリティ試験C53で検証する。ps51-compat.md 罠9参照）
$script:HoJsonDateKindString = ($PSVersionTable.PSEdition -eq "Core") -and
    (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind") -and
    -not [string]::Equals($env:HANDOFF_TEST_FORCE_JSON_FALLBACK, "1", [System.StringComparison]::Ordinal)
function Convert-JsonElementToPS {
    param($El)
    # System.Text.Json.JsonElement → ConvertFrom-Json互換のPSオブジェクト
    # （object→PSCustomObject / array→object[] / 同綴りの重複キーは後勝ち=jq・PS 5.1と同じ）
    $kind = $El.ValueKind
    if ($kind -eq [System.Text.Json.JsonValueKind]::Object) {
        $o = New-Object System.Management.Automation.PSObject
        # PSのプロパティ名は大小非区別のため、「大小違いの別綴りキー」は表現できない
        # （Add-Member -Forceだと後のSOURCEが先のsourceを上書きし、大小を区別するjqと
        # 分裂する — codexレビュー16回目 M1実測）。表現不能な入力は例外→呼び出し側の
        # catchで入力全体を不正とする（安全方向: この経路〔旧pwsh相当〕だけ拒否側に倒れる）
        $names = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::Ordinal)
        $namesCI = New-Object "System.Collections.Generic.HashSet[string]" ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $El.EnumerateObject()) {
            if (-not $namesCI.Add($p.Name) -and -not $names.Contains($p.Name)) {
                throw "case-insensitive-duplicate-key"
            }
            $null = $names.Add($p.Name)
            Add-Member -InputObject $o -MemberType NoteProperty -Name $p.Name `
                -Value (Convert-JsonElementToPS $p.Value) -Force
        }
        return $o
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::Array) {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($it in $El.EnumerateArray()) { $items.Add((Convert-JsonElementToPS $it)) }
        return ,($items.ToArray())
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::String) { return $El.GetString() }
    if ($kind -eq [System.Text.Json.JsonValueKind]::Number) {
        $l = [long]0
        if ($El.TryGetInt64([ref]$l)) { return $l }
        return $El.GetDouble()
    }
    if ($kind -eq [System.Text.Json.JsonValueKind]::True) { return $true }
    if ($kind -eq [System.Text.Json.JsonValueKind]::False) { return $false }
    return $null
}
function ConvertFrom-JsonPreserve {
    param([string]$Raw)
    if ($script:HoJsonDateKindString) {
        return ,(ConvertFrom-Json -InputObject $Raw -NoEnumerate -DateKind String)
    }
    if ($PSVersionTable.PSEdition -eq "Core") {
        # 旧pwsh（-DateKindなし）: ConvertFrom-Jsonの日時自動変換を避けるため
        # System.Text.Jsonで原表記のままパースする（不正JSONは例外→呼び出し側のcatchへ）。
        # MaxDepthは既定64だがConvertFrom-Json（既定1024）に合わせて明示する
        # （深さ65〜1024のJSONがこの経路だけ無効になる分裂の回避 — codexレビュー16回目 L1）
        $opts = New-Object System.Text.Json.JsonDocumentOptions
        $opts.MaxDepth = 1024
        $doc = [System.Text.Json.JsonDocument]::Parse($Raw, $opts)
        try { return ,(Convert-JsonElementToPS $doc.RootElement) }
        finally { $doc.Dispose() }
    }
    return ,(ConvertFrom-Json -InputObject $Raw)
}

# JSON境界のcase-sensitiveプロパティ参照（issue #37）。PSObject.Properties["name"] と
# ドット参照は大小非区別で、"Consumed" 等の大小違いキーにも一致してjq（case-sensitive）と
# 受否が分裂する。判定値の存在確認は Test-HoProp・取得は Get-HoProp を使うこと。
# 同綴り重複キーはパーサ層で解決済み（大小違い重複はConvertFrom-JsonPreserveが拒否）
function Test-HoProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $false }
    foreach ($p in $Obj.PSObject.Properties) {
        if ([string]::Equals($p.Name, $Name, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-HoProp {
    # ordinal完全一致するプロパティの値。無ければ$null（存在とnull値の区別が要る場面は
    # Test-HoPropを併用）。配列値の列挙をreturn境界で崩さないため単項カンマで返す
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    foreach ($p in $Obj.PSObject.Properties) {
        if ([string]::Equals($p.Name, $Name, [System.StringComparison]::Ordinal)) { return ,($p.Value) }
    }
    return $null
}

# 完全性ファイルの既知キー集合（issue #38 — 設計文書4.2/4.3/4.4。閉じたスキーマ）。
# ポインタの handoff_path / size は移行期間用の受理専用キー（無検証・不使用）
$HO_POINTER_KNOWN_KEYS = @("schema_version", "session_id", "nonce", "sha256", "transcript_path",
    "updated_epoch", "updated_at", "consumed", "consumed_at", "handoff_path", "size")
$HO_STATE_KNOWN_KEYS = @("schema_version", "mode", "nonce", "attempts", "completed", "failed")
$HO_CONFIG_KNOWN_KEYS = @("soft_threshold", "hard_threshold", "min_margin", "conservative_fire_pct", "autocompact_window")

function Test-HoOnlyKnownKeys {
    # 閉じたスキーマ検証（issue #38）: 既知キー以外のキーが1つでもあればfalse。
    # 照合はordinal完全一致（大小違いキーは未知キー — issue #37の契約と整合）
    param($Obj, [string[]]$Known)
    if ($null -eq $Obj) { return $false }
    foreach ($p in $Obj.PSObject.Properties) {
        $found = $false
        foreach ($k in $Known) {
            if ([string]::Equals($p.Name, $k, [System.StringComparison]::Ordinal)) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    return $true
}

function Test-HoStateClosedSchema {
    # 状態ファイルの閉じたスキーマ（issue #38 — 設計文書4.3）。schema_versionは現行producerが
    # 書くadditiveキー: 欠落（旧バージョンのファイル）は通し、存在時は数値の整数1のみ許可
    # （jqの `.schema_version == 1` と同一契約 — 数値比較のみ。文字列"1"やbooleanは不一致）
    param($State)
    if (-not (Test-HoOnlyKnownKeys $State $HO_STATE_KNOWN_KEYS)) { return $false }
    if ((Test-HoProp $State "schema_version")) {
        $sv = $State.schema_version
        if (-not (($sv -is [int]) -or ($sv -is [long]) -or ($sv -is [double]) -or ($sv -is [decimal]))) { return $false }
        if (([double]$sv) -ne 1) { return $false }
    }
    return $true
}

function Read-HookInput {
    # stdinのJSONをUTF-8で読んでパースして返す。失敗時は$null（フックは常に作業を妨げない）
    try {
        $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $parsed = ConvertFrom-JsonPreserve $raw
        # ルートがobject以外のJSON（配列・number・boolean・文字列）は不正入力として扱う
        # （sh版のjq `type == "object"` と同一契約 — 罠8。配列だけ拒否する旧実装は
        # ルートスカラーを通し、unknownセッションへの保存やポインタ注入まで進んでいた）
        if (-not ($parsed -is [System.Management.Automation.PSCustomObject])) { return $null }
        return $parsed
    } catch {
        return $null
    }
}

function Get-ProjectDir {
    param($HookInput)
    # CLAUDE_PROJECT_DIR優先、無ければフック入力のcwd（セッション中のcd影響に注意）
    $dir = $env:CLAUDE_PROJECT_DIR
    if ([string]::IsNullOrEmpty($dir) -and $null -ne $HookInput) {
        $hoCwd = Get-HoProp $HookInput "cwd"
        if ($hoCwd -is [string]) { $dir = $hoCwd }
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
    # テスト用シーム: 書き込み失敗経路をパリティ試験で決定的に再現する（C61）
    if ([string]::Equals($env:HANDOFF_TEST_FORCE_WRITE_FAIL, "1", [System.StringComparison]::Ordinal)) {
        throw "HANDOFF_TEST_FORCE_WRITE_FAIL"
    }
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
    param($Value)
    # session_idの検証（パス結合に使うため。不正値による root外書込み/読込みを防ぐ）。
    # 引数は型なし+先頭で -is [string] 検証: [string]型付き引数だと1要素配列["UUID"]が
    # 文字列へ縮退して通り、配列を拒否するjqと分裂する（罠8）
    if (-not ($Value -is [string])) { return $false }
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    # -cmatch: -matchのカルチャ依存の大小畳み込み（U+212A等が[A-Za-z]に一致）を避ける（罠8）
    return ($Value -cmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
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
        if (-not $r.EndsWith($sep, [System.StringComparison]::Ordinal)) { $r = "$r$sep" }
        return $c.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

# --- transcript由来の状態ファイルパス包含ゲート（issue #33） ---
# transcript_pathはhook入力由来の非信頼値であり、固定サフィックス連結のままでは
# 「任意パス+.handoff-state.json」の削除・作成ができてしまう。削除・書込みの対象を
# projects_root（CLAUDE_CONFIG_DIR、無ければ (USERPROFILE|HOME)/.claude、+ /projects）
# 配下の正規パスに限定する（設計文書4.8のうち#33スコープ分。transcript読取り系は#36で再評価）。
# 検証・操作とも「/」正規化後のパスで統一する: pwsh on Linuxでは「\」はセパレータでない
# ため「\」正規化は不成立、逆に「/」はWindowsの.NET APIでもセパレータとして常に通る。
# 包含判定はordinal厳密（要素境界・大小区別）。Windows FSは大小非区別だが、byte厳密の
# sh版と分裂しないよう厳密側へ倒す（実入力は同一環境変数由来のため大小は一致する）

$script:HANDOFF_STATE_SUFFIX = ".handoff-state.json"

function Get-ClaudeProjectsRoot {
    # projects_rootの解決。CLAUDE_CONFIG_DIRはClaude Codeの設定ディレクトリ移設用env
    # （実仕様準拠。テストシームも兼ねる）。解決不能・字句不正はnull（fail-closed）。
    # 正規化は「\→/」+末尾スラッシュ全除去+空拒否（sh版と同一規則。片側だけ
    # "//"や"/tmp/cfg//"を受理する分裂を防ぐ — codexレビュー#33-1 L3）
    $base = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($base)) {
        $userHome = $env:USERPROFILE
        if ([string]::IsNullOrEmpty($userHome)) { $userHome = $env:HOME }
        if ([string]::IsNullOrEmpty($userHome)) { return $null }
        $userHome = $userHome.Replace([char]92, [char]47).TrimEnd([char]47)
        $base = $userHome + "/.claude"
    }
    $base = $base.Replace([char]92, [char]47).TrimEnd([char]47)
    if ([string]::IsNullOrEmpty($base)) { return $null }
    $root = $base + "/projects"
    if (-not (Test-HandoffPathToken $root)) { return $null }
    return $root
}

function Test-HandoffPathToken {
    param([string]$P)
    # 字句検査: 制御文字（C0/DEL）拒否・UNC/デバイスパス（先頭\\・//）拒否・絶対パスのみ・
    # コロンはドライブ位置のみ（ADS遮断）・"."/".."セグメント拒否（/と\の両方を区切り扱い）・
    # Windows予約デバイス名（CON等。拡張子付き含む）拒否。sh版 ho_path_token_ok と同一契約
    if ([string]::IsNullOrEmpty($P)) { return $false }
    foreach ($ch in $P.ToCharArray()) {
        if ([int]$ch -lt 0x20 -or [int]$ch -eq 0x7F) { return $false }
    }
    if ($P.StartsWith("\\", [System.StringComparison]::Ordinal) -or
        $P.StartsWith("//", [System.StringComparison]::Ordinal)) { return $false }
    $isDrive = ($P.Length -ge 3) -and ($P[1] -eq [char]58) -and
        ((($P[0] -ge [char]65) -and ($P[0] -le [char]90)) -or (($P[0] -ge [char]97) -and ($P[0] -le [char]122))) -and
        (($P[2] -eq [char]92) -or ($P[2] -eq [char]47))
    $isUnixAbs = ($P[0] -eq [char]47) -or ($P[0] -eq [char]92)
    if (-not ($isDrive -or $isUnixAbs)) { return $false }
    $rest = $P
    if ($isDrive) { $rest = $P.Substring(2) }
    if ($rest.IndexOf([char]58) -ge 0) { return $false }
    # [char[]]の明示キャスト必須: pwshは配列引数を Split(string separator) オーバーロードへ
    # 束縛し「"/\"という文字列」で分割してしまう（=分割されず検査素通り。PS 5.1はchar[]に
    # 束縛され分裂する — 実測。ps51-compat.md 罠10）
    foreach ($seg in $P.Split([char[]]@([char]47, [char]92))) {
        if ($seg.Length -eq 0) { continue }
        if (Test-OrdinalEqual $seg ".") { return $false }
        if (Test-OrdinalEqual $seg "..") { return $false }
        $stem = $seg
        $dot = $seg.IndexOf(".")
        if ($dot -ge 0) { $stem = $seg.Substring(0, $dot) }
        if ($stem -cmatch '\A[Cc][Oo][Nn]\z|\A[Pp][Rr][Nn]\z|\A[Aa][Uu][Xx]\z|\A[Nn][Uu][Ll]\z|\A[Cc][Oo][Mm][1-9]\z|\A[Ll][Pp][Tt][1-9]\z') { return $false }
    }
    return $true
}

function Test-NotReparsePoint {
    param([string]$P)
    # 実在パスがreparse point（symlink/junction等）でないことを確認。取得失敗は拒否側
    try {
        $it = Get-Item -LiteralPath $P -Force -ErrorAction Stop
        return (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0)
    } catch { return $false }
}

function Test-RegularFile {
    param([string]$P)
    # 実在する「通常ファイル」か（ディレクトリ・symlink/reparse・FIFO/socket/device拒否）。
    # Test-Path -PathType Leaf は「container以外」の判定でUnixの特殊ファイルを通すため
    # 使わない（FIFOをGet-Contentすると停止し得る — codexレビュー#33-1 M1）。
    # Unix pwshは.NET属性で特殊ファイルを判別できないため、POSIXの通常ファイル判定
    # （/bin/sh の test -f。sh版 `[ -f ]` と同一契約）で明示判定する
    try {
        $it = Get-Item -LiteralPath $P -Force -ErrorAction Stop
        if (-not ($it -is [System.IO.FileInfo])) { return $false }
        if (($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if (($PSVersionTable.PSEdition -eq "Core") -and (-not $IsWindows)) {
            $null = & /bin/sh -c 'test -f "$1" && ! test -h "$1"' sh $P 2>$null
            return ($LASTEXITCODE -eq 0)
        }
        return $true
    } catch { return $false }
}

function Get-ValidStateFilePath {
    param($TranscriptPath, [string]$Mode)
    # Mode: "delete"（leafは実在する通常ファイルのみ）| "write"（leafは実在するなら通常
    # ファイル。親ディレクトリは実在必須）。全検証を通った場合のみ「/」正規化済みの
    # <transcript>.handoff-state.json を返し、以降のファイル操作はこの戻り値に対して行う
    # （検証対象と操作対象を同一文字列にする）。検証NGはnull＝機能不使用（fail-closed）
    if (-not ($TranscriptPath -is [string])) { return $null }
    if (-not (Test-HandoffPathToken $TranscriptPath)) { return $null }
    $derived = $TranscriptPath.Replace([char]92, [char]47) + $script:HANDOFF_STATE_SUFFIX
    # 連続区切り（"//"）は正規化後パスの全域で拒否（root部分含む）: 要素分割ベースの
    # 空要素検査はroot以降しか見ず、"C://Users/…" のようなroot部分の重複区切りを
    # PS版だけ受理してshの `*//*` 全域拒否と分裂していた（codexレビュー#33-4 M1実測）
    if ($derived.IndexOf("//", [System.StringComparison]::Ordinal) -ge 0) { return $null }
    # 長さ上限240: Windows実効MAX_PATH(260)側だけ失敗する非対称を排除するため両実装共通。
    # 単位は**UTF-8バイト長**に規範化（PSの.LengthはUTF-16 code unit数、shの${#var}は
    # ロケール依存で分裂する — codexレビュー#33-1 L4。バイト長はcode unit数以上のため
    # MAX_PATH対策として保守的側）
    if ([System.Text.Encoding]::UTF8.GetByteCount($derived) -gt 240) { return $null }
    $root = Get-ClaudeProjectsRoot
    if ($null -eq $root) { return $null }
    if (-not $derived.StartsWith($root + "/", [System.StringComparison]::Ordinal)) { return $null }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    if (-not (Test-NotReparsePoint $root)) { return $null }
    # rootから対象までの各構成要素を検査（中間=実在ディレクトリかつ非reparse。
    # symlink/junction経由でroot外の実体を指す経路を遮断する）
    $parts = $derived.Substring($root.Length + 1).Split([char[]]@([char]47))
    $cur = $root
    for ($i = 0; $i -lt $parts.Length; $i++) {
        if ($parts[$i].Length -eq 0) { return $null }
        $cur = $cur + "/" + $parts[$i]
        if ($i -lt $parts.Length - 1) {
            if (-not (Test-Path -LiteralPath $cur -PathType Container)) { return $null }
            if (-not (Test-NotReparsePoint $cur)) { return $null }
        } elseif (Test-OrdinalEqual $Mode "delete") {
            if (-not (Test-RegularFile $cur)) { return $null }
        } else {
            if (Test-Path -LiteralPath $cur) {
                if (-not (Test-RegularFile $cur)) { return $null }
            }
        }
    }
    return $cur
}

function Get-HoNowEpoch {
    # 現在時刻のUNIX秒（shのho_now_epochと同一契約）。失敗時は$null。
    # テスト用シーム: HANDOFF_TEST_NOW_EPOCH で固定、HANDOFF_TEST_FORCE_NOW_FAIL=1 で
    # 取得失敗を強制（epoch境界・fail-closed経路の決定的検証用）。
    # 採用条件は「先頭ゼロなし・18桁以下の10進のみ」の完全一致（\A/\z — $は末尾改行を
    # 受理してしまう）。形式外は実時刻へフォールバック（sh版と同一契約 — レビュー2回目 L1）
    if ([string]::Equals($env:HANDOFF_TEST_FORCE_NOW_FAIL, "1", [System.StringComparison]::Ordinal)) {
        return $null
    }
    $ov = [string]$env:HANDOFF_TEST_NOW_EPOCH
    if ($ov -cmatch '\A(0|[1-9][0-9]{0,17})\z') { return [long]$ov }
    return [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-HoNowDisplay {
    # 人間可読の現在日時（表示用。shのho_now_displayと同一契約）。失敗時は$null。
    # テスト用シーム: HANDOFF_TEST_FORCE_DATE_FAIL=1 で失敗を強制（dual-writeのフォールバック検証用）
    if ([string]::Equals($env:HANDOFF_TEST_FORCE_DATE_FAIL, "1", [System.StringComparison]::Ordinal)) {
        return $null
    }
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
}

function Get-FileSha256 {
    param([string]$Path)
    # 書き込み直後はAVスキャン等の一時ロックで失敗し得るため短いリトライを入れる。
    # それでも失敗したらnull。null時の縮退（restore側の照合スキップ）は廃止した（issue #31）:
    # producer(check)はポインタ更新をスキップ、consumer(restore)は注入拒否（fail-closed）
    if ([string]::Equals($env:HANDOFF_TEST_FORCE_SHA_FAIL, "1", [System.StringComparison]::Ordinal)) {
        # テスト用シーム: SHA計算失敗経路をパリティ試験で決定的に再現する（C59）
        return $null
    }
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
        if ($s.EndsWith("`r", [System.StringComparison]::Ordinal)) { $s = $s.Substring(0, $s.Length - 1) }
        $s = $s.Trim(' ', "`t")
        if ($s.Length -gt 0) { $lastNonEmpty = $s; break }
    }
    # ordinal必須: PSの-ne/-eqは大小無視。さらに-cne/-ceqもカルチャ比較のため、U+00AD等の
    # 「照合上無視可能」な文字を無視する（実測: U+00AD前置のマーカーが-ceqで等価判定される）。
    # nonce照合はバイト列厳密=StringComparison.Ordinal（sh版のLC_ALL=C awkと同一契約）
    if (-not [string]::Equals($lastNonEmpty, "<!-- handoff-complete: $Nonce -->", [System.StringComparison]::Ordinal)) {
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
        if ($ln.EndsWith("`r", [System.StringComparison]::Ordinal)) { $ln = $ln.Substring(0, $ln.Length - 1) }
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
        if ($null -ne $txt -and (Test-OrdinalEqual $txt.Trim() "true")) { $inside = $true }
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









# handoff-common.ps1 - フック共通ヘルパー（各フックから dot-source される。単体実行しない）
# PS 5.1互換文法のみ使用（三項演算子・??・&&/|| 禁止）。UTF-8 BOM付きで保存すること
# 配布元: https://github.com/Taichis-K/claude-remote-handoff （導入済みバージョンは ../VERSION）

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
# completed_tokens / completed_epoch / completed_nonce / completed_sha256 は additive キー（v0.2.1）。
# いずれも「このサイクルで直近に完成した資料」の情報で、completed=true なら nonce の資料、
# completed=false（ソフトで作った資料の書き直しを指示中）なら completed_nonce の資料を指す。
# checkは「ソフトで作った資料を、ハード閾値を越えたら書き直させる」判定に、
# restoreは書き直しが終わる前に圧縮されたときの旧資料の検証（nonce + SHA-256）と、鮮度表示に使う
$HO_STATE_KNOWN_KEYS = @("schema_version", "mode", "nonce", "attempts", "completed", "failed",
    "completed_tokens", "completed_epoch", "completed_nonce", "completed_sha256")
# completed_epoch の上限（10桁 = 2286年まで）。範囲外は書かない・読んだら不正扱い（sh版と同一契約）
$HO_EPOCH_MAX = [long]9999999999
# completed_tokens の上限（checkの設定値上限 MAX_TOKEN_VALUE と同じ）
$HO_TOKENS_MAX = [long]1000000000
$HO_CONFIG_KNOWN_KEYS = @("soft_threshold", "hard_threshold", "min_margin", "conservative_fire_pct", "autocompact_window")

function Get-HoStrField {
    param($Obj, [string]$Name)
    # フック入力の文字列フィールド（cwd / source / trigger）の取得契約。
    # 文字列以外・NULを含む値・**CRを含む値**は空扱い（sh版 strfield と同一契約 —
    # HANDOFF.mdバックログ12）。CRを落とすのは「シェルが運べないから」で、
    # sh版は @sh + eval の往復でCRが消えるため値を持てない。LFは両実装とも
    # **剥がさず生のまま**扱う（sh版も運べることを実測済み）
    $v = Get-HoProp $Obj $Name
    if (-not ($v -is [string])) { return "" }
    if ($v.IndexOf([char]0) -ge 0) { return "" }
    if ($v.IndexOf([char]13) -ge 0) { return "" }
    return $v
}

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

# usage合算の対象4キー（check と restore で共有する。sh版 ho_last_usage と同一契約）
$HO_USAGE_KEYS = @("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens")

function Get-UsageTotal {
    param($Usage)
    # 4キーがすべて非負整数で揃った「完全なusage」のみ合算を返す。それ以外は0（不採用）
    if ($null -eq $Usage) { return 0 }
    $total = [long]0
    foreach ($k in $HO_USAGE_KEYS) {
        if (-not (Test-HoProp $Usage $k)) { return 0 }
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
    # メインチェーン（isSidechainでない）assistant行のうち、最後の完全なusageの合算を返す。
    # restore から呼ぶと「圧縮直前（clearなら /clear 直前）の使用量」になる: SessionStart
    # フックが走る時点では、圧縮後のassistant行はまだ書かれていない（実測で確認済み）
    $tokens = [long]0
    $lines = Get-Content -LiteralPath $TranscriptPath -Tail $TailLines -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        try {
            # 行全体が配列のJSONは不正行として無視（jqのselect(type=="object")と同一契約。
            # パイプラインの ConvertFrom-Json はpwshで1要素配列が縮退するため使わない — 罠8）
            $e = ConvertFrom-JsonPreserve $line
            if ($null -eq $e -or ($e -is [System.Array]) -or -not (Test-HoProp $e "type")) { continue }
            if (-not ($e.type -is [string]) -or -not (Test-OrdinalEqual $e.type "assistant")) { continue }
            # 除外はboolean trueのみ（jqの `.isSidechain != true` と同一契約。文字列"false"は
            # truthyのため旧実装は誤除外していた — 罠8の型固定）
            if ((Test-HoProp $e "isSidechain") -and ($e.isSidechain -is [bool]) -and $e.isSidechain) { continue }
            if (-not (Test-HoProp $e "message")) { continue }
            # messageが配列の行は不正として無視（jqは配列への .usage アクセスがエラーで行ごと落ちる）
            if ($e.message -is [System.Array]) { continue }
            $u = $null
            if ($null -ne $e.message -and (Test-HoProp $e.message "usage")) { $u = $e.message.usage }
            $t = Get-UsageTotal $u
            if ($t -gt 0) { $tokens = $t }
        } catch { }
    }
    return $tokens
}

function ConvertTo-HoStateLong {
    # 状態ファイルの数値キーの検証: JSON number（文字列・bool不可）かつ整数値かつ範囲内なら [long]、
    # それ以外は $null。1.0 / 1e3 のような整数値の表記も通す（jq の type=="number" and .==floor と
    # 同一契約。sh版は floor|tostring で整数表記へ揃えてから使う）
    param($Value, [long]$Min, [long]$Max)
    if ($null -eq $Value) { return $null }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])) { return $null }
    $d = [double]$Value
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    if ($d -ne [math]::Floor($d)) { return $null }
    if ($d -lt $Min -or $d -gt $Max) { return $null }
    return [long]$d
}

function Get-HoCompletionInfo {
    # 状態から「このサイクルで直近に完成した資料」の nonce と完成時の値を返す（sh版 ho_completion_info と同一契約）。
    # completed=true なら nonce、そうでなければ completed_nonce（書き直しの指示中）。
    # どちらも無ければ $null。値（tokens / epoch）は取れなければ $null。sha はキーが無ければ $null、形式外なら "INVALID"。
    # 閉じたスキーマの検証は呼び出し側で済ませていること
    param($State)
    if ($null -eq $State) { return $null }
    $n = $null
    if ((Test-HoProp $State "completed") -and ($State.completed -is [bool]) -and $State.completed) {
        if ((Test-HoProp $State "nonce") -and ($State.nonce -is [string]) -and $State.nonce -cmatch '\A[A-Za-z0-9-]{8,64}\z') { $n = $State.nonce }
    } elseif ((Test-HoProp $State "completed_nonce") -and ($State.completed_nonce -is [string]) -and
              $State.completed_nonce -cmatch '\A[A-Za-z0-9-]{8,64}\z') {
        $n = $State.completed_nonce
    }
    if ($null -eq $n) { return $null }
    $info = @{ nonce = $n; tokens = $null; epoch = $null; sha = $null }
    if ((Test-HoProp $State "completed_tokens")) { $info.tokens = ConvertTo-HoStateLong $State.completed_tokens 1 $HO_TOKENS_MAX }
    if ((Test-HoProp $State "completed_epoch")) { $info.epoch = ConvertTo-HoStateLong $State.completed_epoch 1 $HO_EPOCH_MAX }
    if (Test-HoProp $State "completed_sha256") {
        # キーがあるのに形式外なら照合を飛ばさず、どの資料とも一致しない値にして拒否させる（sh版 "INVALID" と同一）
        $info.sha = "INVALID"
        if (($State.completed_sha256 -is [string]) -and $State.completed_sha256 -cmatch '\A[0-9A-F]{64}\z') {
            $info.sha = $State.completed_sha256
        }
    }
    return $info
}

function Format-HoFreshnessLine {
    # 復元する資料の鮮度行（v0.2.1。sh版 ho_freshness_line と同一契約・同一文言）。
    # 材料（完成時刻と現在時刻 / 完成時と復元直前の使用量）のどちらも揃わなければ空文字を返す。
    # 未知の値は $null で渡す。使用量は「復元直前 >= 完成時」かつ「復元直前 >= 1」のときだけ出す
    param($DoneEpoch, $NowEpoch, $DoneTokens, $NowTokens, [string]$Source)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $DoneEpoch -and $null -ne $NowEpoch -and $NowEpoch -ge $DoneEpoch) {
        # 整数除算は DivRem で行う（doubleを経由すると大きな値で丸まり、shの $(( )) と分裂する）
        $secRem = [long]0
        $mins = [Math]::DivRem([long]($NowEpoch - $DoneEpoch), [long]60, [ref]$secRem)
        if ($mins -lt 1) {
            $elapsed = "1分未満"
        } elseif ($mins -lt 60) {
            $elapsed = "${mins}分"
        } else {
            $rem = [long]0
            $hrs = [Math]::DivRem([long]$mins, [long]60, [ref]$rem)
            $elapsed = "${hrs}時間${rem}分"
        }
        $parts.Add("完成から${elapsed}経過")
    }
    # 使用量は上限（HO_TOKENS_MAX）以下のときだけ。非現実な値で整数幅を越えさせない（sh版と同一）
    if ($null -ne $DoneTokens -and $null -ne $NowTokens -and $NowTokens -ge 1 -and $NowTokens -ge $DoneTokens -and
        $DoneTokens -le $HO_TOKENS_MAX -and $NowTokens -le $HO_TOKENS_MAX) {
        $grown = $NowTokens - $DoneTokens
        $parts.Add("完成時の使用量 ${DoneTokens} → 復元直前 ${NowTokens}（+${grown}）")
    }
    if ($parts.Count -eq 0) { return "" }
    $crossCheck = "圧縮要約・git状態・直近のユーザーメッセージ"
    if (Test-OrdinalEqual $Source "clear") { $crossCheck = "git状態・直近のユーザーメッセージ" }
    return "※ 資料の鮮度: " + ($parts -join " / ") + "。完成後に行った作業はこの資料に含まれていないため、${crossCheck}と突き合わせて現状を確認すること。"
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
        # NUL/CRを含む値は空扱い（sh版 strfield と同一契約 — バックログ12）
        $dir = Get-HoStrField $HookInput "cwd"
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
    # アンカーは \A…\z（^…$ ではない）。.NETの $ は「終端の直前のLF」にも一致するため、
    # ^…$ だと「UUID + 末尾LF」を受理してしまう。sh版は ho_is_uuid の case による
    # 全文一致で拒否するので、締めないとPS版だけが受理する分裂になる。
    # 以前は sh側が末尾LFを剥がしてから検証していたので ^…$ で揃っていたが、
    # バックログ12で「剥がさず生のまま持つ」へ変えたのに合わせてここも締めた
    return ($Value -cmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z')
}

function New-TempPath {
    param([string]$Dir, [string]$Prefix)
    # 並行実行で衝突しない一時ファイルパス
    return (Join-Path $Dir ("$Prefix.$PID." + [guid]::NewGuid().ToString("N") + ".tmp"))
}

function ConvertTo-HoDriveLowerPath {
    param([string]$P)
    # 先頭が「<ASCII英字>:」ならそのドライブレターだけ小文字へ畳む。
    # sh版の `cd`+`pwd`（MSYS）が「D:/x」も「d:/x」も /d/x へ畳むのに合わせるため。
    # ToLower()はカルチャ依存（トルコ語ロケールで I が dotless i になる）なので使わない
    if ($P.Length -ge 2 -and $P[1] -eq [char]58) {
        $d = $P[0]
        if (($d -ge [char]65 -and $d -le [char]90) -or ($d -ge [char]97 -and $d -le [char]122)) {
            return ([string]$d).ToLowerInvariant() + $P.Substring(1)
        }
    }
    return $P
}

function Test-HoContained {
    param([string]$Root, [string]$Path)
    # 包含ゲートの唯一の判定規則（HANDOFF.mdバックログ16。sh版 ho_contained_strict と
    # 同一契約）。$Root は「/」正規化済み・末尾スラッシュなし、$Path も「/」正規化済み:
    #   連続区切り（"//"）を全域拒否 → ドライブレターを小文字へ畳んで ordinal 前方一致 →
    #   Rootから $Path の親までの各構成要素が「実在ディレクトリかつ非reparse point」
    # **symlink/junctionは追跡せず、経路にあれば拒否する**。以前は PS版が GetFullPath、
    # sh版が `cd`+`pwd` で、どちらも**字句解決のまま**だった（MSYSの `pwd` は既定で
    # 論理パスを返す。物理解決は `pwd -P` — 実測）。そのため projects_root 配下に
    # 置かれたroot外を指すjunctionを**両実装とも受理し、root外のファイルを
    # 引用できていた**（2026-08-31 codexレビュー Medium。ただし「sh版は物理解決するので
    # 拒否する」という指摘の前提は誤りで、分裂ではなく共通の穴だった — C87で実測）。
    # 経路のsymlinkを拒否する規則は組B（Get-ValidStateFilePath）が元から持っており、
    # そちらへ揃えた。
    # ".."は追跡しないと畳めないため、呼び出し側が Test-HandoffPathToken で先に拒否すること
    $r = ConvertTo-HoDriveLowerPath $Root
    $p = ConvertTo-HoDriveLowerPath $Path
    if ($p.IndexOf("//", [System.StringComparison]::Ordinal) -ge 0) { return $false }
    if (-not $p.StartsWith($r + "/", [System.StringComparison]::Ordinal)) { return $false }
    if (-not (Test-Path -LiteralPath $r -PathType Container)) { return $false }
    if (-not (Test-NotReparsePoint $r)) { return $false }
    $ix = $p.LastIndexOf([char]47)
    $rel = $p.Substring(0, $ix).Substring($r.Length)
    if ($rel.StartsWith("/", [System.StringComparison]::Ordinal)) { $rel = $rel.Substring(1) }
    $cur = $r
    if ($rel.Length -gt 0) {
        foreach ($seg in $rel.Split([char[]]@([char]47))) {
            if ($seg.Length -eq 0) { return $false }
            $cur = $cur + "/" + $seg
            if (-not (Test-Path -LiteralPath $cur -PathType Container)) { return $false }
            if (-not (Test-NotReparsePoint $cur)) { return $false }
        }
    }
    # leaf自身がreparse point（symlink/junction）なら拒否する。親までしか見ないと
    # 「<root>/proj/session.jsonl -> /tmp/outside.jsonl」のように**対象ファイルを**
    # リンクに差し替えるだけでroot外を読めてしまう（後段の Test-Path も Get-Content も
    # リンクを追跡する — 2026-08-31 codexレビュー Medium-1）。
    # 実在しないleafは通す（書込みモードの呼び出しがあるため。sh版の `[ -h ]` と同じ扱い）
    try {
        $leaf = Get-Item -LiteralPath $p -Force -ErrorAction Stop
        if (($leaf.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    } catch { }
    return $true
}

function Test-PathUnderRoot {
    param([string]$Root, [string]$Candidate)
    # Root配下であることを確認（..\ やUNC等によるroot外参照を防ぐ）。
    # 判定は Test-HoContained に一本化してある（バックログ16で組A・組Bの契約を統一）。
    # ".." は GetFullPath で畳むのをやめ、Test-HandoffPathToken で拒否する側へ移した
    # （symlinkを追跡しない以上、字句で畳むと sh版と食い違うため）
    if (-not (Test-HandoffNoTraversal $Candidate)) { return $false }
    $r = $Root.Replace([char]92, [char]47).TrimEnd([char]47)
    if ([string]::IsNullOrEmpty($r)) { return $false }
    return (Test-HoContained -Root $r -Path $Candidate.Replace([char]92, [char]47))
}

function Test-HandoffNoTraversal {
    param([string]$P)
    # 組Aの前段検査（sh版 ho_no_traversal と同一契約）。制御文字（C0/DEL）と
    # "."/".." セグメントだけを拒否する。".." は追跡しない以上ここで落とすしかない。
    # **Test-HandoffPathToken は使わない**: あちらはWindows予約デバイス名やドライブ位置
    # 以外のコロンも拒否するが、組Aの候補は利用者のプロジェクトパス由来で、
    # POSIXでは /srv/aux/repo や /srv/team:blue/repo が正当な絶対パスである。
    # 全プラットフォームでWindowsの名前規則を課すとmacOS/Linuxで復元不能になる
    # （2026-08-31 codexレビュー Medium-3）。root外参照は包含判定と経路のsymlink拒否が塞ぐ
    if ([string]::IsNullOrEmpty($P)) { return $false }
    foreach ($ch in $P.ToCharArray()) {
        if ([int]$ch -lt 0x20 -or [int]$ch -eq 0x7F) { return $false }
    }
    foreach ($seg in $P.Replace([char]92, [char]47).Split([char[]]@([char]47))) {
        if ($seg -eq "." -or $seg -eq "..") { return $false }
    }
    return $true
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
    # 包含判定は Test-HoContained に一本化してある（バックログ16で組A=Test-PathUnderRoot と
    # 契約を揃えた）。中身は「連続区切りの全域拒否＋ドライブレターを畳んだordinal前方一致＋
    # rootから親までの各要素が実在ディレクトリかつ非reparse」。
    # 戻り値の $derived はドライブレターを畳まない生の形のままにする
    if (-not (Test-HoContained -Root $root -Path $derived)) { return $null }
    # leafの検査と戻り値は $derived そのものに対して行う（検証対象と操作対象を
    # 同一文字列にする）。以前はrootから組み立て直した文字列を返していたが、
    # ドライブレターの大小を畳んで前方一致するようになった以上、組み立て直すと
    # 「rootの綴りで作った別の文字列」を返し得る（sh版は元から生の _vp を返している）
    if (Test-OrdinalEqual $Mode "delete") {
        if (-not (Test-RegularFile $derived)) { return $null }
    } else {
        if (Test-Path -LiteralPath $derived) {
            if (-not (Test-RegularFile $derived)) { return $null }
        }
    }
    return $derived
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









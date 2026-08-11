# Changelog

## v0.1.3 (2026-08-12)

- **修正（setup）**: `.gitignore` の重複判定が完全一致のみで、意味的に同値な既存行を
  見落として二重追記していた（issue #25: `.claude/settings.local.json`〔`*`なし〕を既に
  無視しているリポジトリで`*`付きが2行目に並ぶ）。対象の種類ごとの同値形
  （`dir/`⇔`dir`⇔`dir/*` / `file`⇔`file*` / `file*`⇔`file`〔部分カバー→`*`付き更新を推奨表示〕。
  ファイルへの末尾`/`は同値としない）を「追記済み」と判定するよう修正。
  比較は大小厳密・trim対象は`[ \t\r]`のみに統一（PSの`-eq`/`.Trim()`とawkの分裂を排除）。
  sh版はUTF-8 BOM付き `.gitignore`（PS 5.1の`Set-Content`/`Add-Content`が作成時に付け得る）の
  先頭行をBOMごと比較して見落としていたため、BOMを除去してから比較するよう修正
  （PS版の`Get-Content`はBOM自動除去のため両実装の判定が分裂していた）。
  ps/sh共通の回帰テスト（`tests/run-setup-gitignore.*`・S1〜S6の6ケース。同値形・
  非同値形〔大小違い・U+00A0前置含む〕・冪等性・BOM付きをカバーし、実行後の
  `.gitignore` 全行〔非ASCIIは `?` へ正規化〕を順序込みで期待値と照合、`*`付きへの
  更新推奨メッセージの提示有無も検証）を追加
  （テスト用に `HANDOFF_SETUP_SKIP_CLAUDE_CHECK=1` でバージョン確認のみスキップ可能）
- **修正（検証ロジック）**: ロケール/カルチャ依存の文字列比較が「照合上無視可能」な文字
  （U+00A0・U+00AD等）を無視し、偽装マーカー・偽装gitignore行を等価判定する穴を両実装で
  排除。sh版: macOSのBWK awkはUTF-8ロケールで`==`/`!=`にstrcoll()を使う（CI実測:
  U+00A0前置行が.gitignoreエントリと等価になりS4が失敗。完了マーカーも同様に偽装通過
  し得た）ため、比較を行うawk（フックのマーカー照合・setupの同値判定・テストの判定）を
  `LC_ALL=C` で実行しstrcmpに固定。PS版: `-ceq`/`-cne`もカルチャ比較でU+00AD等を無視する
  （実測）ため、外部入力（hook JSON・状態ファイル・ポインタ・transcript・環境変数）と
  固定値の等価照合を横断的に `[string]::Equals(..., StringComparison.Ordinal)` へ変更
  （マーカー照合・setup同値判定に加え、SHA-256照合・stateのmode検証・transcriptの
  type判定・sourceの判定・setupのスキップ環境変数等）。nonce/UUIDの形式検証も
  `-cmatch`/`-cnotmatch` に統一（`-match`のカルチャ依存の大小畳み込みでU+212A等が
  `[A-Za-z]` に一致する）。JSON境界の判定値は `-is [string]` で型も固定
  （1要素配列がPSの文字列縮退で通り、配列を拒否するjqと分裂していた）。
  Test-Uuid・ポインタのsha256/transcript_pathも型固定し、`EndsWith` はordinal
  オーバーロードに統一。さらにPS版のSHA照合が「ポインタ経由時か、ポインタが解決先
  セッション自身のものの場合のみ」というsh版の契約に反して無条件適用されており、
  自セッション直接参照+他セッションを指すポインタの構成で誤拒否になるパリティ分裂も
  修正。両実装をバイト列厳密の同一契約に統一し、パリティにC22（U+00A0前置マーカー）・
  C23（末尾U+00A0だけの行）・C24（U+00AD前置マーカー）・C25（typeにU+00AD挿入）・
  C26（modeにU+00AD挿入）・C27（sha256にU+00AD挿入）・C28（typeが配列）・
  C29（modeが配列）・C30（sourceにU+00AD挿入→ポインタ未消費）・C31（非clear時の
  自セッション優先）・C32（sha256が配列）・C33（session_idが配列）・C34（user行の
  配列type/text除外）を追加。さらにhook入力・ポインタ・transcriptの型契約を両実装で
  統一（ルートが配列のJSONは不正扱い / cwd・transcript_path・updated_atは文字列必須 /
  consumed_atは欠落・null・空文字列のみ許可 / sha256は非文字列を不一致扱い〔shの
  `// empty` がfalseをスキップする分裂も解消〕/ isSidechain・isMeta・stop_hook_activeの
  判定はboolean厳密〔文字列"false"をtruthy扱いしない〕/ messageが配列の行は無視 /
  background_tasksは配列のみ有効）し、C35〜C41で回帰検証。
  さらにpwsh 7固有の2つの縮退への対策: (1) パイプラインの `ConvertFrom-Json` はルート配列を
  列挙し1要素配列がオブジェクトへ縮退するため、`-NoEnumerate` を使う共通ヘルパー経由に統一
  （関数のreturn自体も配列を列挙して再縮退するため単項カンマで関数境界の列挙も停止）し、
  ルート配列のhook入力・ポインタ・状態・transcript行を不正として拒否（C42/C43）、
  (2) ISO日時形式のJSON文字列が[datetime]へ自動変換されるため、契約を「原表記維持」とし
  `-DateKind String`（pwsh 7.5+）で変換自体を停止。-DateKindの無い旧pwsh（7.2〜7.4）は
  System.Text.Json（日時変換をしないJsonDocument）による自前変換で代替し、JSON境界の
  日時は全実装で常に文字列（[datetime]受理の分岐は全廃）。
  config・meta.jsonの読込も同ヘルパーへ統一し、hook入力・config・metaはルートが
  object以外（配列・スカラー）を不正として扱う。saveのtrigger・resetのtranscript_pathも
  文字列必須。ポインタのupdated_atは「文字列型かつproducerが書くISO形式
  （+09:00 / +0900 / Z）」を値域まで固定した正規表現+暦日検証で受理してから
  TryParseExact（InvariantCulture）/ date で解析（TryParseやGNU date -d の自由書式・
  範囲外オフセットへの寛容さ、BSD dateの暦繰り上げ正規化で実装間の受否が分裂していた）。
  sh版には型固定の `ho_string_field` を追加しcwd/transcript_path/session_id/source/
  triggerの取得を統一、バックアップ導線のmeta表示もjq型分岐で「objectかつ文字列のみ表示」
  に統一。usage走査（assistant限定・isMeta不問）と引用（user限定・isMeta除外）の
  対象行predicateを明文化し回帰を追加（issue #29）。
  **sha256=null縮退を廃止（issue #31・意図した挙動変更）**: 従来はSHA-256計算失敗
  （AVロック等）時にsha256=nullのポインタを書き、restore側は照合スキップで注入していた
  （producer失敗と改竄を区別できない「整合性ゲートの明示的無効化」経路）。
  ポインタの更新条件は「完了検証とSHA-256計算の双方が成功した時」に変更:
  producer(check)はSHA計算失敗時にポインタを更新せず、stateのcompleted遷移
  （指示ループ回避）が成功した場合のみerror.log記録+systemMessageで資料パスを
  1回通知する（遷移失敗時は専用エラー記録のみ — 通知の繰り返しを防ぐ。両実装同一契約）。
  consumer(restore)はSHA照合が適用される状況でsha256が欠落・null・空文字列の
  ポインタを注入拒否（fail-closed。旧バージョンが書いたsha256=nullポインタは
  アップグレード後に拒否される — 次のhandoff作成サイクルで復帰）。旧latest.jsonは
  上書きしない（他セッションのものは正当な復元対象のまま。自セッション前サイクルの
  ものは旧nonceの完了検証で拒否され、仮に通っても内容変更時はSHA不一致で拒否）。
  回帰C59（SHA失敗シームで他セッションポインタのバイト不変・state completed・
  通知と記録は1回だけ）/C60（sha256欠落・null・空文字列の3態とも注入拒否+専用note）/
  C61（state書き込みも失敗時は通知なし・専用エラー記録）を追加。
  **fire-point検証をfail-closed化し autocompact_window を必須化（issue #32・意図した
  挙動変更）**: 従来はwindowが環境変数からもconfigからも解決できない場合に
  fire-point検証（`hard_threshold + min_margin < floor(window × pct ÷ 100)`）を
  スキップしたまま機能が有効になり、「compactより確実に前で発火」の保証が抜けていた。
  configの `autocompact_window` を必須化（setupは従来から常に書く。無いか不正な
  旧configは機能無効+診断で気づける。診断は他の無効化経路と同じくStopごとに
  error.logへ記録〔256KB超過を検知した次回記録時に末尾500行へtrim〕）し、fire-point検証を常時実施に変更。
  環境変数（CLAUDE_CODE_AUTO_COMPACT_WINDOW / CLAUDE_AUTOCOMPACT_PCT_OVERRIDE）は
  **文字列全体が** `[0-9]{1,10}` のみ受理（PSは `\A..\z`・shはcase全文一致 —
  `^$`/grepの行単位一致は改行混入値を通すため不採用）し、先頭ゼロ除去の10進解釈+
  範囲検査（違反は未設定扱いでconfigへフォールバック。TryParse直渡しの空白・符号への
  寛容さと、shの先頭ゼロ八進解釈・桁数無制限の算術エラーを排除）。
  発火点の丸めをfloorに統一（PS版の[long]キャストは最近接丸めのため、.5以上の端数で
  ps/shの合否が分裂していた）。回帰C62（window無しconfigは無効+Stopごと診断〔2回で
  2件〕）/C63（window envの符号付き・改行前置は拒否、先頭ゼロは10進採用 — 八進解釈と
  一意判別）/C64（floor境界でps/sh同一判定）/C65（pct envの符号・先頭ゼロ・範囲・
  末尾LFゲート）を追加。パリティ計65ケース。setup側（PS版）の静的検証も同じ丸め分裂が
  あったためfloorに統一（setupが受理した設定を実行時にフックが拒否する分裂の解消。
  回帰S8〔floor境界でsetupも拒否〕を追加）。
  setupテストにもS7（スキップ環境変数の偽装値でバージョン確認が迂回されないこと）を追加
- **変更（状態ファイル操作の包含ゲート — issue #33・意図した挙動変更）**: hook入力の
  `transcript_path` は非信頼値だが、従来は `<transcript_path>.handoff-state.json` という
  固定サフィックス連結のまま削除（reset・restore・checkの不正state破棄）・作成（check）・
  ディレクトリ掃除（saveの孤児state削除）に使っており、「任意パス+固定サフィックス」の
  削除・作成ができた。これらの操作対象を **projects_root配下の検証済みパスに限定**する:
  projects_rootは `CLAUDE_CONFIG_DIR`（Claude Codeの設定ディレクトリ移設env）、無ければ
  `(USERPROFILE|HOME)/.claude`、に `/projects` を付けて解決。検証は
  字句（制御文字拒否・`.`/`..`セグメント拒否〔`/`と`\`の両方を区切り扱い〕・UNC/デバイス
  パス拒否・コロンはドライブ位置のみ〔NTFS ADS遮断〕・Windows予約デバイス名拒否・
  絶対パスのみ・派生パス込み長さ≤240）+物理（rootからの各構成要素が実在ディレクトリ
  かつsymlink/reparse pointでない・包含は`/`正規化後の要素境界でbyte厳密）+leaf契約
  （削除=実在する通常ファイルのみ / 書込み=実在するなら通常ファイル）。
  ゲートNG時はcheckのみStopごとにerror.logへ診断を残して機能無効化、
  reset・restore・saveの掃除は黙ってスキップ（いずれもfail-closed）。
  既知の限界（意図した拒否側）: UNCネットワークプロファイル・symlinkを含むprojects
  構成・派生パスがUTF-8で240バイト超・大小文字が環境変数とtranscriptで食い違う構成では機能が
  無効になる。transcriptの読取り系（引用走査・バックアップコピー）の包含は
  issue #36 で再評価（→2026-08-10判断: 不採用）。長さ上限240の単位は**UTF-8バイト長**に規範化（PSのUTF-16
  code unit数とshのロケール依存文字数の分裂を排除）。leafの「通常ファイル」判定は
  Unix pwshではPOSIXの `test -f` で明示判定（`Test-Path -PathType Leaf` はFIFO/socket/
  device等を通すため不採用）。ゲートNG診断に載せる非信頼パスは制御文字を `?` へ
  置換して記録（改行入りパスによるログ行偽装を防止）。回帰C66（root外transcriptで
  check無発火+state非作成・root外の実在stateをresetが削除しない）/C67（`..`セグメント・
  root文字列の要素境界・`..`解決先root外のreset・ゲート診断のStopごと記録）/
  C68（root外stateのrestore後生存とroot内stateの従来どおり削除・save 4cのroot外
  スキップとroot内掃除・多バイト文字でのバイト長上限・`CLAUDE_CONFIG_DIR`末尾LFの
  拒否〔shは `$( )` の末尾LF剥がしで受理してしまう分裂があり、生値の改行検査で遮断〕・
  連続区切り`//`の拒否〔shのIFS分割は末尾空フィールドを落としFSは`//`を畳み込むため、
  PS版も含め正規化後派生パス**全域**（root部分含む）の`//`拒否で統一〕・
  transcript_path末尾LFの拒否〔shはコマンド置換の末尾LF剥がしでゲート前に値が変形する
  ため、制御文字検査を値がシェルへ出る前のjq内で行うパス用取得ho_path_fieldを新設〕）
  を追加。パリティ計68ケース。加えてPS実装の単体試験 `tests/run-unit-path.ps1`
  （P1〜P18）をPS 5.1 / pwshの両方で実行: パリティではOS依存で固定できない分岐 —
  ADS/予約デバイス名/UNC/相対/制御文字の字句拒否・UTF-8バイト長境界・
  junction構成要素の拒否（Windows）・FIFO/symlink/宙吊りsymlinkの拒否（Unix pwsh）—
  を固定。
  副産物: PS実装で `.Split(配列)` のオーバーロード束縛がエディションで分裂する罠を実測
  （pwshは `Split(string)` に束縛され分割されない）。`[char[]]` 明示で修正
  （docs/verification/ps51-compat.md 罠10）
- **変更（ポインタ鮮度判定のupdated_epoch化 — issue #34・意図した挙動変更）**:
  ポインタ `latest.json` の鮮度判定から人間可読日時のパース
  （PS: TryParseExact / sh: date -d/-j+値域regex+暦日検証）を排除し、
  **`updated_epoch`（UNIX秒の整数）を鮮度判定の唯一の正**にする。契約:
  数値型で、**パーサでdouble化された値が整数**（jqの `floor` 同値。PS側もdoubleへ
  正規化してから判定する — PS 5.1のdecimalはsub-ULP小数を保持しpwsh/jqと受否が
  分裂するため。JSON表記上の小数でもdouble丸めで整数になる値は受理）・`0 < v`・
  `v ≤ now+86400`（未来skew上限1日 — 時計改変や偽装ポインタによる無期限延命を遮断）・
  `now - v ≤ 7*86400`。範囲比較で2^53超が先に落ちるため精度問題なく完結する。
  now取得失敗は鮮度判定不能としてポインタ無効（fail-closed）。
  updated_epochが無い/型違い/範囲外は診断をerror.logへ記録して無効、契約内の値で
  期限超過のみ静かに無効（従来の期限切れと同じ扱い — 復元ごとのログ蓄積を避ける）。
  `updated_at` は表示専用として併記を継続（判定には使わない）。**表示時は
  producer形式の1行に一致する場合のみ表示**（形式外は `?`。鮮度検証から外した
  updated_atを未加工表示すると、有効なepoch+SHAのまま改行入り指示や巨大文字列を
  復元出力へ注入できてしまうため — 表示値の形式ゲート）。
  producerは `schema_version: 1`・`updated_epoch`・`consumed: false` を旧フィールドと
  併記するadditive移行（設計文書5章。**旧producerが書いたポインタ〔updated_epochなし〕は
  新consumerが拒否**し、次のhandoffサイクルの完了検証で再生成される）。
  producerのepoch取得失敗はSHA計算失敗と同じ縮退（ポインタ非更新+通知）。
  消費状態は**dual-read/dual-write**（設計文書4.2）: 読取りは
  `consumed == true` または `consumed_at` 非空で消費済み（consumedは存在するなら
  booleanのみ許可 — 型違いはポインタごと無効）、消費時は `consumed = true` と
  非空 `consumed_at` を同一のatomic更新で書く（旧consumer×新producer・
  新consumer×旧producer・PS×shの全組合せで消費が見える）。消費時の日時取得失敗は
  検証済みnowのepoch表記へフォールバックし**consumed_atを必ず非空にする**
  （空を書くと旧consumerが未消費と読みdual-writeの移行保証が破れる）。
  時刻取得は共通関数（PS: Get-HoNowEpoch/Get-HoNowDisplay / sh: ho_now_epoch/
  ho_now_display）に集約し、テスト用シーム（HANDOFF_TEST_NOW_EPOCH固定・
  HANDOFF_TEST_FORCE_NOW_FAIL・HANDOFF_TEST_FORCE_DATE_FAIL）で境界・失敗経路を
  決定的に検証可能にした。
  E2Eは鮮度契約ケースをepochへ置換（C11=7日超過去 / C12=欠落〔旧producer形式の
  fail-closed〕/ C13=非数値文字列 / C37=配列 / C51=0 / C52=数字文字列 /
  C54=未来skew超 / C55=非整数値）し、C69（consumed=true・consumed_at欠落→消費済み）・
  C70（consumed=false・consumed_at非空→消費済み）・C71（clear注入でdual-write
  両フィールド）・C72（改変updated_atが出力に現れない）・C73（sub-ULP小数の
  double丸め受理 — 全実装一致）・C74（日時取得失敗時のconsumed_at非空フォールバック）・
  C75（now固定でのepoch境界5点）・C76（restoreのnow取得失敗fail-closed）・
  C77（producerのepoch取得失敗縮退）・C78（NOW_EPOCHシーム採用契約の一致 —
  末尾LF/先頭ゼロ/19桁は実時刻へフォールバック）を追加。パリティ計78ケース。
  表示ゲート・シーム採用のアンカーは \A/\z（jq/Onigurumaと.NETの ^/$ は行端・
  末尾改行前に一致し得るため — 多行値の迂回を遮断）。
  sh共通から暦日検証 `ho_valid_calendar_day`（判定経路の残置コード）を削除
- **修正（JSON境界のcase-sensitive化 — issue #37）**: PS実装の
  `PSObject.Properties["名前"]` とドット参照は大小非区別のため、大小違いキー
  （例: ポインタの `"Consumed"`・状態ファイルの `"MODE"`・hook入力の `"Source"`）に
  一致し、これらを未知キーとして無視するjq（case-sensitive）と受否が分裂していた
  （例: `"Consumed": true` のみのポインタをPS版は消費済み扱いで拒否・sh版は注入）。
  JSON境界の判定値の存在確認をordinal完全一致の共通ヘルパ `Test-HoProp`
  （+取得用 `Get-HoProp`）へ全面置換（4フック48箇所）。ガード通過後のドット参照は
  大小違い重複キーがパーサ層で拒否済み（unit-json既存契約）のため正確なキーの
  値取得が保証される。唯一ガードなしで残っていたtranscript行の `message.content`
  読取り（PS版だけ `"Content"` を拾い直近ユーザーメッセージ引用が分裂）も
  `Get-HoProp` へ置換。回帰C79（ポインタ"Consumed"のみ→consumedとは別キー扱い
  〔下記issue #38の閉じたスキーマ導入後は未知キーとしてファイル無効=無出力〕 /
  状態"MODE"のみ→スキーマ不正で新規hardサイクル / 入力"Source"のみ→非clear扱いで
  未消費 / message直下"Content"のみ→引用不採用）と、ヘルパ固有契約の単体試験
  U24〜U27（正しい大小・大小違い・null値・1要素配列の型保持）を追加
- **修正（完全性ファイルの閉じたスキーマ — issue #38）**: pointer（latest.json）/
  state（*.handoff-state.json）/ config（handoff-config.json）を既知キー集合の
  完全列挙で検証し、未知キーが1つでもあればファイル無効に変更（タイポで設定が
  既定値に静かに落ちる事故と、未知キー経由の将来の解釈分裂を防ぐ。大小違いキーも
  未知キー — issue #37の契約と整合）。fail方針は現行契約のまま:
  pointer=不使用+診断 / state=破棄+再生成+error.log / config=機能無効+診断。
  pointerはschema_version==1を必須化（欠落=旧形式 / 不一致=未知の形式で診断文言を
  区別。旧producerのポインタは次のhandoffサイクルで再生成される。判定は数値の
  double正規化比較 — jqの数値比較と同一契約で、1.00等の小数表記も1として有効）。
  handoff_path / size は移行期間用の受理専用キーとして既知集合に含める。
  stateはproducerがschema_version:1をadditive書込みするようになり、読取りは
  欠落（旧バージョンが書いたファイル）を許容・存在時は1のみ受理
  （移行: 旧バージョンが書いた既知キーのみのstateはそのまま通る）。
  回帰C80（ポインタ未知キー/schema_version欠落/=2/大小違い重複キー/=1.00/
  ルート非object・state未知キー/schema_version=2/欠落=旧バージョン受理/
  既知フルセット受理/producer全5書込み箇所のschema_version:1書込み・
  compact復元のstate nonce読取り3態・config未知キー）を追加。パリティ計80ケース
- **修正（テスト基盤）**: テストスクリプトが引数指定の作業ディレクトリを無条件に
  再帰削除していた危険を排除（既存パスの指定はエラーとし、削除は自ら作成した
  ディレクトリに限定）。期待値比較を大小・順序・行数まで厳密なordinal比較に変更
  （`Compare-Object`は大小無視・順序無視のため退行を見逃し得た）。
  PS版JSONパーサの単体試験 `tests/run-unit-json.ps1`（U1〜U23）を追加しPS 5.1 /
  pwshの両方で実行（issue #30）: パリティ試験では見えないフォールバック経路の内部契約 —
  経路選択の環境変数判定（ordinal "1" のみ強制。U+00AD付き値でカルチャ比較退行を検出）・
  フォールバック経路への接続（変換関数の呼び出しマーカーで直接確認）・
  大小違い重複キーの拒否・同綴り重複キーの後勝ち（型とordinal値まで検証）・
  深度境界（Coreは64/65/1024受理・1025拒否。PS 5.1のJavaScriptSerializerは
  RecursionLimitで深度100前後から拒否するため共通規範は65受理まで）・
  ルート1要素配列の保持・ISO日時文字列の原表記維持（ordinal一致）・整数の型 — を固定。
  実行済みID集合の完全性も終了前に検証（アサーション削除の退行を検出）
- **ドキュメント**: 手動導入の全体像を番号付き手順で明示（setupはフックのコピー・登録を
  しないことを明記。issue #24）。setupスクリプトは人がターミナルで実行する旨と、
  Claude Codeに導入させる場合の「スクリプトを使わない手順」を追加（AI経由の実行は
  安全分類器にブロックされる実測報告 — issue #23）。権限ルールの置き場所の説明を
  共有/非共有の書き分けに統一（INSTALL.mdがsettings.json断定のままだった — issue #26）。
  READMEにsetupのPowerShell名前付きパラメータ例を併記（issue #27）。
  window値は公称ウィンドウでなく **`/context` 表示の総量**に合わせる旨をREADME/INSTALL.mdに
  明記し、既定値・設定例・gitignore理由の説明も「モデルの窓（200K/1M）」基準から
  「`/context` の総量表示」基準に統一（公称1Mモデルの実効500k実測報告 — issue #28）

## v0.1.2 (2026-08-09)

- **setupの `.gitignore` 追記をマシン/環境固有の4エントリに拡張**: `.claude-handoff/`（従来から）に
  加え、`.claude/handoff-config.json`（閾値はモデルの窓200K/1Mとマシンの設定に依存し、チーム共有
  すると別モデル環境で発火しない/早すぎる原因になる）・`.claude/hooks/claude-remote-handoff/`
  （手動導入のフック本体。OSごとにps/shを選ぶ）・`.claude/settings.local.json*`
  （手動導入のフック登録先と.bak）を追記する。既にtrackedなファイルは警告を出す
- **手動導入（INSTALL.md 方法B）のフック登録先を `.claude/settings.local.json` に変更**:
  フック本体はgitignoreされるため、コミットされる settings.json に登録すると他マシンで
  「存在しないスクリプトを指すフック」となり毎ターンエラーになる問題の予防
- README: チーム利用時の注意（handoff-config.jsonをコミットしない）を追記
- **修正（検証ロジック）**: 必須見出しの直後に `###` 小見出しを置くと「本文が空」と誤判定され
  検証が恒久的に失敗するバグを修正。敵対的レビュー（3回目）を受けて、必須見出しはh1/h2のみ・
  見出し行自体は本文に数えない・走査はps/sh同一の状態機械、に統一
  （###への必須見出し退避や###1行だけの空セクションは両実装とも拒否）。
  さらに4回目レビューで、見出し照合とnonce照合を**大文字小文字厳密**・`##`後の
  **半角空白必須**（`[ \t]`のみ）に統一（PSの `-match`/`-ne` 既定の大小無視と `\s*` の
  空白ゼロ許容により `## goal`・`##Goal` が通ってps/shの合否が分裂していた）。
  資料の**最大サイズ10MB**を導入（巨大current.mdでStop/SessionStartフックを
  CPU・メモリ枯渇させるDoS経路の遮断。超過時は内容を読まずに検証失敗扱い）。
  5回目レビューでさらに: **最大行数10万行**を追加（10MB未満の改行密集ファイルによる
  走査コスト膨張の遮断。PS版は中間配列を廃した単一パス走査に変更）、空白の契約を
  ASCIIの`[ \t]`+行末`\r`除去1回に統一（PSの`.Trim()`/`\s`はU+00A0等を含みawkの
  `[[:space:]]`〔Cロケール〕と分裂）、sh版の`tr -d '\r'`を廃止（行中の埋め込み`\r`まで
  削除してnonce照合がPS版と分裂していた）。6回目レビューで「\r除去は1回だけ」を
  厳密化（PS版は`\n`のみで分割、sh版は全awkに`BINMODE=3`でGit Bash gawkの暗黙CRLF変換を
  抑止。マーカー比較はMSYS bashの`$( )`が末尾`\r\n`を剥ぐためawk内で実施）。
  パリティ試験にC14（###小見出し入りの正常資料）・C15（全見出し###化の拒否）・
  C16（###のみの空セクション拒否+理由数のps/sh一致）・C17（大小違い・空白抜き見出しの
  拒否）・C18（10MB超過の拒否）・C19（行数爆弾の拒否）・C20（埋め込み\rマーカーの拒否）・
  C21（\r\r行末マーカーの拒否）を追加
- **改善（再試行の指示文）**: 完了検証の失敗理由（見出し欠落／本文空／マーカー不一致／最小文字数）を
  再試行指示に含め、「nonceは試行ごとに更新される」注意も明記（同じ書き方の再試行で
  試行枠を浪費させない）
- **改善（注入予算）**: 作成指示に「全体で5000文字以内」の目安と「超過分は中央から省略される」
  事実を明示。再注入時の中略行に省略区間の見出し名を含める（表示は既知の7必須見出しのみ・
  正順・重複なし — 任意見出しの無制限表示は注入・肥大の経路になるため敵対的レビューで限定）
- **改善（複数セッション並行）**: 別セッションが作成した資料をポインタ経由で注入する場合、
  注入文の冒頭に作成セッションを明示。既知の限界10として文書化
- **修正（sh版のfail-silent）**: 実行時にjqが無い場合、jq無しでerror.logへ記録してから
  終了するようにした（従来は痕跡ゼロで沈黙）
- **修正（既定値の不一致）**: フック側の `conservative_fire_pct` フォールバック既定を80→92にし
  setupと統一（config手書きで省略した場合に静かに無効化される罠を解消）
- **改善（実行時再検証）**: 環境変数が見えない環境では configの `autocompact_window` で
  同じ検証を行う（検証が丸ごとスキップされる穴を縮小）。config全数値は
  「JSON numberかつ整数かつ1e9以下」の共通検証に統一（型・上限の分裂とオーバーフロー対策）。
  setup側にも同じ1e9上限の検証を追加（setupが通した設定を実行時にフックが全拒否する
  不整合の解消。4回目レビュー）
- **改善（診断性）**: 不正なhandoff-stateの破棄をerror.logに記録（config不正と対称に）
- **変更（指示文）**: 恒久的決定の反映先を「チーム共有=CLAUDE.md / マシン・個人固有=
  CLAUDE.local.md（+gitignore）/ 判断不能なら資料のKey Decisionsに留める」の書き分けに変更
- **ドキュメント**: INSTALL.mdの1M向け推奨例が静的検証に落ちるのを修正（検証NG時の
  メッセージにも最大許容ハード閾値を表示。sh版にも修正例を追加）。手動導入用の
  OS別完成形JSONスニペット3種を同梱。/hooksでの登録確認・AI導入時の権限ブロック方針・
  混在OSリポジトリの注意を追記。permissionsルールを「実質必須」表記に。アンインストール先を
  settings.local.jsonに更新。既知の限界6（保持対象にcurrent.mdを含む）・
  8（auto compact実発火は実地報告2件で確認済み）を更新
- **テスト**: `KEEP_WORK=1` でパリティ試験の作業ディレクトリを残せるようにした（失敗調査用）。
  lint-sh.ps1を.ps1にも拡張（PSも変数名にCJKを許すため `$var` 直後の非ASCIIが
  未定義変数として空文字にサイレント展開される — 今回の改修中に実測した同型の罠）。
  setup.shのgitignore重複判定でCRLFファイルも扱えるよう\rをtrim

## v0.1.1 (2026-08-08)

- ドッグフーディングのフィードバックを反映し、リセット経路の案内を一律 `/clear` 推奨から
  利用シーン別（Remote Control中・放置運用= auto compactに任せる / 節約重視= `/clear`）に変更
  （READMEとフックの案内文言）
- `/clear` 経路のUX制約（注入資料は次のユーザー入力まで読まれず自動では作業再開しない・
  Remote Controlの画面では会話ログが新しい空セッションに切り替わる）を既知の限界に追記
- プラグイン/マーケットプレイスのdescriptionを日英併記に
- **修正（ポインタ有効期限の fail-open）**: 7日の有効期限が迂回できる経路が3つあった。
  ①sh版がPS版の書く `+09:00` 形式を解釈できない（macOSのBSD `date` のみ。GNU `date -d` では露見しない）
  ②**両実装とも `updated_at` が無いポインタは期限判定ごとスキップしていた**（削るだけで無期限に迂回できた）
  ③**PS版は解釈できない `updated_at` も受理していた**（sh版と挙動が分裂）。
  オフセット表記を正規化したうえで、**時刻が無い/解釈できないポインタは両実装とも fail-closed**
  （無効扱い＋error.logへ記録）に統一した。パリティ試験に C11（他実装形式の期限切れ）・
  C12（`updated_at` 欠落）・C13（解釈不能な `updated_at`）を追加
- **再発防止（静的検査）**: 非ASCII文字の直前の裸の変数展開（`$var`直後の全角等。bash 3.2で
  値が消える）を禁止する `tests/lint-sh.ps1` を追加しCIで強制。bash 5.1 / dash では
  再現しないことも確認（バグはbash 3.2固有）

## v0.1.0 (2026-08-08)

初回リリース。

- 層1: PreCompactでのtranscript全文+git状態バックアップ（世代・日数・容量retention付き）と、
  SessionStart（`clear` / `compact`）での機械的合成文の自動再注入
- 層3: Stopフックでのコンテキスト使用量実測と2段階閾値（ソフト=提案/ハード=強制+完了検証+リトライ）
- 完了検証付きポインタ（必須7セクション+完了マーカー+SHA-256照合）— 検証済みhandoffのみ注入
- `/clear` 推奨経路（トークン消費ゼロ）+ auto compact安全網の2経路
- PowerShell 5.1（Windows標準）/ pwsh / sh+jq の2系統実装（共有フィクスチャでCI一致検証済み）
- Claude Codeプラグイン（Windows）/ 手動導入（macOS/Linux）/ setupスクリプト

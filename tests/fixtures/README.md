# 共有テストフィクスチャ

PS版（hooks/ps/）とsh版（hooks/sh/）の挙動一致を検証するための共有フィクスチャ。
`tests/run-parity.ps1` / `tests/run-parity.sh` が同一の80ケースを各実装に流し、
正規化した結果行を出力する。**検証は `tests/run-local-check.ps1`（PS 5.1 / pwsh の
両方で実行）と `tests/run-local-check.sh`（Git Bash等のsh+jq）で行う** — 期待値
`expected/parity-expected.txt` との照合（大小・順序・行数まで厳密）と失敗時の非0終了を
含む一括実行ラッパー。ランナー単体は結果行を出力するだけで合否判定しないため、
目視だけで成功と誤認しないこと。macOS/Linuxで検証する場合も同ラッパーをそのまま実行できる。

このほか、フィクスチャを使わない単体試験として `tests/run-unit-json.ps1`（U1〜U27）が
PS版JSONパーサの内部契約（フォールバック経路の選択・重複キー処理・深度境界）と
`Test-HoProp` / `Get-HoProp` のcase-sensitive取得契約（issue #37）を、
`tests/run-unit-path.ps1`（P1〜P18）が包含ゲートのOS依存分岐（ADS/予約名/UTF-8バイト長
境界/junction/Unixの特殊ファイル・symlink walk — issue #33）を固定する
（いずれも自己判定型・FAILで exit 1。PS 5.1 / pwsh の両方で実行する。
Unix専用ケースはUnix pwshでのみ実行され、他環境ではSKIP表示になる）。

## 構成

- `transcripts/mixed-below.jsonl` — 敵対的ノイズ入りtranscript:
  正常usage(180) + isSidechain行(9000・除外されるべき) + 部分行 `{"input_tokens":100}` +
  型不正 `input_tokens:true` + 壊れたJSON行 + userメッセージ
- `md/good-handoff.md.tmpl` — 完了検証を通る正しいhandoff（7見出し+本文+最終行マーカー。
  `{{NONCE}}` を実行時に置換）
- `md/good-handoff-subheadings.md.tmpl` — 必須見出し直下に `###` 小見出しを含む正常handoff
- `md/bad-handoff.md.tmpl` — 敵対的handoff（`## Not Goal`・マーカー途中配置・埋め草）
- `md/bad-handoff-h3.md.tmpl` — 必須見出しをすべて `###` へ退避した敵対的handoff
- `md/bad-handoff-empty-sections.md.tmpl` — 各セクションが `###` スタブ1行だけ（実本文ゼロ）
- `md/bad-handoff-casespace.md.tmpl` — 見出しの大小違い（`## goal`）・空白抜き（`##Goal`）
- `expected/parity-expected.txt` — 80ケースの期待出力（全実装で一致すべき正規化結果）
- `expected/setup-gitignore-expected.txt` — setupの `.gitignore` 追記試験
  （`tests/run-setup-gitignore.ps1` / `.sh`、8ケース S1〜S8）の期待出力。
  サマリ行（件数・`*`付き有無・更新推奨メッセージの提示有無・config生成）に加え、
  実行後の `.gitignore` 全行（trim後・順序込み・非ASCIIは `?` 正規化）を
  `SxL ` 行として出力・比較する

## ケース一覧（runner内で構築）

| # | 内容 | 期待 |
|---|---|---|
| C1 | 閾値未満+ノイズ行 | 無発火・状態なし |
| C2 | soft超過(250) | ソフト提案・state soft/1 |
| C3 | 再実行 | 提案はサイクル1回（無出力） |
| C4 | hard超過(450) | エスカレーション・state hard/1 |
| C5 | 未完了で再実行 | リトライ(試行2/3)・state hard/2 |
| C6 | 正しいmd配置後 | 完了・latest.json(nonce一致/sha付き) |
| C7 | 敵対的md | 拒否されてリトライ |
| C8 | restore(clear)+有効ポインタ | 注入(検証済み)+Goal内容+consumed_at |
| C9 | 消費済みポインタ | 無出力 |
| C10 | 改竄md(マーカー後追記) | 注入拒否 |
| C11 | 期限切れポインタ（`updated_epoch` が7日超過去） | 注入拒否 |
| C12 | `updated_epoch` 欠落ポインタ（旧producer形式） | 注入拒否（移行fail-closed・削除で期限迂回できない） |
| C13 | 数値でない `updated_epoch`（文字列） | 注入拒否（両実装で同一判定） |
| C14 | ###小見出し入りの正常md | 完了（###は本文扱い） |
| C15 | 全必須見出しを###化 | 拒否・理由数7（h1/h2のみ有効） |
| C16 | ###スタブのみの空セクション | 拒否・理由数7（見出し行は本文に数えない） |
| C17 | 見出しの大小違い・空白抜き | 拒否・理由数7（大小厳密・`##`後の空白必須） |
| C18 | 10MB超のmd | 拒否・理由数1（読み込む前にサイズで弾く） |
| C19 | 改行20万の行数爆弾（10MB未満） | 拒否・理由数1（行数走査は上限で打ち切り） |
| C20 | マーカーのnonceに\r埋め込み | 拒否・理由数1（行中の\rは除去しない） |
| C21 | マーカー行末を\r\r化 | 拒否・理由数1（行末の\r除去は1回だけ） |
| C22 | マーカー行のU+00A0前置 | 拒否・理由数1（macOSのBWK awkのstrcoll等価を遮断。LC_ALL=C） |
| C23 | 正常マーカー後にU+00A0だけの行 | 拒否・理由数1（U+00A0だけの行は非空行。strcollの空文字列等価を遮断） |
| C24 | マーカー行のU+00AD（soft hyphen）前置 | 拒否・理由数1（PSのカルチャ比較の無視可能文字を遮断。Ordinal比較） |
| C25 | transcriptのtypeにU+00AD挿入（9000トークン行） | 無発火（偽装typeはusage合算から除外） |
| C26 | 状態ファイルのmodeにU+00AD挿入 | スキーマ不正で破棄→新規hardサイクル（hard/1） |
| C27 | ポインタのsha256にU+00AD挿入 | 注入拒否（SHA照合はordinal厳密） |
| C28 | transcriptのtypeが配列["assistant"] | 無発火（JSON境界は型も固定 — 配列は拒否） |
| C29 | 状態ファイルのmodeが配列["hard"] | スキーマ不正で破棄→新規hardサイクル（hard/1） |
| C30 | sourceにU+00AD挿入（"cle?ar"） | clearとして扱わない（注入はするがポインタ未消費） |
| C31 | 非clearソース+他セッション指しポインタ+自セッション資料 | 自セッションの資料を優先注入（sha照合はポインタ経由時のみ） |
| C32 | ポインタのsha256が配列["正しいhash"] | 注入拒否（型固定。jqはJSON文字列化で不一致） |
| C33 | ポインタのsession_idが配列["正しいUUID"] | ポインタ無効・無出力 |
| C34 | transcriptのuser行type/contentパーツtype/textが配列 | 偽装行/要素は引用から除外（正規行のみ注入） |
| C35 | ポインタのsha256がboolean false | 注入拒否（非文字列は不一致扱い。shの`// empty`スキップを排除） |
| C36 | ポインタのconsumed_atが配列[""] | ポインタ無効・無出力 |
| C37 | ポインタのupdated_epochが配列[有効なepoch] | ポインタ無効・無出力 |
| C38 | transcriptのisSidechainが文字列"false" | 除外しない（除外はboolean trueのみ）→ hard発火 |
| C39 | transcriptのmessageが配列・行全体が配列 | usage合算から除外・無発火 |
| C40 | stop_hook_activeが文字列"false"+壊れたstate | ループ停止と扱わず再生成→hard発火 |
| C41 | background_tasksが非配列（文字列） | 0件扱い→ソフト提案を見送らない |
| C42 | ルートが配列のポインタ [{有効ポインタ}] | 無効・無出力（pwshの列挙縮退を遮断） |
| C43 | ルートが配列の状態ファイル | スキーマ不正で破棄→新規hardサイクル（hard/1） |
| C44 | ルートが配列のconfig [{有効な設定}] | 不正として機能無効・無発火 |
| C45 | ルートが配列のhook入力 [{有効なStop入力}] | 不正入力として無視・無発火 |
| C46 | saveのtriggerが配列["compact"] | meta.jsonのtriggerは空文字列 |
| C47 | ルートが配列のmeta.json | バックアップ導線の保存情報は空欄のまま行を付与 |
| C48 | ISO日時形式だけのユーザーメッセージ | 原表記のまま引用（[datetime]化・表記正規化しない） |
| C49 | ルートがスカラーのhook入力（数値0）でsave | 不正入力として無視・unknownバックアップを作らない |
| C50 | ルートがスカラーのhook入力（文字列）でrestore | 無視・有効ポインタも未消費のまま |
| C51 | ポインタのupdated_epochが0 | 契約（0 < v）違反でポインタ無効・無出力 |
| C52 | ポインタのupdated_epochが数字文字列 | 型違いでfail-closed・無出力 |
| C53 | 旧pwsh相当経路の強制（JSONフォールバックパーサ） | 原表記維持で全実装同一出力（日時引用が正規化されない） |
| C54 | updated_epochが未来skew上限超（now+2日） | fail-closed・無出力 |
| C55 | updated_epochが整数でない数値（+0.5） | fail-closed・無出力（floor同値契約） |
| C56 | resetのtranscript_pathが配列["path"] | 状態を削除しない（文字列なら削除する正経路も検証） |
| C57 | user行に完全なusage構造 | 採用しない（usage走査はassistant限定）→ softのまま |
| C58 | isMeta=trueのassistant行のusage | 採用する（isMetaはusage走査では不問）→ hard発火 |
| C59 | SHA計算失敗（シームで強制）で完了検証 | 他セッションの実注入可能ポインタがバイト不変（C59後の実注入も確認）・state completed・systemMessage（資料パス入り）と記録は1回（sha256=null縮退の廃止） |
| C60 | sha256が欠落/null/空文字列の有効ポインタ（3態） | いずれも注入拒否+「SHA-256照合不可」note（照合スキップの廃止 — fail-closed） |
| C61 | SHA失敗+state書き込み失敗（両シーム） | 通知なし・state未完了のまま・専用エラー記録（通知はcompleted遷移成功後のみ） |
| C62 | autocompact_windowの無いconfig（Stop 2回） | 機能無効・無発火+診断2件（fire-point検証のfail-closed化 — window必須。診断はStopごと記録） |
| C63 | 環境変数windowが"+100000"/"0000000600"/"\n600"（config window=500） | 符号付きと改行前置は拒否→無効化 / 先頭ゼロは10進600採用→hard発火（八進解釈・拒否と一意判別） |
| C64 | window=2053×pct=20（発火点410.6） | floorで410 <= 410 → 無効化・無出力（PSの最近接丸めとshの切り捨ての分裂を検出) |
| C65 | 環境変数pctが"+19"/"019"/"0"/"19\n"（config pct=20, window=2100） | 先頭ゼロのみ10進19採用→無効化、他は拒否→hard発火（符号・範囲・末尾LFのゲート検証） |
| C66 | projects_root外のtranscript（check・reset） | checkは無発火+state非作成（診断記録）、root外の実在stateをresetは削除しない（包含ゲート — issue #33の挙動変更） |
| C67 | 「..」セグメント入り・rootの文字列前置だけ一致する隣接ディレクトリ | いずれも拒否（無発火・state非作成・reset生存）。ゲートNG診断はStopごと記録（C66aと合わせ3件） |
| C68 | root外/内stateのrestore・save 4c孤児掃除・多バイト長・config末尾LF | root外は生存/root内は従来どおり削除・掃除（正常系保全）。派生パスUTF-8バイト長>240は拒否（文字数<=240でも）。CLAUDE_CONFIG_DIR末尾LF・連続区切り（//。root部分含む）・transcript_path末尾LFは拒否 |
| C69 | consumed=true・consumed_at欠落のポインタ（dual-read） | 消費済み扱い・無出力 |
| C70 | consumed=false・consumed_at非空のポインタ（旧consumer消費・dual-read） | 消費済み扱い・無出力 |
| C71 | 未消費の有効ポインタをclearで注入（dual-write） | 注入+consumed=true と非空consumed_atが同一更新で書かれる |
| C72 | 有効epoch+SHAのままupdated_atを「有効timestamp行+改行+悪意テキスト」へ改変 | 注入は行われるが当該値は出力に現れない（表示値の形式ゲートは\A/\z固定 — jq/Onigurumaの^/$は行端） |
| C73 | updated_epochの表記がsub-ULP小数（有効値+.00000001） | double丸めで整数となり全実装が受理・注入 |
| C74 | 消費時の日時取得失敗（now固定+HANDOFF_TEST_FORCE_DATE_FAIL） | 注入+consumed_atは正確に "epoch:<固定now>"（dual-write保証） |
| C75 | epoch境界（now固定: now / +86400 / +86401 / -7日 / -7日-1） | ちょうどは受理・+1超過/-1超過は拒否 |
| C76 | restoreのnow取得失敗（HANDOFF_TEST_FORCE_NOW_FAIL） | fail-closed・無出力 |
| C77 | producerのepoch取得失敗 | ポインタ非更新（byte一致）・state completed・専用メッセージ1回 |
| C78 | NOW_EPOCHシームの形式外値（末尾LF/先頭ゼロ/19桁は実時刻新鮮ポインタ）と有効値（epoch=2001年ポインタ+同値シーム） | 形式外は実時刻フォールバックで注入（誤採用/fail-closedならnone）・有効値は採用時のみ注入 — 両実装同一契約 |
| C79 | 大小違いキー（ポインタ"Consumed"のみ / 状態"MODE"のみ / 入力"Source"のみ / transcriptのmessage直下"Content"のみ） | jq準拠のcase-sensitive参照: ポインタ"Consumed"は未知キーでファイル無効=無出力（#38）/ 状態はスキーマ不正→新規hardサイクル / 入力は非clear扱いで未消費 / 直近ユーザーメッセージに不採用 |
| C80 | 完全性ファイルの閉じたスキーマ（issue #38）: ポインタ未知キー / schema_version欠落 / =2 / 大小違い重複キーSHA256 / =1.00 / ルート非object（文字列・数値）・state未知キー / schema_version=2 / 欠落（旧バージョン）/ 既知フルセット / producer全5書込み箇所のschema_version:1（JSON numberかつ1の厳密判定）・compact復元のstate nonce読取り3態・config未知キー | 未知キー・schema_version不正はファイル無効（欠落=旧形式 / 不一致=未知の形式で診断文言区別、非objectは静かに無効=診断増分0）。1.00はdouble正規化で有効・注入。state違反は破棄+再生成、欠落・既知フルセットは受理継続、producerはschema_version:1を書く。compactのnonce読取りは欠落受理/未知キー・version不正でrefused。config違反は機能無効+診断 |

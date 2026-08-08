# 共有テストフィクスチャ

PS版（hooks/ps/）とsh版（hooks/sh/）の挙動一致を検証するための共有フィクスチャ。
`tests/run-parity.ps1` / `tests/run-parity.sh` が同一の21ケースを各実装に流し、
正規化した結果行を出力する。CIは各実装の出力を `expected/parity-expected.txt` と比較する
（4ジョブ: Windows PS 5.1 / Linux pwsh / Linux sh+jq / macOS sh+jq）。

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
- `expected/parity-expected.txt` — 21ケースの期待出力（全実装で一致すべき正規化結果）

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
| C11 | 他実装形式の期限切れポインタ | 注入拒否 |
| C12 | `updated_at` 欠落ポインタ | 注入拒否（削除で期限迂回できない） |
| C13 | 解釈不能な `updated_at` | 注入拒否（両実装で同一判定） |
| C14 | ###小見出し入りの正常md | 完了（###は本文扱い） |
| C15 | 全必須見出しを###化 | 拒否・理由数7（h1/h2のみ有効） |
| C16 | ###スタブのみの空セクション | 拒否・理由数7（見出し行は本文に数えない） |
| C17 | 見出しの大小違い・空白抜き | 拒否・理由数7（大小厳密・`##`後の空白必須） |
| C18 | 10MB超のmd | 拒否・理由数1（読み込む前にサイズで弾く） |
| C19 | 改行20万の行数爆弾（10MB未満） | 拒否・理由数1（行数走査は上限で打ち切り） |
| C20 | マーカーのnonceに\r埋め込み | 拒否・理由数1（行中の\rは除去しない） |
| C21 | マーカー行末を\r\r化 | 拒否・理由数1（行末の\r除去は1回だけ） |

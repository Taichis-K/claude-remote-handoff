# 共有テストフィクスチャ

PS版（hooks/ps/）とsh版（hooks/sh/）の挙動一致を検証するための共有フィクスチャ。
`tests/run-parity.ps1` / `tests/run-parity.sh` が同一の10ケースを各実装に流し、
正規化した結果行を出力する。CIは各実装の出力を `expected/parity-expected.txt` と比較する
（3実行系: Windows PS 5.1 / Linux pwsh / Linux・macOS sh+jq）。

## 構成

- `transcripts/mixed-below.jsonl` — 敵対的ノイズ入りtranscript:
  正常usage(180) + isSidechain行(9000・除外されるべき) + 部分行 `{"input_tokens":100}` +
  型不正 `input_tokens:true` + 壊れたJSON行 + userメッセージ
- `md/good-handoff.md.tmpl` — 完了検証を通る正しいhandoff（7見出し+本文+最終行マーカー。
  `{{NONCE}}` を実行時に置換）
- `md/bad-handoff.md.tmpl` — 敵対的handoff（`## Not Goal`・マーカー途中配置・埋め草。
  構造チェックで弾かれるべき）
- `expected/parity-expected.txt` — 10ケースの期待出力（全実装で一致すべき正規化結果）

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

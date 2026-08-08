# Changelog

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

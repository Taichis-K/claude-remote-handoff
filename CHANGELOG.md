# Changelog

## v0.1.0 (2026-08-08)

初回リリース。

- 層1: PreCompactでのtranscript全文+git状態バックアップ（世代・日数・容量retention付き）と、
  SessionStart（`clear` / `compact`）での機械的合成文の自動再注入
- 層3: Stopフックでのコンテキスト使用量実測と2段階閾値（ソフト=提案/ハード=強制+完了検証+リトライ）
- 完了検証付きポインタ（必須7セクション+完了マーカー+SHA-256照合）— 検証済みhandoffのみ注入
- `/clear` 推奨経路（トークン消費ゼロ）+ auto compact安全網の2経路
- PowerShell 5.1（Windows標準）/ pwsh / sh+jq の2系統実装（共有フィクスチャでCI一致検証済み）
- Claude Codeプラグイン（Windows）/ 手動導入（macOS/Linux）/ setupスクリプト

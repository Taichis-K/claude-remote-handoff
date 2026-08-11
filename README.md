# claude-remote-handoff

**Works with Claude Code Remote Control sessions — no local terminal required.**

Claude CodeのRemote Controlセッションで長時間作業する際、auto compactによる精度低下を防ぐための
フックベース自動引き継ぎツール。コンテキスト使用量が閾値を超えると引き継ぎ資料（handoff）の作成を
自動でClaudeに指示し、auto compact 後または `/clear` 後のコンテキストに自動で再注入します。

> **AIエージェントで導入する場合**: [INSTALL.md](INSTALL.md) の決定論的手順に従ってください。

Inspired by [willseltzer/claude-handoff](https://github.com/willseltzer/claude-handoff) —
this adds automatic, threshold-triggered handoffs via hooks.

## なぜRemote Control対応が必要か

Remote Control中は `/resume` がローカル限定のため、既存ツールが前提とする
`/clear`→`/resume` ワークフローが成立しません。本ツールは
**同一セッション内で完結**します: 引き継ぎ資料の作成も、`/clear`・`/compact` 後の再注入も、
モバイル/Webから操作できる範囲だけで回ります（導入だけはローカルで1回必要です）。

## 動作の流れ

1. **閾値到達（ソフト）**: Stopフックがコンテキスト使用量を実測し、「作業が区切りの
   良いところまで来ていればhandoffを作成せよ」とClaudeに提案（区切りが悪ければ延期可）
2. **閾値到達（ハード）**: 区切りに関係なく作成を強制。完了検証（構造チェック+完了マーカー）
   付きで、失敗時は最大2回リトライ
3. Claudeが `.claude-handoff/<session_id>/current.md` に引き継ぎ資料を作成し、
   ユーザーへリセット経路の選択肢を案内（下記「リセット経路の選び方」）
4. auto compact（または `/clear`）後、SessionStartフックが検証済みの引き継ぎ資料+
   git状態+直近のユーザーメッセージを新しいコンテキストへ自動注入 → そのまま作業続行

## リセット経路の選び方

| 利用シーン | 推奨 | 理由 |
|---|---|---|
| Remote Control中・放置運用 | **auto compactに任せる** | 会話ログが維持され、ユーザー操作ゼロで作業が続く。要約による精度低下は注入される引き継ぎ資料が補う |
| トークン消費を節約したい | `/clear` → 「続き」と一言 | `/compact`（auto含む）は会話全体を送って要約を生成する大きなAPIリクエストで課金/usage limitを消費するが、`/clear` は何も消費しない |

`/clear` の注意点（実運用で確認済み。既知の限界9参照）: 会話ログは新しい空のセッションに
切り替わり（Remote Controlの画面から旧セッションのログは見えなくなります）、注入された資料は
次のユーザー入力まで読まれないため、「続き」など一言送るまで作業は自動再開されません。

## アーキテクチャ（3層）

| 層 | フック | 役割 |
|---|---|---|
| 層1: 決定論的バックアップ | PreCompact / SessionStart | transcript全文+git状態を保存し、機械的合成文を再注入（LLM非依存・常時有効） |
| 層2: 圧縮失敗の予防 | （設定） | `/autocompact` で余裕を持った発火点を設定 |
| 層3: 閾値トリガー | Stop | usage実測→2段階閾値でhandoff作成を指示、完了検証+リトライ、検証済みポインタ更新 |

再注入される資料は完了検証（必須7セクション+完了マーカー+SHA-256照合）を通ったものだけです。
検証に失敗した資料は内容を注入せず、警告とバックアップへの導線のみ注入します。

## インストール

**Windows（プラグイン・推奨）** — ローカルの対話セッションで:

```
/plugin marketplace add Taichis-K/claude-remote-handoff
/plugin install claude-remote-handoff@claude-remote-handoff
```

**macOS/Linux または手動導入** — [INSTALL.md](INSTALL.md) 参照
（pwsh版とsh版〔要jq〕があります）。

⚠️ **プラグイン経路はWindows専用です**。macOS/Linuxで `/plugin install` してもフックは
動作しません（powershell.exe前提のため**静かに失敗**します）。必ずINSTALL.mdの手動導入を
使ってください。

インストール後に必須の設定（詳細はINSTALL.md）:

1. `setup/setup.ps1`（または `setup.sh`）で**閾値ペアを設定** — 未設定の場合、本ツールは何もしません。
   setupスクリプトは**人がターミナルで実行**してください（Claude Codeに実行させると
   ブロックされることがあります。その場合はINSTALL.mdの「スクリプトを使わない手順」へ）

   ```powershell
   # Windows（名前付きパラメータ。既定: window 160000 / soft 120000 / hard 135000）
   powershell -NoProfile -ExecutionPolicy Bypass -File setup\setup.ps1 `
     -AutocompactWindow 500000 -SoftThreshold 400000 -HardThreshold 440000
   ```
   ```sh
   # macOS/Linux（位置引数: window soft hard [margin] [pct]）
   sh setup/setup.sh 500000 400000 440000
   ```

   ⚠️ window値は**モデルの公称ウィンドウではなく `/context` が表示する総量**に合わせて
   ください（例: 1Mコンテキストモデルでも表示が `xxx k / 500k` なら 500000。
   公称値を入れると閾値到達前にauto compactが走り、実質無効になります）
2. セッションで `/autocompact <window値>`（setupに渡した値と同じ値）
3. 権限ルール `Edit(.claude-handoff/**)` の追加（**実質必須**: 無いとhandoff作成のたびに
   許可プロンプトで中断します）

setupは `.gitignore` へマシン/環境固有の4エントリ（`.claude-handoff/`・
`.claude/handoff-config.json`・`.claude/hooks/claude-remote-handoff/`・
`.claude/settings.local.json*`）を追記します。
特に `.claude/handoff-config.json` は**コミットしないでください**: 閾値は実効コンテキスト
総量（`/context` の表示。モデル・環境で異なる）とマシンの設定に依存するため、チームで
共有すると総量の異なる環境で「発火しない/早すぎる」原因になります
（各マシンでsetupを実行するのが正です）。

## 既知の限界

1. **Stopフックは応答完了時にしか発火しない**: 1ターン中に大量のファイル読取り等で
   ソフト閾値からautocompact発火点まで一気に超えると、引き継ぎ資料を作る前に
   auto compactが走ることがあります。この場合も層1（決定論的バックアップ）は機能します
2. **usage実測は遅れ得る**: transcriptは非同期書き込みのため、フック発火時点の
   最新ターンを含まない可能性があります（マージンで軽減していますが排除はできません）
3. **引き継ぎ資料作成の成功は保証されない**: 権限拒否・APIエラー等で失敗し得ます。
   完了検証付きの有限リトライで軽減し、打ち切り時はユーザーへ通知します
4. **閾値到達からcompactまでの差分は意味的handoffに反映されない**: 資料は閾値時点の
   スナップショットで、以降の進捗はgit状態・直近メッセージの機械的情報でのみ補完されます
5. **autocompact値と閾値の整合検証は申告値ベース**: 発火のたびに、有効な環境変数
   （`CLAUDE_CODE_AUTO_COMPACT_WINDOW` / `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`。
   全体が1〜10桁のASCII数字のみ有効）、無ければ必須の `autocompact_window` 設定値で
   `ハード閾値+マージン < floor(window×発火%÷100)` を検証し、満たさない場合は機能を
   無効化します（error.logに記録）。ただし検証に使うwindow値は「ユーザーの申告」であり、
   実際のClaude Code設定との一致やcompactの実発火時機までは保証できません
6. **保存データに秘密情報が含まれ得ます**: `.claude-handoff/` にはtranscriptと
   git diffが保存されます。setupが `.gitignore` へ追記しますが、クラウド同期・
   共有マシン経由の露出は防げません。保持は既定で30日・500MBまでで自動削除されます
   （**バックアップ世代だけでなく引き継ぎ資料本体〔current.md〕も削除対象**です。
   ただしポインタは7日で失効するため、注入経路への影響はありません）。
   手動で消す場合は `.claude-handoff/` ディレクトリを削除してください
   （秘密情報のマスキング機能はありません）
7. **バックアップの保存はbest-effort**: transcriptが200MBを超える場合・ディスク空き容量が
   不足する場合はコピーを見送ります（meta.jsonに記録）。また `.claude-handoff/` 配下に
   git trackedなファイルがある場合、保存機能全体が無効化されます（error.logに記録）
8. **未検証の範囲**: Remote Control実機（モバイル/Webからの操作）での通し動作は
   未実測です（同一フックが発火するため低リスクと判断しています）。
   auto compact実発火→再注入の通し動作は、独立した実地報告2件（Windows/pwsh・macOS/sh、
   いずれも1Mコンテキスト）で確認済みです
9. **`/clear` 経路のUX制約**: `/clear` はsession_idごと新規セッションになるため、
   Remote Controlの画面では会話ログが空のセッションに切り替わります（旧セッションの
   ログはその画面からは見えません）。また注入された引き継ぎ資料は次のユーザー入力まで
   読まれないため、自動では作業が再開されません（「続き」など一言送る必要があります）
10. **複数セッション同時利用時の挙動**: ポインタ（latest.json）はプロジェクト単位で
    1つのため、同一プロジェクトで複数セッションを並行させると、`/clear` 後に
    **別セッションが作成した資料**が注入されることがあります。この場合、注入文の冒頭に
    「※ この資料は別セッション（uuid）で作成されたものです」と明示されるので、
    内容が現在の作業と一致するか確認してから使ってください
11. **特殊なプロファイル構成では機能が無効になります**: 安全のため、セッション状態
    ファイルの作成・削除はClaude Codeのプロジェクトディレクトリ
    （`CLAUDE_CONFIG_DIR`、無ければ `(USERPROFILE|HOME)/.claude`、配下の `projects/`）
    の中に限定しています。UNCネットワークパスのプロファイル・途中にシンボリックリンクや
    ジャンクションを含む構成・`CLAUDE_CONFIG_DIR` とtranscriptのパスで大小文字表記が
    食い違う構成・派生パスがUTF-8で240バイトを超える場合は、
    層3（閾値トリガー）が無効になります（error.logに記録。層1のバックアップは動作します）

## 動作要件

- Claude Code **v2.1.163以上**
- Windows: 追加インストール不要（標準のPowerShell 5.1で動作） /
  macOS・Linux: PowerShell 7 または sh+**jq**

## アンインストール

プラグイン導入なら `/plugin uninstall claude-remote-handoff`。手動導入なら
`.claude/settings.local.json`（旧手順で導入した場合は `.claude/settings.json`）から
該当フックエントリを除去。いずれも
`.claude-handoff/`（保存データ）と `.claude/handoff-config.json`（設定）は
残るため、不要なら削除してください。

## License

MIT

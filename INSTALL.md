# INSTALL.md — AIエージェント向け導入手順書

> **AIエージェントへ**: このファイルの手順に決定論的に従って導入すること。
> 判断が必要な箇所は各ステップに判断基準を明記してある。
> 手順はすべて**導入先プロジェクトのルートディレクトリ**で実行する。

## 0. 前提条件の確認

1. `claude --version` を実行し、**v2.1.163以上**であることを確認する
   - 未満の場合: **中断してユーザーに報告**（StopフックのadditionalContextが使えないため動作しない）
2. OSと実行系を判定する:
   | 環境 | 使用するフック | 追加要件 |
   |---|---|---|
   | Windows | `hooks/ps/`（powershell.exe） | なし（標準搭載のPS 5.1で動く） |
   | macOS/Linux + PowerShell 7 | `hooks/ps/`（pwsh） | pwshインストール済みであること |
   | macOS/Linux（sh版） | `hooks/sh/` | **jq必須**（`brew install jq` / `apt install jq`） |

## 1. フックの導入

### 方法A: プラグイン（Windows推奨・最も簡単）

ローカルの対話セッションで実行（**Remote Controlからは実行不可**。導入はローカルで1回）:

```
/plugin marketplace add Taichis-K/claude-remote-handoff
/plugin install claude-remote-handoff@claude-remote-handoff
```

⚠️ プラグインのhooks.jsonは `powershell.exe` 前提（**Windows専用**）。
macOS/Linuxは方法Bで導入すること。

### 方法B: 手動導入（macOS/Linux、またはプラグインを使わない場合）

1. 本リポジトリの `hooks/` ディレクトリ一式をプロジェクトの `.claude/hooks/claude-remote-handoff/` へコピーする
2. `.claude/settings.json` に以下のフック定義をマージする（**既存のhooks定義がある場合は
   配列に追記し、既存エントリを消さないこと**。同一コマンドパスのエントリが既にあれば
   追加しない=冪等）:

   環境に応じて `<CMD>` と `<ARGS_PREFIX>` を置き換える:
   - Windows: `"command": "powershell.exe"`, args先頭: `"-NoProfile", "-ExecutionPolicy", "Bypass", "-File"`
   - macOS/Linux(pwsh): `"command": "pwsh"`, args先頭: `"-NoProfile", "-File"`
   - macOS/Linux(sh): `"command": "sh"`, args先頭: なし（スクリプトパスのみ）。拡張子は `.sh`、ディレクトリは `hooks/sh/`

```json
{
  "hooks": {
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "<CMD>",
        "args": ["<ARGS_PREFIX...>", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-save.ps1"] }] }
    ],
    "SessionStart": [
      { "matcher": "compact",
        "hooks": [{ "type": "command", "command": "<CMD>",
          "args": ["<ARGS_PREFIX...>", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "clear",
        "hooks": [{ "type": "command", "command": "<CMD>",
          "args": ["<ARGS_PREFIX...>", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "resume",
        "hooks": [{ "type": "command", "command": "<CMD>",
          "args": ["<ARGS_PREFIX...>", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-reset.ps1"] }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "<CMD>",
        "args": ["<ARGS_PREFIX...>", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-check.ps1"] }] }
    ]
  }
}
```

3. マージ前に `.claude/settings.json` のバックアップ（`.claude/settings.json.bak`）を作ること。
   マージ後にJSONとして妥当か検証し、壊れていたらバックアップを戻して中断すること

## 2. セットアップスクリプトの実行（閾値ペア設定・必須）

**この手順を省くとツールは動かない**（閾値の明示設定が無い場合、Stopフックは何もしない設計）。

setupスクリプトの入手: **プラグイン導入では対象プロジェクトにsetupは配置されない**ため、
本リポジトリを任意の場所へcloneして（または最新Releaseのzipを展開して）そこから実行する:

```
git clone https://github.com/Taichis-K/claude-remote-handoff.git <任意の作業場所>
```

対象プロジェクトを指定して実行（`<kit>` = 上でcloneした場所）:

```
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\setup\setup.ps1 -ProjectDir <対象プロジェクトのルート>

# macOS/Linux（第6引数が対象プロジェクト。1-5引数は window/soft/hard/margin/pct）
sh <kit>/setup/setup.sh 160000 120000 135000 10000 92 <対象プロジェクトのルート>
```

- 既定値: autocompact window 160000 / ソフト閾値 120000 / ハード閾値 135000（200Kモデル向け）
- 1Mコンテキストモデルを使う場合の例: `setup.ps1 -AutocompactWindow 500000 -SoftThreshold 400000 -HardThreshold 450000`
- 静的検証NG（exit 1）の場合は**設定は書き込まれない**。表示された指示に従い値を調整すること
- スクリプトは `.gitignore` への `.claude-handoff/` 追記も行う（git未導入時はスキップ）

## 3. Claude Code側の設定

1. **autocompact値**: セッション内で `/autocompact 160000`（setupに渡したwindow値と同じ値）
   - Remote Control中のモバイル/Webからも設定可（v2.1.221以降）
2. **書き込み許可ルール**（推奨。無いと引き継ぎ資料作成のたびに許可プロンプトが出る）:
   `.claude/settings.json` の permissions に以下をマージ:
   ```json
   { "permissions": { "allow": ["Edit(.claude-handoff/**)"] } }
   ```
   - ⚠️ ルール名は `Edit(...)` であること（`Write(...)` はファイル権限チェックに使われない）
3. **workspace trust**: このプロジェクトで一度Claude Codeを**対話起動**してtrustダイアログを
   承認すること（未trustのワークスペースではプロジェクトsettings.jsonの許可ルールが無視される）

## 4. 動作検証チェックリスト

1. `.claude/handoff-config.json` が存在する
2. `.gitignore` に `.claude-handoff/` がある（gitプロジェクトの場合）
3. フック動作確認（低閾値で一時テスト）:
   - `.claude/handoff-config.json` を一時的に次の内容へ**丸ごと置き換える**（完全なJSONで書くこと）:
     ```json
     {"autocompact_window":160000,"soft_threshold":1000,"hard_threshold":2000,"min_margin":10000,"conservative_fire_pct":92}
     ```
   - 対話セッションで何か1ターン会話する → 応答完了時に引き継ぎ資料の作成が始まれば層3は動作している
   - `.claude-handoff/<session_id>/current.md` と `.claude-handoff/latest.json` が作られることを確認
   - `/clear` を実行 → 次の発言で引き継ぎ内容をClaudeが把握していれば層1は動作している
   - **確認後、setupを再実行して閾値を必ず本来の値に戻す**
4. エラーが疑われる場合は `.claude-handoff/error.log` を確認する

## 注意事項

- `/plugin` はRemote Controlからはローカル限定。**導入はローカルで1回、恩恵はRC中に**
- 保存されるデータ（transcript全文・git diff）には秘密情報が含まれ得る。
  `.claude-handoff/` をコミット・同期対象にしないこと（README「既知の限界」参照）
- アンインストール: プラグインは `/plugin uninstall`。手動導入は settings.json から
  該当エントリを除去し、`.claude/hooks/claude-remote-handoff/` と `.claude-handoff/` を削除

# INSTALL.md — AIエージェント向け導入手順書

> **AIエージェントへ**: このファイルの手順に決定論的に従って導入すること。
> 判断が必要な箇所は各ステップに判断基準を明記してある。
> 手順はすべて**導入先プロジェクトのルートディレクトリ**で実行する。
>
> ⚠️ settings（特にhooks）への書き込みは、任意コマンドの自動実行を設定する行為のため
> **権限承認でブロックされることがある**。拒否されたら回避策を探さず、
> マージ後のJSONを提示してユーザーに適用を委ねること。

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
   - このディレクトリは**コミットしないこと**（OSごとにps/shを選ぶマシン固有物。
     後述のsetupが `.gitignore` へ追記する）
2. `.claude/settings.local.json`（個人用・コミット非対象の設定ファイル）に以下のフック定義を
   マージする（**既存のhooks定義がある場合は配列に追記し、既存エントリを消さないこと**。
   同一コマンドパスのエントリが既にあれば追加しない=冪等）:
   - ⚠️ コミットされる `.claude/settings.json` には入れないこと: フック本体（手順1）は
     gitignoreされるため、settings.jsonに登録するとリポジトリを共有した他のマシンで
     「存在しないスクリプトを指すフック」となり毎ターンエラーになる

   環境に合う**完成形スニペット**を1つ選んでそのままマージする（置換不要）:

   **Windows（powershell.exe / PS 5.1）**:

```json
{
  "hooks": {
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "powershell.exe",
        "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-save.ps1"] }] }
    ],
    "SessionStart": [
      { "matcher": "compact",
        "hooks": [{ "type": "command", "command": "powershell.exe",
          "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "clear",
        "hooks": [{ "type": "command", "command": "powershell.exe",
          "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "resume",
        "hooks": [{ "type": "command", "command": "powershell.exe",
          "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-reset.ps1"] }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "powershell.exe",
        "args": ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-check.ps1"] }] }
    ]
  }
}
```

   **macOS/Linux（pwsh = PowerShell 7）**:

```json
{
  "hooks": {
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "pwsh",
        "args": ["-NoProfile", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-save.ps1"] }] }
    ],
    "SessionStart": [
      { "matcher": "compact",
        "hooks": [{ "type": "command", "command": "pwsh",
          "args": ["-NoProfile", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "clear",
        "hooks": [{ "type": "command", "command": "pwsh",
          "args": ["-NoProfile", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "resume",
        "hooks": [{ "type": "command", "command": "pwsh",
          "args": ["-NoProfile", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-reset.ps1"] }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "pwsh",
        "args": ["-NoProfile", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-check.ps1"] }] }
    ]
  }
}
```

   **macOS/Linux（sh + jq）**:

```json
{
  "hooks": {
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "sh",
        "args": ["${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/sh/handoff-save.sh"] }] }
    ],
    "SessionStart": [
      { "matcher": "compact",
        "hooks": [{ "type": "command", "command": "sh",
          "args": ["${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/sh/handoff-restore.sh"] }] },
      { "matcher": "clear",
        "hooks": [{ "type": "command", "command": "sh",
          "args": ["${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/sh/handoff-restore.sh"] }] },
      { "matcher": "resume",
        "hooks": [{ "type": "command", "command": "sh",
          "args": ["${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/sh/handoff-reset.sh"] }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "sh",
        "args": ["${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/sh/handoff-check.sh"] }] }
    ]
  }
}
```

3. マージ前に `.claude/settings.local.json` のバックアップ（`.claude/settings.local.json.bak`）を
   作ること（新規作成の場合は不要）。マージ後にJSONとして妥当か検証し、壊れていたら
   バックアップを戻して中断すること。`.bak` はコミットせず（setupの `.gitignore` 追記が
   `settings.local.json*` として両方カバーする）、確認後は削除してよい

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
- 1Mコンテキストモデルを使う場合の例（どちらも静的検証を通る組み合わせ）:
  - `setup.ps1 -AutocompactWindow 500000 -SoftThreshold 400000 -HardThreshold 440000`
    （window=500000・既定margin/pctのままなら hard の上限は 449999）
  - `sh setup.sh 800000 600000 700000`（window 800000 の例）
- 静的検証NG（exit 1）の場合は**設定は書き込まれない**。表示された指示（最大許容ハード閾値を含む）に従い値を調整すること
- スクリプトは `.gitignore` への追記も行う（git未導入時はスキップ）。追記されるのは
  マシン/環境固有の4エントリ: `.claude-handoff/`（保存データ）・
  `.claude/handoff-config.json`（閾値はモデルの窓200K/1Mとマシンの設定に依存）・
  `.claude/hooks/claude-remote-handoff/`（手動導入のフック本体）・
  `.claude/settings.local.json*`（手動導入のフック登録先。`.bak` も含む）。
  既にtrackedなファイルがあれば警告が出るので `git rm --cached` で整理すること

## 3. Claude Code側の設定

1. **autocompact値**: セッション内で `/autocompact 160000`（setupに渡したwindow値と同じ値）
   - Remote Control中のモバイル/Webからも設定可（v2.1.221以降）
2. **書き込み許可ルール**（**実質必須**。無いとStopのたびに書き込み許可プロンプトが出て
   資料作成が中断する — Remote Control中は特に致命的）:
   `.claude/settings.json` の permissions に以下をマージ:
   ```json
   { "permissions": { "allow": ["Edit(.claude-handoff/**)"] } }
   ```
   - ⚠️ ルール名は `Edit(...)` であること（`Write(...)` はファイル権限チェックに使われない）
   - このルールはマシン固有ではないためコミットして共有してよい。コミットしたくない場合は
     `.claude/settings.local.json` の permissions でも同様に機能する
3. **workspace trust**: このプロジェクトで一度Claude Codeを**対話起動**してtrustダイアログを
   承認すること（未trustのワークスペースではプロジェクトsettings.jsonの許可ルールが無視される）
4. **フック登録の反映確認**: `/hooks` で5エントリ（PreCompact / SessionStart×3 / Stop）が
   見えるか確認し、**見えなければClaude Codeを再起動**すること。設定の反映タイミングは
   経路・バージョンで異なる実測があり（settings.local.json経由は実行中セッションでも
   有効化された例、プラグイン経由は再起動まで有効化されなかった例の両方）、
   閾値未満のときフックは痕跡を残さないため「効いていない」ことに気づけない

## 4. 動作検証チェックリスト

1. `.claude/handoff-config.json` が存在する
2. `.gitignore` に4エントリ（`.claude-handoff/`・`.claude/handoff-config.json`・
   `.claude/hooks/claude-remote-handoff/`・`.claude/settings.local.json*`）がある
   （gitプロジェクトの場合）
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
- **混在OS（Windows/macOS等）で共有するリポジトリでは**: フック登録は必ず
  `.claude/settings.local.json`（本手順の標準）に置き、閾値設定
  （`.claude/handoff-config.json`）とフック本体（`.claude/hooks/claude-remote-handoff/`）は
  **各マシン持ち**にすること（setupが `.gitignore` へ追記する）。共有ファイルに片方のOSの
  フック定義をコミットすると、他方のOSのセッションが存在しないコマンド/スクリプトを叩いて壊れる
- 保存されるデータ（transcript全文・git diff）には秘密情報が含まれ得る。
  `.claude-handoff/` をコミット・同期対象にしないこと（README「既知の限界」参照）
- アンインストール: プラグインは `/plugin uninstall`。手動導入は settings.local.json
  （旧手順で settings.json に登録した場合はそちら）から該当エントリを除去し、
  `.claude/hooks/claude-remote-handoff/` と `.claude-handoff/` を削除

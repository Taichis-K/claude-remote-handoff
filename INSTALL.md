# INSTALL.md — AIエージェント向け導入手順書

> **AIエージェントへ**: このファイルの手順に決定論的に従って導入すること。
> 判断が必要な箇所は各ステップに判断基準を明記してある。
> 手順はすべて**導入先プロジェクトのルートディレクトリ**で実行する。
>
> ⚠️ settings（特にhooks）への書き込みは、任意コマンドの自動実行を設定する行為のため
> **権限承認でブロックされることがある**。拒否されたら回避策を探さず、
> マージ後のJSONを提示してユーザーに適用を委ねること。
> **経路を変えて再試行しないこと**（編集ツール → シェル → 一時ファイルと `cp`、のように
> 変えても拒否は同じ判断であり、迂回にあたる。実測報告では、経路を変えても拒否され、
> 3回試して3回とも止まった）。これは書式の誤りやI/Oエラーのような通常の失敗とは別物で、
> 内容を変えて通そうとする意味は無い。
>
> ⚠️ **setupスクリプトの実行も安全分類器にブロックされることがある**（外部から取得した
> スクリプトの実行と判定される — 実測報告あり）。ブロックされたら回避策を探さず、
> §2の「スクリプトを使わない手順」（ファイル編集のみ）で置き換えること。

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

### 方法0: `/handoff-init` コマンド（OS共通・推奨）

**この手順書を読んでいるAIエージェントへ**: 利用者から「このリポジトリを見て導入して」と
言われた場合、まずこの方法0を採ること。やることは
**`commands/handoff-init.md` を利用者のユーザーレベル（`~/.claude/commands/`）へコピーする**
だけである（マシンごとに1回）。
⚠️ **環境変数 `CLAUDE_CONFIG_DIR` が設定されていれば、コピー先は `$CLAUDE_CONFIG_DIR/commands/`**
である。Claude Code の設定ディレクトリはこの変数で移設でき、移設すると `~/.claude` は使われない。
確かめずに `~/.claude/commands/` へ置くと、**ファイルは作られるのにコマンドが一覧に出ない**。フックの配置・登録・閾値設定・`.gitignore`・許可ルールは、
以後 `/handoff-init` が各プロジェクトで行う。**この節より下の方法A・方法B・§2 は、
`/handoff-init` を使わない場合の手順**である。

**ただし §3 のうち 3-1（`/autocompact`）・3-3（workspace trust の承認）・
3-4（`/hooks` で5エントリを確認し、見えなければ再起動）は、`/handoff-init` を使っても必要**である。
いずれも人の操作が要り、コマンドは案内するだけなので、「§3 も不要」と説明しないこと。
とくに 3-4 を飛ばすと、登録は書かれたのに実行中のセッションへ反映されず、
**閾値未満ではフックが痕跡を残さないので誰も気づけない**。

コピーするときは次を守ること。

- **可動する枝ではなく、最新のリリースタグから取る**
  （`git ls-remote --tags` でタグを調べ、
  `git -c core.autocrlf=false clone --depth 1 --branch <タグ>`）。
  このファイルは以後AIが従う手順書になるため、取得元が差し替わると影響が大きい。
  **`-c core.autocrlf=false` は外さないこと**（本リポジトリには `.gitattributes` があるので
  通常はこれ無しでもLFのままだが、**それ以前のタグを取るときは守られない**。
  詳細は §2 の同じ注意書き）。
  タグは `v<数>.<数>.<数>` 形式で、**数値ごとに比較する**
  （文字列順では `v0.1.10` が `v0.1.9` より前になる）
- 置く前に、**タグ・commit SHA・`hooks/VERSION` を利用者に提示して確認を取る**。
  タグと `VERSION` の突き合わせは、**タグ先頭の `v` を1つ取り除いた文字列**と
  **`VERSION` の中身から前後の空白・改行を除いた文字列**が一致すればよい
  （`v0.1.5` と `0.1.5` は一致）
- **これは真正性の検証ではない**。タグ固定が防ぐのは「可動する枝が知らないうちに
  差し替わる」事故だけで、配布元アカウントが侵害されていればタグ・SHA・`VERSION` は
  すべて攻撃者が作れる。利用者に尋ねるのは「**この配布元を信頼して、フックとして
  自動実行させてよいか**」であり、「検証しました」と説明しないこと
- 既に `~/.claude/commands/handoff-init.md` がある場合は、黙って上書きせず、
  **既存の内容と取得したものを比較して差分を示してから**置き換える
  （このファイル自体に版番号は入っていないので、内容比較で判断する）
- **置く前に、コピー先が安全かを確かめる**。`~/.claude/commands/handoff-init.md` と
  そこへ至るディレクトリの **symlink / junction / reparse point を解決した実体パス**を求め、
  それが `~/.claude/` の外を指しているなら、**実体パスを見せて書いてよいか確認する**
  （dotfiles 管理で `~/.claude/commands` を repo へ張っているのは正常な構成なので、
  symlink があること自体では止めない。止めたいのは `~/.ssh/config` のような
  無関係なファイルを上書きする場合である）。**承認が無いまま書かない**

コピー後、利用者に「導入したいプロジェクトで `/handoff-init` を実行してください」と伝える。
フックの更新も同じコマンドで、配布元の最新リリースと版を比べて差があれば入れ替える
（プラグインで導入済みの場合だけは例外で、フックの更新は `claude plugin update` の担当。
コマンドは版を比べてその旨を案内する）。

コマンドは**配布物を取得する経路では**、**配布元の `commands/handoff-init.md` と自分自身を
内容比較し、違えば置き換えてよいかを尋ねる**。手順の契約が変わるリリースで
「フックだけ新しく、手順は古い」という混在にならないようにするため
（フックに触れず設定だけ書く経路では配布物を取得しないので、この比較は行われない。
その場合はコマンドがその旨を報告する）。

**呼び出し名に注意**: `~/.claude/commands/` に置いた場合は `/handoff-init`。
プラグイン経由で入っている場合は名前空間が付き
`/claude-remote-handoff:handoff-init` になる。

### 方法A: プラグイン（Windows・フックを全プロジェクト一括更新したい場合）

ローカルの対話セッションで実行（**Remote Controlからは実行不可**。導入はローカルで1回）:

```
/plugin marketplace add Taichis-K/claude-remote-handoff
/plugin install claude-remote-handoff@claude-remote-handoff
```

⚠️ プラグインのhooks.jsonは `powershell.exe` 前提（**Windows専用**）。
macOS/Linuxは方法Bで導入すること。

### 方法B: 手動導入（macOS/Linux、またはプラグインを使わない場合）

手動導入の全体像（この順に実施。各ステップの詳細は該当節を参照）:

1. `hooks/ps`（または `hooks/sh`）を `.claude/hooks/claude-remote-handoff/` へコピー（本節の手順1）
2. フック定義JSONを `.claude/settings.local.json` へマージ（本節の手順2）
3. setupスクリプトを実行 — **やるのは設定生成と `.gitignore` 追記だけ**で、
   フックのコピーや登録は行わない（§2）
4. permissions.allow に `Edit(.claude-handoff/**)` を追加（§3-2）
5. `/autocompact <window値>` を実行し、`/hooks` で5エントリを確認（§3-1, §3-4）

手順:

1. 本リポジトリの `hooks/` ディレクトリ一式をプロジェクトの `.claude/hooks/claude-remote-handoff/` へコピーする
   - このディレクトリは**コミットしないこと**（OSごとにps/shを選ぶマシン固有物。
     後述のsetupが `.gitignore` へ追記する）
   - `hooks/VERSION`（導入したバージョンの記録）も**必ず一緒にコピーすること**。
     後から「入っているのがどの版か」を判別する唯一の手段になる（§5）
2. `.claude/settings.local.json`（個人用・コミット非対象の設定ファイル）に以下のフック定義を
   マージする（**既存のhooks定義がある場合は配列に追記し、既存エントリを消さないこと**。
   **(イベント名, matcher, type, command, args) の5つがすべて一致**するエントリが既にあれば
   追加しない=冪等。**コマンドパスだけで判定しないこと** — SessionStartの `compact` と `clear` は
   どちらも同じ `handoff-restore` を指すため、パスだけで見ると片方が登録されず
   `/clear` 後の復元が動かなくなる。**`type` も落とさないこと** — `"type"` が違うエントリを
   「ある」と誤判定すると、発火しないまま導入済みに見える）:
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
        "args": ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-save.ps1"] }] }
    ],
    "SessionStart": [
      { "matcher": "compact",
        "hooks": [{ "type": "command", "command": "powershell.exe",
          "args": ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "clear",
        "hooks": [{ "type": "command", "command": "powershell.exe",
          "args": ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-restore.ps1"] }] },
      { "matcher": "resume",
        "hooks": [{ "type": "command", "command": "powershell.exe",
          "args": ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-reset.ps1"] }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "powershell.exe",
        "args": ["-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", "${CLAUDE_PROJECT_DIR}/.claude/hooks/claude-remote-handoff/ps/handoff-check.ps1"] }] }
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

3. マージ前に `.claude/settings.local.json` のバックアップを作ること（新規作成の場合は不要）。
   **固定名 `.bak` ではなく `.claude/settings.local.json.bak-<年月日時分秒>` のように
   衝突しない名前にする**（固定名だと、前回の中断で残った退避を壊すか、
   壊さないよう避けた結果「戻す先が今回の退避ではない」事故になり、
   **古い内容へ巻き戻して現在の `permissions.deny` を失う**）。
   マージ後にJSONとして妥当か検証し、壊れていたら**今回作った退避を**戻して中断すること。
   退避はコミットせず（setupの `.gitignore` 追記が `settings.local.json*` として
   両方カバーする）、確認後は削除してよい

## 2. セットアップスクリプトの実行（閾値ペア設定・必須）

**この手順を省くとツールは動かない**（閾値の明示設定が無い場合、Stopフックは何もしない設計）。

このスクリプトが行うのは次の3つ**だけ**（フックのコピーや settings への登録は行わない — それは§1）:
(1) `claude --version` の最低要件確認 (2) 閾値の静的検証 → `.claude/handoff-config.json` 書き込み
(3) `.gitignore` へのマシン固有4エントリ追記。

⚠️ **setupスクリプトは人がターミナルで実行すること**。Claude Codeに実行させると
「外部から取得したスクリプトの実行」として安全分類器にブロックされることがある（実測報告あり）。
Claude Codeに導入まで任せる場合は、後述の「**スクリプトを使わない手順**」をファイル編集として
行わせること。

**閾値の決め方**: `autocompact_window` には**モデルの公称ウィンドウではなく、Claude Codeの
`/context` が表示する総量**を入れること（例: Opus 5の1Mコンテキストモデルでも `/context` の
表示は `xxx k / 500k` — この場合は 500000）。公称値（1000000等）を入れると発火点の計算が
実際の2倍になり、閾値に到達する前にauto compactが走ってツールが実質無効化される。
`/autocompact` に設定する値も同じ値にする。

setupスクリプトの入手: **プラグイン導入では対象プロジェクトにsetupは配置されない**ため、
本リポジトリを任意の場所へcloneして（または最新Releaseのzipを展開して）そこから実行する:

```
git -c core.autocrlf=false clone https://github.com/Taichis-K/claude-remote-handoff.git <任意の作業場所>
```

⚠️ **`-c core.autocrlf=false` を外さないこと。** 本リポジトリのルートには `.gitattributes`
（`* text eol=lf`）があるので通常はこれ無しでもLFのままだが、**それが入る前のタグを取ると
守られない**。その場合、作業ツリーの改行は**cloneする人の `core.autocrlf` 次第**になり、
`true`（Windowsの既定インストール等）だと `.sh` がCRLFでチェックアウトされ、
macOS/Linuxで `$'\r': command not found` になって動かない
（v0.1.0〜v0.1.3のRelease zipが実際にこれで壊れていた）。この指定はコマンド1回きりで、
利用者のgit設定は変えない。**最新Releaseのzipを展開する場合はこの問題は起きない**
（zipはLFで固めてある）。

対象プロジェクトを指定して実行（`<kit>` = 上でcloneした場所）:

```
# Windows
powershell -NoProfile -ExecutionPolicy Bypass -File <kit>\setup\setup.ps1 -ProjectDir <対象プロジェクトのルート>

# macOS/Linux（第6引数が対象プロジェクト。1-5引数は window/soft/hard/margin/pct）
sh <kit>/setup/setup.sh 160000 120000 135000 10000 92 <対象プロジェクトのルート>
```

- 既定値: autocompact window 160000 / ソフト閾値 120000 / ハード閾値 135000
  （`/context` の総量表示が 200000 の環境向け）
- `/context` の総量表示が 500000 の環境（1Mコンテキストモデルの実測例）の設定例
  （静的検証を通る組み合わせ。sh版は同じ値を位置引数で渡す）:
  - `setup.ps1 -AutocompactWindow 500000 -SoftThreshold 400000 -HardThreshold 440000`
    （window=500000・既定margin/pctのままなら hard の上限は 449999）
  - `sh setup.sh 500000 400000 440000`
- 静的検証NG（exit 1）の場合は**設定は書き込まれない**。表示された指示（最大許容ハード閾値を含む）に従い値を調整すること
- スクリプトは `.gitignore` への追記も行う（git未導入時はスキップ）。追記されるのは
  マシン/環境固有の4エントリ: `.claude-handoff/`（保存データ）・
  `.claude/handoff-config.json`（閾値は `/context` の総量表示とマシンの設定に依存）・
  `.claude/hooks/claude-remote-handoff/`（手動導入のフック本体）・
  `.claude/settings.local.json*`（手動導入のフック登録先。`.bak` も含む）。
  既にtrackedなファイルがあれば警告が出るので `git rm --cached` で整理すること

### スクリプトを使わない手順（Claude Codeに導入させる場合はこちら）

setupスクリプトの3操作は次のファイル編集で置き換えられる:

1. `claude --version` が v2.1.163以上であることを確認する
2. `.claude/handoff-config.json` を次の内容で作成する（値は上記「閾値の決め方」に従う。
   すべてJSONの整数で書くこと）:
   ```json
   {"autocompact_window":160000,"soft_threshold":120000,"hard_threshold":135000,"min_margin":10000,"conservative_fire_pct":92}
   ```
   制約（フックの実行時検証と同一。満たさない設定は**全体が無効化される**）:
   - `1 <= soft_threshold <= hard_threshold <= 1,000,000,000`
   - `1 <= autocompact_window <= 1,000,000,000`（**必須** — v0.1.3から。無いか不正な場合は
     機能全体が無効化され、error.logにStopごとに記録される〔ログは256KB超過を検知した次回記録時に末尾500行へ自動trim〕）
   - `0 <= min_margin <= 1,000,000,000`
   - `1 <= conservative_fire_pct <= 100`
   - `hard_threshold + min_margin < floor(autocompact_window × conservative_fire_pct ÷ 100)`
     （発火点の計算は整数除算＝小数点以下切り捨て）
3. `.gitignore` に次の4行を追記する:
   ```
   .claude-handoff/
   .claude/handoff-config.json
   .claude/hooks/claude-remote-handoff/
   .claude/settings.local.json*
   ```
   既存行との重複判定は**対象の種類ごとに**行う（完全一致に加え、次の同値形があれば追記しない）:
   - ディレクトリ項目（`.claude-handoff/`・`.claude/hooks/claude-remote-handoff/`）:
     末尾 `/` なし・末尾 `/*` の行も同値
   - ファイル項目（`.claude/handoff-config.json`）: `*` 付き（`.claude/handoff-config.json*`）の
     行も同値（より広くカバーする）
   - `.claude/settings.local.json*`: `*` なしの行があれば追記はしないが、`*` 付きへ
     更新すると `.bak` もカバーされる（更新を推奨）
   - **末尾 `/` を付けた `.claude/settings.local.json/` 等はディレクトリ専用パターンで
     ファイルを無視しないため、同値とみなさない**（同値行が無い項目のみ、上記の正規形の行を追記する）

   追記対象がgit trackedになっていないかも確認する（trackedなら `git rm --cached` の実行を
   ユーザーに提案する）

## 3. Claude Code側の設定

1. **autocompact値**: セッション内で `/autocompact 160000`（setupに渡したwindow値と同じ値）
   - Remote Control中のモバイル/Webからも設定可（v2.1.221以降）
2. **書き込み許可ルール**（**実質必須**。無いとStopのたびに書き込み許可プロンプトが出て
   資料作成が中断する — Remote Control中は特に致命的）:
   permissions に以下をマージ。置き場所は**チームで共有するなら `.claude/settings.json`、
   共有しないなら `.claude/settings.local.json`**（どちらでも機能する。共有リポジトリで
   settings.json がgit管理下の場合、そちらに入れるとコミット差分が出る点に注意）:
   ```json
   { "permissions": { "allow": ["Edit(.claude-handoff/**)"] } }
   ```
   - ⚠️ ルール名は `Edit(...)` であること（`Write(...)` はファイル権限チェックに使われない）
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
     （Claudeが書くのは同じディレクトリの `draft.md` で、完了検証に通ると `current.md` に置き換わる）
   - `/clear` を実行 → 次の発言で引き継ぎ内容をClaudeが把握していれば層1は動作している
   - **確認後、setupを再実行して閾値を必ず本来の値に戻す**
4. エラーが疑われる場合は `.claude-handoff/error.log` を確認する

## 5. 導入済みバージョンの確認とアップグレード

上流で既に直っている不具合を手元で追い直す事故が実際に起きているため、
**動作を疑ったら最初にバージョンを確認すること**。手順は導入方法で異なる。

### 5-1. 導入済みバージョンの確認

**方法A（プラグイン）**: バージョンと**インストールscope**（`user` / `project` / `local` /
`managed`）が表示される。scopeは §5-2 の更新で必要になるので控えておくこと。

```
claude plugin list
claude plugin list --json   # scope・installPath まで確実に見たい場合
```

**方法B（手動導入）**: 導入先にコピーされた `VERSION` を読む。

```
cat .claude/hooks/claude-remote-handoff/VERSION
```

- `VERSION` が無い場合、**配布物を一式コピーしているなら v0.1.3 以前**
  （このファイルはv0.1.4で追加された）。`ps/`・`sh/` だけをコピーした不完全導入や、
  利用者が削除した場合もあり得るので、それ以上の特定はしない。いずれにせよ
  §5-2 のとおり一式で入れ直すこと
- 最新版とその変更内容: https://github.com/Taichis-K/claude-remote-handoff/releases
  （`CHANGELOG.md` に修正済みの不具合が症状ごと載っている。手元の症状が該当しないか先に見る）

### 5-2. アップグレード手順

**先に共通の確認**（版を飛ばして上げる場合は、間の各Releaseの「導入・更新」も読むこと）:

1. **未消費の引き継ぎ資料が残っていないか確認する**。旧バージョンが書いた
   `.claude-handoff/latest.json` は更新後に拒否されることがある（v0.1.3の変更）。
   残っているなら**更新前に消費する**（`/clear` して復元させる）こと。
   更新後は次のhandoff作成サイクルから復元が復帰する
2. `.claude-handoff/` は**削除しない**（過去の資料とバックアップが入っている）。
   フックの入れ替えでこのディレクトリに触れる必要はない

**方法A（プラグイン）**: **§5-1で控えたscopeを必ず `--scope` で指定する**。

```
claude plugin update claude-remote-handoff --scope <user|project|local|managed>
```

- ⚠️ `--scope` の既定値は `user`。**省略すると別scopeの導入は更新されない**
  （`local` / `project` で入れている場合に「更新したのに直らない」となる）。
  `local` / `project` の場合は**対象プロジェクトのルートで実行**すること
- **反映にはClaude Codeの再起動が必要**（`claude plugin update` の仕様）
- `hooks.json` はプラグイン側が持つため、`settings.local.json` の編集は不要
- 自動更新が有効な環境では、明示的に実行しなくても更新されることがある

**方法B（手動導入）**:

1. 最新Releaseのzipを展開する（または本リポジトリを `git pull` する）
2. `.claude/hooks/claude-remote-handoff/` を**新しい `hooks/` 一式で丸ごと置き換える**
   （差分適用はしない。ローカルで手を入れていた場合その改変は失われる — 必要なら退避しておく）
3. `.claude/settings.local.json` のフック定義を §1手順2 の最新スニペットと突き合わせ、
   コマンド・引数が変わっていれば差し替える（**v0.1.4でWindowsの `args` に
   `-WindowStyle Hidden` が入った** — 無くても機能は動作する。コンソールウィンドウの
   点滅対策）
4. `/hooks` で5エントリが見えるか確認し、見えなければClaude Codeを再起動する

**両方に共通の最終確認**:

- `.claude/handoff-config.json` に `autocompact_window` があるか確認する
  （**v0.1.3から必須**。無いか不正だと機能は黙って無効化され、
  `.claude-handoff/error.log` にだけ診断が残る）。無ければ §2 のsetupを再実行する
- 手書きconfigの場合、既知キー以外があると機能が無効になる（§2参照）

### 5-3. 複数プロジェクト・複数マシンに入れている場合

**手動導入（方法B）の場合**、フック本体は**プロジェクトごとの複製**で、`.gitignore` 対象の
ためgitでは配れない。1か所直しても他は古いまま残る。導入先を洗い出し、
**全数を同じ版へ揃えること**。

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

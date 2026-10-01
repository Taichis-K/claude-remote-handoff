#!/bin/sh
# handoff-common.sh - フック共通ヘルパー（各フックから . で読み込む。単体実行しない）
# 依存: jq（必須）。sha256sum または shasum、timeout があれば利用する（無くても縮退動作）
# PS版 handoff-common.ps1 と挙動一致必須（dist/tests で検証）
# 配布元: https://github.com/Taichis-K/claude-remote-handoff （導入済みバージョンは ../VERSION）

# jq不在の検出（issue #18: 以前は無言終了でerror.logにも残らなかった）。
# jq無しで書ける手段だけで記録する。$1=フック名。不在なら1を返す（呼び出し側はexit 0）
ho_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        ho_error "$CLAUDE_PROJECT_DIR/.claude-handoff" "$1" "jqが見つかりません。sh版フックはjq必須のため何もせず終了します（PATHとインストールを確認してください）"
    fi
    return 1
}

# stdin全体を ${HO_INPUT} へ読み込み、各フックが使うフィールドをまとめて取り出す。
# JSONとして不正・object以外なら1を返す（呼び出し側はexit 0）。
#
# 以前は「type=="object" の検証」と「フィールドごとの取得」で毎回jqを起こしていた
# （handoff-checkの最小経路で stdin を6回パースしていた。cwd は ho_handoff_root と
# ho_project_dir から2回）。Windowsではプロセス起動が1回70〜85ms、コマンド置換の
# fork がさらに約26msかかり、フック1回の実測時間に直接効く（2026-08-30の速度対策。
# handoff-config.json の7回パース解消と同じ趣旨）。
# 値は @sh でシェル引用してから eval するため、空白・引用符・グロブ文字・`$`・
# バッククォートを含む値も分割・展開・実行されずに元のまま渡る。
#
# 取得契約（フィールドごとにjqを起こしていた頃と同一）:
#   - 文字列フィールド（cwd / session_id / source / trigger）は文字列以外の型を空扱い
#     （PS版の -is [string] ガードと同一契約 — 罠8の型固定）。**NULとCRを含む値も空扱い**、
#     **LFは剥がさず生のまま持つ**（HANDOFF.mdバックログ12）。理由は下の「運べるもの」参照
#   - パスフィールド（transcript_path）は文字列型かつC0制御文字/DELを含まない場合のみ返す。
#     制御文字の検査は値がシェルへ出る前にjq内で行う（codexレビュー#33-4 L2）
#   - background_tasks は要素数（配列でなければ0）。判定側の契約は従来どおり
#   - JSON文がちょうど1個であることを要求する（-s + length==1）。連結JSON
#     （{"a":1}{"b":2} のような入力）はPS版の ConvertFrom-Json が
#     「Additional text encountered」で拒否する一方、旧sh版は jq -e の終了コードが
#     最後の出力値で決まるため「最後の文がobjectなら通す」という緩い判定だった。
#     PS版に合わせて拒否する（fail-closed。sh/PSの受否分裂の解消）
#   - stop_hook_active は**判定結果**（0/1）で持つ。値そのものを運ぶと
#     コマンド置換が末尾のLFを剥がし、「true + 末尾LF」が "true" と一致してしまい、
#     PS版（完全一致で不一致）と割れる。契約は「boolean true か 文字列 "true" のみ有効」
#
# **シェルが運べるもの・運べないもの**（この設計の前提。すべて実測 — バックログ12）:
#   - LF: 運べる。jqのstdoutはテキストモードで値の中のLFをCRLFへ変えるが、
#     MSYSのシェルは eval の解析時にCRを落とすので、往復するとLFに戻る
#     （値が「x + LF」のJSONを @sh + eval に通すと「x + LF」のまま。末尾LFも保つ）。
#     Linuxではそもそも変換が無く素通りする
#   - CR: **運べない**。上記のとおり eval がCRを落とすため、「x + CR + y」が xy になる。
#     コマンド置換なら残るが、今度は値の中のLFがCRLFに化けたままになる。
#     どちらの経路でもCRとLFを同時に正しくは運べない
#   - NUL: **運べない**（バックログ13）
# したがって揃えられるのは「NUL・CRを含む値は空扱い、LFは生のまま」だけである。
# CR入りの値は正当な入力に存在しない（session_idはUUID、sourceは clear/compact 等、
# triggerは auto/manual、cwdはパス）ので、両実装で空へ落とす側に倒す。
# 以前は末尾LFをjq側で剥がしていたが、PS版は生値を使うため
#   「clear + 末尾LF」を sh版だけ clear と見る / 内部LFの値でsh版だけCRが増える
# という分裂になっていた（実測）。剥がすのをやめ、遅い経路も廃止した
ho_read_input() {
    HO_INPUT=$(cat)
    [ -n "$HO_INPUT" ] || return 1
    HO_CWD=""
    HO_TRANSCRIPT_PATH=""
    HO_SESSION_ID=""
    HO_SOURCE=""
    HO_TRIGGER=""
    HO_BG_TASKS=0
    HO_STOP_ACTIVE=0
    _fields=$(printf '%s' "$HO_INPUT" | jq -s -r '
        def strfield: if type == "string" and (contains("\u0000") | not)
                         and (contains("\r") | not) then . else "" end;
        def pathfield: if type == "string" and (test("[\u0000-\u001f\u007f]") | not) then . else "" end;
        if length == 1 and (.[0] | type) == "object" then .[0] |
            "HO_CWD=\(.cwd | strfield | @sh) " +
            "HO_TRANSCRIPT_PATH=\(.transcript_path | pathfield | @sh) " +
            "HO_SESSION_ID=\(.session_id | strfield | @sh) " +
            "HO_SOURCE=\(.source | strfield | @sh) " +
            "HO_TRIGGER=\(.trigger | strfield | @sh) " +
            "HO_BG_TASKS=\(.background_tasks | if type == "array" then length else 0 end) " +
            "HO_STOP_ACTIVE=\(if .stop_hook_active == true then 1
                elif (.stop_hook_active | type) == "string" and .stop_hook_active == "true" then 1
                else 0 end)"
        else empty end' 2>/dev/null)
    [ -n "$_fields" ] || return 1
    eval "$_fields"
    return 0
}

# JSONファイル（$1）から文字列フィールド（$2）を取り出す。文字列型かつNULを含まない
# 場合だけ値を返し、それ以外は空を返す（HANDOFF.mdバックログ13）。
#
# 生の `$(jq -r '.field' file)` は**NULをシェルへ渡せない**。Git shは
# 「ignored null byte in input」としてNULを取り除いた値を返すため、
# `"<uuid>\u0000"` が正規のUUIDへ、`"<正しいSHA>\u0000"` が正しいSHAへ縮退して
# 検証を通ってしまう（実測: ガード無しだと注入とポインタ消費まで進む）。
# PS版は.NET文字列としてNULを保持するので拒否する側で、そのまま受否が分裂する。
# **シェルはNULを保持できない**以上、揃えられるのは「NULを含む値は空扱い」だけである。
#
# 弾くのは**NULだけ**にする。他のC0制御文字やDELはシェルをそのまま通り、
# 下流の検証（UUID正規表現・SHAの完全一致・`[ -f ]`）がPS版と同じ結果を出すため、
# ここで落とすと逆にsh版だけが拒否する分裂を作る（DEL入りの実在パスを
# PS版だけが引用する — 2026-08-30 codexレビュー Low）
ho_json_str_field() {
    jq -r --arg k "$2" \
        '.[$k] | if type == "string" and (contains("\u0000") | not) then . else "" end' \
        "$1" 2>/dev/null
}

# プロジェクトディレクトリと引き継ぎルートを HO_PROJECT_DIR / HO_HANDOFF_ROOT に設定する。
# 決められなければ1を返す（呼び出し側はexit 0）。値を戻り値でなく変数で返すのは
# コマンド置換のforkを避けるため（以前は $(ho_handoff_root) と $(ho_project_dir) で
# 2回forkし、その中で cwd を1回ずつパースしていた）。
#
# 挙動変更（意図的・PS版に寄せる方向。2026-08-30 codexレビュー Low-5）:
# 旧実装は $(ho_project_dir) のコマンド置換が CLAUDE_PROJECT_DIR の末尾LFを剥がしていた。
# PS版の Get-ProjectDir は $env:CLAUDE_PROJECT_DIR を生のまま返すので、剥がさない方が
# 一致する。末尾LF入りの値ではPS版と同様に config が見つからず静かに無効化される
# （fail-closed。そもそも環境変数に改行が入るのは設定ミス）
ho_set_project() {
    # 参照は ${x:-} 形式にする（ho_require_jq と同じ流儀）。旧実装は $( ) の中で展開して
    # いたため set -u 環境でも「サブシェルが落ちる → 外側の || exit 0」で静かに終わったが、
    # メインシェルで展開する形にするとフック自体が異常終了する
    # （2026-08-30 codexレビュー2回目 Low-1）
    HO_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-}
    [ -n "$HO_PROJECT_DIR" ] || HO_PROJECT_DIR=${HO_CWD:-}
    [ -n "$HO_PROJECT_DIR" ] || return 1
    # ⚠️ .claude/ 配下は使わない（sensitive file保護でLLMが書けない — PS版コメント参照）
    # 連結前に末尾の区切りを落とす（PS版は Join-Path が畳む）。落とさないと
    # CLAUDE_PROJECT_DIR="/srv/repo/" が "/srv/repo//.claude-handoff" になり、
    # 包含判定の「連続区切りの全域拒否」に掛かってsh版だけ復元できなくなる
    # （2026-08-31 codexレビュー Medium-2）。HO_PROJECT_DIR 自体は変えない
    # （PS版も $dir を加工せず Join-Path 側で畳んでいるため）。"/" だけの場合は空にしない
    _sp_base=$HO_PROJECT_DIR
    while :; do
        case "$_sp_base" in
            ?*/|?*\\) _sp_base=${_sp_base%?} ;;
            *) break ;;
        esac
    done
    HO_HANDOFF_ROOT="$_sp_base/.claude-handoff"
    return 0
}

# dirname(1) をパラメータ展開で置き換えるのは不可（2026-08-30 codexレビュー High-1/Medium-3）。
# MSYS版の dirname は**バックスラッシュも区切りとして扱う**（`C:\x\y` → `C:\x`）が、
# POSIX版は `.` を返す。素のシェルで書くとどちらかのプラットフォームで必ず割れ、
# バックスラッシュを区切り扱いにすると今度はLinuxの「名前に \ を含むパス」を壊す。
# `$(dirname …)` のforkは残すこと。

# $1=handoffRoot $2=source $3=message
ho_error() {
    [ -n "$1" ] || return 0
    mkdir -p "$1" 2>/dev/null || return 0
    _log="$1/error.log"
    # サイズ上限256KB: 超過時は末尾500行だけ残す
    if [ -f "$_log" ]; then
        _sz=$(wc -c < "$_log" 2>/dev/null || echo 0)
        if [ "$_sz" -gt 262144 ] 2>/dev/null; then
            tail -n 500 "$_log" > "$_log.trim" 2>/dev/null && mv -f "$_log.trim" "$_log"
        fi
    fi
    printf '[%s] %s: %s\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$2" "$3" >> "$_log" 2>/dev/null
    return 0
}

# 原子的書き込み: stdinの内容を$1へ（tmp→rename。tmp名は短いランダム名 — MAX_PATH対策はPS版と同じ思想）
ho_write_atomic() {
    # テスト用シーム: 書き込み失敗経路をパリティ試験で決定的に再現する（C61）
    if [ "${HANDOFF_TEST_FORCE_WRITE_FAIL:-}" = "1" ]; then
        cat > /dev/null
        return 1
    fi
    _dst="$1"
    _dir=$(dirname "$_dst")
    # tmp名のランダム部分は外さないこと。PID＋連番の予測可能な名前にすると、
    # 同ディレクトリへ書ける相手が書き込み前にsymlinkを置いて被害ファイルを
    # 上書きさせられる（2026-08-30 codexレビュー Medium-4。速度目的で
    # od+tr を外そうとして差し戻した）
    _tmp="$_dir/~ho.$$.$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' \n' || echo $$).tmp"
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$_dst" || { rm -f "$_tmp"; return 1; }
    return 0
}

# 文字列全体が1〜10桁のASCII数字であることを検証する（環境変数ゲート用 — issue #32）。
# grep -Eq は行単位一致のため改行混入値（"LF500"等）の1行が通ってしまう。caseは全文一致。
# 文字クラスはロケール照合順の影響を避けるため範囲でなく列挙で書く
ho_is_uint_token() {
    case "$1" in
        ''|*[!0123456789]*) return 1 ;;
    esac
    [ ${#1} -le 10 ]
}

# UUID形式（16進 8-4-4-4-12）か。caseは全文一致なので、grep -Eq のように
# 「改行の後ろに文字が続く値」の1行目だけが通ることがない（HANDOFF.mdバックログ11:
# `<uuid>` + LF + `x` を sh版は受理・PS版は拒否していた。MSYSのgrepはCRも行末として
# 落とすためWindowsでも再現する）。ho_is_uint_token で既に塞いだのと同型の罠。
# 末尾LFだけの `<uuid>` + LF も、strfieldが末尾LFを剥がさなくなった（バックログ12）ため
# 長さが37になってここで落ちる。PS版も Test-Uuid のアンカーを終端一致へ締めたので、
# 両実装とも拒否側で揃う。
# 文字クラスはロケール照合順の影響を避けるため範囲でなく列挙で書く
# （ho_is_uint_token と同じ理由）。grepプロセスが1つ減る副次効果もある
ho_is_uuid() {
    # 長さ36とハイフン位置を固定する（caseの ? は改行を含む任意の1文字に一致するので、
    # 改行入りの値はここで長さが合わずに落ちる）
    case "$1" in
        ????????-????-????-????-????????????) ;;
        *) return 1 ;;
    esac
    # ハイフンで区切り、各セグメントが16進のみ・セグメントがちょうど5個であることを見る。
    # 5個より多ければ、上のパターンの ? のどれかがハイフンだったということ
    _u=$1
    _un=0
    while :; do
        case "${_u%%-*}" in
            *[!0123456789abcdefABCDEF]*) return 1 ;;
        esac
        _un=$((_un + 1))
        case "$_u" in
            *-*) _u=${_u#*-} ;;
            *) break ;;
        esac
    done
    [ "$_un" -eq 5 ]
}

ho_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        # od+awkの2プロセスで組み立てる（2026-08-30の速度対策。以前は
        # od+tr+cut×5 の7プロセスだった。Windowsではプロセス起動が1回70〜85msで、
        # フック1回の実測時間に直接効く）。odの出力行数に依存しないよう
        # 全フィールドを連結してから桁位置で切る（LC_ALL=Cでlocale非依存）
        od -An -N16 -tx1 /dev/urandom | LC_ALL=C awk '
            { for (i = 1; i <= NF; i++) h = h $i }
            END { print substr(h, 1, 8) "-" substr(h, 9, 4) "-" substr(h, 13, 4) "-" substr(h, 17, 4) "-" substr(h, 21, 12) }'
    fi
}

# $1=パス: 先頭が「ASCII英字 + :」ならそのドライブレターだけ小文字にして
# **HO_DRIVE_LOWER へ入れる**（PS版 ConvertTo-HoDriveLowerPath と同一契約）。
# MSYSの pwd が「D:/x」も「d:/x」も /d/x へ畳むのに合わせるための正規化。
# 標準出力ではなく変数で返すのは、包含判定がStopフックの都度経路にあり、
# コマンド置換 $( ) のforkが1回26msかかるため（実測。docs/design参照）。
# trも使わず case で畳むのも同じ理由
ho_drive_lower() {
    HO_DRIVE_LOWER=$1
    case "$1" in
        [A-Za-z]:*) ;;
        *) return 0 ;;
    esac
    _dl_d=${1%"${1#?}"}
    _dl_rest=${1#?}
    case $_dl_d in
        A) _dl_d=a ;; B) _dl_d=b ;; C) _dl_d=c ;; D) _dl_d=d ;; E) _dl_d=e ;;
        F) _dl_d=f ;; G) _dl_d=g ;; H) _dl_d=h ;; I) _dl_d=i ;; J) _dl_d=j ;;
        K) _dl_d=k ;; L) _dl_d=l ;; M) _dl_d=m ;; N) _dl_d=n ;; O) _dl_d=o ;;
        P) _dl_d=p ;; Q) _dl_d=q ;; R) _dl_d=r ;; S) _dl_d=s ;; T) _dl_d=t ;;
        U) _dl_d=u ;; V) _dl_d=v ;; W) _dl_d=w ;; X) _dl_d=x ;; Y) _dl_d=y ;;
        Z) _dl_d=z ;;
    esac
    HO_DRIVE_LOWER="$_dl_d$_dl_rest"
}

# $1=root（「/」正規化済み・末尾スラッシュなし） $2=検査対象（「/」正規化済み）:
# root配下ならexit 0。包含ゲートの唯一の判定規則（HANDOFF.mdバックログ16。
# PS版 Test-HoContained と同一契約）:
#   連続区切り（"//"）を全域拒否 → ドライブレターを小文字へ畳んで ordinal 前方一致 →
#   rootから $2 の親までの各構成要素が「実在ディレクトリかつ非symlink」
# **symlink/junctionは追跡せず、経路にあれば拒否する**。以前は sh版が `cd`+`pwd`、
# PS版が GetFullPath で、どちらも**字句解決のまま**だった（`pwd` は既定で論理パスを返す。
# 物理解決は `pwd -P` — 実測）。そのため projects_root 配下に置かれた
# root外を指すjunctionを**両実装とも受理し、root外のファイルを引用できていた**
# （2026-08-31 codexレビュー Medium。ただし「sh版は物理解決するので拒否する」という
# 指摘の前提は誤りで、分裂ではなく共通の穴だった — C87で実測）。
# 経路のsymlinkを拒否する規則は組B（ho_valid_state_path）が元から持っており、そちらへ揃えた。
# ".."は追跡しないと畳めないため、呼び出し側が ho_path_token_ok で先に拒否すること
ho_contained_strict() {
    ho_drive_lower "$1"; _cs_root=$HO_DRIVE_LOWER
    ho_drive_lower "$2"; _cs_p=$HO_DRIVE_LOWER
    case "$_cs_p" in *//*) return 1 ;; esac
    case "$_cs_p" in
        "$_cs_root"/*) : ;;
        *) return 1 ;;
    esac
    [ -d "$_cs_root" ] || return 1
    if [ -h "$_cs_root" ]; then return 1; fi
    _cs_parent="${_cs_p%/*}"
    _cs_rel="${_cs_parent#"$_cs_root"}"
    _cs_rel="${_cs_rel#/}"
    _cs_walk="$_cs_root"
    if [ -n "$_cs_rel" ]; then
        _cs_oldifs="$IFS"; IFS='/'; set -f
        for _cs_seg in $_cs_rel; do
            if [ -z "$_cs_seg" ]; then IFS="$_cs_oldifs"; set +f; return 1; fi
            _cs_walk="$_cs_walk/$_cs_seg"
            if [ -h "$_cs_walk" ] || [ ! -d "$_cs_walk" ]; then
                IFS="$_cs_oldifs"; set +f; return 1
            fi
        done
        IFS="$_cs_oldifs"; set +f
    fi
    # leaf自身がsymlinkなら拒否する。親までしか見ないと
    # 「<root>/proj/session.jsonl -> /tmp/outside.jsonl」のように**対象ファイルを**
    # リンクに差し替えるだけでroot外を読めてしまう（後段の [ -f ] も cat/tail も
    # リンクを追跡する — 2026-08-31 codexレビュー Medium-1）。
    # 実在しないleafは通す（書込みモードの呼び出しがあるため）
    if [ -h "$_cs_p" ]; then return 1; fi
    return 0
}

# $1=root $2=candidate: root配下ならexit 0（PS版 Test-PathUnderRoot と同一契約）。
# 判定は ho_contained_strict に一本化してある（バックログ16で組A・組Bの契約を統一）
# $1=パス: 組Aの前段検査。制御文字（C0/DEL）と "."/".." セグメントだけを拒否する
# （PS版 Test-HandoffNoTraversal と同一契約）。".." は追跡しない以上ここで落とすしかない。
# **ho_path_token_ok は使わない**: あちらはWindows予約デバイス名やドライブ位置以外の
# コロンも拒否するが、組Aの候補は利用者のプロジェクトパス由来で、
# POSIXでは /srv/aux/repo や /srv/team:blue/repo が正当な絶対パスである。
# 全プラットフォームでWindowsの名前規則を課すとmacOS/Linuxで復元不能になる
# （2026-08-31 codexレビュー Medium-3）。root外参照は包含判定と経路のsymlink拒否が塞ぐ
ho_no_traversal() {
    case "$1" in
        '') return 1 ;;
    esac
    printf '%s' "$1" | LC_ALL=C awk '
        NR > 1 { bad = 1; exit }
        NR == 1 {
            p = $0
            if (p ~ /[[:cntrl:]]/) bad = 1
            gsub(/\\/, "/", p)
            n = split(p, seg, "/")
            for (i = 1; i <= n; i++) {
                if (seg[i] == "." || seg[i] == "..") bad = 1
            }
        }
        END { if (NR == 0) bad = 1; exit bad ? 1 : 0 }'
}

ho_under_root() {
    ho_no_traversal "$2" || return 1
    _ur_root=$(printf '%s' "$1" | tr '\\' '/')
    while [ "${_ur_root%/}" != "$_ur_root" ]; do _ur_root="${_ur_root%/}"; done
    [ -n "$_ur_root" ] || return 1
    _ur_p=$(printf '%s' "$2" | tr '\\' '/')
    ho_contained_strict "$_ur_root" "$_ur_p"
}

# --- transcript由来の状態ファイルパス包含ゲート（issue #33） ---
# transcript_pathはhook入力由来の非信頼値であり、固定サフィックス連結のままでは
# 「任意パス+.handoff-state.json」の削除・作成ができてしまう。削除・書込みの対象を
# projects_root（CLAUDE_CONFIG_DIR、無ければ (USERPROFILE|HOME)/.claude、+ /projects）
# 配下の正規パスに限定する（設計文書4.8のうち#33スコープ分。transcript読取り系は#36で再評価）。
# 検証・操作とも「\」→「/」正規化後のパスで統一し、包含判定はbyte厳密・要素境界。
# PS版 Get-ValidStateFilePath / Test-HandoffPathToken / Get-ClaudeProjectsRoot と同一契約

HO_STATE_SUFFIX=".handoff-state.json"

# 完全性ファイルの既知キー集合（issue #38 — 設計文書4.2/4.3/4.4。閉じたスキーマ）。
# jqの --argjson known へ渡すJSON配列リテラル。ポインタの handoff_path / size は
# 移行期間用の受理専用キー（無検証・不使用）。照合はjqのキー完全一致
# （大小違いキーは未知キー — issue #37の契約と整合）
HO_POINTER_KNOWN_KEYS='["schema_version","session_id","nonce","sha256","transcript_path","updated_epoch","updated_at","consumed","consumed_at","handoff_path","size"]'
# completed_tokens / completed_epoch / completed_nonce / completed_sha256 は additive キー（v0.2.1。PS版と同一契約）。
# いずれも「このサイクルで直近に完成した資料」の情報で、completed=true なら nonce の資料、
# completed=false（ソフトで作った資料の書き直しを指示中）なら completed_nonce の資料を指す
HO_STATE_KNOWN_KEYS='["schema_version","mode","nonce","attempts","completed","failed","completed_tokens","completed_epoch","completed_nonce","completed_sha256"]'
HO_CONFIG_KNOWN_KEYS='["soft_threshold","hard_threshold","min_margin","conservative_fire_pct","autocompact_window"]'
# completed_epoch の上限（10桁 = 2286年まで。PS版 $HO_EPOCH_MAX と同一）
HO_EPOCH_MAX=9999999999
# completed_tokens の上限（checkの設定値上限と同じ。PS版 $HO_TOKENS_MAX と同一）
HO_TOKENS_MAX=1000000000

# transcript末尾からメインチェーン最後の完全なusage合算を返す（不正行は無視）。
# $1=transcript $2=末尾から読む行数。check と restore で共有する（PS版 Get-LastUsageFromTranscript と同一契約）。
# restore から呼ぶと「圧縮直前（clearなら /clear 直前）の使用量」になる: SessionStart
# フックが走る時点では、圧縮後のassistant行はまだ書かれていない（実測で確認済み）。
# 引用符込みの "usage" を含まない行は jq に渡さない（大きな tool_result の行を解析しないため。
# JSON 文字列の中の引用符は必ずエスケープされるので、引用符込みで現れるのはキーか値そのものが
# usage の文字列のときだけ — 設計メモ docs/design/2026-10-01-transcript-tail-reader.md。PS版と同一契約。
# キー名の文字をバックスラッシュ+u+16進4桁でエスケープした usage は読まない: Claude Code はそう書かない — 契約外）。
# grep は -a（バイナリ判定で行を出さなくなるのを防ぐ）と LC_ALL=C（ロケールに依らずバイト列で比べる）
ho_last_usage() {
    tail -n "$2" "$1" 2>/dev/null | LC_ALL=C grep -aF '"usage"' | jq -rRn '
        [ inputs | fromjson? // empty
          | select(type == "object" and .type == "assistant" and (.isSidechain != true))
          | .message.usage? | select(type == "object")
          | [ .input_tokens, .cache_read_input_tokens, .cache_creation_input_tokens, .output_tokens ]
          | select(all(.[]; type == "number" and . == floor and . >= 0))
          | add | select(. > 0)
        ] | last // 0' 2>/dev/null || echo 0
}

# 状態ファイルから「このサイクルで直近に完成した資料」を読む（v0.2.1。PS版 Get-HoCompletionInfo と同一契約）。
# $1=状態ファイル。出力は「nonce 完成時使用量 完成時刻 SHA-256」の1行（値が取れない項目は - 。SHA-256 はキーがあるのに形式外なら INVALID で、照合を必ず失敗させる）、
# 該当が無い・閉じたスキーマに反する・読めないときは空。数値は「number・整数値・範囲内」を
# floor|tostring で整数表記に揃える（1.0 や 1e3 をそのまま算術比較に渡さないため）
ho_completion_info() {
    jq -r --argjson known "$HO_STATE_KNOWN_KEYS" --argjson emax "$HO_EPOCH_MAX" --argjson tmax "$HO_TOKENS_MAX" '
        def okint(min; max): type == "number" and . == floor and . >= min and . <= max;
        def oknonce: type == "string" and test("\\A[A-Za-z0-9-]{8,64}\\z");
        if type == "object"
           and ([keys_unsorted[] | select(. as $k | $known | index($k) | not)] | length == 0)
           and ((has("schema_version") | not) or (.schema_version == 1))
        then
            (if .completed == true then (if (.nonce | oknonce) then .nonce else null end)
             elif (.completed_nonce | oknonce) then .completed_nonce
             else null end) as $n
            | if $n == null then ""
              else $n
                + " " + (if (.completed_tokens | okint(1; $tmax)) then (.completed_tokens | floor | tostring) else "-" end)
                + " " + (if (.completed_epoch | okint(1; $emax)) then (.completed_epoch | floor | tostring) else "-" end)
                + " " + (if (.completed_sha256 | type == "string" and test("\\A[0-9A-F]{64}\\z")) then .completed_sha256 elif has("completed_sha256") then "INVALID" else "-" end)
              end
        else "" end' "$1" 2>/dev/null
}

# 復元する資料の鮮度行（v0.2.1。PS版 Format-HoFreshnessLine と同一契約・同一文言）。
# $1=完成時刻epoch $2=現在epoch $3=完成時の使用量 $4=復元直前の使用量 $5=source（未知の値は空）。
# 材料がどちらも揃わなければ何も出さない。使用量は「復元直前 >= 完成時」かつ「復元直前 >= 1」のときだけ
ho_freshness_line() {
    _fparts=""
    case "$1" in ''|*[!0-9]*) ;; *)
        case "$2" in ''|*[!0-9]*) ;; *)
            if [ "$2" -ge "$1" ] 2>/dev/null; then
                _fmins=$(( ($2 - $1) / 60 ))
                if [ "$_fmins" -lt 1 ]; then
                    _felapsed="1分未満"
                elif [ "$_fmins" -lt 60 ]; then
                    _felapsed="${_fmins}分"
                else
                    _fhrs=$(( _fmins / 60 ))
                    _frem=$(( _fmins % 60 ))
                    _felapsed="${_fhrs}時間${_frem}分"
                fi
                _fparts="完成から${_felapsed}経過"
            fi ;;
        esac ;;
    esac
    case "$3" in ''|*[!0-9]*) ;; *)
        case "$4" in ''|*[!0-9]*) ;; *)
            # 上限（HO_TOKENS_MAX）以下のときだけ。桁数で先に落として整数幅を越えさせない（PS版と同一）
            if [ "${#3}" -le 10 ] && [ "${#4}" -le 10 ] &&
               [ "$3" -le "$HO_TOKENS_MAX" ] 2>/dev/null && [ "$4" -le "$HO_TOKENS_MAX" ] 2>/dev/null &&
               [ "$4" -ge 1 ] 2>/dev/null && [ "$4" -ge "$3" ] 2>/dev/null; then
                _fgrown=$(( $4 - $3 ))
                _ftok="完成時の使用量 ${3} → 復元直前 ${4}（+${_fgrown}）"
                if [ -n "$_fparts" ]; then
                    _fparts="${_fparts} / ${_ftok}"
                else
                    _fparts="$_ftok"
                fi
            fi ;;
        esac ;;
    esac
    [ -n "$_fparts" ] || return 0
    if [ "$5" = "clear" ]; then
        _fcheck="git状態・直近のユーザーメッセージ"
    else
        _fcheck="圧縮要約・git状態・直近のユーザーメッセージ"
    fi
    printf '※ 資料の鮮度: %s。完成後に行った作業はこの資料に含まれていないため、%sと突き合わせて現状を確認すること。' "$_fparts" "$_fcheck"
}

ho_projects_root() {
    # 解決不能・字句不正は失敗（fail-closed）。優先順はPS版と同一。
    # 正規化は「\→/」+末尾スラッシュ全除去+空拒否（PS版と同一規則。片側だけ
    # "//"や"/tmp/cfg//"を受理する分裂を防ぐ — codexレビュー#33-1 L3）。
    # 改行入りの生値はコマンド置換 $( ) が末尾LFを剥がし「改行を含まない値」として
    # 通ってしまう（PS版は拒否 — 分裂）ため、置換に通す前に全域拒否する（#33-2 L2）
    _lf=$(printf '\nX'); _lf="${_lf%X}"
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        _b="$CLAUDE_CONFIG_DIR"
    else
        if [ -n "${USERPROFILE:-}" ]; then
            _h="$USERPROFILE"
        elif [ -n "${HOME:-}" ]; then
            _h="$HOME"
        else
            return 1
        fi
        case "$_h" in *"$_lf"*) return 1 ;; esac
        _h=$(printf '%s' "$_h" | tr '\\' '/')
        while [ "${_h%/}" != "$_h" ]; do _h="${_h%/}"; done
        _b="$_h/.claude"
    fi
    case "$_b" in *"$_lf"*) return 1 ;; esac
    _b=$(printf '%s' "$_b" | tr '\\' '/')
    while [ "${_b%/}" != "$_b" ]; do _b="${_b%/}"; done
    [ -n "$_b" ] || return 1
    _r="$_b/projects"
    ho_path_token_ok "$_r" || return 1
    printf '%s' "$_r"
}

ho_path_token_ok() {
    # 字句検査: 制御文字（C0/DEL）拒否・UNC/デバイスパス（先頭\\・//）拒否・絶対パスのみ・
    # コロンはドライブ位置のみ（ADS遮断）・"."/".."セグメント拒否（/と\の両方を区切り扱い）・
    # Windows予約デバイス名（CON等。拡張子付き含む）拒否。判定はLC_ALL=Cでbyte厳密。
    # 末尾LFはawkの行単位読みで見えなくなるため、先にcaseで改行混入を全域拒否する
    _lf=$(printf '\nX'); _lf="${_lf%X}"
    case "$1" in
        ''|*"$_lf"*) return 1 ;;
    esac
    printf '%s' "$1" | LC_ALL=C awk '
        NR > 1 { bad = 1; exit }
        NR == 1 {
            p = $0
            if (p ~ /[[:cntrl:]]/) bad = 1
            if (p ~ /^\\\\/ || p ~ /^\/\//) bad = 1
            drive = (p ~ /^[A-Za-z]:[\/\\]/)
            if (!drive && p !~ /^[\/\\]/) bad = 1
            q = p
            if (drive) q = substr(p, 3)
            if (index(q, ":") > 0) bad = 1
            gsub(/\\/, "/", p)
            n = split(p, seg, "/")
            for (i = 1; i <= n; i++) {
                s = seg[i]
                if (s == "") continue
                if (s == "." || s == "..") bad = 1
                stem = s
                d = index(s, ".")
                if (d > 0) stem = substr(s, 1, d - 1)
                stem = toupper(stem)
                if (stem ~ /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$/) bad = 1
            }
        }
        END { if (NR == 0) bad = 1; exit bad ? 1 : 0 }'
}

ho_valid_state_path() {
    # $1=transcript_path $2=mode（delete|write）。全検証を通った場合のみ「/」正規化済みの
    # <transcript>.handoff-state.json をstdoutへ出し0を返す。以降のファイル操作はこの
    # 戻り値に対して行う（検証対象と操作対象を同一文字列にする）。検証NGは1（fail-closed）。
    # mode=delete: leafは実在するsymlinkでない通常ファイルのみ
    # mode=write : leafは実在するなら通常ファイル（親ディレクトリは実在必須）
    # 注: 宙吊りsymlinkのleafはsh版は-hで拒否、PS版はTest-Pathの版差で許容し得るが、
    # いずれもrename上書きでリンク自体の置換になり参照先追跡はしない（安全方向の非対称のみ）
    _tp="$1"; _mode="$2"
    ho_path_token_ok "$_tp" || return 1
    _vp="$(printf '%s' "$_tp" | tr '\\' '/')$HO_STATE_SUFFIX"
    # 長さ上限240: Windows実効MAX_PATH(260)側だけ失敗する非対称を排除するため両実装共通。
    # 単位は**UTF-8バイト長**に規範化（${#var}はロケール依存の文字数になり得るため
    # wc -cで決定的にバイト数を取る — codexレビュー#33-1 L4）
    _len=$(printf '%s' "$_vp" | LC_ALL=C wc -c | tr -d ' \t')
    [ "$_len" -le 240 ] 2>/dev/null || return 1
    _root=$(ho_projects_root) || return 1
    # 包含判定は ho_contained_strict に一本化してある（HANDOFF.mdバックログ16で
    # 組A=ho_under_root と契約を揃えた）。中身は「連続区切り（"//"）の全域拒否＋
    # ドライブレターを畳んだordinal前方一致＋rootから親までの各要素が実在ディレクトリ
    # かつ非symlink」。連続区切りを全域で見るのは、shのIFS分割が末尾の空フィールドを
    # 落としFSが"//"を畳むため、空要素検査だけではPS版と分裂するから
    # （codexレビュー#33-3 L2実測: "proj//x.jsonl" をshだけ受理していた）。
    # 戻り値の _vp はドライブレターを畳まない生の形のままにする（判定と操作の対象を
    # 揃えるという原則は維持しつつ、畳みは比較の中だけに閉じる）
    ho_contained_strict "$_root" "$_vp" || return 1
    if [ "$_mode" = "delete" ]; then
        if [ -h "$_vp" ]; then return 1; fi
        [ -f "$_vp" ] || return 1
    else
        if [ -h "$_vp" ]; then return 1; fi
        if [ -e "$_vp" ] && [ ! -f "$_vp" ]; then return 1; fi
    fi
    printf '%s' "$_vp"
}

# 現在時刻のUNIX秒（PS版 Get-HoNowEpoch と同一契約）。失敗時はreturn 1。
# テスト用シーム: HANDOFF_TEST_NOW_EPOCH で固定、HANDOFF_TEST_FORCE_NOW_FAIL=1 で
# 取得失敗を強制（epoch境界・fail-closed経路の決定的検証用）。
# 採用条件は「先頭ゼロなし・18桁以下の10進のみ」の完全一致（末尾LF・先頭ゼロ・過大桁は
# 実時刻へフォールバック。先頭ゼロはjqの--argjsonで不正JSONになり、PS版の[long]解釈と
# 分裂する — レビュー2回目 L1）
ho_now_epoch() {
    if [ "${HANDOFF_TEST_FORCE_NOW_FAIL:-}" = "1" ]; then
        return 1
    fi
    _ov="${HANDOFF_TEST_NOW_EPOCH:-}"
    case "$_ov" in
        ''|*[!0-9]*) date +%s; return $? ;;
    esac
    case "$_ov" in
        0) printf '%s' "$_ov"; return 0 ;;
        0*) date +%s; return $? ;;
    esac
    if [ "${#_ov}" -le 18 ]; then
        printf '%s' "$_ov"
        return 0
    fi
    date +%s
}

# 人間可読の現在日時（表示用。PS版 Get-HoNowDisplay と同一契約）。失敗時はreturn 1。
# テスト用シーム: HANDOFF_TEST_FORCE_DATE_FAIL=1 で失敗を強制（dual-writeのフォールバック検証用）
ho_now_display() {
    if [ "${HANDOFF_TEST_FORCE_DATE_FAIL:-}" = "1" ]; then
        return 1
    fi
    date +%Y-%m-%dT%H:%M:%S%z
}

ho_sha256() {
    # 失敗時は空文字。空文字時の縮退（restore側の照合スキップ）は廃止した（issue #31）:
    # producer(check)はポインタ更新をスキップ、consumer(restore)は注入拒否（fail-closed。PS版と同じ）
    # テスト用シーム: SHA計算失敗経路をパリティ試験で決定的に再現する（C59）
    if [ "${HANDOFF_TEST_FORCE_SHA_FAIL:-}" = "1" ]; then
        return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | awk '{print toupper($1)}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print toupper($1)}'
    fi
}

# 完了検証: $1=file $2=nonce [$3=minChars]。PS版 Test-HandoffComplete と同一仕様
#  1) 最小サイズ 2) マーカーが最後の非空行に完全一致
#  3) コードフェンス外で7必須見出しの完全一致+各セクション本文非空
ho_test_complete() {
    [ -z "$(ho_incomplete_reasons "$1" "$2" "${3:-300}")" ]
}

# 完了検証の失敗理由を1行（" / "区切り）で出力する（空出力=検証合格）。
# 文言・並び順はPS版 Get-HandoffIncompleteReasons と同一（挙動一致。issue #5）
ho_incomplete_reasons() {
    _f="$1"; _nonce="$2"; _min="${3:-300}"
    if [ ! -f "$_f" ]; then printf 'ファイルが存在しない'; return 0; fi
    _rs=""
    # PS版はUTF-16文字数、sh版はバイト数になるが「最小サイズの下限」としては同等に機能する
    _sz=$(wc -c < "$_f" 2>/dev/null || echo 0)
    # 最大サイズ（10MB）超過は他の検証より先に弾く: 巨大current.mdによるフックの
    # CPU・メモリ枯渇を防ぐ（codexレビュー4回目 M2。文言・閾値はPS版と同一）
    if [ "$_sz" -gt 10485760 ] 2>/dev/null; then printf '全体が最大サイズ（10MB）超過'; return 0; fi
    # 最大行数: 改行の数が100000を超える資料も弾く（codexレビュー5回目 M1。
    # 文言・閾値はPS版と同一契約=\nの個数）
    _nl=$(wc -l < "$_f" 2>/dev/null || echo 0)
    if [ "$_nl" -gt 100000 ] 2>/dev/null; then printf '全体が最大行数（100000行）超過'; return 0; fi
    if ! [ "$_sz" -ge "$_min" ] 2>/dev/null; then
        _rs="全体が最小文字数（${_min}）未満"
    fi
    # 最終非空行とマーカーの比較: 空白の契約はASCIIの[ \t]+行末\rの除去1回のみ。
    # tr -d '\r'は行中の埋め込み\rまで消してPS版と合否が分裂するため使わない（5回目 L2/L3）。
    # BINMODE=3はGit BashのGNU awkの暗黙CRLF変換を抑止し「\r除去は1回」の契約を
    # 全awk実装で揃える（gawk以外では無害な変数代入。6回目 L1）。
    # 比較はawk内で行う: MSYS bashの$( )は末尾の\r\nを丸ごと剥ぐため、\rを残した値を
    # コマンド置換で持ち出すと環境で比較結果が分裂する（実測）。
    # LC_ALL=C必須: macOSのBWK awkはUTF-8ロケールで文字列比較(==/!=)にstrcoll()を使い、
    # U+00A0等の「照合上無視可能」な文字を無視して等価判定する（実測。NBSP前置マーカーや
    # NBSPだけの行が偽装通過し、バイト厳密なPS版と合否が分裂する）。Cロケールでstrcmpに固定する
    _marker_ok=$(LC_ALL=C awk -v BINMODE=3 -v m="<!-- handoff-complete: $_nonce -->" \
        '{ line = $0; sub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line); if (line != "") last = line }
         END { print (last == m ? "ok" : "ng") }' "$_f")
    if [ "$_marker_ok" != "ok" ]; then
        [ -n "$_rs" ] && _rs="$_rs / "
        _rs="${_rs}完了マーカーが最後の非空行に無い、またはnonceが今回の指示の値と一致しない"
    fi
    # 状態機械で走査（PS版と同一セマンティクス。codexレビュー3回目 High-1）:
    # 必須見出しはh1/h2のみ・見出し行自体は本文に数えない・
    # h1/h2の非必須見出しで帰属打ち切り・###以深は帰属維持（issue #4）
    _sec=$(awk -v BINMODE=3 '
        BEGIN {
            n = split("Goal|Completed|Not Yet Done|Failed Approaches|Key Decisions|Current State|Resume Instructions", names, "|")
            for (i = 1; i <= n; i++) { found[i] = 0; body[i] = 0 }
            cur = 0; fence = 0
        }
        {
            line = $0; sub(/\r$/, "", line)
            # 空白は[ \t]のみ（[[:space:]]はロケール依存でPS版と分裂し得る。5回目 L2）
            if (line ~ /^[ \t]*```/) { fence = !fence; next }
            if (fence) next
            if (line ~ /^#/) {
                matched = 0
                for (i = 1; i <= n; i++) {
                    # 注: {1,2}のインターバル式は古いBSD awk/mawkで非対応のため ##? を使う。
                    # 空白は[ \t]を1文字以上必須（##Goal のような非見出し行を弾く。PS版と同一契約）
                    if (line ~ ("^##?[ \t]+" names[i] "[ \t]*$")) { found[i] = 1; cur = i; matched = 1; break }
                }
                if (!matched && line ~ /^##?[ \t]/) { cur = 0 }
                next
            }
            t = line; gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (cur > 0 && length(t) > 0 && t !~ /^<!--/) body[cur] = 1
        }
        END {
            out = ""
            for (i = 1; i <= n; i++) {
                if (!found[i]) { if (out != "") out = out " / "; out = out "見出しが無い: " names[i] }
                else if (!body[i]) { if (out != "") out = out " / "; out = out "本文が空: " names[i] }
            }
            print out
        }' "$_f")
    if [ -n "$_sec" ]; then
        [ -n "$_rs" ] && _rs="$_rs / "
        _rs="$_rs$_sec"
    fi
    printf '%s' "$_rs"
}

# gitコマンドをtimeout・出力バイト上限付きで実行: $1=outfile $2=workdir $3=timeout秒 $4=maxbytes 残り=git引数
# 結果ステータスをstdoutへ: ok / truncated / timeout / exit=N
ho_git_capture() {
    _out="$1"; _wd="$2"; _to="$3"; _max="$4"; shift 4
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_to" git -C "$_wd" "$@" > "$_out" 2>/dev/null
        _rc=$?
    else
        git -C "$_wd" "$@" > "$_out" 2>/dev/null
        _rc=$?
    fi
    if [ "$_rc" -eq 124 ]; then printf 'timeout'; return 0; fi
    _sz=$(wc -c < "$_out" 2>/dev/null || echo 0)
    if [ "$_sz" -gt "$_max" ] 2>/dev/null; then
        head -c "$_max" "$_out" > "$_out.trunc" 2>/dev/null && mv -f "$_out.trunc" "$_out"
        printf '\n...(truncated at %s bytes)' "$_max" >> "$_out"
        printf 'truncated'
        return 0
    fi
    if [ "$_rc" -ne 0 ]; then printf 'exit=%s' "$_rc"; return 0; fi
    printf 'ok'
}

# $1=workdir $2=tmpdir: gitリポジトリ内ならexit 0
ho_git_repo() {
    command -v git >/dev/null 2>&1 || return 1
    _probe="$2/~ho-probe.$$.tmp"
    _r=$(ho_git_capture "$_probe" "$1" 5 1024 rev-parse --is-inside-work-tree)
    _val=$(cat "$_probe" 2>/dev/null | tr -d '\r\n[:space:]')
    rm -f "$_probe" 2>/dev/null
    [ "$_r" = "ok" ] && [ "$_val" = "true" ]
}

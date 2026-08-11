#!/bin/sh
# handoff-common.sh - フック共通ヘルパー（各フックから . で読み込む。単体実行しない）
# 依存: jq（必須）。sha256sum または shasum、timeout があれば利用する（無くても縮退動作）
# PS版 handoff-common.ps1 と挙動一致必須（dist/tests で検証）

# jq不在の検出（issue #18: 以前は無言終了でerror.logにも残らなかった）。
# jq無しで書ける手段だけで記録する。$1=フック名。不在なら1を返す（呼び出し側はexit 0）
ho_require_jq() {
    command -v jq >/dev/null 2>&1 && return 0
    if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
        ho_error "$CLAUDE_PROJECT_DIR/.claude-handoff" "$1" "jqが見つかりません。sh版フックはjq必須のため何もせず終了します（PATHとインストールを確認してください）"
    fi
    return 1
}

# stdin全体を$HO_INPUTへ読み込む。JSONとして不正なら1を返す
ho_read_input() {
    HO_INPUT=$(cat)
    [ -n "$HO_INPUT" ] || return 1
    printf '%s' "$HO_INPUT" | jq -e 'type=="object"' >/dev/null 2>&1 || return 1
    return 0
}

# $HO_INPUTからフィールドを取り出す（無ければ空文字）
ho_field() {
    printf '%s' "$HO_INPUT" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

# 文字列フィールド専用の取得: 文字列以外の型（配列・boolean・number等）は空扱い
# （PS版の -is [string] ガードと同一契約。ho_fieldは非文字列をjqの出力表現で返すため、
# パス等に使うとPS版と挙動が分裂し得る — 罠8の型固定）
ho_string_field() {
    printf '%s' "$HO_INPUT" | jq -r --arg k "$1" '.[$k] | if type == "string" then . else "" end' 2>/dev/null
}

# パス用フィールド取得: 文字列型かつC0制御文字/DELを含まない場合のみ返す（それ以外は空）。
# シェルのコマンド置換は末尾LFを剥がすため、ho_string_fieldでは「末尾改行入りパス」が
# 「改行なしの有効パス」へ化け、生値を保持して字句ゲートで拒否するPS版と受否が分裂する
# （codexレビュー#33-4 L2）。制御文字の検査は値がシェルへ出る前にjq内で行う
ho_path_field() {
    printf '%s' "$HO_INPUT" | jq -r --arg k "$1" \
        '.[$k] | if type == "string" and (test("[\u0000-\u001f\u007f]") | not) then . else "" end' 2>/dev/null
}

ho_project_dir() {
    if [ -n "$CLAUDE_PROJECT_DIR" ]; then
        printf '%s' "$CLAUDE_PROJECT_DIR"
    else
        ho_string_field cwd
    fi
}

ho_handoff_root() {
    # ⚠️ .claude/ 配下は使わない（sensitive file保護でLLMが書けない — PS版コメント参照）
    d=$(ho_project_dir)
    [ -n "$d" ] || return 1
    printf '%s/.claude-handoff' "$d"
}

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

ho_is_uuid() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

ho_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
    else
        _h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        printf '%s-%s-%s-%s-%s\n' \
            "$(printf '%s' "$_h" | cut -c1-8)" "$(printf '%s' "$_h" | cut -c9-12)" \
            "$(printf '%s' "$_h" | cut -c13-16)" "$(printf '%s' "$_h" | cut -c17-20)" \
            "$(printf '%s' "$_h" | cut -c21-32)"
    fi
}

# $1=root $2=candidate: 正規化後にroot配下ならexit 0
ho_under_root() {
    _r=$(cd "$1" 2>/dev/null && pwd) || return 1
    _cdir=$(dirname "$2")
    _c=$(cd "$_cdir" 2>/dev/null && pwd) || return 1
    case "$_c/" in
        "$_r"/*|"$_r/") return 0 ;;
        *) return 1 ;;
    esac
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
HO_STATE_KNOWN_KEYS='["schema_version","mode","nonce","attempts","completed","failed"]'
HO_CONFIG_KNOWN_KEYS='["soft_threshold","hard_threshold","min_margin","conservative_fire_pct","autocompact_window"]'

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
    # 連続する区切り（"//"）は全域拒否: shのIFS分割は末尾の空フィールドを落とし、
    # ファイルシステムは"//"を畳み込むため、空要素検査だけではPS版（空要素拒否）と
    # 分裂する（codexレビュー#33-3 L2実測: "proj//x.jsonl" をshだけ受理していた）
    case "$_vp" in
        *//*) return 1 ;;
    esac
    case "$_vp" in
        "$_root"/*) : ;;
        *) return 1 ;;
    esac
    [ -d "$_root" ] || return 1
    if [ -h "$_root" ]; then return 1; fi
    # rootから親ディレクトリまでの各構成要素を検査（実在ディレクトリかつ非symlink。
    # symlink経由でroot外の実体を指す経路を遮断する）
    _parent="${_vp%/*}"
    _relp="${_parent#"$_root"}"
    _relp="${_relp#/}"
    _walk="$_root"
    if [ -n "$_relp" ]; then
        _oldifs="$IFS"; IFS='/'; set -f
        for _seg in $_relp; do
            if [ -z "$_seg" ]; then IFS="$_oldifs"; set +f; return 1; fi
            _walk="$_walk/$_seg"
            if [ -h "$_walk" ] || [ ! -d "$_walk" ]; then
                IFS="$_oldifs"; set +f; return 1
            fi
        done
        IFS="$_oldifs"; set +f
    fi
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

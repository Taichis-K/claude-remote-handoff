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

ho_project_dir() {
    if [ -n "$CLAUDE_PROJECT_DIR" ]; then
        printf '%s' "$CLAUDE_PROJECT_DIR"
    else
        ho_field cwd
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
    _dst="$1"
    _dir=$(dirname "$_dst")
    _tmp="$_dir/~ho.$$.$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' \n' || echo $$).tmp"
    cat > "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$_dst" || { rm -f "$_tmp"; return 1; }
    return 0
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

ho_sha256() {
    # 失敗時は空文字（restore側はスキップで縮退 — PS版と同じ）
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
    # コマンド置換で持ち出すと環境で比較結果が分裂する（実測）
    _marker_ok=$(awk -v BINMODE=3 -v m="<!-- handoff-complete: $_nonce -->" \
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

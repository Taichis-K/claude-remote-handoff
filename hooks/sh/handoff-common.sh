#!/bin/sh
# handoff-common.sh - フック共通ヘルパー（各フックから . で読み込む。単体実行しない）
# 依存: jq（必須）。sha256sum または shasum、timeout があれば利用する（無くても縮退動作）
# PS版 handoff-common.ps1 と挙動一致必須（dist/tests で検証）

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
    _f="$1"; _nonce="$2"; _min="${3:-300}"
    [ -f "$_f" ] || return 1
    # PS版はUTF-16文字数、sh版はバイト数になるが「最小サイズの下限」としては同等に機能する
    _sz=$(wc -c < "$_f" 2>/dev/null || echo 0)
    [ "$_sz" -ge "$_min" ] 2>/dev/null || return 1
    _last=$(awk 'NF { line=$0 } END { print line }' "$_f" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$_last" = "<!-- handoff-complete: $_nonce -->" ] || return 1
    awk '
        BEGIN {
            n = split("Goal|Completed|Not Yet Done|Failed Approaches|Key Decisions|Current State|Resume Instructions", names, "|")
            for (i = 1; i <= n; i++) { found[i] = 0; body[i] = 0 }
            cur = 0; fence = 0
        }
        {
            line = $0; sub(/\r$/, "", line)
            if (line ~ /^[[:space:]]*```/) { fence = !fence; next }
            if (fence) next
            if (line ~ /^#/) {
                cur = 0
                for (i = 1; i <= n; i++) {
                    if (line ~ ("^#{1,3}[[:space:]]*" names[i] "[[:space:]]*$")) { found[i] = 1; cur = i; break }
                }
                next
            }
            t = line; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            if (cur > 0 && length(t) > 0 && t !~ /^<!--/) body[cur] = 1
        }
        END {
            for (i = 1; i <= n; i++) if (!found[i] || !body[i]) exit 1
            exit 0
        }' "$_f"
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

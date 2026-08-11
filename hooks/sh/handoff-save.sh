#!/bin/sh
# handoff-save.sh - 層1: PreCompactフック（sh版・jq必須）
# PS版 handoff-save.ps1 と挙動一致必須。仕様はPS版ヘッダと HANDOFF.md「層1」参照
. "$(dirname "$0")/handoff-common.sh"

GIT_TIMEOUT_SEC=10
GIT_MAX_BYTES=2000000
KEEP_GENERATIONS=3
RETENTION_DAYS=30
MAX_TRANSCRIPT_BYTES=209715200   # 200MB
MAX_TOTAL_BYTES=524288000        # 500MB

main() {
    ho_require_jq handoff-save || exit 0
    ho_read_input || exit 0
    handoff_root=$(ho_handoff_root) || exit 0
    project_dir=$(ho_project_dir)

    session_id=$(ho_string_field session_id)
    ho_is_uuid "$session_id" || session_id="unknown"
    transcript=$(ho_path_field transcript_path)

    mkdir -p "$handoff_root" 2>/dev/null || exit 0

    is_repo=0
    ho_git_repo "$project_dir" "$handoff_root" && is_repo=1

    # trackedファイル検出時は保存無効化
    if [ "$is_repo" = "1" ]; then
        probe="$handoff_root/~ho-tracked.$$.tmp"
        r=$(ho_git_capture "$probe" "$project_dir" "$GIT_TIMEOUT_SEC" 65536 ls-files -- .claude-handoff)
        tracked=$(cat "$probe" 2>/dev/null | tr -d '[:space:]')
        rm -f "$probe" 2>/dev/null
        if [ -n "$tracked" ]; then
            ho_error "$handoff_root" "handoff-save" ".claude-handoff配下にgit trackedなファイルがあるため保存を無効化しました。.gitignoreに .claude-handoff/ を追加し、trackedファイルを整理してください"
            exit 0
        fi
    fi

    stamp=$(date +%Y%m%d-%H%M%S)
    dest_dir="$handoff_root/$session_id/backup/$stamp"
    mkdir -p "$dest_dir" 2>/dev/null || exit 0

    items="{}"

    # 1. transcript全文コピー（サイズ上限・空き容量best-effort確認つき）
    if [ -n "$transcript" ] && [ -f "$transcript" ]; then
        t_size=$(wc -c < "$transcript" | tr -d '[:space:]')
        free_kb=$(df -k "$dest_dir" 2>/dev/null | awk 'NR==2 {print $4}')
        need_kb=$((t_size / 512 + 1))
        if [ "$t_size" -gt "$MAX_TRANSCRIPT_BYTES" ] 2>/dev/null; then
            items=$(printf '%s' "$items" | jq --arg v "skipped-too-large($t_size bytes)" '.transcript = $v')
        elif [ -n "$free_kb" ] && [ "$free_kb" -lt "$need_kb" ] 2>/dev/null; then
            items=$(printf '%s' "$items" | jq '.transcript = "skipped-low-disk-space"')
            ho_error "$handoff_root" "handoff-save" "空きディスク容量不足のためtranscriptコピーを見送り（size=${t_size}）"
        elif cp -f "$transcript" "$dest_dir/transcript.jsonl" 2>/dev/null; then
            items=$(printf '%s' "$items" | jq '.transcript = "ok"')
        else
            items=$(printf '%s' "$items" | jq '.transcript = "error: copy failed"')
        fi
    else
        items=$(printf '%s' "$items" | jq '.transcript = "missing"')
    fi

    # 2. git状態（status / diff / diff --cached / untracked を区別して保存）
    if [ "$is_repo" = "1" ]; then
        r=$(ho_git_capture "$dest_dir/git-status.txt" "$project_dir" "$GIT_TIMEOUT_SEC" "$GIT_MAX_BYTES" status --porcelain)
        items=$(printf '%s' "$items" | jq --arg v "$r" '."git-status" = $v')
        r=$(ho_git_capture "$dest_dir/git-diff.txt" "$project_dir" "$GIT_TIMEOUT_SEC" "$GIT_MAX_BYTES" diff --no-ext-diff --no-textconv)
        items=$(printf '%s' "$items" | jq --arg v "$r" '."git-diff" = $v')
        r=$(ho_git_capture "$dest_dir/git-diff-cached.txt" "$project_dir" "$GIT_TIMEOUT_SEC" "$GIT_MAX_BYTES" diff --cached --no-ext-diff --no-textconv)
        items=$(printf '%s' "$items" | jq --arg v "$r" '."git-diff-cached" = $v')
        r=$(ho_git_capture "$dest_dir/git-untracked.txt" "$project_dir" "$GIT_TIMEOUT_SEC" "$GIT_MAX_BYTES" ls-files --others --exclude-standard)
        items=$(printf '%s' "$items" | jq --arg v "$r" '."git-untracked" = $v')
    else
        items=$(printf '%s' "$items" | jq '.git = "not-a-repo-or-git-missing"')
    fi

    # 3. メタデータ（原子的書き込み）
    trigger=$(ho_string_field trigger)
    jq -n --arg sa "$(date +%Y-%m-%dT%H:%M:%S%z)" --arg sid "$session_id" --arg tg "$trigger" \
          --arg tp "$transcript" --argjson it "$items" \
        '{saved_at: $sa, session_id: $sid, trigger: $tg, transcript_path: $tp, items: $it}' \
        | ho_write_atomic "$dest_dir/meta.json"

    # 4a. セッション毎の世代数上限
    backup_root="$handoff_root/$session_id/backup"
    ls -1 "$backup_root" 2>/dev/null | sort -r | tail -n +$((KEEP_GENERATIONS + 1)) | while read -r g; do
        [ -n "$g" ] && rm -rf "$backup_root/$g" 2>/dev/null
    done

    # 4b. 日数上限（最終更新が古いセッションディレクトリを削除）
    for d in "$handoff_root"/*/; do
        [ -d "$d" ] || continue
        newest=$(find "$d" -type f -mtime -"$RETENTION_DAYS" 2>/dev/null | head -n 1)
        [ -z "$newest" ] && rm -rf "$d" 2>/dev/null
    done

    # 4c. 孤児状態ファイルの掃除（自ツールのパターンに完全一致するもののみ）。
    # 対象ディレクトリはtranscript_pathが包含ゲートを通る場合のみ採用する（issue #33 —
    # 従来は任意ディレクトリを掃除対象にできた）。-type fはsymlinkを対象にしない
    if _vsp=$(ho_valid_state_path "$transcript" write); then
        tdir="${_vsp%/*}"
        find "$tdir" -maxdepth 1 -name "*.handoff-state.json" -type f -mtime +"$RETENTION_DAYS" 2>/dev/null \
            -exec rm -f {} \; 2>/dev/null
    fi

    # 4d. 全体容量上限（超過時は現セッション以外の古いものから削除）
    total=$(du -sk "$handoff_root" 2>/dev/null | awk '{print $1 * 1024}')
    if [ -n "$total" ] && [ "$total" -gt "$MAX_TOTAL_BYTES" ] 2>/dev/null; then
        ls -1tr "$handoff_root" 2>/dev/null | while read -r d; do
            [ -d "$handoff_root/$d" ] || continue
            [ "$d" = "$session_id" ] && continue
            total2=$(du -sk "$handoff_root" 2>/dev/null | awk '{print $1 * 1024}')
            [ "$total2" -le "$MAX_TOTAL_BYTES" ] 2>/dev/null && break
            rm -rf "$handoff_root/$d" 2>/dev/null
            ho_error "$handoff_root" "handoff-save" "容量上限超過のため旧セッション $d を削除"
        done
    fi
}

main
exit 0

#!/bin/sh
# handoff-reset.sh - SessionStartフック（matcher: resume。sh版・jq必須）
# PS版 handoff-reset.ps1 と挙動一致必須: transcript_pathに対応する状態ファイルを削除する
. "$(dirname "$0")/handoff-common.sh"

ho_read_input || exit 0
tp=$(ho_field transcript_path)
[ -n "$tp" ] && rm -f "$tp.handoff-state.json" 2>/dev/null
exit 0

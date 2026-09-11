#!/bin/sh
# handoff-reset.sh - SessionStartフック（matcher: resume。sh版・jq必須）
# PS版 handoff-reset.ps1 と挙動一致必須: transcript_pathに対応する状態ファイルを削除する
# 配布元: https://github.com/Taichis-K/claude-remote-handoff （導入済みバージョンは ../VERSION）
. "$(dirname "$0")/handoff-common.sh"

ho_require_jq handoff-reset || exit 0
ho_read_input || exit 0
tp=$HO_TRANSCRIPT_PATH
# 削除対象はprojects_root配下の包含ゲートを通った実在通常ファイルのみ（issue #33:
# 従来は任意パス+固定サフィックスを削除できた — 挙動変更）。ゲートNGは黙って何もしない
if sf=$(ho_valid_state_path "$tp" delete); then
    rm -f "$sf" 2>/dev/null
fi
exit 0

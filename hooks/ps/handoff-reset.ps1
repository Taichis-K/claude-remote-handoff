# handoff-reset.ps1 - SessionStartフック（matcher: resume）
# 受け取ったtranscript_pathに対応する状態ファイル <transcript_path>.handoff-state.json を削除する。
# resumeはsession_id / transcript_pathが維持される（実測確定）ため、この削除で
# 「復帰後に閾値超過なら再度handoffを発火させる」という意図どおりに動く。
# PS 5.1互換文法・UTF-8 BOM付きで保存すること。HANDOFF.md「層3 > ループ防止と完了検証 5」参照

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "handoff-common.ps1")

$handoffRoot = $null
try {
    $inp = Read-HookInput
    if ($null -eq $inp) { exit 0 }
    $handoffRoot = Get-HandoffRoot $inp
    if ($inp.PSObject.Properties["transcript_path"] -and -not [string]::IsNullOrEmpty($inp.transcript_path)) {
        $sf = "$($inp.transcript_path).handoff-state.json"
        if (Test-Path $sf) { Remove-Item $sf -Force }
    }
} catch {
    Write-HandoffError $handoffRoot "handoff-reset" "$($_.Exception.GetType().Name): $($_.Exception.Message)"
}
exit 0



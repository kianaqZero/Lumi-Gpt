function Get-LumiCodexHome {
    $configured=$env:GPT_QUOTA_PET_CODEX_HOME
    if(-not $configured){$configured=$env:CODEX_HOME}
    if(-not $configured){$configured=Join-Path $env:USERPROFILE '.codex'}
    return [IO.Path]::GetFullPath($configured)
}

function Get-LumiQuotaBubblePacket($Context) {
    if(-not $Context){return $null}
    Sync-PetQuotaPages $Context
    $entry=$Context.Cache[$Context.ViewKey];$isCurrent=($Context.ViewKey -eq $Context.LoginKey)
    $data=if($isCurrent -and ($Context.LoginAwaiting -or $Context.Accounts.Busy -or $Context.Accounts.NeedsRecovery)){$null}elseif($entry){$entry.data}else{$null}
    $windows=@{}
    foreach($name in @('session','weekly')){
        $w=if($data){$data.$name}else{$null}
        $windows[$name]=if($w){[ordered]@{remaining_percent=[double]$w.remaining_percent;reset_local=[string]$w.reset_local;window_minutes=[int]$w.window_minutes}}else{$null}
    }
    $stale=($entry -and $entry.at -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($entry.at)).TotalMinutes -ge 5)
    return [ordered]@{profiles=@($Context.Profiles|ForEach-Object {[ordered]@{key=[string]$_.key;label=[string]$_.label}});view_key=[string]$Context.ViewKey;login_key=[string]$Context.LoginKey;login_label=[string]$Context.Accounts.Label;follow_login=[bool]$Context.FollowLogin;plan=if($data){[string]$data.plan}else{''};session=$windows.session;weekly=$windows.weekly;checked_at=if($data){[string]$data.checked_at}else{''};cached=([bool]$stale -or [bool]($entry -and $entry.error));error=if($entry){[string]$entry.error}else{''};awaiting=(-not [bool]$data)}
}

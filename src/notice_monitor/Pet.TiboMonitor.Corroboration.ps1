# Read-only observations of existing quota pages. This module never handles auth.
function Get-PetTiboQuotaObservations($Pages,[DateTimeOffset]$Now) {
    $result=@{};if(-not $Pages){return $result}
    foreach($key in @($Pages.Order|Select-Object -Unique)){
        if($key -notmatch '^[a-f0-9]{64}$'){continue};$entry=$Pages.Cache[$key]
        if(-not $entry -or -not $entry.data -or -not $entry.data.ok -or $entry.error){continue}
        try{$at=[DateTimeOffset]::Parse($entry.at);$server=[DateTimeOffset]::Parse($entry.data.checked_at)}catch{continue}
        if(($Now-$at).TotalSeconds -lt -300 -or ($Now-$at).TotalSeconds -gt 600 -or ($Now-$server).TotalSeconds -gt 600 -or ($Now-$server).TotalSeconds -lt -300){continue}
        $item=[ordered]@{key=$key;at=$at.ToUnixTimeSeconds();session=$null;weekly=$null}
        foreach($bucket in @('session','weekly')){
            $w=$entry.data.$bucket;if(-not $w){continue}
            try{$pct=[double]$w.remaining_percent;$deadline=[long]$w.resets_at;$minutes=[int]$w.window_minutes}catch{continue}
            if([double]::IsNaN($pct) -or [double]::IsInfinity($pct) -or $pct -lt 0 -or $pct -gt 100 -or $deadline -le 0 -or $minutes -le 0){continue}
            $item[$bucket]=[pscustomobject]@{remaining=$pct;deadline=$deadline;minutes=$minutes}
        }
        $result[$key]=[pscustomobject]$item
    };return $result
}
function Invoke-PetTiboQuotaCorroboration($Context,$Pages,[DateTimeOffset]$Now) {
    if(-not $Pages -or $Context.Stopped -or -not $Context.Enabled -or -not $Context.State){return}
    $latest=Get-PetTiboValue $Context.State 'latest';$watch=Get-PetTiboValue $Context.State 'corroboration'
    if($watch){
        $valid=$watch.version -eq 1 -and $watch.basis_id -match '^[0-9]{15,22}$' -and (Test-PetTiboSourceUrl $watch.basis_url) -and $watch.status -in @('watching','suspected','confirmed') -and @($watch.baseline).Count -le 200 -and @($watch.events).Count -le 400
        try{$null=[DateTimeOffset]::Parse($watch.expires_at)}catch{$valid=$false}
        if(-not $valid){$watch=$null}
    }
    $verified=$latest -and $latest.kind -eq 'completed' -and (Get-PetTiboValue $latest 'verification') -and $latest.verification.status -eq 'primary_confirmed' -and ((Get-PetTiboValue $latest.verification 'global' $false) -or (Get-PetTiboValue $latest.verification 'all_accounts' $false))
    if($verified){
        if($watch -and $watch.status -ne 'confirmed'){
            $watch.status='confirmed';$watch.confirmed_id=$latest.id
            if($Context.Active -and (Get-PetTiboValue $Context.Active 'assessment') -eq 'suspected'){$Context.Active=$null}
            $keep=@();while($Context.Queue.Count){$n=$Context.Queue.Dequeue();if((Get-PetTiboValue $n 'assessment') -ne 'suspected'){$keep+=@($n)}};foreach($n in $keep){$Context.Queue.Enqueue($n)}
            Save-PetTiboMonitor $Context
        };return
    }
    $isPreparation=$latest -and $latest.kind -in @('planned','in_progress') -and $latest.text -match '(?i)\bglobal reset\b|\b(?:codex|usage|quota|rate limits?)\b'
    if($isPreparation){
        try{$published=[DateTimeOffset]::Parse($latest.at)}catch{return}
        if(($Now-$published).TotalSeconds -lt -300 -or ($Now-$published).TotalHours -gt 24){return}
        if(-not $watch -or $watch.basis_id -ne $latest.id){
            $watch=[pscustomobject]@{version=1;basis_id=$latest.id;basis_url=$latest.url;basis_at=$latest.at;expires_at=$published.AddHours(24).ToString('o');status='watching';baseline=@();events=@();notified=$false;next_probe=0;next_official=0;confirmed_id=''}
            $Context.State|Add-Member -MemberType NoteProperty -Name corroboration -Value $watch -Force
        }
    }
    if(-not $watch -or $watch.status -eq 'confirmed' -or [DateTimeOffset]::Parse($watch.expires_at) -lt $Now){return}
    $unix=$Now.ToUnixTimeSeconds();$snapshots=Get-PetTiboQuotaObservations $Pages $Now;$old=@{};foreach($p in @($watch.baseline)){if($p.key -in $Pages.Order){$old[$p.key]=$p}}
    $events=@($watch.events|Where-Object {$_.key -in $Pages.Order -and $unix-[long]$_.at -le 120 -and [long]$_.at -le $unix+300});$changed=$false
    foreach($key in $snapshots.Keys){
        $next=$snapshots[$key];$prior=$old[$key];if($prior -and [long]$next.at -le [long]$prior.at){continue}
        if($prior -and [long]$next.at-[long]$prior.at -le 600){
            foreach($bucket in @('session','weekly')){
                $before=$prior.$bucket;$after=$next.$bucket
                if(-not $before -or -not $after -or $before.minutes -ne $after.minutes){continue}
                # Normal expiry updates the baseline, then the new period remains watched.
                $early=[long]$before.deadline -gt ([long]$next.at+120)
                $recovered=[double]$after.remaining -ge 95 -and ([double]$after.remaining-[double]$before.remaining -ge 10 -or ([long]$after.deadline -ne [long]$before.deadline -and [long]$after.deadline -gt [long]$next.at+120))
                if($early -and $recovered){$events=@($events|Where-Object {-not ($_.key -eq $key -and $_.bucket -eq $bucket)})+@([pscustomobject]@{key=$key;bucket=$bucket;at=[long]$next.at;old_deadline=[long]$before.deadline});$changed=$true}
            }
        }
        $old[$key]=$next;$changed=$true
    }
    $watch.baseline=@($old.Values);$watch.events=$events
    $accountCount=@($Pages.Order|Select-Object -Unique).Count;$matched=@();$bucketUsed=''
    foreach($bucket in @('weekly','session')){$keys=@($events|Where-Object bucket -eq $bucket|Select-Object -ExpandProperty key -Unique);if(($accountCount -eq 1 -and $keys.Count -eq 1) -or ($accountCount -gt 1 -and $keys.Count -ge 2)){$matched=$keys;$bucketUsed=$bucket;break}}
    if($matched.Count -and -not $watch.notified){
        $watch.notified=$true;$watch.status='suspected';$windowLabel=if($bucketUsed -eq 'weekly'){'周'}else{'小时窗口'}
        $description=if($matched.Count -gt 1){[string]$matched.Count+'个账号的'+$windowLabel+'额度同期提前恢复'}else{'当前账号的'+$windowLabel+'额度在预计重置时间前恢复'}
        $notice=[pscustomobject]@{id=$watch.basis_id;url=$watch.basis_url;at=$Now.ToString('o');kind='in_progress';label='疑似全球重置，正在核对';message=$description+'，疑似全球重置已完成，正在核对 Tibo 后续原帖。';assessment='suspected';basis_id=$watch.basis_id;account_count=$matched.Count;quota_window=$bucketUsed;provider='本机额度观测';verification=$null}
        if($Context.Active -and $Context.Active.id -eq $watch.basis_id){$Context.Active=$null}
        if($Context.Queue.Count -lt 10){$Context.Queue.Enqueue($notice)};$watch.next_official=$unix;$changed=$true
        $Context.State.history=@($Context.State.history|Select-Object -Last 49)+@($notice)
    }
    if($watch.status -eq 'suspected' -and $unix -ge [long]$watch.next_official -and -not $Context.Pending){Request-PetTiboRefresh $Context $Now;$watch.next_official=$unix+60;$changed=$true}
    # Reuse serialized, read-only quota workers, without changing login or page selection.
    if($unix -ge [long]$watch.next_probe -and -not $Pages.Stopped -and -not $Pages.Accounts.Simulation -and -not $Pages.Accounts.Busy -and -not $Pages.Accounts.NeedsRecovery -and $Pages.Accounts.BackendAvailable){
        foreach($key in $Pages.Order){Request-PetQuotaPageRefresh $Pages $key};$watch.next_probe=$unix+120;$changed=$true
    }
    if($changed){Save-PetTiboMonitor $Context;$Context.PanelStamp=''}
}
function Observe-PetTiboQuotaCorroboration($Context,$Pages,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    try{Invoke-PetTiboQuotaCorroboration $Context $Pages $Now}catch{Write-Verbose ('Quota corroboration unavailable: '+$_.Exception.GetType().Name)}
}

# The existing cache reader is retained; this detector replaces announcement-gated observation.
function Invoke-PetTiboQuotaCorroboration($Context,$Pages,[DateTimeOffset]$Now) {
 if(-not $Pages -or $Pages.Stopped -or $Context.Stopped -or -not $Context.Enabled){return}
 $unix=$Now.ToUnixTimeSeconds();if(-not $Context.State){Save-PetTiboMonitor $Context}
 $watch=Get-PetTiboValue $Context.State 'corroboration';$changed=$false
 if(-not $watch -or $watch.version -ne 2){
  $watch=[pscustomobject]@{version=2;status='watching';baseline=@();events=@();receipts=@();next_probe=0;next_official=0;accelerate_until=0;last_cycle=0;latest_assessment=$null;confirmation_id=''}
  $Context.State|Add-Member -MemberType NoteProperty -Name corroboration -Value $watch -Force;$changed=$true
 }
 # No new timer: cap comparisons on the existing one-second UI timer at once per five seconds.
 if($watch.last_cycle -and $unix -ge [long]$watch.last_cycle -and $unix-[long]$watch.last_cycle -lt 5){return};$watch.last_cycle=$unix
 $latest=Get-PetTiboValue $Context.State 'latest';$preparation=$false
 if($latest -and $latest.kind -in @('planned','in_progress')){try{$age=($Now-[DateTimeOffset]::Parse($latest.at)).TotalSeconds;$preparation=$age -ge -30 -and $age -lt 21600}catch{}}
 $snapshot=Get-PetTiboQuotaObservations $Pages $Now;$old=@{}
 foreach($p in @($watch.baseline)){if($p.key -in $Pages.Order){$old[$p.key]=$p}}
 $events=@($watch.events|Where-Object {$_.key -in $Pages.Order -and $unix-[long]$_.at -le 120 -and [long]$_.at -le $unix})
 foreach($key in $snapshot.Keys){
  $next=$snapshot[$key];$prior=$old[$key];if($prior -and [long]$next.at -le [long]$prior.at){continue}
  if($prior -and [long]$next.at-[long]$prior.at -le 600){
   foreach($bucket in @('session','weekly')){
    $before=$prior.$bucket;$after=$next.$bucket;if(-not $before -or -not $after -or $before.minutes -ne $after.minutes){continue}
    $early=[long]$before.deadline -gt ([long]$next.at+120);$rise=[double]$after.remaining-[double]$before.remaining
    $advanced=[long]$after.deadline-[long]$before.deadline -ge 120
    # Consumption after reset may already bring the reading below 95%; a substantial rise
    # plus a moved future deadline is then required. Small deadline jitter never suffices.
    $recovered=$rise -ge 10 -and ([double]$after.remaining -ge 95 -or ($advanced -and [long]$after.deadline -gt [long]$next.at+120))
    if($early -and $recovered){$events=@($events|Where-Object {-not ($_.key -eq $key -and $_.bucket -eq $bucket)})+@([pscustomobject]@{key=$key;bucket=$bucket;at=[long]$next.at;before_at=[long]$prior.at;old_deadline=[long]$before.deadline;new_deadline=[long]$after.deadline;rise=$rise})}
   }
  }
  $old[$key]=$next;$changed=$true
 }
 $watch.baseline=@($old.Values);$watch.events=$events
 $accountCount=@($Pages.Order|Select-Object -Unique).Count;$matched=@();$bucketUsed=''
 foreach($bucket in @('weekly','session')){
  $eligible=@($events|Where-Object bucket -eq $bucket);$keys=@($eligible|Select-Object -ExpandProperty key -Unique)
  if(($accountCount -eq 1 -and $keys.Count -eq 1) -or ($accountCount -gt 1 -and $keys.Count -ge 2)){$matched=$eligible;$bucketUsed=$bucket;break}
 }
 if($matched.Count){
  $receipt=($matched|Sort-Object key|ForEach-Object {$_.key+'|'+$_.bucket+'|'+$_.old_deadline+'|'+$_.new_deadline}) -join ';';$recent=@($watch.receipts|Where-Object {$unix-[long]$_.at -lt 86400})
  if($receipt -notin @($recent|ForEach-Object {$_.signature}) -and -not @($recent|Where-Object {$unix-[long]$_.at -lt 300}).Count){
   $observedAt=[long]($matched|Measure-Object at -Maximum).Maximum;$localId='local-reset-'+$observedAt
   $count=@($matched|Select-Object -ExpandProperty key -Unique).Count;$windowLabel=if($bucketUsed -eq 'weekly'){'周'}else{'小时窗口'}
   $description=if($count -gt 1){[string]$count+'个账号的'+$windowLabel+'额度同期提前恢复'}else{'当前账号的'+$windowLabel+'额度在预计重置时间前恢复'}
   $notice=[pscustomobject]@{id=$localId;url='';at=[DateTimeOffset]::FromUnixTimeSeconds($observedAt).ToString('o');kind='in_progress';label='疑似全球重置，正在核对';message=$description+'，疑似全球重置已完成，正在核对官方消息。';assessment='suspected';account_count=$count;quota_window=$bucketUsed;provider='本机额度观测';verification=$null}
   $watch.status='suspected';$watch.latest_assessment=$notice;$watch.confirmation_id='';$watch.accelerate_until=$unix+1800;$watch.next_official=$unix
   $watch|Add-Member -MemberType NoteProperty -Name event_start_at -Value ([long]($matched|Measure-Object before_at -Minimum).Minimum) -Force
   $watch.receipts=@($recent|Select-Object -Last 49)+@([pscustomobject]@{signature=$receipt;at=$observedAt;notice_id=$localId})
   if($Context.Queue.Count -lt 10){$Context.Queue.Enqueue($notice)};$Context.State.history=@($Context.State.history|Select-Object -Last 49)+@($notice);$changed=$true
  }
 }
 # Never reuse a previous event's official completion to confirm or disable a new reset.
 if($watch.status -eq 'suspected' -and $watch.latest_assessment -and $latest -and $latest.kind -eq 'completed'){
  $proof=Get-PetTiboValue $latest 'verification';$sameCycle=$false
  try{$postAt=[DateTimeOffset]::Parse($latest.at);$start=[DateTimeOffset]::FromUnixTimeSeconds([long]$watch.event_start_at);$sameCycle=$postAt -ge $start.AddSeconds(-30) -and $postAt -le $Now.AddSeconds(30)}catch{}
  if($sameCycle -and $proof -and $proof.status -eq 'primary_confirmed' -and ((Get-PetTiboValue $proof 'global' $false) -or (Get-PetTiboValue $proof 'all_accounts' $false))){
   $watch.status='confirmed';$watch.confirmation_id=$latest.id;$watch.accelerate_until=0;$provisional=$watch.latest_assessment.id
   if($Context.Active -and $Context.Active.id -eq $provisional){$Context.Active=$null}
   $keep=@();while($Context.Queue.Count){$n=$Context.Queue.Dequeue();if($n.id -ne $provisional){$keep+=@($n)}};foreach($n in $keep){$Context.Queue.Enqueue($n)}
   $known=@($Context.State.history|Where-Object {$_.id -eq $latest.id -and $_.kind -eq 'completed'})
   if(-not $known.Count){$Context.State.history=@($Context.State.history|Select-Object -Last 49)+@($latest);if($Context.Queue.Count -lt 10){$Context.Queue.Enqueue($latest)}};$changed=$true
  }
 }
 if($watch.status -eq 'suspected' -and $unix -lt [long]$watch.accelerate_until -and $unix -ge [long]$watch.next_official -and -not $Context.Pending -and -not $Context.Failures){Request-PetTiboRefresh $Context $Now;$watch.next_official=$unix+60;$changed=$true}
 $interval=if($preparation -or $unix -lt [long]$watch.accelerate_until){60}else{120}
 # Existing serialized workers only. Availability of the standalone quota runtime is enough;
 # do not depend on a running Codex desktop/shared backend or change any auth/page selection.
 if($unix -ge [long]$watch.next_probe){
  if(-not $Pages.Accounts.Simulation -and -not $Pages.Accounts.Busy -and -not $Pages.Accounts.NeedsRecovery -and (Get-PetTiboValue $Pages.Accounts 'QuotaAvailable' $false)){
   foreach($key in @($Pages.Order|Select-Object -Unique)){
    $entry=$Pages.Cache[$key];$fresh=$false
    if($entry -and -not $entry.error){try{$age=($Now-[DateTimeOffset]::Parse($entry.at)).TotalSeconds;$fresh=$age -ge -30 -and $age -lt $interval}catch{}}
    $inFlight=($Pages.Task -and $Pages.Task.Key -eq $key) -or ($key -eq $Pages.LoginKey -and $Pages.Accounts.WorkTask)
    $queued=($Pages.Wanted -and $Pages.Wanted.ContainsKey($key)) -or ($key -eq $Pages.LoginKey -and $Pages.Accounts.RefreshWanted)
    $backoff=$entry -and $entry.error -and $Pages.NextProbe -and $Pages.NextProbe.ContainsKey($key) -and $Now -lt $Pages.NextProbe[$key]
    if(-not $fresh -and -not $inFlight -and -not $queued -and -not $backoff){Request-PetQuotaPageRefresh $Pages $key}
   }
  }
  $watch.next_probe=$unix+$interval;$changed=$true
 }
 if($changed){Save-PetTiboMonitor $Context;$Context.PanelStamp=''}
}

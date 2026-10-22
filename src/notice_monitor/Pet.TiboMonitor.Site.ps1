# Public community data and local quota are displayed independently.
function Test-LumiSiteFresh($Packet,[DateTimeOffset]$Now){
 if(-not $Packet){return $false};try{$age=($Now-[DateTimeOffset]::Parse($Packet.updated_at)).TotalSeconds;return $age -ge -300 -and $age -le 900}catch{return $false}
}
function Get-PetTiboDisplayState($Context,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow){
 $d=Get-PetTiboLegacyDisplayState $Context $Now
 $site=Get-PetTiboValue $Context.State 'site';$timeline=Get-PetTiboValue $site 'timeline';$forecast=Get-PetTiboValue $site 'forecast'
 $events=@(Get-PetTiboValue $timeline 'events' @());$last=if($events.Count){$events[0]}else{$null}
 $latest=Get-PetTiboValue $Context.State 'latest';$feedTime=[DateTimeOffset]::MinValue
 if($latest){try{$feedTime=[DateTimeOffset]::Parse($latest.at)}catch{}}
 if($last){try{
  $at=[DateTimeOffset]::Parse($last.at)
  if($at -ge $feedTime -and -not $d.official_completion){
   $d.code=if(($Now-$at).TotalHours -lt 24){'site_completed'}else{'site_history'}
   $d.judgment='社区时间线记录的重置；本账号是否恢复见下方实测。';$d.post_label='社区重置记录';$d.expected_until=$null
   if(-not (Test-LumiSiteFresh $timeline $Now) -or (Get-PetTiboValue $site 'timeline_error')){$d.judgment+=' 当前显示缓存。'}
  }
 }catch{}}
 $signal=Get-PetTiboValue $forecast 'signal'
 if($signal -and (Test-LumiSiteFresh $forecast $Now) -and -not (Get-PetTiboValue $site 'forecast_error')){try{
  $after=[DateTimeOffset]::Parse($signal.at) -ge $feedTime
  if($last){$after=$after -and [DateTimeOffset]::Parse($signal.at) -gt [DateTimeOffset]::Parse($last.at)}
  $w=Get-PetTiboValue $signal 'window';$active=(-not $w) -or [DateTimeOffset]::Parse($w.end_at) -gt $Now
  if($after -and $active -and ($Now-[DateTimeOffset]::Parse($signal.at)).TotalHours -lt 24){
   $d.code=if(Get-PetTiboValue $signal 'pending'){'site_pending'}else{'planned'}
   $d.judgment='社区检测到明确重置进展；仍需核实完成及账号范围。';$d.expected_until=if($w){$w.end_at}else{$null}
  }
 }catch{}}
 return $d
}
function Get-LumiAnnouncementAccountText($Context,[DateTimeOffset]$Now){
 $pages=Get-PetTiboValue $Context 'QuotaPages';if(-not $pages -or -not $pages.LoginKey){return '当前账号：尚未取得登录记录。'}
 $key=$pages.LoginKey;$profile=@($pages.Profiles|Where-Object key -eq $key|Select-Object -First 1)
 $label=if($profile.Count){$profile[0].label}else{'当前账号'}
 $entry=$pages.Cache[$key];$fresh=$false
 if($entry -and $entry.data -and $entry.data.ok -and -not $entry.error -and -not $pages.LoginAwaiting){try{$age=($Now-[DateTimeOffset]::Parse($entry.at)).TotalSeconds;$fresh=$age -ge -30 -and $age -le 600}catch{}}
 if(-not $fresh){return $label+"`n本账号恢复情况尚未核实；请刷新额度。"}
 $buckets=@();foreach($name in @('session','weekly')){$w=$entry.data.$name;if($w -and $null -ne $w.remaining_percent){$n=[double]$w.remaining_percent;if($n -ge 0 -and $n -le 100){$buckets+=@($(if($name -eq 'session'){'小时额度'}else{'周额度'})+' '+$n.ToString('0.#')+'%')}}}
 $status='已读取当前额度；不能仅凭公告判定本账号已恢复。'
 $site=Get-PetTiboValue $Context.State 'site';$timeline=Get-PetTiboValue $site 'timeline';$events=@(Get-PetTiboValue $timeline 'events' @())
 if($events.Count){try{
  $eventAt=[DateTimeOffset]::Parse($events[0].at)
  $confirmed=@($pages.History|Where-Object {$_.key -eq $key -and $_.kind -eq 'confirmed' -and [DateTimeOffset]::Parse($_.at) -ge $eventAt -and [DateTimeOffset]::Parse($_.at) -le $Now})
  if($confirmed.Count){$status='本账号已观测到额度恢复；不据此断言恢复原因或其他账号状态。'}
 }catch{}}
 return $label+"`n"+($buckets -join '  ·  ')+"`n"+$status+"`n更新 "+[DateTimeOffset]::Parse($entry.at).ToLocalTime().ToString('MM-dd HH:mm:ss')
}

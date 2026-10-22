function Get-PetTiboValue($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default};$p=$Object.PSObject.Properties[$Name];if($p){return $p.Value};return $Default
}
function Test-PetTiboSourceUrl([string]$Url) {return $Url -cmatch '^https://x\.com/thsottiaux/status/[0-9]{15,22}$'}
function Test-PetTiboLocalNotice($Item) {return $Item -and $Item.id -cmatch '^local-reset-[0-9]{10,13}$' -and $Item.assessment -eq 'suspected' -and $Item.provider -eq '本机额度观测' -and $Item.url -eq ''}
function New-PetTiboMonitor {
    param([string]$BundleRoot,[string]$Runtime,[string]$StatePath,[scriptblock]$OnChanged={},[scriptblock]$OnNotice={},[switch]$NoTimers,[string]$FixturePath='',[string]$FixtureNow='')
    $state=$null
    if([IO.File]::Exists($StatePath)){
        try{
            if((Get-Item -LiteralPath $StatePath).Length -gt 524288){throw 'CACHE_LIMIT'}
            $state=[IO.File]::ReadAllText($StatePath)|ConvertFrom-Json
            if($state.version -ne 1 -or $state.handle -ne 'thsottiaux' -or $state.enabled -isnot [bool] -or $null -eq $state.seen -or $null -eq $state.history){throw 'INVALID_CACHE'}
            if($state.checked_at){$null=[DateTimeOffset]::Parse($state.checked_at)}
            foreach($item in @($state.latest)+@($state.history)){
                if($item){if((-not (Test-PetTiboSourceUrl ([string]$item.url)) -and -not (Test-PetTiboLocalNotice $item)) -or $item.kind -notin @('planned','completed','in_progress','mentioned')){throw 'INVALID_CACHE'};$null=[DateTimeOffset]::Parse($item.at)}
            }
        }catch{$state=$null}
    }
    $enabled=if($state){[bool](Get-PetTiboValue $state 'enabled' $true)}else{$true}
    $c=[pscustomobject]@{BundleRoot=$BundleRoot;Runtime=$Runtime;StatePath=$StatePath;State=$state;Enabled=$enabled;OnChanged=$OnChanged;OnNotice=$OnNotice;OnOpenSource={param($uri);Start-Process -FilePath $uri};Timer=$null;Stopped=$false;Bootstrap=$true;Pending=$null;Generation=0;Due=[DateTimeOffset]::UtcNow;Failures=0;Status=if($enabled){'准备连接'}else{'已关闭'};LastError='';Queue=[Collections.Generic.Queue[object]]::new();Active=$null;Until=[DateTimeOffset]::MinValue;FixturePath=$FixturePath;FixtureNow=$FixtureNow;OutputPath=Join-Path (Split-Path $StatePath) ('tibo-worker-'+[Guid]::NewGuid().ToString('N')+'.json');Panel=$null;PanelStatus=$null;PanelDetail=$null;PanelCheck=$null;PanelRefresh=$null;PanelSource=$null;PanelStamp='';PanelSummary=$null;PanelSubline=$null;LastAttempt=[DateTimeOffset]::MinValue;RetryUntil=[DateTimeOffset]::MinValue;PanelForecast=$null;PanelAccount=$null;PanelTimeline=$null;QuotaPages=$null}
    if(-not $NoTimers){$t=New-Object Windows.Threading.DispatcherTimer;$t.Interval=[TimeSpan]::FromSeconds(1);$t.Add_Tick({Invoke-PetTiboMonitorTick $c}.GetNewClosure());$c.Timer=$t;$t.Start()}
    return $c
}
function Save-PetTiboMonitor($Context) {
    if(-not $Context.State){$Context.State=[pscustomobject]@{version=1;handle='thsottiaux';enabled=$Context.Enabled;anchor=$null;seen=@();history=@();latest=$null;checked_at=$null;source_checked_at=$null}}
    $Context.State.enabled=$Context.Enabled;$text=$Context.State|ConvertTo-Json -Depth 12;$tmp=$Context.StatePath+'.tmp'
    [void][IO.Directory]::CreateDirectory((Split-Path $Context.StatePath));[IO.File]::WriteAllText($tmp,$text,[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($Context.StatePath)){[IO.File]::Replace($tmp,$Context.StatePath,[NullString]::Value)}else{[IO.File]::Move($tmp,$Context.StatePath)}
}
function Stop-PetTiboWorker($Context) {
    if($Context.Pending){$p=$Context.Pending.Process;try{if(-not $p.HasExited){$p.Kill();[void]$p.WaitForExit(1500)}}catch{}finally{$p.Dispose();$Context.Pending=$null}}
}
function Set-PetTiboMonitorEnabled($Context,[bool]$Enabled) {
    if($Context.Stopped){return};$Context.Generation++;Stop-PetTiboWorker $Context;$Context.Enabled=$Enabled;$Context.Bootstrap=$true;$Context.Queue.Clear();$Context.Active=$null;$Context.Status=if($Enabled){'准备连接'}else{'已关闭'};$Context.Due=[DateTimeOffset]::UtcNow;Save-PetTiboMonitor $Context;$null=& $Context.OnChanged $Context
}
function Request-PetTiboRefresh($Context,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {if($Context.Enabled -and -not $Context.Stopped -and -not $Context.Pending){$Context.Due=$Now;if($Context.LastAttempt.AddSeconds(60) -gt $Context.Due){$Context.Due=$Context.LastAttempt.AddSeconds(60)};if($Context.RetryUntil -gt $Context.Due){$Context.Due=$Context.RetryUntil}}}
function Start-PetTiboWorker($Context,[DateTimeOffset]$Now) {
    if($Context.Pending -or $Context.Stopped -or -not $Context.Enabled){return};if($Now -lt $Context.LastAttempt.AddSeconds(60) -or $Now -lt $Context.RetryUntil){return};$Context.LastAttempt=$Now
    $worker=Join-Path $Context.BundleRoot 'tibo-worker.cjs'
    if(-not [IO.File]::Exists($worker) -or -not [IO.File]::Exists($Context.Runtime)){throw 'MONITOR_RUNTIME_MISSING'}
    $arguments=@(('"'+$worker+'"'),('--state="'+$Context.StatePath+'"'),('--output="'+$Context.OutputPath+'"'))
    if($Context.Bootstrap){$arguments+='--bootstrap'}
    if($Context.FixturePath){$arguments+=('--fixture="'+$Context.FixturePath+'"');if($Context.FixtureNow){$arguments+=('--now='+$Context.FixtureNow)}}
    $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=$Context.Runtime;$info.Arguments=$arguments -join ' ';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WindowStyle='Hidden';$info.EnvironmentVariables['ELECTRON_RUN_AS_NODE']='1'
    $p=New-Object Diagnostics.Process;$p.StartInfo=$info;if(-not $p.Start()){throw 'MONITOR_WORKER_NOT_STARTED'}
    $Context.Pending=[pscustomobject]@{Process=$p;Started=$Now;Generation=$Context.Generation};$Context.Status='正在检查';$null=& $Context.OnChanged $Context
}
function Invoke-PetTiboMonitorTick($Context,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    if($Context.Stopped){return}
    if($Context.Active -and $Now -ge $Context.Until){$Context.Active=$null;$null=& $Context.OnChanged $Context}
    try {
        if($Context.Pending){
            $job=$Context.Pending
            if(($Now-$job.Started).TotalSeconds -gt 25){Stop-PetTiboWorker $Context;throw 'SOURCE_TIMEOUT'}
            if($job.Process.HasExited){
                $exitCode=$job.Process.ExitCode;$job.Process.Dispose();$Context.Pending=$null
                if($job.Generation -ne $Context.Generation -or -not $Context.Enabled){return}
                if($exitCode -ne 0 -or -not [IO.File]::Exists($Context.OutputPath)){throw 'SOURCE_UNAVAILABLE'}
                if((Get-Item -LiteralPath $Context.OutputPath).Length -gt 524288){throw 'OVERSIZED_RESULT'}
                $r=[IO.File]::ReadAllText($Context.OutputPath)|ConvertFrom-Json
                try{$retry=Get-PetTiboValue $r 'next_allowed_at';if($retry){$Context.RetryUntil=[DateTimeOffset]::Parse($retry)}}catch{};if(-not $r.ok){throw ([string]$r.error)}
                if($r.state.version -ne 1 -or $r.state.handle -ne 'thsottiaux'){throw 'INVALID_SOURCE_IDENTITY'}
                $watch=Get-PetTiboValue $Context.State 'corroboration'
                $Context.State=$r.state
                if($watch){$Context.State|Add-Member -MemberType NoteProperty -Name corroboration -Value $watch -Force}
                $Context.Failures=0;$Context.LastError='';$Context.Status=if(Get-PetTiboValue $r.state 'feed_error'){'动态源暂不可用；社区数据已更新'}else{'监测中'};$Context.Bootstrap=$false;$Context.Due=$Now.AddMinutes(5);if($Context.RetryUntil -gt $Context.Due){$Context.Due=$Context.RetryUntil};Save-PetTiboMonitor $Context
                foreach($n in @($r.notices)){if($n -and $n.kind -in @('planned','completed','in_progress','mentioned') -and (Test-PetTiboSourceUrl ([string]$n.url)) -and $Context.Queue.Count -lt 10){$Context.Queue.Enqueue($n)}}
                $null=& $Context.OnChanged $Context
            }
        }
        if(-not $Context.Active -and $Context.Queue.Count -and $Context.Enabled){$Context.Active=$Context.Queue.Dequeue();$Context.Until=$Now.AddSeconds(18);$null=& $Context.OnNotice $Context.Active;$null=& $Context.OnChanged $Context}
        if($Context.Enabled -and -not $Context.Pending -and $Now -ge $Context.Due){Start-PetTiboWorker $Context $Now}
    } catch {
        Stop-PetTiboWorker $Context;$Context.Failures++;$Context.LastError=$_.Exception.Message;$Context.Status=if($Context.LastError -eq 'STALE_SOURCE'){'来源数据延迟'}else{'来源暂不可用'};$Context.Due=$Now.AddSeconds([Math]::Min(1800,300*[Math]::Pow(2,[Math]::Min(3,$Context.Failures-1))));$null=& $Context.OnChanged $Context
    }
}
function Dismiss-PetTiboNotice($Context) {if($Context.Active){$Context.Active=$null;$Context.Until=[DateTimeOffset]::MinValue;$null=& $Context.OnChanged $Context}}
function Stop-PetTiboMonitor($Context) {if(-not $Context){return};$Context.Stopped=$true;if($Context.Timer){$Context.Timer.Stop()};Stop-PetTiboWorker $Context;if($Context.Panel){$Context.Panel.Close()}}

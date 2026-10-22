# Quota browsing owns no login credentials and never performs an account switch.
if(-not ('PetQuotaStateAtomic' -as [type])){
    Add-Type -TypeDefinition 'public static class PetQuotaStateAtomic { public static void Replace(string source,string destination) { System.IO.File.Replace(source,destination,null); } }'
}
function New-PetQuotaPages {
    param($Accounts,[string]$BundleRoot,[string]$StatePath='', [scriptblock]$OnChanged={},[scriptblock]$OnNotice={},[switch]$NoTimers)
    $c=[pscustomobject]@{Accounts=$Accounts;BundleRoot=$BundleRoot;StatePath=$StatePath;OnChanged=$OnChanged;OnNotice=$OnNotice
        LoginKey='';ViewKey='';FollowLogin=$true;LoginAwaiting=$true;CurrentQuota=$null;Profiles=@();Order=@();Epoch=0;Cache=@{};Ledger=@{};History=@()
        Due=@{};Wanted=@{};NextProbe=@{};Task=$null;Timer=$null;Stopped=$false;TempRoot='';LastSignature='';LastUi='';LastSave='';SoundEnabled=$true}
    if($StatePath -and [IO.File]::Exists($StatePath)){
        try {
            $s=[IO.File]::ReadAllText($StatePath)|ConvertFrom-Json
            $c.Order=@($s.order | Where-Object {$_ -match '^[a-f0-9]{64}$'})
            foreach($e in @($s.cache)){if($e.key -match '^[a-f0-9]{64}$'){$c.Cache[$e.key]=$e}}
            foreach($e in @($s.ledger)){if($e.id -match '^[a-f0-9]{64}\|(session|weekly)\|([0-9]+|low:[0-9]+|low:unknown)$'){$c.Ledger[$e.id]=$e.kind}}
            $c.History=@($s.history | Select-Object -Last 50)
            if($s.PSObject.Properties['sound_enabled']){$c.SoundEnabled=[bool]$s.sound_enabled}
        } catch { Write-Verbose ('State read failed at '+$_.InvocationInfo.ScriptLineNumber+' '+$_.Exception.GetType().Name);$c.Order=@();$c.Cache=@{};$c.Ledger=@{};$c.History=@() }
    }
    Sync-PetQuotaPages $c
    if(-not $NoTimers){
        $c.TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('GPTQuotaPet-Pages-'+[Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($c.TempRoot)
        $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(1)
        $timer.Add_Tick({Invoke-PetQuotaPagesTick $c}.GetNewClosure());$c.Timer=$timer;$timer.Start()
    }
    return $c
}
function Save-PetQuotaPages($Context) {
    if(-not $Context.StatePath){return}
    # Deliberate allowlist: only account IDs, labels, quota windows and reminder receipts.
    $content=[ordered]@{version=2;sound_enabled=$Context.SoundEnabled;order=@($Context.Order);cache=@($Context.Cache.Values);ledger=@($Context.Ledger.Keys | ForEach-Object {[pscustomobject]@{id=$_;kind=$Context.Ledger[$_]}});history=@($Context.History | Select-Object -Last 50)} | ConvertTo-Json -Depth 16
    if($content -eq $Context.LastSave){return}
    $tmp=$Context.StatePath+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Context.StatePath))
        [IO.File]::WriteAllText($tmp,$content,[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($Context.StatePath)){[PetQuotaStateAtomic]::Replace($tmp,$Context.StatePath)}else{[IO.File]::Move($tmp,$Context.StatePath)}
        $Context.LastSave=$content
    } catch {Write-Verbose ('State write failed: '+$_.Exception.GetType().Name)} finally {<# Retain failed atomic-output leftovers. #>}
}
function Sync-PetQuotaPages($Context) {
    $a=$Context.Accounts
    $profiles=@($a.Profiles | Where-Object {$_.key -match '^[a-f0-9]{64}$'} | Group-Object key | ForEach-Object {$_.Group[0]})
    $signature=(@($profiles | Sort-Object key | ForEach-Object {$_.key+'|'+$_.label})) -join ';'
    if($signature -ne $Context.LastSignature){
        $Context.Epoch++;$Context.LastSignature=$signature
        $keys=@($profiles | ForEach-Object {$_.key})
        $Context.Order=@($Context.Order | Where-Object {$_ -in $keys})
        foreach($p in $profiles){if($p.key -notin $Context.Order){$Context.Order+=@($p.key);$Context.Wanted[$p.key]=$true}}
        foreach($k in @($Context.Cache.Keys)){if($k -notin $keys){$Context.Cache.Remove($k);$Context.Wanted.Remove($k);$Context.NextProbe.Remove($k)}}
        $Context.Profiles=@($Context.Order | ForEach-Object {$key=$_;@($profiles | Where-Object {$_.key -eq $key})[0]})
        Save-PetQuotaPages $Context
    }
    if($Context.LoginKey -ne $a.Key){
        $Context.LoginKey=$a.Key;$Context.ViewKey=$a.Key;$Context.FollowLogin=$true;$Context.LoginAwaiting=$true
    }
    if($Context.FollowLogin){$Context.ViewKey=$Context.LoginKey}
    elseif($Context.ViewKey -notin $Context.Order){$Context.FollowLogin=$true;$Context.ViewKey=$Context.LoginKey}
}
function Select-PetQuotaPage($Context,[string]$Key) {
    Sync-PetQuotaPages $Context
    if($Key -notin $Context.Order){return $false}
    $Context.ViewKey=$Key;$Context.FollowLogin=$false
    if(-not $Context.Cache.ContainsKey($Key)){$Context.Wanted[$Key]=$true}
    $null=& $Context.OnChanged $Context
    return $true
}
function Follow-PetQuotaLogin($Context) {
    $Context.FollowLogin=$true;Sync-PetQuotaPages $Context;$null=& $Context.OnChanged $Context
}
function Move-PetQuotaPage($Context,[int]$Delta) {
    if(-not $Context.Order.Count){return}
    $i=[Array]::IndexOf([object[]]$Context.Order,$Context.ViewKey)
    if($i -lt 0){$i=if($Delta -lt 0){0}else{-1}}
    $i=($i+$Delta+$Context.Order.Count)%$Context.Order.Count
    $null=Select-PetQuotaPage $Context $Context.Order[$i]
}
function Request-PetQuotaPageRefresh($Context,[string]$Key='') {
    Sync-PetQuotaPages $Context;if(-not $Key){$Key=$Context.ViewKey}
    if($Key -eq $Context.LoginKey -and $Key){Request-PetAccountSyncRefresh $Context.Accounts}
    elseif($Key -in $Context.Order){$Context.Wanted[$Key]=$true}
}
function ConvertTo-PetSafeQuota($Data) {
    $windows=@{}
    foreach($name in @('session','weekly')){
        $w=$Data.$name
        if($w){$windows[$name]=[pscustomobject]@{remaining_percent=[Math]::Max([double]0,[Math]::Min([double]100,[double]$w.remaining_percent));used_percent=[double]$w.used_percent;window_minutes=[int]$w.window_minutes;resets_at=$w.resets_at;reset_local=[string]$w.reset_local}}
        else{$windows[$name]=$null}
    }
    return [pscustomobject]@{ok=$true;plan=[string]$Data.plan;checked_at=[string]$Data.checked_at;session=$windows.session;weekly=$windows.weekly}
}
function Add-PetQuotaNotice($Context,[string]$Key,[string]$Bucket,[long]$Deadline,[string]$Kind,[DateTimeOffset]$Now) {
    $id=$Key+'|'+$Bucket+'|'+$Deadline
    if($Context.Ledger.ContainsKey($id)){
        # A verified result upgrades the record without repeating a popup already delivered.
        if($Kind -eq 'confirmed' -and $Context.Ledger[$id] -eq 'estimated'){
            $Context.Ledger[$id]='confirmed'
            foreach($n in $Context.History){if($n.id -eq $id){$n.kind='confirmed';$n.message=$n.label+' 的'+$n.window_label+'额度已重置（已核实）'}}
            Save-PetQuotaPages $Context
        }
        return
    }
    $profile=@($Context.Profiles | Where-Object {$_.key -eq $Key});if(-not $profile.Count){return}
    $label=[string]$profile[0].label;$windowLabel=if($Bucket -eq 'weekly'){'周'}else{'小时窗口'}
    $message=if($Kind -eq 'confirmed'){$label+' 的'+$windowLabel+'额度已重置（已核实）'}else{$label+' 的'+$windowLabel+'预计重置时间已到，待核实'}
    $notice=[pscustomobject]@{id=$id;key=$Key;label=$label;window=$Bucket;window_label=$windowLabel;deadline=$Deadline;kind=$Kind;at=$Now.ToString('o');message=$message}
    $Context.Ledger[$id]=$Kind;$Context.History=@($Context.History | Select-Object -Last 49)+@($notice)
    Save-PetQuotaPages $Context;$null=& $Context.OnNotice $notice
}
function Submit-PetQuotaPage($Context,[string]$Key,$Data,[int]$Epoch=-1,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    Sync-PetQuotaPages $Context
    if($Context.Stopped -or $Key -notin $Context.Order -or ($Epoch -ge 0 -and $Epoch -ne $Context.Epoch) -or -not $Data.ok){return $false}
    $safe=ConvertTo-PetSafeQuota $Data;$old=$Context.Cache[$Key]
    foreach($name in @('session','weekly')){
        $prior=if($old){$old.data.$name}else{$null};$next=$safe.$name
        if($prior -and $next -and $prior.resets_at -and $next.resets_at){
            $deadline=[long]$prior.resets_at
            if($Now.ToUnixTimeSeconds() -ge $deadline -and [long]$next.resets_at -gt $deadline){
                Add-PetQuotaNotice $Context $Key $name $deadline 'confirmed' $Now
                $Context.Due.Remove($Key+'|'+$name+'|'+$deadline)
            }
        }
    }
    $Context.Cache[$Key]=[pscustomobject]@{key=$Key;at=$Now.ToString('o');data=$safe;error=''}
    if($Key -eq $Context.LoginKey){$Context.LoginAwaiting=$false}
    $Context.Wanted.Remove($Key);$Context.NextProbe[$Key]=$Now.AddMinutes(5)
    Save-PetQuotaPages $Context;$null=& $Context.OnChanged $Context;return $true
}
function Set-PetQuotaPageError($Context,[string]$Key,[string]$Message,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    if($Key -notin $Context.Order){return}
    if($Context.Cache.ContainsKey($Key)){$Context.Cache[$Key].error=$Message}
    else{$Context.Cache[$Key]=[pscustomobject]@{key=$Key;at='';data=$null;error=$Message}}
    $Context.NextProbe[$Key]=$Now.AddMinutes(5);$Context.Wanted.Remove($Key)
    Save-PetQuotaPages $Context;$null=& $Context.OnChanged $Context
}
function Observe-PetQuotaResetTimes($Context,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    foreach($key in $Context.Order){
        $entry=$Context.Cache[$key];if(-not $entry -or -not $entry.data -or -not $entry.at){continue}
        foreach($name in @('session','weekly')){
            $w=$entry.data.$name;if(-not $w -or -not $w.resets_at){continue}
            $deadline=[long]$w.resets_at;$id=$key+'|'+$name+'|'+$deadline
            if($Now.ToUnixTimeSeconds() -lt $deadline -or $Context.Ledger.ContainsKey($id)){continue}
            # Don't create reminders from a server response already overdue at observation time.
            if(([DateTimeOffset]::Parse($entry.at)).ToUnixTimeSeconds() -ge $deadline){continue}
            if(-not $Context.Due.ContainsKey($id)){
                $Context.Due[$id]=[pscustomobject]@{key=$key;window=$name;deadline=$deadline;since=$Now;requested=$false}
                Request-PetQuotaPageRefresh $Context $key
            }
            if(($Now-$Context.Due[$id].since).TotalSeconds -ge 30){Add-PetQuotaNotice $Context $key $name $deadline 'estimated' $Now;$Context.Due.Remove($id)}
        }
    }
}
function Start-PetQuotaPageWorker($Context,[string]$Key,[switch]$ResetCards,[string]$ConsumeCreditId='',[string]$RequestId='') {
    if($Context.Accounts.Simulation){throw 'Live worker disabled in simulation'}
    $out=Join-Path $Context.TempRoot ([Guid]::NewGuid().ToString('N')+'.json')
    $argsList=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Context.BundleRoot 'QuotaPage.Worker.ps1'),'-OutputPath',$out,'-TargetKey',$Key,'-Epoch',[string]$Context.Epoch)
    if($ResetCards){$argsList+='-ResetCards'}
    if($ConsumeCreditId){$argsList+=@('-ConsumeCreditId',$ConsumeCreditId,'-RequestId',$RequestId)}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments=($argsList | ForEach-Object {ConvertTo-PetAccountNativeArgument ([string]$_)}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$p=New-Object Diagnostics.Process;$p.StartInfo=$psi
    try{$null=$p.Start()}catch{$p.Dispose();throw}
    return [pscustomobject]@{Process=$p;Output=$out;Generation=$Context.Epoch;Operation='ReadOnlyPage';Key=$Key;Started=[DateTimeOffset]::UtcNow}
}
function Invoke-PetQuotaPagesTick($Context) {
    if($Context.Stopped){return}
    try {
        Sync-PetQuotaPages $Context
        if($Context.Task){
            $task=$Context.Task
            $r=Receive-PetAccountSyncWorker $task
            if($r){
                $Context.Task=$null
                if($task.Generation -eq $Context.Epoch -and $task.Key -in $Context.Order){
                    if($r.ok -and $r.key -eq $task.Key -and $r.epoch -eq $task.Generation){$null=Submit-PetQuotaPage $Context $task.Key $r.data $task.Generation}
                    else{Set-PetQuotaPageError $Context $task.Key '读取未完成；如凭据过期，请登录该账号后重新保存'}
                } else {foreach($k in $Context.Order){if($k -ne $Context.LoginKey){$Context.Wanted[$k]=$true}}}
            }
        }
        Observe-PetQuotaResetTimes $Context
        $now=[DateTimeOffset]::UtcNow
        foreach($key in $Context.Order){
            if($key -ne $Context.LoginKey -and (-not $Context.NextProbe.ContainsKey($key) -or $now -ge $Context.NextProbe[$key])){$Context.Wanted[$key]=$true}
        }
        if(-not $Context.Task -and -not $Context.Accounts.Busy -and -not $Context.Accounts.NeedsRecovery -and $Context.Accounts.QuotaAvailable){
            $keys=@($Context.Order | Where-Object {$_ -ne $Context.LoginKey -and $Context.Wanted.ContainsKey($_)})
            if($keys.Count){
                $key=if($Context.ViewKey -in $keys){$Context.ViewKey}else{$keys[0]}
                $Context.Wanted.Remove($key)
                if($Context.Accounts.Simulation){
                    $fake=[pscustomobject]@{Key=$key;Generation=0};$r=New-PetAccountSimulationQuota $fake;$null=Submit-PetQuotaPage $Context $key $r.data
                }else{$Context.Task=Start-PetQuotaPageWorker $Context $key}
            }
        }
        $null=& $Context.OnChanged $Context
    } catch {if($Context.ViewKey){Set-PetQuotaPageError $Context $Context.ViewKey '额度页暂不可用，请刷新重试'}}
}
function Stop-PetQuotaPages($Context) {
    $Context.Stopped=$true;if($Context.Timer){$Context.Timer.Stop()};Save-PetQuotaPages $Context
    # Workers finish their own isolated probes. Never terminate a login exchange.
    if(-not $Context.Task -and $Context.TempRoot -and [IO.Directory]::Exists($Context.TempRoot)){
        $resolved=[IO.Path]::GetFullPath($Context.TempRoot);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^GPTQuotaPet-Pages-[a-f0-9]{32}$'){<# Retain test and probe receipts; classify without deleting. #>}
    }
}

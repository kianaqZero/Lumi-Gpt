$script:tiboMonitor=$null
. (Join-Path $PSScriptRoot 'Pet.TiboMonitor.ps1')
. (Join-Path $PSScriptRoot 'Pet.TiboMonitor.Corroboration.ps1')
. (Join-Path $PSScriptRoot 'Pet.TiboMonitor.Continuous.ps1')
. (Join-Path $PSScriptRoot 'Pet.TiboMonitor.UI.ps1')
$tiboBundleRoot=$PSScriptRoot;$tiboPetRoot=Split-Path $PSScriptRoot
$tiboRuntime=Join-Path $tiboPetRoot 'runtime\electron\electron.exe'
$tiboStatePath=Join-Path $tiboPetRoot $(if($AccountSyncSimulation){'local_state\tibo-monitor-simulation.json'}else{'local_state\tibo-monitor.json'})
if($AccountSyncSimulation -and $env:GPT_QUOTA_TIBO_TEST_ROOT){$tiboStatePath=Join-Path ([IO.Path]::GetFullPath($env:GPT_QUOTA_TIBO_TEST_ROOT)) 'state.json'}
$tiboFixture=if($AccountSyncSimulation){[string]$env:GPT_QUOTA_TIBO_TEST_FEED}else{''}
$script:tiboMonitor=New-PetTiboMonitor -BundleRoot $tiboBundleRoot -Runtime $tiboRuntime -StatePath $tiboStatePath -NoTimers:$AccountSyncSimulation -FixturePath $tiboFixture -OnChanged {
    param($ctx);$ctx.QuotaPages=$script:quotaPages;Observe-PetTiboQuotaCorroboration $ctx $script:quotaPages;Update-PetTiboMonitorPanel $ctx
} -OnNotice {param($notice);Play-PetQuotaAlertSound ([pscustomobject]@{kind='tibo';message=$notice.message})}
if($AccountSyncSimulation){$script:tiboMonitor.Enabled=$false;$script:tiboMonitor.Status='模拟测试未联网'}
if($AccountSyncSimulation){$script:tiboMonitor.OnOpenSource={param($uri);$script:tiboLastOpenedSource=$uri}}
$script:tiboMonitor.QuotaPages=$script:quotaPages
if($script:tiboMonitor.Timer){$script:tiboMonitor.Timer.Add_Tick({Observe-PetTiboQuotaCorroboration $script:tiboMonitor $script:quotaPages;Update-PetTiboMonitorPanel $script:tiboMonitor})}
$window.Add_Closed({Stop-PetTiboMonitor $script:tiboMonitor})

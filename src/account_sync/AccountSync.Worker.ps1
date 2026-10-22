param(
    [ValidateSet('Inspect','Probe','Switch','Recover','Save')][string]$Operation='Inspect',
    [string]$SharedHome, [string]$OutputPath,
    [string]$ExpectedKey, [string]$TargetKey, [int]$Generation=0,
    [string]$Label, [switch]$IdleConfirmed, [switch]$ManageDaemon
)
$ErrorActionPreference='Stop'
# This process owns the vendor library's script scope. The WPF pet never imports it.
. (Join-Path (Split-Path $PSScriptRoot) 'Lumi.Environment.ps1')
if(-not $SharedHome){$SharedHome=Get-LumiCodexHome}
$operationValue=$Operation; $outputValue=$OutputPath; $homeValue=$SharedHome
$expectedValue=$ExpectedKey; $targetValue=$TargetKey; $generationValue=$Generation
$idleValue=[bool]$IdleConfirmed; $labelValue=$Label; $daemonValue=[bool]$ManageDaemon
$stage='prepare'; $held=$false; $gate=$null; $probeHome=$null;$pending=$null;$profile=$null;$attempted=$false
. (Join-Path $PSScriptRoot 'Pet.AccountRecovery.ps1')
. (Join-Path $PSScriptRoot 'Pet.QuotaRuntime.ps1')
. (Join-Path $PSScriptRoot 'Pet.DesktopRestart.ps1')
$restartTrace=[pscustomobject]@{phase='prepare';auth_changed=$false;desktop_closed=$false;frontend_ready=$false}
function Publish-PetWorkerResult($Result) {
    $Result | Add-Member -NotePropertyName generation -NotePropertyValue $generationValue -Force
    $Result | Add-Member -NotePropertyName operation -NotePropertyValue $operationValue -Force
    $temp=$outputValue+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temp,($Result | ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp,$outputValue)
    } finally { <# Failed atomic-output leftovers are retained for classification. #> }
}
try {
    if([IO.Path]::GetFullPath($homeValue).TrimEnd('\') -ne (Get-LumiCodexHome).TrimEnd('\')){throw 'home'}
    if([string]::IsNullOrWhiteSpace($outputValue)){throw 'output'}
    if($operationValue -in @('Switch','Recover') -and -not $idleValue){$stage='idle_required';throw 'idle'}
    . (Join-Path $PSScriptRoot 'vendor\Codex-Backend-Switcher.ps1') -LibraryOnly
    $script:CodexHome=[IO.Path]::GetFullPath($homeValue)
    $script:AuthPath=Join-Path $script:CodexHome 'auth.json'
    $script:Store=Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher\profiles'
    $stage='source_configuration'; Assert-Configuration
    if($operationValue -in @('Switch','Recover','Save')){
        $gate=[Threading.Mutex]::new($false,'Local\CodexAccountSwitcher')
        try {$held=$gate.WaitOne(0)} catch [Threading.AbandonedMutexException] {$held=$true}
        if(-not $held){$stage='switcher_busy';throw 'busy'}
    }
    $stage='read_current'
    $raw=[IO.File]::ReadAllText($script:AuthPath)
    $currentKey=Get-IdentityKey $raw
    $profiles=@()
    if(Test-Path -LiteralPath $script:Store){$profiles=@(Get-Profiles)}
    $currentProfile=@($profiles | Where-Object {$_.key -eq $currentKey})
    $currentLabel=if($currentProfile.Count){[string]$currentProfile[0].label}else{'当前账号 '+$currentKey.Substring(0,6)}
    if($operationValue -ne 'Inspect' -and $currentKey -ne $expectedValue){$stage='source_changed';throw 'changed'}
    switch($operationValue){
        'Inspect' {
            $available=$false;$fingerprint=''
            try {$b=Get-DesktopBackend; $available=$true;$fingerprint=('{0}|{1}|{2}|{3}' -f $b.DesktopPid,$b.DesktopCreated,$b.BackendPid,$b.Created)} catch {}
            $runtime=Find-PetQuotaRuntime -SharedHome $script:CodexHome
            $installation=$null;if($available){try{$installation=Get-PetCodexInstallationDetection $b}catch{}}
            $safeProfiles=@($profiles | ForEach-Object {[pscustomobject]@{key=[string]$_.key;label=[string]$_.label}})
            $recoveryPath=Join-Path $script:Store 'backend-recovery.json'
            Publish-PetWorkerResult ([pscustomobject]@{ok=$true;key=$currentKey;label=$currentLabel;profiles=$safeProfiles;backend_available=$available;backend_fingerprint=$fingerprint;quota_available=[bool]$runtime;quota_fingerprint=if($runtime){$runtime.fingerprint}else{''};installation=$installation;recovery_available=[IO.File]::Exists($recoveryPath)})
        }
        'Save' {
            [void][IO.Directory]::CreateDirectory($script:Store)
            $stage='save_profile'; $null=Save-Profile $raw $labelValue
            Publish-PetWorkerResult ([pscustomobject]@{ok=$true;key=$currentKey;label=$currentLabel})
        }
        'Probe' {
            $stage='quota_runtime';$runtime=Find-PetQuotaRuntime -SharedHome $script:CodexHome;if(-not $runtime){throw 'runtime_missing'}
            $backend=$null;try{$backend=Get-DesktopBackend}catch{}
            $auth=$raw | ConvertFrom-Json
            $probeHome=Join-Path ([IO.Path]::GetTempPath()) ('GPTQuotaPet-Probe-'+[Guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($probeHome)
            [IO.File]::WriteAllText((Join-Path $probeHome 'config.toml'),"cli_auth_credentials_store = `"ephemeral`"`n",[Text.UTF8Encoding]::new($false))
            . (Join-Path $PSScriptRoot 'Quota.SelectedAccount.ps1')
            $fingerprint=if($backend){('{0}|{1}|{2}|{3}' -f $backend.DesktopPid,$backend.DesktopCreated,$backend.BackendPid,$backend.Created)}else{''}
            $stage='quota_probe'
            # Access token goes only over private stdin. No auth.json or refresh token is copied.
            $data=Invoke-PetSelectedAccountQuota -CodexHome $probeHome -CodexExecutable $runtime.path -AccessToken ([string]$auth.tokens.access_token) -AccountId ([string]$auth.tokens.account_id)
            $stage='verify_source'
            $after=Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))
            if($after -ne $currentKey -or [IO.File]::ReadAllText($script:AuthPath) -ne $raw){$stage='source_changed';throw 'changed'}
            $stage='verify_runtime';$again=Find-PetQuotaRuntime -SharedHome $script:CodexHome
            if(-not $again -or $again.fingerprint -ne $runtime.fingerprint){throw 'runtime_changed'}
            if($backend){try{$checkBackend=Get-DesktopBackend;if(('{0}|{1}|{2}|{3}' -f $checkBackend.DesktopPid,$checkBackend.DesktopCreated,$checkBackend.BackendPid,$checkBackend.Created) -ne $fingerprint){$fingerprint=''}}catch{$fingerprint=''}}
            Publish-PetWorkerResult ([pscustomobject]@{ok=[bool]$data.ok;key=$currentKey;label=$currentLabel;data=$data;backend_fingerprint=$fingerprint;quota_fingerprint=$runtime.fingerprint;code=if($data.ok){'complete'}else{'quota_unavailable'}})
        }
        {$_ -in @('Switch','Recover')} {
            $stage='select_target'
            if($operationValue -eq 'Recover'){
                $record=[IO.File]::ReadAllText((Join-Path $script:Store 'backend-recovery.json')) | ConvertFrom-Json
                if($record.home -ne $script:CodexHome){throw 'recovery_home'}
                $targetRaw=Unprotect-Text $record.encryptedAuth
                $profile=[pscustomobject]@{home=$record.home;key=(Get-IdentityKey $targetRaw);encryptedAuth=$record.encryptedAuth;label='上次切换前的账号'}
            } else {
                if($targetValue -notmatch '^[a-f0-9]{64}$'){throw 'target'}
                $targetProfiles=@($profiles | Where-Object {$_.key -eq $targetValue})
                if($targetProfiles.Count -ne 1){throw 'target'}
                $profile=$targetProfiles[0]
            }
            $stage='restart_preflight';$attempted=$true
            $pending=Start-PetDesktopRestartSwitch -Profile $profile -ExpectedKey $expectedValue -IdleConfirmed $idleValue -Trace $restartTrace -ManageDaemon $daemonValue
            Publish-PetWorkerResult ([pscustomobject]@{ok=$true;code='complete';key=$pending.TargetKey;label=$pending.Label;reconnected=$true;unchanged=$pending.unchanged;desktop_client_ready_confirmed=$pending.desktop_client_ready_confirmed;auth_exchange_confirmed=$pending.auth_exchange_confirmed;restart_performed=$pending.restart_performed})
        }
    }
} catch {
    $safeDetail=Get-PetSwitchFailureDetail $_
    if($attempted){$stage=$restartTrace.phase}
    # Never serialize exceptions: they may include credential-bearing JSON.
    $message=switch($stage){
        'quota_runtime' {'未找到本机 Codex 运行文件。安装运行文件后可独立查询额度，无需启动客户端。'}
        'idle_required' {'请先确认所有 Codex 任务已经结束。'}
        'switcher_busy' {'另一份账号切换器正在运行。关闭浮动切换按钮后重试。'}
        'source_changed' {'当前登录记录已变化，旧额度已丢弃；请刷新后重试。'}
        'reconnect_timeout' {'后端重连超时。额度保持空白，请检查 Codex；必要时手动恢复上次账号。'}
        'source_configuration' {'共享登录配置不符合文件凭据切换条件。请使用 Codex 内置登录。'}
        'restart_preflight' {'尚未关闭 Codex 或切换账号。请检查是否有其他 Codex 客户端、目标快照是否过期及当前安装是否支持自动启动。'}
        'desktop_close' {'Codex 未正常退出，已停止切号并保留当前登录。请处理退出提示，确认任务全部结束后重试。'}
        'restart_exchange' {'Codex 已退出，但账号交换未确认。请检查登录记录；不要重复切号。'}
        'desktop_launch' {'登录记录已更新，但 Codex 自动打开失败。请从原快捷方式打开 Codex，然后刷新检测。'}
        'frontend_reconnect' {'Codex 已重新打开，但前端连接尚未确认。请检查 Codex，再刷新检测；不要重复切号。'}
        'frontend_unconfirmed' {'当前账号无需切换，但 Codex 前端连接尚未确认。请先恢复 Codex 连接，再刷新检测。'}
        'switch_backend' {'切换未完成。请检查目标快照是否过期、后端是否唯一及 Codex 版本兼容性。'}
        default {'账号同步未完成。请检查 Codex 登录、已保存账号和本地后端。'}
    }
    $failure=[pscustomobject]@{ok=$false;code=$stage;message=$message}
    if($attempted -and $profile){
        $diskKey='';$diskLabel=''
        try{
            $diskKey=Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))
            $p=@($profiles|Where-Object key -eq $diskKey)
            $diskLabel=if($p.Count){[string]$p[0].label}else{'当前账号'}
        }catch{}
        $failure=New-PetSwitchFailureDisposition -Code $stage -ExpectedKey $expectedValue -TargetKey $profile.key -DiskKey $diskKey -DiskLabel $diskLabel -ExchangeReturned $restartTrace.auth_changed
    }
    $specificMessage=Get-PetSwitchFailureMessage $safeDetail $stage
    if($specificMessage){$message=$specificMessage}
    if($stage -in @('restart_preflight','desktop_close','desktop_drain','restart_exchange','desktop_launch','frontend_reconnect','frontend_unconfirmed')){$failure.message=$message}
    if($attempted -and $stage -eq 'desktop_drain'){
        $reopen=[bool](Get-PetRecoveryValue $restartTrace 'source_reopen_requested' $false)
        $failure|Add-Member -NotePropertyName source_reopen_requested -NotePropertyValue $reopen -Force
        if($reopen){$failure.message+=' 已请求重新打开原账号的 Codex，本次不再继续切换。'}
        # Keep only safe identifiers, never exception messages, arguments or stack text.
        $failure|Add-Member -NotePropertyName diagnostic_type -NotePropertyValue ($_.Exception.GetType().FullName -replace '[^A-Za-z0-9._]','') -Force
        $errorId=([string]$_.FullyQualifiedErrorId).Split(',')[0]
        $knownIds=@('InvokeMethodOnNull','PropertyNotFoundStrict','MethodInvocationException','NoProcessFoundForGivenId','ProcessCommandException','UnauthorizedAccessException','CimJob_BrokenCimSession','HRESULT 0x80041010')
        $failure|Add-Member -NotePropertyName diagnostic_id -NotePropertyValue $(if($errorId -in $knownIds){$errorId}else{'unclassified'}) -Force
    }
    $failure|Add-Member -NotePropertyName detail -NotePropertyValue $safeDetail -Force
    Publish-PetWorkerResult $failure
} finally {
    if($held){$gate.ReleaseMutex()}; if($gate){$gate.Dispose()}
    if($probeHome){
        $resolved=[IO.Path]::GetFullPath($probeHome)
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and ([IO.Path]::GetFileName($resolved) -match '^GPTQuotaPet-Probe-[a-f0-9]{32}$')){
            # Preserve token-free probe files for artifact classification; no deletion.
        }
    }
}

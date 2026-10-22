param([string]$TargetKey,[string]$OutputPath,[int]$Epoch=0,[switch]$ResetCards,[string]$ConsumeCreditId='',[string]$RequestId='')
$ErrorActionPreference='Stop'
$keyValue=$TargetKey;$outValue=$OutputPath;$epochValue=$Epoch;$probeHome=$null;$stage='prepare'
try {
    if($keyValue -notmatch '^[a-f0-9]{64}$'){throw 'identity'}
    . (Join-Path $PSScriptRoot '..\account_sync\vendor\Codex-Backend-Switcher.ps1') -LibraryOnly
    . (Join-Path (Split-Path $PSScriptRoot) 'Lumi.Environment.ps1')
    $script:CodexHome=Get-LumiCodexHome;$script:AuthPath=Join-Path $script:CodexHome 'auth.json'
    $script:Store=Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher\profiles'
    $profiles=@(Get-Profiles | Where-Object {$_.key -eq $keyValue});if($profiles.Count -ne 1){throw 'profile'}
    $record=$profiles[0];$stage='read_credentials'
    $current=[IO.File]::ReadAllText($script:AuthPath)
    $useCurrent=((Get-IdentityKey $current) -eq $keyValue)
    if($ConsumeCreditId -and (-not $useCurrent -or $RequestId -notmatch '^[a-fA-F0-9-]{36}$')){throw 'Current account required'}
    $raw=if($useCurrent){$current}else{Unprotect-Text $record.encryptedAuth}
    if((Get-IdentityKey $raw) -ne $keyValue){throw 'identity'}
    $auth=$raw|ConvertFrom-Json
    $parts=([string]$auth.tokens.access_token).Split('.')
    if($parts.Length -eq 3){
        $payload=$parts[1].Replace('-','+').Replace('_','/');$payload+='='*((4-$payload.Length%4)%4)
        $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))|ConvertFrom-Json
        if($claims.exp -and [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -le [DateTimeOffset]::UtcNow.AddSeconds(30)){$stage='credential_expired';throw 'expiry'}
    }
    . (Join-Path $PSScriptRoot '..\account_sync\Pet.QuotaRuntime.ps1')
    $stage='quota_runtime';$runtime=Find-PetQuotaRuntime -SharedHome $script:CodexHome;if(-not $runtime){throw 'runtime_missing'}
    $probeHome=Join-Path ([IO.Path]::GetTempPath()) ('GPTQuotaPet-PageProbe-'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($probeHome)
    [IO.File]::WriteAllText((Join-Path $probeHome 'config.toml'),"cli_auth_credentials_store = `"ephemeral`"`n",[Text.UTF8Encoding]::new($false))
    if($ResetCards){
        . (Join-Path $PSScriptRoot '..\account_sync\ResetCards.Normalize.ps1')
        . (Join-Path $PSScriptRoot '..\account_sync\Quota.ResetCardSnapshot.ps1')
    }else{. (Join-Path $PSScriptRoot '..\account_sync\Quota.SelectedAccount.ps1')}
    $stage='quota_probe'
    # Read-only external-token session: no shared auth write, refresh token, saved-profile update or backend restart.
    $extra=@{};if($ResetCards){$extra=@{ConsumeCreditId=$ConsumeCreditId;RequestId=$RequestId;BeforeConsume={if([IO.File]::ReadAllText($script:AuthPath) -cne $current){throw 'Login changed'};$saved=@(Get-Profiles|Where-Object {$_.key -eq $keyValue});if($saved.Count -ne 1 -or $saved[0].encryptedAuth -cne $record.encryptedAuth){throw 'Profile changed'}}}}
    $data=Invoke-PetSelectedAccountQuota -CodexHome $probeHome -CodexExecutable $runtime.path -AccessToken ([string]$auth.tokens.access_token) -AccountId ([string]$auth.tokens.account_id) @extra
    $stage='verify_runtime';$again=Find-PetQuotaRuntime -SharedHome $script:CodexHome;if(-not $again -or $again.fingerprint -ne $runtime.fingerprint){throw 'runtime_changed'}
    $stage='profile_changed';$after=@(Get-Profiles | Where-Object {$_.key -eq $keyValue})
    if($after.Count -ne 1 -or $after[0].encryptedAuth -ne $record.encryptedAuth){throw 'profile_changed'}
    if($useCurrent -and [IO.File]::ReadAllText($script:AuthPath) -ne $current){throw 'login_changed'}
    $result=[pscustomobject]@{ok=[bool]$data.ok;key=$keyValue;epoch=$epochValue;data=$data;code='complete'}
}catch{
    # Exception text may contain credentials; publish only a fixed code and message.
    $result=[pscustomobject]@{ok=$false;key=$keyValue;epoch=$epochValue;code=$stage;message='读取未完成；凭据过期时需登录该账号后重新保存'}
}finally{
    if($probeHome){
        $resolved=[IO.Path]::GetFullPath($probeHome);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^GPTQuotaPet-PageProbe-[a-f0-9]{32}$'){<# Keep token-free probe files for artifact classification; no deletion. #>}
    }
}
$tmp=$outValue+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
try{[IO.File]::WriteAllText($tmp,($result|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false));[IO.File]::Move($tmp,$outValue)}finally{<# Retain failed output leftovers for artifact classification. #>}

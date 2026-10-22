# Disposition and local status receipts. No credential access or process mutation.
function Write-PetAccountRecoveryReceipt($Context,$Result,[string]$Event){
    if($Context.Simulation -or -not $Context.RecoveryReceiptPath){return}
    try{
        $operation=[string](Get-PetRecoveryValue $Result 'operation' 'unknown')
        if($operation -notin @('Switch','Recover','Save','Probe','Inspect')){$operation='unknown'}
        $code=[string](Get-PetRecoveryValue $Result 'code' 'unknown');if($code -notmatch '^[a-z0-9_]{1,40}$'){$code='unknown'}
        $detail=[string](Get-PetRecoveryValue $Result 'detail' 'none');if($detail -notin @('desktop_other_client','desktop_backend_unavailable','desktop_process_drain_timeout','desktop_home_mismatch','desktop_launch_unsupported','desktop_changed','desktop_quit_unavailable','desktop_quit_ambiguous','desktop_close_rejected','desktop_close_timeout','restart_target_invalid','restart_target_expired','frontend_unconfirmed','source_changed','frontend_reconnect_timeout','unclassified','none')){$detail='unclassified'}
        $row=[ordered]@{at_utc=[DateTimeOffset]::UtcNow.ToString('o');event=$Event;operation=$operation;code=$code;generation=$Context.Generation;disk_status=$Context.SwitchDiskStatus;backend_detected=$Context.BackendAvailable;quota_reverified=($Event -eq 'quota_reverified');desktop_client_ready_confirmed=[bool](Get-PetRecoveryValue $Result 'desktop_client_ready_confirmed' $false);auth_exchange_confirmed=[bool](Get-PetRecoveryValue $Result 'auth_exchange_confirmed' $false)}
        if([string](Get-PetRecoveryValue $Result 'detail' 'none') -in @('desktop_shared_daemon','desktop_shared_daemon_control_failed')){$detail=[string](Get-PetRecoveryValue $Result 'detail' 'none')}
        $row.detail=$detail
        if([string](Get-PetRecoveryValue $Result 'detail' 'none') -in @('desktop_process_identity_unavailable','desktop_process_scan_failed')){$row.detail=[string]$Result.detail}
        foreach($field in @('diagnostic_type','diagnostic_id')){
            $safe=[string](Get-PetRecoveryValue $Result $field '')
            if($safe -match '^[A-Za-z][A-Za-z0-9_.]{0,149}$'){$row[$field]=$safe}
        }
        $row.source_reopen_requested=[bool](Get-PetRecoveryValue $Result 'source_reopen_requested' $false)
        [void][IO.Directory]::CreateDirectory((Split-Path $Context.RecoveryReceiptPath))
        [IO.File]::AppendAllText($Context.RecoveryReceiptPath,(($row|ConvertTo-Json -Compress)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    }catch{} # Diagnostics must not change account operation behavior.
}
function Get-PetRecoveryValue($Object,[string]$Name,$Default=$null){
    if($Object -and $Object.PSObject.Properties.Name -contains $Name){return $Object.$Name};return $Default
}
function New-PetSwitchFailureDisposition {
    param([string]$Code,[string]$ExpectedKey,[string]$TargetKey,[string]$DiskKey,[string]$DiskLabel,[bool]$ExchangeReturned)
    $valid=($DiskKey -match '^[a-f0-9]{64}$');$status='unknown'
    if($valid){$status=if($TargetKey -and $DiskKey -eq $TargetKey -and $TargetKey -ne $ExpectedKey){'target_confirmed'}elseif($DiskKey -eq $ExpectedKey){'source_confirmed'}else{'other_confirmed'}}
    $label=if($DiskLabel){$DiskLabel}else{'当前账号'}
    $message=switch($status){
        'target_confirmed' {'登录记录已切换到 '+$label+'，但 Codex 后端连接未确认。请先结束任务，再在 Codex 中重试连接或重启 Codex；桌宠会重新检测并核对额度。不要重复切换。'}
        'source_confirmed' {'未确认切换到目标账号，当前登录记录仍为 '+$label+'。请先检查 Codex 连接，再刷新检测。'}
        'other_confirmed' {'当前登录记录已变成其他账号（'+$label+'），本次切换未确认。已丢弃旧额度，请刷新检测。'}
        default {'账号操作未完成，当前登录身份暂未确认。请检查 Codex 登录与连接，再刷新检测。'}
    }
    return [pscustomobject]@{ok=$false;code=$Code;message=$message;disk_status=$status;disk_key=if($valid){$DiskKey}else{''};disk_label=if($valid){$label}else{''};auth_exchange_confirmed=($ExchangeReturned -and $status -eq 'target_confirmed');backend_connection_confirmed=$false}
}
function Request-PetAccountRecoveryRecheck($Context){
    if($Context.Stopped -or $Context.Busy){return}
    Reset-PetAccountSyncGeneration $Context
    $Context.RefreshWanted=$true;$Context.NextInspect=[DateTime]::MinValue
    if($Context.NeedsRecovery){
        Set-PetAccountSyncStatus $Context '重新检测当前登录与 Codex 后端；这不会重启 Codex，也不会再次切号。'
    }else{Set-PetAccountSyncStatus $Context '重新检测当前登录…'}
}
function Apply-PetAccountSyncInspection($Context,$Result,[int]$Sequence){
    if($Context.Busy -or $Context.Stopped -or $Result.generation -ne $Context.Generation){return $false}
    if(-not $Result.ok){
        if($Context.Key){Reset-PetAccountSyncGeneration $Context;$Context.Key=''}
        $Context.BackendAvailable=$false;$Context.BackendFingerprint='';$Context.QuotaAvailable=$false;$Context.QuotaFingerprint='';$Context.RecoveryProbePending=$false
        $null=& $Context.OnFailure ([pscustomobject]@{ok=$false;state='not_logged_in';message=$Result.message})
        Set-PetAccountSyncStatus $Context $Result.message;return $false
    }
    $oldQuotaFingerprint=$Context.QuotaFingerprint
    $oldFingerprint=$Context.BackendFingerprint
    Set-PetAccountSyncSource $Context $Result.key $Result.label
    $Context.Profiles=@($Result.profiles);$Context.BackendAvailable=[bool]$Result.backend_available;$Context.RecoveryAvailable=[bool]$Result.recovery_available
    $Context.BackendFingerprint=[string](Get-PetRecoveryValue $Result 'backend_fingerprint' '')
    $Context.QuotaAvailable=[bool](Get-PetRecoveryValue $Result 'quota_available' $Context.BackendAvailable)
    $Context.QuotaFingerprint=[string](Get-PetRecoveryValue $Result 'quota_fingerprint' '')
    if($oldQuotaFingerprint -and $oldQuotaFingerprint -ne $Context.QuotaFingerprint){$Context.Candidate=$null;$Context.RefreshWanted=$true}
    $Context.Installation=Get-PetRecoveryValue $Result 'installation' $null
    if($Context.NeedsRecovery -and $oldFingerprint -and $oldFingerprint -ne $Context.BackendFingerprint){
        $Context.Candidate=$null;$Context.RefreshWanted=$true
    }
    if($Context.NeedsRecovery){
        # Inspect adopts only the identity actually read from disk. It never exchanges it.
        $Context.RecoveryKey=$Context.Key;$Context.RecoveryLabel=$Context.Label
        $Context.RecoveryProbePending=($Context.BackendAvailable -and [bool]$Context.BackendFingerprint)
        if(-not $Context.RecoveryProbePending){
            $Context.Candidate=$null;$Context.RefreshWanted=$true
            Set-PetAccountSyncStatus $Context ('当前登录记录为 '+$Context.Label+'；尚未检测到可核对的 Codex 后端。请先在 Codex 中重试连接或重启，再刷新检测。')
        }elseif(-not $Context.Candidate){
            $Context.RefreshWanted=$true
            Set-PetAccountSyncStatus $Context ('已检测到 Codex 后端，正在重新核对 '+$Context.Label+' 的额度。')
        }
    }
    $null=Confirm-PetAccountSyncCandidate $Context $Sequence
    Update-PetAccountSyncPanel $Context;return $true
}

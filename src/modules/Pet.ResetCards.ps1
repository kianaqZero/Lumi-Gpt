# On-demand metadata and explicit, idempotent current-account redemption.
$script:lumiResetCards=[pscustomobject]@{Task=$null;Key='';Epoch=-1;Packet=$null;LastRequested=[DateTimeOffset]::MinValue;ConsumeTask=$null;OperationMessage='';Attempt=$null}
function Request-LumiResetCards($Context,[switch]$Force) {
    Sync-PetQuotaPages $Context
    $c=$script:lumiResetCards;$now=[DateTimeOffset]::UtcNow
    if($c.Task -or $c.ConsumeTask -or ($now-$c.LastRequested).TotalSeconds -lt 2){return}
    if(-not $Force -and $c.Key -eq $Context.LoginKey -and $c.Packet -and ($now-$c.LastRequested).TotalSeconds -lt 60){return}
    if($Context.Accounts.Busy -or $Context.Accounts.NeedsRecovery -or $Context.LoginKey -notmatch '^[a-f0-9]{64}$'){return}
    if($c.Key -cne $Context.LoginKey){$c.OperationMessage=''}
    $c.Key=$Context.LoginKey;$c.Epoch=$Context.Epoch;$c.LastRequested=$now
    $c.Packet=[pscustomobject]@{state='reading';available_count=$null;details_known=$false;cards=@();checked_at=$null}
    if($Context.Accounts.Simulation){
        $c.Packet=[pscustomobject]@{state='read';available_count=0;details_known=$true;cards=@();checked_at=$now.ToString('o');simulation=$true};return
    }
    try{$c.Task=Start-PetQuotaPageWorker $Context $c.Key -ResetCards}catch{$c.Packet=[pscustomobject]@{state='read_failed';available_count=$null;details_known=$false;cards=@();checked_at=$null}}
}
function Get-LumiResetCardsPacket($Context) {
    if(-not $Context){return $null};Sync-PetQuotaPages $Context;$c=$script:lumiResetCards
    Complete-LumiResetCardConsume $Context
    if($c.Task){
        $r=Receive-PetAccountSyncWorker $c.Task
        if($r){
            $task=$c.Task;$c.Task=$null
            if($task.Key -eq $Context.LoginKey -and $task.Generation -eq $Context.Epoch -and $r.ok -and $r.key -eq $task.Key -and $r.epoch -eq $task.Generation -and $r.data.PSObject.Properties['reset_cards']){$c.Packet=$r.data.reset_cards}
            else{$c.Packet=[pscustomobject]@{state='read_failed';available_count=$null;details_known=$false;cards=@();checked_at=$null}}
        }
    }
    if(($Context.Accounts.Busy -and -not $c.ConsumeTask) -or $Context.Accounts.NeedsRecovery){return [ordered]@{account_label='账号状态待确认';key='';state='account_changing';available_count=$null;details_known=$false;cards=@();checked_at=$null;redemption_eligibility='not_checked'}}
    $p=if($c.Key -eq $Context.LoginKey -and $c.Epoch -eq $Context.Epoch){$c.Packet}else{$null}
    return [ordered]@{busy=[bool]$c.ConsumeTask;operation_message=$(if($c.Key -ceq $Context.LoginKey){$c.OperationMessage}else{''});account_label=[string]$Context.Accounts.Label;key=[string]$Context.LoginKey;state=if($p){[string]$p.state}else{'not_read'};available_count=if($p){$p.available_count}else{$null};details_known=if($p){[bool]$p.details_known}else{$false};cards=@(if($p){$p.cards});checked_at=if($p){$p.checked_at}else{$null};redemption_eligibility='not_checked'}
}

function Request-LumiResetCardConsume($Context,$Command) {
    $c=$script:lumiResetCards
    Sync-PetQuotaPages $Context
    if($Context.Accounts.Simulation){$c.OperationMessage='模拟：未调用真实重置卡接口';return}
    if($c.Task -or $c.ConsumeTask -or $Context.Accounts.Busy -or $Context.Accounts.NeedsRecovery){return}
    if($Command.key -cne $Context.LoginKey -or $c.Key -cne $Context.LoginKey -or $c.Epoch -ne $Context.Epoch){throw 'Reset card account changed'}
    if($Command.request_id -notmatch '^[a-fA-F0-9-]{36}$'){throw 'Invalid reset attempt'}
    $rows=@($c.Packet.cards|Where-Object {$_.id -ceq $Command.credit_id -and $_.redeemable})
    if($rows.Count -ne 1){throw 'Reset card no longer available'}
    $attemptPath=Join-Path $script:live2dQuotaBundleRoot 'local_state/reset-card-attempt.json'
    $old=$null;try{if(Test-Path -LiteralPath $attemptPath){$old=[IO.File]::ReadAllText($attemptPath)|ConvertFrom-Json}}catch{}
    $request=if($old -and $old.key -ceq $Command.key -and $old.credit_id -ceq $Command.credit_id -and $old.outcome -eq 'unknown'){$old.request_id}else{$Command.request_id}
    $c.Attempt=[pscustomobject]@{key=$Command.key;credit_id=$Command.credit_id;request_id=$request;outcome='unknown';at=[DateTimeOffset]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($attemptPath,($c.Attempt|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $c.ConsumeTask=Start-PetQuotaPageWorker $Context $Command.key -ResetCards -ConsumeCreditId $Command.credit_id -RequestId $request
    $Context.Accounts.Busy=$true;$c.OperationMessage='正在使用并核对结果，请稍候…'
}
function Complete-LumiResetCardConsume($Context) {
    $c=$script:lumiResetCards;if(-not $c.ConsumeTask){return}
    $r=$null;$task=$c.ConsumeTask
    if(([DateTimeOffset]::UtcNow-$task.Started).TotalSeconds -gt 90){
        try{if(-not $task.Process.HasExited){$task.Process.Kill()};$task.Process.Dispose()}catch{}
        $r=[pscustomobject]@{ok=$false}
    }else{$r=Receive-PetAccountSyncWorker $task}
    if(-not $r){return}
    $c.ConsumeTask=$null;$Context.Accounts.Busy=$false
    $outcome=if($r.PSObject.Properties['data'] -and $r.data -and $r.data.PSObject.Properties['consume_outcome']){[string]$r.data.consume_outcome}else{''}
    if($task.Key -cne $Context.LoginKey -or $task.Generation -ne $Context.Epoch){$outcome=''}
    switch($outcome){
        'reset' {$c.OperationMessage='重置成功，已更新卡片和额度。'}
        'alreadyRedeemed' {$c.OperationMessage='这次请求此前已成功，无需重复使用。'}
        'nothingToReset' {$c.OperationMessage='当前没有符合重置条件的额度，未消耗卡片。'}
        'noCredit' {$c.OperationMessage='服务端确认没有可用重置卡。'}
        default {$c.OperationMessage='使用结果尚未确认。请刷新核对；重试同一卡片将沿用原请求，避免重复消耗。'}
    }
    $c.Attempt.outcome=if($outcome){$outcome}else{'unknown'}
    $attemptPath=Join-Path $script:live2dQuotaBundleRoot 'local_state/reset-card-attempt.json'
    [IO.File]::WriteAllText($attemptPath,($c.Attempt|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if($r.ok -and $task.Key -ceq $Context.LoginKey -and $task.Generation -eq $Context.Epoch){$c.Packet=$r.data.reset_cards;$null=Submit-PetQuotaPage $Context $task.Key $r.data $task.Generation}
    $Context.Accounts.RefreshWanted=$true;$c.LastRequested=[DateTimeOffset]::MinValue
    Request-LumiResetCards $Context -Force
}

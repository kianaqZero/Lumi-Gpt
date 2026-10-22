# Only the current logged-in identity can produce a low-quota alert.
function Test-PetLoginLowQuota($Context,[string]$Key,$Data,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    Sync-PetQuotaPages $Context
    if($Context.Stopped -or $Context.Accounts.Busy -or $Context.Accounts.NeedsRecovery -or -not $Data.ok -or $Key -ne $Context.LoginKey){return}
    foreach($name in @('session','weekly')){
        $w=$Data.$name
        if(-not $w -or $null -eq $w.remaining_percent -or [double]$w.remaining_percent -ge 15){continue}
        $cycle=if($w.resets_at){[string][long]$w.resets_at}else{'unknown'}
        $id=$Key+'|'+$name+'|low:'+$cycle
        if($Context.Ledger.ContainsKey($id)){continue}
        $label=$Context.Accounts.Label;$windowLabel=if($name -eq 'weekly'){'周'}else{'小时窗口'}
        $remaining=[Math]::Max([double]0,[Math]::Min([double]100,[double]$w.remaining_percent))
        $message=('{0} 的{1}额度只剩 {2:0.#}%，快见底啦，请留意后续使用。' -f $label,$windowLabel,$remaining)
        $notice=[pscustomobject]@{id=$id;key=$Key;label=$label;window=$name;window_label=$windowLabel;deadline=if($w.resets_at){[long]$w.resets_at}else{0};kind='low';at=$Now.ToString('o');message=$message}
        $Context.Ledger[$id]='low';$Context.History=@($Context.History | Select-Object -Last 49)+@($notice)
        Save-PetQuotaPages $Context;$null=& $Context.OnNotice $notice
    }
}
function Play-PetQuotaAlertSound($Notice) {
    if(-not $script:quotaPages.SoundEnabled){return}
    try{
        $name=if($Notice.kind -eq 'low'){'quota-low.wav'}else{'quota-reset.wav'}
        $file=Join-Path $PSScriptRoot ('sounds\'+$name)
        if([IO.File]::Exists($file)){
            $script:quotaSoundPlayer.SoundLocation=$file;$script:quotaSoundPlayer.Load();$script:quotaSoundPlayer.Play()
        }elseif($Notice.kind -eq 'low'){[Media.SystemSounds]::Exclamation.Play()}else{[Media.SystemSounds]::Asterisk.Play()}
    }catch{}
}

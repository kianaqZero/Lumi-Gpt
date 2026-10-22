function Update-PetQuotaPagesUi($Context) {
    if(-not $Context){return}
    Sync-PetQuotaPages $Context
    $selector=X 'QuotaPageSelect';$tag=(@($Context.Profiles | ForEach-Object {$_.key+'|'+$_.label})) -join ';'
    $script:quotaPageSelecting=$true
    try {
        if($selector.Tag -ne $tag){$selector.Items.Clear();foreach($p in $Context.Profiles){[void]$selector.Items.Add($p)};$selector.Tag=$tag}
        $index=[Array]::IndexOf([object[]]$Context.Order,$Context.ViewKey)
        $selector.SelectedIndex=$index
    }finally{$script:quotaPageSelecting=$false}
    (X 'QuotaPageIndex').Text=if($index -ge 0){'{0}/{1}' -f ($index+1),$Context.Order.Count}else{'—/'+$Context.Order.Count}
    (X 'QuotaPagePrev').IsEnabled=($Context.Order.Count -gt 1);(X 'QuotaPageNext').IsEnabled=($Context.Order.Count -gt 1)
    (X 'QuotaFollowBtn').Content=if($Context.FollowLogin){'跟随登录'}else{'回到当前'}
    $isCurrent=($Context.ViewKey -eq $Context.LoginKey)
    $profile=@($Context.Profiles | Where-Object {$_.key -eq $Context.ViewKey})
    $viewLabel=if($profile.Count){[string]$profile[0].label}else{'当前账号（未绑定）'}
    $entry=$Context.Cache[$Context.ViewKey]
    $data=if($isCurrent -and $Context.LoginAwaiting){$null}elseif($entry){$entry.data}elseif($isCurrent){$Context.CurrentQuota}else{$null}
    $errorMessage=if($entry){[string]$entry.error}else{''}
    $message='查看 '+$viewLabel+' · 登录 '+$Context.Accounts.Label
    if($Context.Accounts.Busy){$message+=' · 账号操作中'}
    $freshness=if($errorMessage){'缓存 · '+$errorMessage}elseif($data){'更新 '+$data.checked_at}else{'读取对应账号额度…'}
    if($entry -and $entry.at -and -not $errorMessage -and ([DateTimeOffset]::UtcNow-[DateTimeOffset]::Parse($entry.at)).TotalMinutes -ge 5){$freshness='缓存 '+$entry.data.checked_at+' · 等待刷新'}
    if(-not $Context.Order.Count){$freshness='在“账号”中保存账号后自动加入分页'}
    if($Context.Accounts.NeedsRecovery -and $isCurrent){$data=$null;$freshness='账号切换未确认，请在“账号”中检查或恢复'}
    $statusText.Text=$message;$statusText.ToolTip=$message
    $lastUpdate.Text=$freshness;$lastUpdate.ToolTip=$freshness
    $stamp=$Context.ViewKey+'|'+$Context.LoginAwaiting+'|'+($data|ConvertTo-Json -Depth 8 -Compress)+'|'+$errorMessage
    if($stamp -eq $Context.LastUi){return};$Context.LastUi=$stamp
    $planText.Text=if($data){([string]$data.plan).ToUpper()}else{'--'}
    foreach($name in @('session','weekly')){
        $w=if($data){$data.$name}else{$null}
        if($name -eq 'session'){$bar=$sessionBar;$pct=$sessionPct;$reset=$sessionReset}else{$bar=$weeklyBar;$pct=$weeklyPct;$reset=$weeklyReset}
        $bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty,$null)
        if($w){$bar.Value=[double]$w.remaining_percent;$pct.Text=('{0:0.#}%' -f $w.remaining_percent);$reset.Text='重置 '+$w.reset_local}
        else{$bar.Value=0;$pct.Text='--%';$reset.Text=if($data){'当前未返回该额度窗口'}else{'等待对应账号额度'}}
    }
}
$script:quotaActiveNotice=$null
function Show-PetQuotaNotice($Notice) {
    $script:quotaNoticeQueue.Enqueue($Notice)
    if($script:quotaNoticeTimer.IsEnabled){return}
    Show-NextPetQuotaNotice
}
function Show-NextPetQuotaNotice {
    if(-not $script:quotaNoticeQueue.Count){$script:quotaActiveNotice=$null;(X 'QuotaNotice').Visibility='Collapsed';$script:quotaNoticeTimer.Stop();return}
    $n=$null
    while($script:quotaNoticeQueue.Count){
        $pending=$script:quotaNoticeQueue.Dequeue()
        if($pending.kind -eq 'low' -and $pending.key -ne $script:accountSyncContext.Key){continue}
        $n=$pending;break
    }
    if(-not $n){$script:quotaActiveNotice=$null;(X 'QuotaNotice').Visibility='Collapsed';$script:quotaNoticeTimer.Stop();return}
    $script:quotaActiveNotice=$n
    (X 'QuotaNoticeText').Text=$n.message
    Play-PetQuotaAlertSound $n
    (X 'QuotaNotice').ToolTip=$n.message;(X 'QuotaNotice').Visibility='Collapsed'
    $script:quotaNoticeTimer.Start()
}
function Show-PetQuotaNoticeHistory {
    $w=New-Object Windows.Window;$w.Title='额度提醒记录';$w.Width=540;$w.Height=360;$w.Owner=$window;$w.FontFamily='Microsoft YaHei UI';$w.Background='#F5FAF8';$w.Resources.MergedDictionaries.Add($window.Resources)
    $scroller=New-Object Windows.Controls.ScrollViewer;$stack=New-Object Windows.Controls.StackPanel;$stack.Margin='18'
    $items=@($script:quotaPages.History)
    if(-not $items.Count){$items=@([pscustomobject]@{at='';message='暂无额度重置提醒。小时窗口按服务端实际返回的时长显示。'})}
    [Array]::Reverse($items)
    foreach($n in $items){$t=New-Object Windows.Controls.TextBlock;$t.Text=$n.at+"`n"+$n.message;$t.TextWrapping='Wrap';$t.Margin='0,0,0,16';[void]$stack.Children.Add($t)}
    $scroller.Content=$stack;$w.Content=$scroller;$w.Show()
}

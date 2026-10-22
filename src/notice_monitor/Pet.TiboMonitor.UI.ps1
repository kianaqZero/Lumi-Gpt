# Pure presentation of existing evidence. No state mutation, network, quota claims or notices.
function Get-PetTiboLegacyDisplayState($Context,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
 $latest=Get-PetTiboValue $Context.State 'latest';$watch=Get-PetTiboValue $Context.State 'corroboration'
 $result=[pscustomobject]@{code='no_post';judgment='暂无可核对的新重置消息';post_label='';expected_until=$null;local_message='';official_completion=$false}
 if(-not $latest){
  $local=Get-PetTiboValue $watch 'latest_assessment';$fresh=$false
  if($local -and $watch.status -eq 'suspected'){try{$age=($Now-[DateTimeOffset]::Parse($local.at)).TotalSeconds;$fresh=$age -ge -30 -and $age -lt 86400}catch{}}
  if($fresh){$result.code='locally_observed';$result.judgment='本机已观测到提前恢复，疑似全球重置；官方仍待核对';$result.local_message=$local.message}
  return $result
 }
 $proof=Get-PetTiboValue $latest 'verification';$originalChecked=$proof -and $proof.status -eq 'primary_confirmed';$suffix=if($originalChecked){' · 原文已核对'}else{' · 原文待核对'}
 $result.post_label=$latest.label
 $at=$null;try{$at=[DateTimeOffset]::Parse($latest.at)}catch{}
 if($latest.kind -eq 'mentioned'){$result.code='mentioned';$result.judgment='检测到重置相关消息，完成状态和适用账号仍待核实';$result.post_label='重置相关动态'+$suffix
 }elseif($latest.kind -eq 'planned'){
  $result.code='planned';$result.judgment='有新的重置预告，尚未核实完成';$result.post_label='重置预告'+$suffix
  $expired=$false
  if($at -and $latest.text -match '(?i)^Landing\s+(?:within|in)\s+(?:the\s+)?next\s+(\d+)\s+(hours?|minutes?)\s*[.!]*$'){
   $amount=[int]$Matches[1];$hours=$Matches[2] -match '^hour'
   if($amount -gt 0 -and $amount -le $(if($hours){48}else{2880})){
    $until=if($hours){$at.AddHours($amount)}else{$at.AddMinutes($amount)};$result.expected_until=$until.ToString('o');$expired=$Now -ge $until
   }
  }elseif($at){$expired=($Now-$at).TotalHours -ge 24}
  if($expired){$result.code='expired_preparation';$result.judgment='旧预告已过期，目前没有取得可确认的完成消息';$result.post_label='历史预告'+$suffix}
 }elseif($latest.kind -eq 'in_progress'){
  $result.code='in_progress';$result.judgment='原帖称重置正在推进，完成结果待核对'
  if($at -and ($Now-$at).TotalHours -ge 24){$result.code='old_progress';$result.judgment='尚未取得后续完成消息';$result.post_label='历史进度消息'+$suffix}
 }elseif($latest.kind -eq 'completed'){
  $result.code='completed_unverified';$result.judgment='收到完成消息，官方完成状态待核对';$result.post_label='重置完成消息'+$suffix
  if($originalChecked){$result.code='completed_post_checked';$result.judgment='已核对完成原文，适用范围以原帖为准'}
  if($originalChecked -and ((Get-PetTiboValue $proof 'global' $false) -or (Get-PetTiboValue $proof 'all_accounts' $false))){$result.code='official_completed';$result.judgment='官方原帖已确认本轮全球重置完成';$result.official_completion=$true
   if($at -and ($Now-$at).TotalHours -ge 24){$result.code='historical_official_completion';$result.judgment='历史全球重置完成记录，尚无更新的完成公告'}
  }
 }
 # A local observation is evidence of recovery, not an official announcement. Tie it to the
 # latest preparation's time range; a previous cycle must not overwrite a newer announcement.
 $assessment=Get-PetTiboValue $watch 'latest_assessment';$relevant=$false
 if($assessment -and $at){try{$observed=[DateTimeOffset]::Parse($assessment.at);$relevant=$observed -ge $at.AddMinutes(-2) -and ($Now-$observed).TotalHours -lt 24 -and $observed -le $Now.AddSeconds(30)}catch{}}
 if($relevant -and $watch.status -eq 'suspected' -and (-not $result.official_completion -or $at -lt $observed.AddMinutes(-2))){$result.code='locally_observed';$result.judgment='本机已观测到提前恢复，疑似全球重置；官方仍待核对';$result.local_message=$assessment.message;$result.official_completion=$false}
 return $result
}


. (Join-Path $PSScriptRoot 'Pet.TiboMonitor.Site.ps1')
function Update-PetTiboMonitorPanel($Context,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow){
 if(-not $Context.Panel){return}
 $site=Get-PetTiboValue $Context.State 'site';$f=Get-PetTiboValue $site 'forecast';$timeline=Get-PetTiboValue $site 'timeline';$latest=Get-PetTiboValue $Context.State 'latest'
 $display=Get-PetTiboDisplayState $Context $Now
 $headlines=@{no_post='暂无新重置预告';mentioned='可能重置';planned='即将重置';expired_preparation='上次预告已过期';in_progress='额度重置正在推进';old_progress='等待后续完成消息';completed_unverified='可能已完成重置（待核实）';completed_post_checked='重置完成';official_completed='重置完成';historical_official_completion='上次已确认的重置';locally_observed='本机观测到额度恢复';site_completed='社区记录称重置完成';site_history='上次社区记录的重置';site_pending='可能已完成重置（待核实）'}
 $account=Get-LumiAnnouncementAccountText $Context $Now
 $forecastText='预测暂不可用；公告和账号实测继续独立检查。'
 if($f){
  $confidence=switch($f.confidence){'high'{'高'}'medium'{'中'}default{'低'}}
  $cached=(-not (Test-LumiSiteFresh $f $Now)) -or [bool](Get-PetTiboValue $site 'forecast_error')
  if((Test-LumiSiteFresh $f $Now)){$forecastText='未来 24 小时  '+$f.p24+'%    |    未来 48 小时  '+$f.p48+'%'}else{$forecastText='预测已过期，暂不显示旧概率。'}
  $forecastText+="`n置信度："+$confidence+$(if($cached){' · 缓存'}else{''})+"`n计算时间："+[DateTimeOffset]::Parse($f.updated_at).ToLocalTime().ToString('MM-dd HH:mm')+"`n社区实验预测，不是官方承诺。"
 }
 $records=@(Get-PetTiboValue $timeline 'events' @());$recordText='尚未取得社区重置记录。'
 if($records.Count){$lines=@();foreach($r in @($records|Select-Object -First 3)){$lines+=@([DateTimeOffset]::Parse($r.at).ToLocalTime().ToString('yyyy-MM-dd HH:mm')+"`n"+$r.summary)};$recordText=$lines -join "`n`n";if(-not (Test-LumiSiteFresh $timeline $Now) -or (Get-PetTiboValue $site 'timeline_error')){$recordText='历史缓存 · '+$recordText}}
 $detail='公告、社区记录和本账号额度分别核对。来源可能延迟或漏帖。'
 $checked=Get-PetTiboValue $Context.State 'checked_at';if($checked){$detail+="`n上次成功检查："+[DateTimeOffset]::Parse($checked).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')}
 if($display.expected_until){$detail+="`n预告时间上限："+[DateTimeOffset]::Parse($display.expected_until).ToLocalTime().ToString('MM-dd HH:mm')}
 if($latest){$detail+="`n`n最近相关原文：`n"+$latest.text}
 $detail+="`n`n正常每 5 分钟检查；所有手动检查也遵守至少 60 秒间隔及服务端退避。"
 $stamp=@($Context.Status,$Context.Enabled,$display.code,$display.judgment,$forecastText,$account,$recordText,$detail) -join '|'
 if($stamp -ne $Context.PanelStamp){
  $Context.PanelStamp=$stamp;$Context.PanelStatus.Text=$(if($Context.FixturePath){'演示 · '}else{''})+$Context.Status+' · Tibo / Codex Reset'
  $Context.PanelSummary.Text=$headlines[$display.code];$Context.PanelSubline.Text=$display.judgment
  $Context.PanelForecast.Text=$forecastText;$Context.PanelAccount.Text=$account;$Context.PanelTimeline.Text=$recordText;$Context.PanelDetail.Text=$detail
 }
 $Context.PanelCheck.IsChecked=$Context.Enabled
 $Context.PanelRefresh.IsEnabled=$Context.Enabled -and -not $Context.Pending -and $Now -ge $Context.LastAttempt.AddSeconds(60) -and $Now -ge $Context.RetryUntil
 $Context.PanelSource.IsEnabled=($null -ne $latest -or $records.Count -gt 0)
 if(Get-Command Set-LumiWindowLanguage -ErrorAction SilentlyContinue){Set-LumiWindowLanguage $Context.Panel}
}
function Open-PetTiboSource($Context,[switch]$Latest,[string]$Id=''){
 $item=if($Latest){Get-PetTiboValue $Context.State 'latest'}elseif($Id -match '^[0-9]{15,22}$'){@(Get-PetTiboValue $Context.State 'history' @())|Where-Object id -eq $Id|Select-Object -Last 1}else{$Context.Active}
 if($Latest){$site=Get-PetTiboValue $Context.State 'site';$records=@(Get-PetTiboValue (Get-PetTiboValue $site 'timeline') 'events' @());if($records.Count -and (Test-PetTiboSourceUrl $records[0].url) -and (-not $item -or [DateTimeOffset]::Parse($records[0].at) -ge [DateTimeOffset]::Parse($item.at))){$item=$records[0]}}
 if($item -and (Test-PetTiboSourceUrl ([string]$item.url))){$null=& $Context.OnOpenSource ([string]$item.url)}
}
function New-LumiNoticeText([string]$Text,[double]$Size=13){$t=[Windows.Controls.TextBlock]::new();$t.Text=$Text;$t.FontSize=$Size;$t.TextWrapping='Wrap';$t.LineHeight=$Size*1.65;return $t}
function New-LumiNoticeCard($Parent,[string]$Title,$Text,[bool]$Emphasized=$false){
 $card=[Windows.Controls.Border]::new();$card.Background=if($Emphasized){'#EEE5F7'}else{'#FFFDFF'};$card.BorderBrush='#D4C5E1';$card.BorderThickness='1';$card.CornerRadius='16';$card.Padding='16';$card.Margin='0,0,0,12'
 $stack=[Windows.Controls.StackPanel]::new();if($Title){$titleBlock=New-LumiNoticeText $Title 12;$titleBlock.Foreground='#695078';$titleBlock.Margin='0,0,0,8';[void]$stack.Children.Add($titleBlock)}
 [void]$stack.Children.Add($Text);$card.Child=$stack;[void]$Parent.Children.Add($card);return $stack
}
function Show-PetTiboMonitorPanel($Context){
 if($Context.Panel){$Context.Panel.Show();$Context.Panel.Activate();return}
 $w=[Windows.Window]::new();$w.Title='Lumi · 重置公告';$w.Width=620;$w.Height=[Math]::Min(740,[Windows.SystemParameters]::WorkArea.Height-70);$w.MinWidth=460;$w.MinHeight=380;$w.Owner=$window;$w.FontFamily='Microsoft YaHei UI';$w.Background='#F8F4FC';$w.Foreground='#30203F';$w.Resources.MergedDictionaries.Add($window.Resources)
 $style=[Windows.Style]::new([Windows.Controls.Button]);$template=[Windows.Markup.XamlReader]::Parse('<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Button"><Border Background="{TemplateBinding Background}" BorderBrush="#B9A2CD" BorderThickness="1" CornerRadius="10" Padding="11,7"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#E8DAF4"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger></ControlTemplate.Triggers></ControlTemplate>');$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::TemplateProperty,$template));$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::BackgroundProperty,[Windows.Media.BrushConverter]::new().ConvertFromString('#F3ECF9')));$style.Setters.Add([Windows.Setter]::new([Windows.Controls.Control]::ForegroundProperty,[Windows.Media.BrushConverter]::new().ConvertFromString('#402654')));$w.Resources.Add([Windows.Controls.Button],$style)
 $dock=[Windows.Controls.DockPanel]::new();$dock.Margin='18';$bar=[Windows.Controls.WrapPanel]::new();$bar.Margin='0,10,0,0';[Windows.Controls.DockPanel]::SetDock($bar,'Bottom');[void]$dock.Children.Add($bar)
 $check=[Windows.Controls.CheckBox]::new();$check.Content='开启公告监测';$check.Margin='0,8,14,0';[void]$bar.Children.Add($check)
 $refresh=[Windows.Controls.Button]::new();$refresh.Content='检查更新';$refresh.Margin='0,0,8,0';[void]$bar.Children.Add($refresh)
 $source=[Windows.Controls.Button]::new();$source.Content='查看原帖';[void]$bar.Children.Add($source)
 $status=New-LumiNoticeText '' 12;$status.Margin='0,0,0,12';[Windows.Controls.DockPanel]::SetDock($status,'Top');[void]$dock.Children.Add($status)
 $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.VerticalScrollBarVisibility='Auto';$scroll.HorizontalScrollBarVisibility='Disabled';$stack=[Windows.Controls.StackPanel]::new();$stack.Margin='0,0,10,0';$scroll.Content=$stack;[void]$dock.Children.Add($scroll)
 $headline=New-LumiNoticeText '' 23;$headline.FontWeight='SemiBold';$copy=New-LumiNoticeCard $stack '' $headline $true;$subline=New-LumiNoticeText '' 12;$subline.Margin='0,6,0,0';[void]$copy.Children.Add($subline)
 $forecast=New-LumiNoticeText '' 15;$null=New-LumiNoticeCard $stack '社区预测' $forecast
 $account=New-LumiNoticeText '' 13;$null=New-LumiNoticeCard $stack '本账号实测' $account
 $records=New-LumiNoticeText '' 12;$records.Tag='LumiExternalContent';$null=New-LumiNoticeCard $stack '最近重置记录 · 社区整理' $records
 $credit=New-LumiNoticeText '' 12;$credit.Margin='0,0,0,12';$credit.Inlines.Add([Windows.Documents.Run]::new('数据：'));$link=[Windows.Documents.Hyperlink]::new([Windows.Documents.Run]::new('codex-reset.com'));$link.Add_Click({$null=& $Context.OnOpenSource 'https://codex-reset.com/zh/'}.GetNewClosure());$credit.Inlines.Add($link);[void]$stack.Children.Add($credit)
 $expander=[Windows.Controls.Expander]::new();$expander.Header='原文与监测详情';$text=New-LumiNoticeText '' 12;$text.Margin='0,10,0,8';$expander.Content=$text;[void]$stack.Children.Add($expander);$w.Content=$dock
 $Context.Panel=$w;$Context.PanelStatus=$status;$Context.PanelSummary=$headline;$Context.PanelSubline=$subline;$Context.PanelForecast=$forecast;$Context.PanelAccount=$account;$Context.PanelTimeline=$records;$Context.PanelDetail=$text;$Context.PanelCheck=$check;$Context.PanelRefresh=$refresh;$Context.PanelSource=$source;$Context.PanelStamp=''
 $refresh.Add_Click({Request-PetTiboRefresh $Context}.GetNewClosure());$source.Add_Click({Open-PetTiboSource $Context -Latest}.GetNewClosure());$check.Add_Click({Set-PetTiboMonitorEnabled $Context ($check.IsChecked -eq $true)}.GetNewClosure())
 $w.Add_Closed({foreach($name in @('Panel','PanelStatus','PanelSummary','PanelSubline','PanelForecast','PanelAccount','PanelTimeline','PanelDetail','PanelCheck','PanelRefresh','PanelSource')){$Context.$name=$null}}.GetNewClosure())
 Update-PetTiboMonitorPanel $Context;$w.Show()
}

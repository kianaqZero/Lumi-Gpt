. (Join-Path $PSScriptRoot 'Pet.AccountRecovery.ps1')
# Independent account module. Existing state, drag, zoom and motion code stay in the pet.
function New-PetAccountSyncContext {
    param([string]$BundleRoot,[string]$SharedHome,$Owner,[switch]$Simulation,[switch]$NoTimers,
          [scriptblock]$OnClear={},[scriptblock]$OnStatus={},[scriptblock]$OnQuota={},
          [scriptblock]$OnRefresh={},[scriptblock]$OnFailure={})
    $c=[pscustomobject]@{
        BundleRoot=$BundleRoot;SharedHome=$SharedHome;Owner=$Owner;Simulation=[bool]$Simulation
        OnClear=$OnClear;OnStatus=$OnStatus;OnQuota=$OnQuota;OnRefresh=$OnRefresh;OnFailure=$OnFailure
        Generation=0;Key='';Label='账号';Profiles=@();BackendAvailable=$false;QuotaAvailable=$false;QuotaFingerprint='';RecoveryAvailable=$false
        Busy=$false;NeedsRecovery=$false;Stopped=$false;InspectTask=$null;WorkTask=$null;Candidate=$null
        InspectSequence=0;CandidateAfterInspectSequence=0
        RefreshWanted=$true;NextInspect=[DateTime]::MinValue;Timer=$null;Panel=$null;Controls=$null
        Status='等待账号检测';Diagnostic='';TempRoot='';SimulationPrevious='';Installation=$null;ManageDaemon=$false
        RecoveryReceiptPath='';RecoveryKey='';RecoveryLabel='';RecoveryProbePending=$false;BackendFingerprint='';SwitchDiskStatus='none'
    }
    if($Simulation){
        $c.Profiles=@([pscustomobject]@{key=('a'*64);label='演示账号 A'},[pscustomobject]@{key=('b'*64);label='演示账号 B'})
        $c.BackendAvailable=$true;$c.QuotaAvailable=$true
        Set-PetAccountSyncSource $c ('a'*64) '演示账号 A'
    } else {
        $c.TempRoot=Join-Path ([IO.Path]::GetTempPath()) ('GPTQuotaPet-Sync-'+[Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($c.TempRoot)
        if(-not $NoTimers){$c.RecoveryReceiptPath=Join-Path (Split-Path $BundleRoot) 'evidence/account-recovery.jsonl'}
    }
    if(-not $NoTimers){
        $timer=New-Object Windows.Threading.DispatcherTimer
        $timer.Interval=[TimeSpan]::FromMilliseconds(250)
        $tick={Invoke-PetAccountSyncTick $c}.GetNewClosure()
        $timer.Add_Tick($tick);$c.Timer=$timer;$timer.Start()
    }
    return $c
}
function Set-PetAccountSyncStatus($Context,[string]$Message) {
    $Context.Status=$Message
    $null=& $Context.OnStatus $Context.Label $Message
    Update-PetAccountSyncPanel $Context
}
function Reset-PetAccountSyncGeneration($Context) {
    $Context.Generation++;$Context.Candidate=$null
    $null=& $Context.OnClear
}
function Set-PetAccountSyncSource($Context,[string]$Key,[string]$Label) {
    if($Context.Key -ne $Key){Reset-PetAccountSyncGeneration $Context;$Context.Key=$Key;$Context.RefreshWanted=$true}
    $Context.Label=$Label
}
function Test-PetAccountSyncResult($Context,$Result) {
    return (-not $Context.Stopped -and -not $Context.Busy -and -not $Context.NeedsRecovery -and
        $Result.ok -and $Result.generation -eq $Context.Generation -and
        $Result.key -eq $Context.Key -and -not [string]::IsNullOrWhiteSpace($Context.Key))
}
function Submit-PetAccountSyncQuota($Context,$Result) {
    if(-not (Test-PetAccountSyncResult $Context $Result)){return $false}
    $null=& $Context.OnQuota $Result.data $Context.Label
    Set-PetAccountSyncStatus $Context $(if($Context.Simulation){'模拟额度 · 未访问真实账号'}else{'额度已同步'})
    return $true
}
function Confirm-PetAccountSyncCandidate($Context,[int]$InspectSequence) {
    if(-not $Context.Candidate -or $InspectSequence -le $Context.CandidateAfterInspectSequence){return $false}
    $candidate=$Context.Candidate;$Context.Candidate=$null
    $quotaFingerprint=[string](Get-PetRecoveryValue $candidate 'quota_fingerprint' '')
    if($quotaFingerprint -and $quotaFingerprint -ne $Context.QuotaFingerprint){$Context.RefreshWanted=$true;return $false}
    $fingerprint=[string](Get-PetRecoveryValue $candidate 'backend_fingerprint' '')
    if(-not $quotaFingerprint -and $fingerprint -and $fingerprint -ne $Context.BackendFingerprint){$Context.RefreshWanted=$true;return $false}
    $recovering=$Context.NeedsRecovery
    if($recovering){
        if(-not $Context.RecoveryProbePending -or -not $Context.BackendAvailable -or -not $fingerprint -or
           $candidate.key -ne $Context.Key -or $candidate.key -ne $Context.RecoveryKey -or
           $candidate.generation -ne $Context.Generation){$Context.RefreshWanted=$true;return $false}
        $Context.NeedsRecovery=$false;$Context.RecoveryProbePending=$false;$Context.RecoveryKey='';$Context.RecoveryLabel=''
    }
    $accepted=Submit-PetAccountSyncQuota $Context $candidate
    if($recovering -and $accepted){Write-PetAccountRecoveryReceipt $Context $candidate 'quota_reverified';Set-PetAccountSyncStatus $Context ('已重新确认 '+$Context.Label+'，额度已同步。')}
    return $accepted
}
function ConvertTo-PetAccountNativeArgument([string]$Value) {
    # Windows CreateProcess quoting, never shell interpolation.
    $escaped=[regex]::Replace($Value,'(\\*)"','$1$1\"')
    $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
    return '"'+$escaped+'"'
}
function Start-PetAccountSyncWorker($Context,[string]$Operation,[string]$TargetKey='',[bool]$IdleConfirmed=$false,[string]$Label='') {
    if($Context.Simulation){throw 'Simulation must not launch a live worker.'}
    $out=Join-Path $Context.TempRoot ([Guid]::NewGuid().ToString('N')+'.json')
    $workerArguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $Context.BundleRoot 'AccountSync.Worker.ps1'),
        '-Operation',$Operation,'-SharedHome',$Context.SharedHome,'-OutputPath',$out,'-Generation',[string]$Context.Generation)
    if($Context.Key){$workerArguments+=@('-ExpectedKey',$Context.Key)}
    if($TargetKey){$workerArguments+=@('-TargetKey',$TargetKey)}
    if($Label){$workerArguments+=@('-Label',$Label)}
    if($IdleConfirmed){$workerArguments+='-IdleConfirmed'}
    if($Context.ManageDaemon -and $Operation -in @('Switch','Recover')){$workerArguments+='-ManageDaemon'}
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments=($workerArguments | ForEach-Object {ConvertTo-PetAccountNativeArgument ([string]$_)}) -join ' '
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.WorkingDirectory=Split-Path -Parent $Context.BundleRoot
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi
    try {$null=$p.Start()} catch {$p.Dispose();throw}
    return [pscustomobject]@{Process=$p;Output=$out;Generation=$Context.Generation;Operation=$Operation;Started=[DateTime]::UtcNow;Sequence=0}
}
function Receive-PetAccountSyncWorker($Task) {
    if(-not $Task.Process.HasExited){return $null}
    try {
        if([IO.File]::Exists($Task.Output)){return ([IO.File]::ReadAllText($Task.Output) | ConvertFrom-Json)}
        return [pscustomobject]@{ok=$false;code='worker_exit';message='账号检测进程未完成，请刷新重试。';generation=$Task.Generation;operation=$Task.Operation}
    } catch {
        return [pscustomobject]@{ok=$false;code='worker_output';message='账号检测结果无效，请刷新重试。';generation=$Task.Generation;operation=$Task.Operation}
    } finally {
        $Task.Process.Dispose()
        # Retain non-credential worker receipts for artifact classification.
    }
}
function New-PetAccountSimulationQuota($Context) {
    $remaining=if($Context.Key -eq ('a'*64)){78}else{23}
    $window=[pscustomobject]@{remaining_percent=$remaining;used_percent=(100-$remaining);window_minutes=300;reset_local='模拟重置时间';resets_at=$null}
    $weekly=[pscustomobject]@{remaining_percent=($remaining-10);used_percent=(110-$remaining);window_minutes=10080;reset_local='模拟重置时间';resets_at=$null}
    $data=[pscustomobject]@{ok=$true;state='online';plan='模拟';auth_type='chatgpt';session=$window;weekly=$weekly;checked_at=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')}
    return [pscustomobject]@{ok=$true;key=$Context.Key;generation=$Context.Generation;data=$data}
}
function Request-PetAccountSyncRefresh($Context) {
    if($Context.Stopped){return}
    $Context.RefreshWanted=$true;$Context.NextInspect=[DateTime]::MinValue
}
function Get-PetAccountBlockerSummary($Installation) {
    if(-not $Installation){return ''}
    $items=@($Installation.blockers | Where-Object kind -eq 'other_client' | ForEach-Object {([string]$_.name)+' (PID '+([int]$_.pid)+')'})
    return ($items -join '、')
}
function Start-PetAccountSyncAction {
    param($Context,[ValidateSet('Switch','Recover','Save')][string]$Operation,[string]$TargetKey='',[bool]$IdleConfirmed=$false,[string]$Label='')
    if($Context.Busy -or $Context.Stopped){return $false}
    if($Operation -in @('Switch','Recover') -and -not $IdleConfirmed){Set-PetAccountSyncStatus $Context '请先确认所有 Codex 任务已经结束。';return $false}
    if([string]::IsNullOrWhiteSpace($Context.Key)){Set-PetAccountSyncStatus $Context '请先完成当前账号检测。';return $false}
    if($Operation -eq 'Switch' -and @($Context.Profiles | Where-Object {$_.key -eq $TargetKey}).Count -ne 1){Set-PetAccountSyncStatus $Context '请选择已保存的账号。';return $false}
    if($Operation -in @('Switch','Recover') -and $Context.Installation){
        if($Context.Installation.other_client_present){Set-PetAccountSyncStatus $Context ('检测到独立客户端：'+(Get-PetAccountBlockerSummary $Context.Installation)+'。尚未切号；请先结束对应客户端任务，再刷新检测。');return $false}
        $Context.ManageDaemon=[bool]($IdleConfirmed -and $Context.Installation.shared_daemon_present)
    }
    if($Context.WorkTask){Set-PetAccountSyncStatus $Context '正在读取额度，稍后重试。';return $false}
    if($Context.NeedsRecovery -and $Operation -eq 'Switch'){Request-PetAccountRecoveryRecheck $Context;return $false}
    # Fence every earlier inspection/probe before launching a switch.
    Reset-PetAccountSyncGeneration $Context
    $Context.Busy=$true;$Context.RefreshWanted=$false;$Context.RecoveryProbePending=$false
    Set-PetAccountSyncStatus $Context $(if($Operation -eq 'Save'){'保存账号中…'}else{'切换中：正常关闭并重新打开 Codex，再核对额度…'})
    if($Context.Simulation){
        if($Operation -eq 'Recover'){$TargetKey=$Context.SimulationPrevious}
        if($Operation -ne 'Save' -and $TargetKey){
            $previous=$Context.Key;$p=@($Context.Profiles | Where-Object {$_.key -eq $TargetKey})[0]
            Set-PetAccountSyncSource $Context $p.key $p.label
            $Context.SimulationPrevious=$previous;$Context.RecoveryAvailable=$true
        }
        $Context.Busy=$false;$Context.NeedsRecovery=$false;$Context.RefreshWanted=$true
        Set-PetAccountSyncStatus $Context '模拟切换完成 · 未访问真实账号'
        return $true
    }
    try {$Context.WorkTask=Start-PetAccountSyncWorker $Context $Operation $TargetKey $IdleConfirmed $Label;return $true}
    catch {$Context.Busy=$false;$Context.NeedsRecovery=$false;$Context.RefreshWanted=$true;Set-PetAccountSyncStatus $Context '未能启动切换进程，请重试。';return $false}
}
function Complete-PetAccountSyncAction($Context,$Result) {
    $Context.Busy=$false
    if($Result.generation -ne $Context.Generation){Set-PetAccountSyncStatus $Context '已丢弃过期的账号操作结果。';return}
    if($Result.ok){
        $Context.NeedsRecovery=$false;$Context.RecoveryProbePending=$false;$Context.RecoveryKey='';$Context.RecoveryLabel=''
        Set-PetAccountSyncSource $Context $Result.key $Result.label
        if([bool](Get-PetRecoveryValue $Result 'restart_performed' $false)){Write-PetAccountRecoveryReceipt $Context $Result 'desktop_restart_verified'}
        $Context.RefreshWanted=$true;$Context.NextInspect=[DateTime]::MinValue
        Set-PetAccountSyncStatus $Context '登录记录已确认，正在刷新对应额度…'
    } else {
        # A failed exchange/reconnect must never resume showing the previous quota.
        $Context.NeedsRecovery=($Result.code -in @('reconnect','reconnect_timeout','source_changed','switch_backend','worker_exit','worker_output','desktop_close','desktop_drain','restart_exchange','desktop_launch','frontend_reconnect','frontend_unconfirmed'))
        $Context.RefreshWanted=$false;$Context.NextInspect=[DateTime]::MinValue
        $Context.RecoveryProbePending=$false;$Context.SwitchDiskStatus=[string](Get-PetRecoveryValue $Result 'disk_status' 'unknown')
        $diskKey=[string](Get-PetRecoveryValue $Result 'disk_key' '')
        if($diskKey -match '^[a-f0-9]{64}$'){
            Set-PetAccountSyncSource $Context $diskKey ([string](Get-PetRecoveryValue $Result 'disk_label' '当前账号'))
            $Context.RecoveryKey=$diskKey;$Context.RecoveryLabel=$Context.Label
        }
        $null=& $Context.OnClear
        Write-PetAccountRecoveryReceipt $Context $Result 'exchange_result'
        $Context.Diagnostic='上次切换未完成：'+[string](Get-PetRecoveryValue $Result 'message' '')
        Set-PetAccountSyncStatus $Context $Result.message
    }
}
function Invoke-PetAccountSyncTick($Context) {
    if($Context.Stopped){return}
    if($Context.Simulation){
        if($Context.RefreshWanted -and -not $Context.Busy -and -not $Context.NeedsRecovery){$Context.RefreshWanted=$false;$null=& $Context.OnRefresh;$null=Submit-PetAccountSyncQuota $Context (New-PetAccountSimulationQuota $Context)}
        return
    }
    try {
        if($Context.WorkTask){
            $task=$Context.WorkTask;$result=Receive-PetAccountSyncWorker $task
            if($null -ne $result){
                $Context.WorkTask=$null
                if($task.Operation -eq 'Probe'){
                    $recoveryResult=($Context.NeedsRecovery -and $Context.RecoveryProbePending -and $result.ok -and
                        $result.generation -eq $Context.Generation -and $result.key -eq $Context.Key -and
                        $result.key -eq $Context.RecoveryKey -and [bool]$Context.BackendFingerprint -and
                        (Get-PetRecoveryValue $result 'backend_fingerprint' '') -eq $Context.BackendFingerprint)
                    if((Test-PetAccountSyncResult $Context $result) -or $recoveryResult){
                        $Context.Candidate=$result;$Context.CandidateAfterInspectSequence=$Context.InspectSequence
                        $Context.NextInspect=[DateTime]::MinValue
                    }
                    elseif($result.generation -eq $Context.Generation){
                        $null=& $Context.OnClear
                        $null=& $Context.OnFailure ([pscustomobject]@{ok=$false;state='error';message='当前账号额度未读到；请检查登录后刷新。'})
                        $Context.NextInspect=[DateTime]::MinValue
                        if($Context.NeedsRecovery){
                            $Context.RecoveryProbePending=$false;$Context.RefreshWanted=$true
                            Set-PetAccountSyncStatus $Context ('当前登录记录为 '+$Context.Label+'，额度尚未核实；请检查 Codex 连接后刷新检测。')
                        }else{Set-PetAccountSyncStatus $Context '当前账号额度未读到；请检查登录后刷新。'}
                    }
                } else {Complete-PetAccountSyncAction $Context $result}
            }
        }
        if($Context.InspectTask){
            $inspectTask=$Context.InspectTask
            $result=Receive-PetAccountSyncWorker $inspectTask
            if($null -ne $result){
                $Context.InspectTask=$null
                $null=Apply-PetAccountSyncInspection $Context $result $inspectTask.Sequence
            }
        }
        if($Context.Busy){return}
        if(-not $Context.InspectTask -and [DateTime]::UtcNow -ge $Context.NextInspect){
            $Context.InspectTask=Start-PetAccountSyncWorker $Context 'Inspect'
            $Context.InspectSequence++;$Context.InspectTask.Sequence=$Context.InspectSequence
            $Context.NextInspect=[DateTime]::UtcNow.AddSeconds(5)
        }
        if($Context.RefreshWanted -and $Context.Key -and -not $Context.WorkTask -and (-not $Context.NeedsRecovery -or $Context.RecoveryProbePending) -and $Context.QuotaAvailable){
            $Context.RefreshWanted=$false
            $null=& $Context.OnRefresh
            Set-PetAccountSyncStatus $Context '读取当前账号额度…'
            $Context.WorkTask=Start-PetAccountSyncWorker $Context 'Probe'
        }
    } catch {Set-PetAccountSyncStatus $Context '账号同步暂不可用，请刷新重试。'}
}
function Update-PetAccountSyncPanel($Context) {
    if(-not $Context.Controls){return}
    $u=$Context.Controls
    $u.Current.Text='当前登录记录：'+$Context.Label
    if($u.ContainsKey('Installation')){
        $u.Installation.Text='自动检测安装位置中…'
        if($Context.QuotaAvailable -and -not $Context.Installation){$u.Installation.Text='已找到额度查询组件，可独立刷新。账号切换需要打开 Codex 客户端。'}
        if($Context.Installation){$u.Installation.Text='后端实际位置：'+$Context.Installation.backend_actual_path+$(if($Context.Installation.shared_daemon_present){"`n切换时会自动处理并恢复后台连接；刷新只检测。"}elseif($Context.Installation.other_client_present){("`n独立客户端："+(Get-PetAccountBlockerSummary $Context.Installation)+"。请先结束其任务后刷新检测。")}else{"`n已找到当前桌面后端。"})}
        $u.Daemon.Visibility='Collapsed'
    }
    $u.Status.Text=$Context.Status
    $u.BusyNote.Visibility=if($Context.Busy){'Visible'}else{'Collapsed'}
    if($u.ContainsKey('Diagnostic')){$u.Diagnostic.Text=$Context.Diagnostic;$u.Diagnostic.Visibility=if($Context.Diagnostic){'Visible'}else{'Collapsed'}}
    $selected=if($u.Accounts.SelectedItem){$u.Accounts.SelectedItem.key}else{''}
    $keys=(@($Context.Profiles | ForEach-Object {$_.key+':'+$_.label})) -join '|'
    if($u.Accounts.Tag -ne $keys){
        $u.Accounts.Items.Clear();foreach($p in $Context.Profiles){[void]$u.Accounts.Items.Add($p)};$u.Accounts.Tag=$keys
        foreach($p in $Context.Profiles){if($p.key -eq $selected){$u.Accounts.SelectedItem=$p;break}}
        if($u.Accounts.SelectedIndex -lt 0 -and $u.Accounts.Items.Count){$u.Accounts.SelectedIndex=0}
    }
    $canAct=(-not $Context.Busy -and -not $Context.WorkTask -and [bool]$Context.Key)
    $u.Accounts.IsEnabled=$canAct;$u.Idle.IsEnabled=-not $Context.Busy
    $u.Switch.IsEnabled=($canAct -and -not $Context.NeedsRecovery -and $Context.BackendAvailable -and $u.Idle.IsChecked -eq $true -and $u.Accounts.Items.Count -gt 0)
    $u.Recover.IsEnabled=($canAct -and $Context.BackendAvailable -and $Context.RecoveryAvailable -and $u.Idle.IsChecked -eq $true)
    $u.Save.IsEnabled=$canAct;$u.Refresh.IsEnabled=-not $Context.Busy
    if(Get-Command Set-LumiWindowLanguage -ErrorAction SilentlyContinue){Set-LumiWindowLanguage $Context.Panel}
}
function New-PetAccountSyncPanel($Context) {
    [xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="lumi · 登录账号" Width="510" Height="535" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#F7F5FB" Foreground="#302844">
 <Window.Resources>
  <Style x:Key="SoftButton" TargetType="Button">
   <Setter Property="Padding" Value="16,8"/><Setter Property="MinHeight" Value="38"/><Setter Property="MinWidth" Value="92"/>
   <Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Background" Value="#F5F0FA"/><Setter Property="Foreground" Value="#51416E"/><Setter Property="BorderBrush" Value="#D9CDEA"/><Setter Property="BorderThickness" Value="1"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="Button">
     <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="11" Padding="{TemplateBinding Padding}">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="True"/>
     </Border>
    </ControlTemplate></Setter.Value>
   </Setter>
   <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#ECE3F7"/><Setter Property="BorderBrush" Value="#B7A4D7"/></Trigger>
    <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#E1D5F0"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#F0ECF5"/><Setter Property="Foreground" Value="#746B83"/><Setter Property="BorderBrush" Value="#DDD7E6"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
   </Style.Triggers>
  </Style>
  <Style TargetType="Button" BasedOn="{StaticResource SoftButton}"/>
  <Style x:Key="PrimaryAction" TargetType="Button" BasedOn="{StaticResource SoftButton}">
   <Setter Property="Background" Value="#6C55A6"/><Setter Property="Foreground" Value="#FFFFFF"/><Setter Property="BorderBrush" Value="#6C55A6"/>
   <Style.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#5E4799"/><Setter Property="BorderBrush" Value="#5E4799"/></Trigger>
    <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#503B87"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#DED7EA"/><Setter Property="Foreground" Value="#5E536F"/><Setter Property="BorderBrush" Value="#DED7EA"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
   </Style.Triggers>
  </Style>
  <Style TargetType="TextBox"><Setter Property="Background" Value="#FFFFFF"/><Setter Property="Foreground" Value="#302844"/><Setter Property="BorderBrush" Value="#D7CEE7"/><Setter Property="Padding" Value="8,5"/></Style>
  <Style x:Key="AccountChoiceItem" TargetType="ComboBoxItem">
   <Setter Property="Foreground" Value="#3F325E"/><Setter Property="Padding" Value="12,9"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="ComboBoxItem">
     <Border x:Name="ItemChrome" Background="Transparent" CornerRadius="8" Padding="{TemplateBinding Padding}">
      <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True"/>
     </Border>
     <ControlTemplate.Triggers>
      <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="#EEE6F8"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter TargetName="ItemChrome" Property="Background" Value="#E7DCF5"/><Setter Property="FontWeight" Value="SemiBold"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value>
   </Setter>
  </Style>
  <Style TargetType="ComboBox">
   <Setter Property="Background" Value="#FFFFFF"/><Setter Property="Foreground" Value="#302844"/><Setter Property="BorderBrush" Value="#D7CEE7"/>
   <Setter Property="ItemContainerStyle" Value="{StaticResource AccountChoiceItem}"/>
   <Setter Property="Template">
    <Setter.Value><ControlTemplate TargetType="ComboBox">
     <Grid>
      <Border x:Name="SelectionChrome" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="11">
       <Grid>
        <ContentPresenter x:Name="ContentSite" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}" ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}" IsHitTestVisible="False" VerticalAlignment="Center" Margin="13,0,38,0"/>
        <Path Data="M 0 0 L 4 4 L 8 0" Stroke="#715B9A" StrokeThickness="1.8" Width="9" Height="5" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,15,0"/>
       </Grid>
      </Border>
      <ToggleButton x:Name="DropToggle" Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
       <ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"/></ControlTemplate></ToggleButton.Template>
      </ToggleButton>
      <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" Focusable="False" AllowsTransparency="True" PopupAnimation="Fade">
       <Border Background="#FFFFFF" BorderBrush="#D7C9EA" BorderThickness="1" CornerRadius="11" Padding="4" MinWidth="{TemplateBinding ActualWidth}">
        <ScrollViewer MaxHeight="220" VerticalScrollBarVisibility="Auto" CanContentScroll="True"><ItemsPresenter/></ScrollViewer>
       </Border>
      </Popup>
     </Grid>
     <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="SelectionChrome" Property="BorderBrush" Value="#A78FCB"/><Setter TargetName="SelectionChrome" Property="Background" Value="#FCFAFF"/></Trigger>
      <Trigger Property="IsDropDownOpen" Value="True"><Setter TargetName="SelectionChrome" Property="BorderBrush" Value="#785FA8"/></Trigger>
      <Trigger Property="IsEnabled" Value="False"><Setter TargetName="SelectionChrome" Property="Background" Value="#F1EDF5"/><Setter TargetName="SelectionChrome" Property="BorderBrush" Value="#DED8E7"/></Trigger>
     </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value>
   </Setter>
  </Style>
 </Window.Resources>
 <Grid>
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <Border Grid.Row="0" Background="#FFFFFF" BorderBrush="#E5DEED" BorderThickness="0,0,0,1" Padding="22,17,22,15">
   <StackPanel>
    <TextBlock Text="登录账号" FontSize="21" FontWeight="SemiBold" Foreground="#332453"/>
    <TextBlock Text="查看当前账号，或切换到已保存的账号" Margin="0,5,0,0" Foreground="#695E7F" FontSize="12"/>
   </StackPanel>
  </Border>
  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
   <StackPanel Margin="20,18,20,18">
    <Border Background="#FFFFFF" BorderBrush="#E2DBEC" BorderThickness="1" CornerRadius="15" Padding="16,14" Margin="0,0,0,12">
     <StackPanel>
      <TextBlock Text="当前状态" FontSize="12" Foreground="#72668A"/>
      <TextBlock x:Name="Current" Margin="0,5,0,10" FontSize="15" FontWeight="SemiBold" Foreground="#332453" TextWrapping="Wrap"/>
      <TextBlock x:Name="Status" TextWrapping="Wrap" Foreground="#4E3F79" FontSize="13"/>
      <TextBlock x:Name="BusyNote" Text="关闭此页不会中断已开始的账号操作；桌宠会继续核对结果。" TextWrapping="Wrap" Foreground="#6B5A89" Margin="0,8,0,0" FontSize="12" Visibility="Collapsed"/>
      <TextBlock x:Name="Diagnostic" TextWrapping="Wrap" Foreground="#9A4B4B" Margin="0,9,0,0" FontSize="12" Visibility="Collapsed"/>
     </StackPanel>
    </Border>
    <Border Background="#FFFFFF" BorderBrush="#E2DBEC" BorderThickness="1" CornerRadius="15" Padding="16,14" Margin="0,0,0,12">
     <StackPanel>
      <TextBlock Text="切换账号" FontSize="15" FontWeight="SemiBold" Foreground="#332453"/>
      <TextBlock Text="选择已保存账号" Margin="0,12,0,6" FontSize="12" Foreground="#655A7A"/>
      <ComboBox x:Name="Accounts" Height="40"><ComboBox.ItemTemplate><DataTemplate><TextBlock Text="{Binding label}"/></DataTemplate></ComboBox.ItemTemplate></ComboBox>
      <CheckBox x:Name="Idle" Margin="0,12,0,12" Foreground="#514665"><TextBlock Text="本机及远程任务均已结束；同意切换时重开 Codex" TextWrapping="Wrap"/></CheckBox>
      <WrapPanel><Button x:Name="Switch" Content="切换到所选账号" Style="{StaticResource PrimaryAction}" Margin="0,0,8,0"/><Button x:Name="Refresh" Content="刷新检测"/></WrapPanel>
     </StackPanel>
    </Border>
    <Expander Header="更多操作与诊断" Foreground="#514665" FontWeight="SemiBold">
     <StackPanel Margin="2,10,2,4">
      <TextBlock Text="保存当前账号的名称" FontSize="12" Foreground="#655A7A" Margin="0,0,0,5"/>
      <DockPanel><Button x:Name="Save" Content="保存" DockPanel.Dock="Right" Margin="8,0,0,0"/><TextBox x:Name="Label" MaxLength="60" VerticalContentAlignment="Center"/></DockPanel>
      <Button x:Name="Recover" Content="手动恢复上次切换前的账号" Margin="0,10,0,0" HorizontalAlignment="Left"/>
      <TextBlock x:Name="Installation" TextWrapping="Wrap" FontSize="11" Foreground="#655A7A" Margin="0,12,0,0"/>
      <CheckBox x:Name="Daemon" Visibility="Collapsed"><TextBlock Text="本机与远程任务已结束，同时停止并恢复共享后台" TextWrapping="Wrap"/></CheckBox>
      <TextBlock x:Name="Footnote" Text="切换会退出并重开 Codex，无法在原窗口内刷新登录。请先结束全部任务。刷新检测不会切号；额度分页只供查看。" TextWrapping="Wrap" FontSize="11" Foreground="#655A7A" Margin="0,10,0,0"/>
     </StackPanel>
    </Expander>
   </StackPanel>
  </ScrollViewer>
  <Border Grid.Row="2" Background="#FFFFFF" BorderBrush="#E5DEED" BorderThickness="0,1,0,0" Padding="20,12">
   <DockPanel LastChildFill="True">
    <Button x:Name="ClosePanel" Content="关闭窗口" DockPanel.Dock="Right" MinWidth="88" Margin="12,0,0,0"/>
    <TextBlock Text="账号操作继续运行，稍后可重新打开查看" Foreground="#72668A" FontSize="11" VerticalAlignment="Center" TextWrapping="Wrap"/>
   </DockPanel>
  </Border>
 </Grid>
</Window>
'@
    $w=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
    $u=@{};foreach($name in @('Current','Accounts','Idle','Switch','Refresh','Status','BusyNote','Diagnostic','Save','Label','Recover','Footnote','Installation','Daemon','ClosePanel')){$u[$name]=$w.FindName($name)}
    if($Context.Simulation){$w.Title+=' · 模拟';$u.Footnote.Text='模拟模式：A/B 及额度都是测试数据，不读取真实登录，不停止任何 Codex 进程。'}
    if($Context.Owner){$w.Owner=$Context.Owner;$w.Resources.MergedDictionaries.Add($Context.Owner.Resources)}
    $w.FontFamily='Microsoft YaHei UI'
    $Context.Panel=$w;$Context.Controls=$u
    $c=$Context
    $u.Idle.Add_Checked({Update-PetAccountSyncPanel $c}.GetNewClosure())
    $u.Idle.Add_Unchecked({Update-PetAccountSyncPanel $c}.GetNewClosure())
    $u.Daemon.Add_Checked({$c.ManageDaemon=$true;Update-PetAccountSyncPanel $c}.GetNewClosure())
    $u.Daemon.Add_Unchecked({$c.ManageDaemon=$false;Update-PetAccountSyncPanel $c}.GetNewClosure())
    $w.Add_Closed({$c.ManageDaemon=$false}.GetNewClosure())
    $u.Switch.Add_Click({if($u.Accounts.SelectedItem){$null=Start-PetAccountSyncAction $c 'Switch' $u.Accounts.SelectedItem.key ($u.Idle.IsChecked -eq $true)}}.GetNewClosure())
    $u.Recover.Add_Click({$null=Start-PetAccountSyncAction $c 'Recover' '' ($u.Idle.IsChecked -eq $true)}.GetNewClosure())
    $u.Save.Add_Click({$null=Start-PetAccountSyncAction $c 'Save' '' $false $u.Label.Text}.GetNewClosure())
    $u.Refresh.Add_Click({
        Request-PetAccountRecoveryRecheck $c
    }.GetNewClosure())
    $u.ClosePanel.Add_Click({$w.Close()}.GetNewClosure())
    # Closing only detaches this view. The context timer and a running worker stay alive,
    # so a switch can finish and a reopened panel can show its final status.
    $w.Add_Closed({$c.Panel=$null;$c.Controls=$null}.GetNewClosure())
    Update-PetAccountSyncPanel $c
    return $w
}
function Show-PetAccountSyncPanel($Context) {
    if($Context.Panel){$Context.Panel.Activate() | Out-Null;return}
    $w=New-PetAccountSyncPanel $Context
    $w.Show()
    # Opening the view uses the current account snapshot. Quota refresh is an explicit
    # action; starting a network probe here disabled the entire switch view each time.
    if(-not $Context.Key){$Context.NextInspect=[DateTime]::MinValue}
}
function Stop-PetAccountSyncContext($Context) {
    $Context.Stopped=$true
    if($Context.Timer){$Context.Timer.Stop()}
    # Do not kill an account exchange on exit. It completes independently.
    # Transient process results contain labels/quotas only, never credentials.
    if(-not $Context.WorkTask -and -not $Context.InspectTask -and $Context.TempRoot -and [IO.Directory]::Exists($Context.TempRoot)){
        $resolved=[IO.Path]::GetFullPath($Context.TempRoot)
        $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
        if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^GPTQuotaPet-Sync-[a-f0-9]{32}$'){
            <# Retain test and probe receipts; classify without deleting. #>
        }
    }
}

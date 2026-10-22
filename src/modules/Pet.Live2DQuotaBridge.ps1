# This module belongs only to the isolated Live2D quota candidate.
. (Join-Path $PSScriptRoot 'Pet.BubbleQuota.ps1')
. (Join-Path $PSScriptRoot 'Pet.ResetCards.ps1')
$script:live2dBridge=$null
$script:live2dQuotaBundleRoot=Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'Pet.ForegroundGuard.ps1')
. (Join-Path $PSScriptRoot 'Pet.CodexTask.ps1')
$window.ShowActivated=$false
$window.Title='lumi'
$window.Background=$null
$rootCanvas.Background=$null
if(-not ('PetQuotaWindowNative' -as [type])){
Add-Type @'
using System;using System.Runtime.InteropServices;
public static class PetQuotaWindowNative {
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll",SetLastError=true)]static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int height,uint flags);
 public static void RaiseOwnWindow(IntPtr h,bool topmost){
  uint owner;GetWindowThreadProcessId(h,out owner);
  if(h==IntPtr.Zero||owner!=System.Diagnostics.Process.GetCurrentProcess().Id)throw new InvalidOperationException("Quota window is not owned by this host");
  if(!SetWindowPos(h,topmost?new IntPtr(-1):IntPtr.Zero,0,0,0,0,0x13))throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
 }
}
'@
}
function Restore-Live2DQuotaWindowPresentation {
    $b=$script:live2dBridge
    if(-not $b -or -not $script:bubbleOpen -or $b.FullscreenSuspended -or $b.TrayMinimized){return}
    $window.Topmost=[bool]$b.DesiredTopmost
    $handle=([Windows.Interop.WindowInteropHelper]::new($window)).Handle
    # Explicit page opening raises only its own WPF window, without activation.
    # Repeating bridge ticks never reassert the quota window's z-order.
    [PetQuotaWindowNative]::RaiseOwnWindow($handle,[bool]$b.DesiredTopmost)
    $b.QuotaPresentationCount++
}
function Write-Live2DQuotaState {
    if(-not $script:live2dBridge){return}
    $b=$script:live2dBridge
    $visual=Get-PetQChibiVisualState -LogicalState $script:logicalState
    if($script:appearance -eq 'chibi' -and $script:Q_CHIBI_STATE_CONTROLLER){$visual=[string]$script:Q_CHIBI_STATE_CONTROLLER.State}
    $task=Read-PetCodexTaskPacket
    $taskVisual=Get-PetCodexTaskVisualState -Packet $task -Session $b.Session -Owner $PID -Manual:([bool]$b.OverrideId) -Fullscreen:([bool]$b.FullscreenSuspended)
    if($taskVisual){$visual=$taskVisual;if($taskVisual -in @('working','thinking')){$script:lastActivityUtc=[DateTime]::UtcNow}}
    elseif(-not $b.OverrideId -and [DateTimeOffset]::UtcNow -lt $b.StartupGreetingUntil){$visual='greeting'}
    $form=if($b.OverrideId){$b.Registry.forms | Where-Object id -eq $b.OverrideId | Select-Object -First 1}else{$b.Registry.forms | Where-Object {$_.appearance -eq $script:appearance -and $_.state -eq $visual} | Select-Object -First 1}
    if(-not $form){throw 'No verified Live2D form for current visual state'}
    $b.Sequence++
    $state=[ordered]@{schema=1;session=$b.Session;sequence=$b.Sequence;processed_sequence=$b.ProcessedSequence;published_utc=[DateTimeOffset]::UtcNow.ToString('o');closed=[bool]$b.Closed;owner_pid=$PID;form_id=[string]$form.id;visual_state=[string]$form.state;semantic_state=$script:semanticState;activity_state=$script:activityState;manual_override=[bool]$b.OverrideId;scale=if($script:appearance -eq 'anime'){$b.AnimeScale}else{$b.ChibiScale};topmost=[bool]$b.DesiredTopmost;fullscreen_suspended=[bool]$b.FullscreenSuspended;foreground_epoch=$b.ForegroundEpoch;locked=[bool]$script:locked;x=[int][Math]::Round($window.Left+365);y=[int][Math]::Round($window.Top);quota_open=[bool]$script:bubbleOpen;quota_summary=[string]$mini.Text;simulation=[bool]$AccountSyncSimulation;control_test_request=[bool]$b.ControlTest;tibo_notice=$(if($script:tiboMonitor){$script:tiboMonitor.Active}else{$null});tap_feedback_active=([DateTimeOffset]::UtcNow -lt $b.TapUntil);input_health=[ordered]@{native_down_utc=$b.LastNativeDown;preview_down_utc=$b.LastPreviewDown;preview_source=$b.LastPreviewSource;hit_test_visible=[bool]$window.IsHitTestVisible;enabled=[bool]$window.IsEnabled;opacity=[double]$window.Opacity};account_panel_open=[bool]($script:accountSyncContext.Panel -and $script:accountSyncContext.Panel.IsVisible)}
    $state['reset_cards']=Get-LumiResetCardsPacket $script:quotaPages
    $state['quota_detail']=Get-LumiQuotaBubblePacket $script:quotaPages
    $state['quota_notice']=if($script:quotaActiveNotice){[string]$script:quotaActiveNotice.message}else{''}
    $state['quota_notice_id']=if($script:quotaActiveNotice){[string]$script:quotaActiveNotice.id}else{''}
    $state['quota_notice_key']=if($script:quotaActiveNotice){[string]$script:quotaActiveNotice.key}else{''}
    $state['tray_minimized']=[bool]$b.TrayMinimized
    $state['restore_epoch']=[int]$b.ExplicitRestoreEpoch
    $temp=Join-Path $b.Root 'state.next.json';$dest=Join-Path $b.Root 'state.json'
    [IO.File]::WriteAllText($temp,($state|ConvertTo-Json -Depth 5 -Compress),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $dest -Force
}
function Invoke-Live2DQuotaCommand($Command) {
    $b=$script:live2dBridge
    if($Command.session -ne $b.Session -or $Command.schema -ne 1){throw 'Wrong bridge session'}
    switch([string]$Command.command){
        'minimize' {
            if(-not $b.TrayMinimized){
                $b.TrayQuotaWasOpen=[bool]$script:bubbleOpen;Show-Bubble $false
                $b.TrayPanelWasOpen=[bool]($script:accountSyncContext.Panel -and $script:accountSyncContext.Panel.IsVisible)
                if($b.TrayPanelWasOpen){$script:accountSyncContext.Panel.Hide()}
                $b.TrayMinimized=$true;$window.Opacity=0;$window.IsHitTestVisible=$false;$window.Topmost=$false
            }
        }
        'restore' {
            $wasMinimized=$b.TrayMinimized
            Restore-PetExplicitPresentation
            if($wasMinimized){
                if($b.TrayQuotaWasOpen){Show-Bubble $true;Restore-Live2DQuotaWindowPresentation}
                if($b.TrayPanelWasOpen -and -not $b.FullscreenSuspended -and $script:accountSyncContext.Panel){$script:accountSyncContext.Panel.Show()}
            }
        }
        'language' {Set-LumiLanguage ([string]$Command.value);if($script:accountSyncContext.Panel){Set-LumiWindowLanguage $script:accountSyncContext.Panel};if($script:tiboMonitor.Panel){$script:tiboMonitor.PanelStamp='';Update-PetTiboMonitorPanel $script:tiboMonitor}}
        'reset-cards-read' {Request-LumiResetCards $script:quotaPages}
        'reset-cards-refresh' {Request-LumiResetCards $script:quotaPages -Force}
        'reset-cards-consume' {Request-LumiResetCardConsume $script:quotaPages $Command}
        'quota-page' {$null=Select-PetQuotaPage $script:quotaPages ([string]$Command.key)}
        'quota-follow' {Follow-PetQuotaLogin $script:quotaPages}
        'quota-refresh' {Request-PetQuotaPageRefresh $script:quotaPages}
        'quota' {Touch-PetActivity;Show-Bubble(-not $script:bubbleOpen);if($script:bubbleOpen){Restore-Live2DQuotaWindowPresentation;Refresh-Quota}}
        'accounts' {Touch-PetActivity;Show-PetAccountSyncPanel $script:accountSyncContext}
        'refresh' {Touch-PetActivity;Show-Bubble $true;Restore-Live2DQuotaWindowPresentation;Refresh-Quota}
        'history' {Touch-PetActivity;Show-PetQuotaNoticeHistory}
        'tibo' {Touch-PetActivity;Show-PetTiboMonitorPanel $script:tiboMonitor}
        'tibo-source' {Touch-PetActivity;Open-PetTiboSource $script:tiboMonitor -Id ([string]$Command.id)}
        'tibo-dismiss' {Dismiss-PetTiboNotice $script:tiboMonitor}
        'sound' {$script:quotaPages.SoundEnabled=[bool]$Command.value;Save-PetQuotaPages $script:quotaPages}
        'appearance' {
            $next=[string]$Command.value;if($next -notin @('chibi','anime')){throw 'Invalid appearance'}
            if($b.OverrideId){$old=$b.Registry.forms|Where-Object id -eq $b.OverrideId|Select-Object -First 1;$mapped=$b.Registry.forms|Where-Object {$_.appearance -eq $next -and $_.state -eq $old.state}|Select-Object -First 1;$b.OverrideId=[string]$mapped.id}
            Apply-PetVisualState -Appearance $next -LogicalState $script:logicalState;Save-State;Touch-PetActivity
        }
        'tap' {$b.TapUntil=[DateTimeOffset]::UtcNow.AddSeconds(1.6);Touch-PetActivity;Set-PetActivityState -State 'interaction' -Trigger 'interaction.live2d_click' -Reason 'Live2D character click';$script:interactionActive=$true;$script:interactionStartedUtc=[DateTime]::UtcNow;$script:interactionTimer.Start()}
        'form' {
            $f=$b.Registry.forms | Where-Object id -eq ([string]$Command.id) | Select-Object -First 1
            if(-not $f -or -not $f.core_verified){throw 'Unknown or unverified form'}
            $b.OverrideId=[string]$f.id
            if($script:appearance -ne $f.appearance){Apply-PetVisualState -Appearance $f.appearance -LogicalState $script:logicalState;Save-State}
            Touch-PetActivity
        }
        'auto' {$b.OverrideId='';Touch-PetActivity;[void](Update-PetAutomaticVisualState -Trigger 'interaction.live2d_auto' -Reason 'return to existing automatic policy' -Force)}
        'scale' {$v=[double]$Command.value;if([double]::IsNaN($v) -or [double]::IsInfinity($v) -or $v -lt .5 -or $v -gt 1.15){throw 'Invalid renderer scale'};if($script:appearance -eq 'anime'){$b.AnimeScale=$v}else{$b.ChibiScale=$v};Touch-PetActivity}
        'topmost' {$b.DesiredTopmost=[bool]$Command.value;$window.Topmost=$b.DesiredTopmost -and -not $b.FullscreenSuspended -and -not $b.TrayMinimized;Save-State;Touch-PetActivity}
        'lock' {$script:locked=[bool]$Command.value;Save-State;Touch-PetActivity}
        'move' {if(-not $script:locked){$x=[double]$Command.x;$y=[double]$Command.y;if([double]::IsNaN($x) -or [double]::IsNaN($y) -or [Math]::Abs($x) -gt 100000 -or [Math]::Abs($y) -gt 100000){throw 'Invalid native position'};$window.Left=$x-365;$window.Top=$y;[void](Clamp-PetWindowToCurrentMonitor);Save-State;Touch-PetActivity}}
        'quit' {$window.Close()}
        default {throw 'Unknown renderer command'}
    }
}
function Start-Live2DQuotaBridge {
    if($script:live2dBridge){throw 'Renderer bridge already started'}
    $modelRoot=Join-Path $script:live2dQuotaBundleRoot 'models\original'
    $registry=Read-JsonFile (Join-Path $modelRoot 'MODEL_REGISTRY.json')
    if(-not $registry.all_15_animated -or @($registry.forms).Count -ne 15){throw 'Verified 15-form motion registry required'}
    $session=[Guid]::NewGuid().ToString('N');$root=Join-Path $script:live2dQuotaBundleRoot ('local_state\render_sessions\'+$session)
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'commands'))
    $script:live2dBridge=[pscustomobject]@{Session=$session;Root=$root;Registry=$registry;Sequence=0;ProcessedSequence=0;OverrideId='';ChibiScale=1.0;AnimeScale=1.0;Closed=$false;Process=$null;Timer=$null;Seen=@{};Failures=@();ModelRoot=$modelRoot;ControlTest=$false;TapUntil=[DateTimeOffset]::MinValue;StartupGreetingUntil=[DateTimeOffset]::UtcNow.AddSeconds(4)}
    $window.Width=785;$window.Height=650
    $script:live2dBridge | Add-Member -NotePropertyName DesiredTopmost -NotePropertyValue ([bool]$window.Topmost)
    $script:live2dBridge | Add-Member -NotePropertyName FullscreenSuspended -NotePropertyValue $false
    $script:live2dBridge | Add-Member -NotePropertyName ForegroundClearTicks -NotePropertyValue 0
    $script:live2dBridge | Add-Member -NotePropertyName ForeignWindowToken -NotePropertyValue ''
    $script:live2dBridge | Add-Member -NotePropertyName ForeignWindowFullscreen -NotePropertyValue $false
    $script:live2dBridge | Add-Member -NotePropertyName ForegroundEpoch -NotePropertyValue 0
    $script:live2dBridge | Add-Member -NotePropertyName ExplicitRestoreEpoch -NotePropertyValue 0
    $script:live2dBridge | Add-Member -NotePropertyName QuotaPresentationCount -NotePropertyValue 0
    foreach($name in @('TrayMinimized','TrayQuotaWasOpen','TrayPanelWasOpen')){$script:live2dBridge | Add-Member -NotePropertyName $name -NotePropertyValue $false}
    foreach($name in @('LastNativeDown','LastPreviewDown','LastPreviewSource')){$script:live2dBridge | Add-Member -NotePropertyName $name -NotePropertyValue $null}
    $window.Add_PreviewMouseDown({param($sender,$event);$b=$script:live2dBridge;if($b){$b.LastPreviewDown=[DateTimeOffset]::UtcNow.ToString('o');$source=$event.OriginalSource;$b.LastPreviewSource=if($source -and $source.PSObject.Properties['Name'] -and $source.Name){[string]$source.Name}else{[string]$source.GetType().Name}}})
    $nativeHook=[Windows.Interop.HwndSourceHook]{param($handle,$message,$wParam,$lParam,$handled);if($message -eq 0x201 -and $script:live2dBridge){$script:live2dBridge.LastNativeDown=[DateTimeOffset]::UtcNow.ToString('o')};return [IntPtr]::Zero}
    $source=[Windows.Interop.HwndSource]::FromHwnd(([Windows.Interop.WindowInteropHelper]::new($window)).Handle)
    if($source){$source.AddHook($nativeHook)}
    $script:live2dBridge | Add-Member -NotePropertyName InputHook -NotePropertyValue $nativeHook
    Update-PetFullscreenGuard
    $petArea.Visibility=[Windows.Visibility]::Hidden
    [void](Clamp-PetWindowToCurrentMonitor)
    Write-Live2DQuotaState
    $renderer=Join-Path $script:live2dQuotaBundleRoot 'renderer'
    $runtime=Join-Path $script:live2dQuotaBundleRoot 'runtime\electron\electron.exe'
    $args=@(('"'+$renderer+'"'),('--bridge="'+$root+'"'),('--owner='+$PID))
    if($AccountSyncSimulation -and $env:GPT_QUOTA_PET_BRIDGE_TEST -eq '1'){$args+='--bridge-test'}
    $script:live2dBridge.Process=Start-Process -FilePath $runtime -ArgumentList $args -WorkingDirectory $modelRoot -WindowStyle Hidden -PassThru
    $summary=[ordered]@{session=$session;owner_pid=$PID;renderer_pid=$script:live2dBridge.Process.Id;root=$root;simulation=[bool]$AccountSyncSimulation}
    [IO.File]::WriteAllText((Join-Path $script:live2dQuotaBundleRoot 'local_state\render_session.json'),($summary|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $t=New-Object Windows.Threading.DispatcherTimer;$t.Interval=[TimeSpan]::FromMilliseconds(250)
    $t.Add_Tick({
        $b=$script:live2dBridge
        try{
            if($b.Process.HasExited){throw 'Owned Live2D renderer exited'}
            Update-PetFullscreenGuard
            foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $b.Root 'commands') -Filter '*.json' -File | Where-Object {-not $b.Seen.ContainsKey($_.Name)} | Sort-Object Name | Select-Object -First 100)){
                if($b.Seen.ContainsKey($file.Name)){continue}
                $b.Seen[$file.Name]=$true
                try{if($file.Length -gt 4096){throw 'Oversized bridge command'};$cmd=Read-JsonFile $file.FullName;if(-not $cmd){throw 'Invalid bridge command'};Invoke-Live2DQuotaCommand $cmd;$b.ProcessedSequence=[Math]::Max($b.ProcessedSequence,[int]$cmd.sequence)}catch{$b.Failures+=@([string]$_.Exception.Message);Write-PetCaughtException 'live2d.command_rejected' $_}
            }
            # The bridge owns no visible pixels in the tray. Keep account and
            # notification polling alive, but avoid four full state writes/s.
            $interval=if($b.TrayMinimized){1000}elseif($b.FullscreenSuspended){500}else{250}
            if($b.Timer.Interval.TotalMilliseconds -ne $interval){$b.Timer.Interval=[TimeSpan]::FromMilliseconds($interval)}
            if(-not $b.Closed){Write-Live2DQuotaState}
        }catch{Write-PetCaughtException 'live2d.bridge_failure' $_;$b.Failures+=@([string]$_.Exception.Message);$window.Close()}
    })
    $script:live2dBridge.Timer=$t;$t.Start()
}
$window.Add_Loaded({try{Start-Live2DQuotaBridge}catch{Write-PetCaughtException 'live2d.bridge_start' $_;$window.Close()}})
$window.Add_Closed({
    if($script:live2dBridge){$b=$script:live2dBridge;$b.Closed=$true;$b.Timer.Stop();try{Write-Live2DQuotaState}catch{}
        if($b.Process -and -not $b.Process.HasExited){if(-not $b.Process.WaitForExit(2000)){try{$b.Process.Kill()}catch{}}}
        $r=[ordered]@{session=$b.Session;failures=@($b.Failures);commands_seen=$b.Seen.Count;sequence=$b.Sequence;renderer_exited=($b.Process -and $b.Process.HasExited);stage_02_complete=$false}
        [IO.File]::WriteAllText((Join-Path $b.Root 'closed.json'),($r|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    }
})

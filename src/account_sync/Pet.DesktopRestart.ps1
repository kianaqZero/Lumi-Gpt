# R6 account transaction: orderly desktop exit, credential exchange, registered app activation.
# No process termination, private IPC, installation edits, or renderer injection.
. (Join-Path $PSScriptRoot 'Pet.SwitchDiagnostics.ps1')
function Get-PetRestartBackend {
    try{return Get-DesktopBackend}catch{throw 'desktop_backend_unavailable'}
}
function Initialize-PetDesktopRestartNative {
    if('PetDesktopLifecycle' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPetApplicationActivationManager {
    [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appId, [MarshalAs(UnmanagedType.LPWStr)] string args, uint options, out uint pid);
}
public static class PetDesktopLifecycle {
    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetMenuItemCount(IntPtr menu);
    [DllImport("user32.dll")] static extern IntPtr GetSubMenu(IntPtr menu, int pos);
    [DllImport("user32.dll")] static extern uint GetMenuItemID(IntPtr menu, int pos);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMenuString(IntPtr menu, uint pos, StringBuilder text, int max, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wParam, IntPtr lParam);
    static int FindQuit(IntPtr menu) {
        int found=-1;
        for(int i=0;i<GetMenuItemCount(menu);i++) {
            var text=new StringBuilder(512); GetMenuString(menu,(uint)i,text,text.Capacity,0x400);
            string label=text.ToString().Split('\t')[0].Replace("&","").Trim();
            var sub=GetSubMenu(menu,i); int id=sub!=IntPtr.Zero?FindQuit(sub):-1;
            if(sub==IntPtr.Zero && (label=="退出" || label.StartsWith("退出 ") || label.StartsWith("退出Codex") || label.StartsWith("退出ChatGPT") || label=="Quit" || label.StartsWith("Quit ") || label=="Exit" || label.StartsWith("Exit "))){
                uint value=GetMenuItemID(menu,i); if(value!=0xffffffff && value<=65535)id=(int)value;
            }
            if(id==-2)return -2; if(id>=0){if(found>=0)return -2;found=id;}
        }
        return found;
    }
    public static int QuitMenuId(IntPtr hwnd, int expectedPid) {
        uint pid;GetWindowThreadProcessId(hwnd,out pid);if(pid!=expectedPid)throw new InvalidOperationException("Window owner changed");
        return FindQuit(GetMenu(hwnd));
    }
    public static bool RequestQuit(IntPtr hwnd,int expectedPid,int id) {
        if(QuitMenuId(hwnd,expectedPid)!=id || id<0)throw new InvalidOperationException("Quit menu changed");
        return PostMessage(hwnd,0x111,new IntPtr(id),IntPtr.Zero);
    }
    public static uint Activate(string appId) {
        object instance=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")));
        try {uint pid; int hr=((IPetApplicationActivationManager)instance).ActivateApplication(appId,null,0,out pid);Marshal.ThrowExceptionForHR(hr);return pid;}
        finally {Marshal.FinalReleaseComObject(instance);}
    }
}
'@
}
function Get-PetDesktopLaunchSpec($Backend){
    $exe=[IO.Path]::GetFullPath($Backend.DesktopPath)
    # Registered activation obtains the user's environment rather than the worker's temporary environment.
    $registeredHome=[Environment]::GetEnvironmentVariable('CODEX_HOME','User')
    if(-not $registeredHome){$registeredHome=[Environment]::GetEnvironmentVariable('CODEX_HOME','Machine')}
    if(-not $registeredHome -or [IO.Path]::GetFullPath($registeredHome).TrimEnd('\') -ne [IO.Path]::GetFullPath($script:CodexHome).TrimEnd('\')){throw 'desktop_home_mismatch'}
    $package=@(Get-AppxPackage -Name OpenAI.Codex | Where-Object {
        $root=[IO.Path]::GetFullPath($_.InstallLocation).TrimEnd('\')+'\'
        $exe.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)
    })
    if($package.Count -ne 1){throw 'desktop_launch_unsupported'}
    [xml]$manifest=[IO.File]::ReadAllText((Join-Path $package[0].InstallLocation 'AppxManifest.xml'))
    $apps=@($manifest.Package.Applications.Application | Where-Object {
        [IO.Path]::GetFullPath((Join-Path $package[0].InstallLocation ([string]$_.Executable))) -eq $exe
    })
    if($apps.Count -ne 1 -or $manifest.Package.Identity.Name -ne 'OpenAI.Codex'){throw 'desktop_launch_unsupported'}
    $appId=[string]$package[0].PackageFamilyName+'!'+[string]$apps[0].Id
    if($appId -notmatch '^OpenAI\.Codex_[a-z0-9]+![A-Za-z0-9_.-]+$'){throw 'desktop_launch_unsupported'}
    Initialize-PetDesktopRestartNative
    $desktop=Get-Process -Id $Backend.DesktopPid -ErrorAction Stop
    if($desktop.Path -ne $exe -or $desktop.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $Backend.DesktopCreated -or $desktop.MainWindowHandle -eq [IntPtr]::Zero){throw 'desktop_changed'}
    $menu=[PetDesktopLifecycle]::QuitMenuId($desktop.MainWindowHandle,$desktop.Id)
    $mode='native_menu'
    if($menu -lt 0){
        $deadline=[DateTime]::UtcNow.AddSeconds(3);$fileMenu=$null
        do{$fileMenu=Get-PetDesktopFileMenu $desktop.MainWindowHandle;if($fileMenu){break};Start-Sleep -Milliseconds 150}while([DateTime]::UtcNow -lt $deadline)
        if(-not $fileMenu){throw 'desktop_quit_unavailable'}
        $mode='file_menu_uia'
    }
    return [pscustomobject]@{Executable=$exe;AppId=$appId;Window=$desktop.MainWindowHandle;MenuId=$menu;QuitMode=$mode;RegisteredHomeVerified=$true;DesktopPid=$Backend.DesktopPid;DesktopCreated=$Backend.DesktopCreated}
}
function Get-PetDesktopFileMenu([IntPtr]$Window){
    Add-Type -AssemblyName UIAutomationClient
    $root=[Windows.Automation.AutomationElement]::FromHandle($Window)
    if(-not $root){return $null}
    $type=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::MenuItem)
    $matches=@($root.FindAll([Windows.Automation.TreeScope]::Descendants,$type) | Where-Object {$_.Current.Name -in @('文件','File') -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen})
    $matches=@(Get-PetDistinctUiaElements $matches)
    if($matches.Count -ne 1){return $null}
    $pattern=$null
    if(-not $matches[0].TryGetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern,[ref]$pattern)){return $null}
    return [pscustomobject]@{Root=$root;Element=$matches[0];Pattern=$pattern}
}
function Get-PetDistinctUiaElements($Elements){
    # Popup menus can expose the same native element twice in the accessibility tree.
    $seen=[Collections.Generic.HashSet[string]]::new()
    foreach($element in $Elements){$id=[string]::Join(',',$element.GetRuntimeId());if($seen.Add($id)){$element}}
}
function Test-PetDesktopQuitLabel([string]$Label){
    # Explicitly exclude the adjacent "退出登录" / "Log out" account command.
    $text=($Label -replace '\s+Ctrl\+Q$','').Replace('&','').Trim()
    return ($text -match '^(?:退出\s*(?:ChatGPT|Codex)|Quit(?:\s+(?:ChatGPT|Codex))?|Exit(?:\s+(?:ChatGPT|Codex))?)$')
}
function Invoke-PetDesktopFileQuit($Spec){
    $null=Assert-PetRestartProcess $Spec
    $menu=Get-PetDesktopFileMenu $Spec.Window
    if(-not $menu){throw 'desktop_quit_unavailable'}
    $invoked=$false
    try{
        $menu.Pattern.Expand();$deadline=[DateTime]::UtcNow.AddSeconds(3)
        do{
            $type=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::MenuItem)
            $quit=@($menu.Root.FindAll([Windows.Automation.TreeScope]::Descendants,$type) | Where-Object {
                (Test-PetDesktopQuitLabel $_.Current.Name) -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen
            })
            $quit=@(Get-PetDistinctUiaElements $quit)
            if($quit.Count -eq 1){break};if($quit.Count -gt 1){throw 'desktop_quit_ambiguous'}
            Start-Sleep -Milliseconds 150
        }while([DateTime]::UtcNow -lt $deadline)
        if($quit.Count -ne 1){throw 'desktop_quit_unavailable'}
        $null=Assert-PetRestartProcess $Spec
        $pattern=$null
        if(-not $quit[0].TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){throw 'desktop_quit_unavailable'}
        $pattern.Invoke();$invoked=$true
    }finally{if(-not $invoked){try{$menu.Pattern.Collapse()}catch{}}}
}
function Assert-PetRestartProcess($Spec){
    $p=Get-Process -Id $Spec.DesktopPid -ErrorAction Stop
    if($p.Path -ne $Spec.Executable -or $p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $Spec.DesktopCreated){throw 'desktop_changed'}
    return $p
}
function Request-PetDesktopExit($Spec){
    $p=Assert-PetRestartProcess $Spec
    if($p.MainWindowHandle -ne $Spec.Window){throw 'desktop_changed'}
    if($Spec.MenuId -ge 0){
        if(-not [PetDesktopLifecycle]::RequestQuit($Spec.Window,$Spec.DesktopPid,$Spec.MenuId)){throw 'desktop_close_rejected'}
    }elseif($Spec.QuitMode -eq 'file_menu_uia'){Invoke-PetDesktopFileQuit $Spec}
    else{throw 'desktop_quit_unavailable'}
}
function Test-PetRestartProcessAlive([int]$ProcessId,[long]$Created){
    $p=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if(-not $p){return $false}
    try{
        if($p.HasExited){return $false}
        return ($p.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $Created)
    }catch{
        # Exit can occur between Get-Process and StartTime. Absence is a clean
        # exit; inability to inspect an existing process must remain fail-closed.
        $again=Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if(-not $again){return $false}
        try{if($again.HasExited){return $false}}finally{$again.Dispose()}
        throw 'desktop_process_identity_unavailable'
    }finally{$p.Dispose()}
}
function Assert-PetNoOtherCodexClient($Backend=$null){
    # Never close another desktop, CLI, or another project's Codex client.
    $blocked=@(Get-PetRestartBlockers $Backend)
    if(@($blocked|Where-Object kind -eq 'other_client').Count -gt 0){throw 'desktop_other_client'}
    if($blocked.Count -gt 0){throw 'desktop_shared_daemon'}
}
function Start-PetRegisteredDesktop($Spec){
    Initialize-PetDesktopRestartNative
    return [PetDesktopLifecycle]::Activate($Spec.AppId)
}
function Test-PetDesktopFrontendReady($Backend,[string]$LogRoot=(Join-Path $env:LOCALAPPDATA 'Codex\Logs')){
    $started=[DateTime]::FromFileTimeUtc($Backend.DesktopCreated)
    $days=@($started.ToLocalTime().ToString('yyyy/MM/dd'),[DateTime]::Now.ToString('yyyy/MM/dd')) | Select-Object -Unique
    $good=$null;$bad=$null
    foreach($day in $days){
        $dir=Join-Path $LogRoot $day
        if(-not [IO.Directory]::Exists($dir)){continue}
        $pattern='codex-desktop-*-'+$Backend.DesktopPid+'-t0-*.log'
        foreach($file in @(Get-ChildItem -LiteralPath $dir -Filter $pattern -File)){
            $stream=$null
            try{
                $stream=[IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                # Read bounded head and tail so later logs cannot hide the startup acknowledgement.
                $segments=@();$positions=@(0L)
                if($stream.Length -gt 262144){$positions+=([Math]::Max(262144L,$stream.Length-262144L))}
                foreach($position in $positions){
                    [void]$stream.Seek($position,[IO.SeekOrigin]::Begin)
                    $buffer=[byte[]]::new([int][Math]::Min(262144L,$stream.Length-$position));$count=0
                    while($count -lt $buffer.Length){$read=$stream.Read($buffer,$count,$buffer.Length-$count);if($read -le 0){break};$count+=$read}
                    $segments+=[Text.Encoding]::UTF8.GetString($buffer,0,$count)
                }
                foreach($line in (($segments -join "`n") -split "`n")){
                    if($line -notmatch '\[AppServerConnection\] app_server_connection\.state_changed ' -or
                       $line -notmatch '(?:^|\s)hostId=local(?:\s|$)' -or $line -notmatch '(?:^|\s)transport=stdio(?:\s|$)' -or
                       $line -notmatch '^\d{4}-\d{2}-\d{2}T'){continue}
                    $time=[DateTimeOffset]::Parse($line.Split(' ')[0]).UtcDateTime
                    if($time -lt $started){continue}
                    if($line -match '(?:^|\s)cause=post_initialize_connection_state(?:\s|$)' -and
                        $line -match '(?:^|\s)next=connected(?:\s|$)' -and $line -match '(?:^|\s)initialized=true(?:\s|$)'){
                        if($null -eq $good -or $time -gt $good){$good=$time}
                    }elseif($line -match '(?:^|\s)next=(?:disconnected|error|connecting|restarting)(?:\s|$)'){
                        if($null -eq $bad -or $time -gt $bad){$bad=$time}
                    }
                }
            }catch{}finally{if($stream){$stream.Dispose()}}
        }
    }
    return ($null -ne $good -and ($null -eq $bad -or $good -gt $bad))
}
function Test-PetFreshDesktopBackend($Previous,$Next,$Spec){
    return ($Next.DesktopPath -eq $Spec.Executable -and
        ($Next.DesktopPid -ne $Previous.DesktopPid -or $Next.DesktopCreated -ne $Previous.DesktopCreated) -and
        ($Next.BackendPid -ne $Previous.BackendPid -or $Next.Created -ne $Previous.Created))
}
function Assert-PetRestartTarget($Profile){
    if($Profile.home -ne $script:CodexHome){throw 'restart_target_invalid'}
    $raw=Unprotect-Text $Profile.encryptedAuth
    if((Get-IdentityKey $raw) -ne $Profile.key){throw 'restart_target_invalid'}
    $auth=$raw | ConvertFrom-Json
    try{
        $payload=$auth.tokens.access_token.Split('.')[1].Replace('-','+').Replace('_','/')
        $payload+='='*((4-$payload.Length%4)%4)
        $claims=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if(-not $claims.exp -or [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -le [DateTimeOffset]::UtcNow.AddMinutes(2)){throw 'expired'}
    }catch{throw 'restart_target_expired'}
    return $raw
}
function Start-PetDesktopRestartSwitchCore {
    param($Profile,[string]$ExpectedKey,[bool]$IdleConfirmed,$Trace,[int]$CloseSeconds=25,[int]$ConnectSeconds=45)
    if(-not $IdleConfirmed){$Trace.phase='idle_required';throw 'idle_required'}
    $Trace.phase='restart_preflight'
    Assert-Configuration
    $target=Assert-PetRestartTarget $Profile
    $previous=Get-PetRestartBackend
    Assert-PetNoOtherCodexClient $previous
    $spec=Get-PetDesktopLaunchSpec $previous
    $source=[IO.File]::ReadAllText($script:AuthPath)
    if((Get-IdentityKey $source) -ne $ExpectedKey){$Trace.phase='source_changed';throw 'source_changed'}
    # Same-account selection must not close Codex or rewrite credentials.
    if($Profile.key -eq $ExpectedKey){
        $ready=Test-PetDesktopFrontendReady $previous
        if(-not $ready){$Trace.phase='frontend_unconfirmed';throw 'frontend_unconfirmed'}
        return [pscustomobject]@{Previous=$previous;TargetKey=$ExpectedKey;Label=$Profile.label;unchanged=$true;desktop_client_ready_confirmed=$true;auth_exchange_confirmed=$false;restart_performed=$false}
    }
    Save-Profile $source '' | Out-Null
    Write-Atomic (Join-Path $script:Store 'backend-recovery.json') (([ordered]@{home=$script:CodexHome;encryptedAuth=(Protect-Text $source)}) | ConvertTo-Json)
    $verify=Get-PetRestartBackend
    if($verify.DesktopPid -ne $previous.DesktopPid -or $verify.DesktopCreated -ne $previous.DesktopCreated -or $verify.BackendPid -ne $previous.BackendPid -or $verify.Created -ne $previous.Created){throw 'desktop_changed'}
    Assert-PetNoOtherCodexClient $previous
    $owned=Get-PetOwnedRestartIdentities $previous
    $Trace.phase='desktop_close';Request-PetDesktopExit $spec
    $Trace.phase='desktop_drain'
    try{Wait-PetOwnedRestartExit $previous $owned $CloseSeconds}catch{
        $drainError=$_
        # No exchange has occurred. If the original desktop really exited and
        # the source identity is unchanged, recover only its registered entry.
        try{
            if(-not (Test-PetRestartProcessAlive $previous.DesktopPid $previous.DesktopCreated) -and
               (Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -eq $ExpectedKey){
                [void](Start-PetRegisteredDesktop $spec)
                $Trace|Add-Member -NotePropertyName source_reopen_requested -NotePropertyValue $true -Force
            }
        }catch{} # Recovery must not mask the original drain error or retry the switch.
        throw $drainError
    }
    $Trace.desktop_closed=$true
    $Trace.phase='restart_exchange'
    Assert-PetNoOtherCodexClient
    # Read the final source after exit; its refresh token may have rotated during shutdown.
    $source=[IO.File]::ReadAllText($script:AuthPath)
    if((Get-IdentityKey $source) -ne $ExpectedKey){$Trace.phase='source_changed';throw 'source_changed'}
    Save-Profile $source '' | Out-Null
    Write-Atomic (Join-Path $script:Store 'backend-recovery.json') (([ordered]@{home=$script:CodexHome;encryptedAuth=(Protect-Text $source)}) | ConvertTo-Json)
    Assert-Configuration;Assert-PetNoOtherCodexClient
    if([IO.File]::ReadAllText($script:AuthPath) -ne $source){$Trace.phase='source_changed';throw 'source_changed'}
    Write-Atomic $script:AuthPath $target
    $Trace.auth_changed=$true
    if((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $Profile.key){$Trace.phase='source_changed';throw 'source_changed'}
    Assert-PetNoOtherCodexClient
    $launchAfter=[DateTime]::UtcNow.ToFileTimeUtc()
    $Trace.phase='desktop_launch';[void](Start-PetRegisteredDesktop $spec)
    $Trace.phase='frontend_reconnect';$deadline=[DateTime]::UtcNow.AddSeconds($ConnectSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        if((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $Profile.key){$Trace.phase='source_changed';throw 'source_changed'}
        $next=$null;try{$next=Get-DesktopBackend}catch{}
        if($next -and $next.DesktopCreated -ge $launchAfter -and (Test-PetFreshDesktopBackend $previous $next $spec) -and (Test-PetDesktopFrontendReady $next)){
            $Trace.frontend_ready=$true
            return [pscustomobject]@{Previous=$previous;TargetKey=$Profile.key;Label=$Profile.label;unchanged=$false;desktop_client_ready_confirmed=$true;auth_exchange_confirmed=$true;restart_performed=$true}
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'frontend_reconnect_timeout'
}
function Start-PetDesktopRestartSwitch {
    param($Profile,[string]$ExpectedKey,[bool]$IdleConfirmed,$Trace,[int]$CloseSeconds=25,[int]$ConnectSeconds=45,[bool]$ManageDaemon=$false)
    if(-not $ManageDaemon){return Start-PetDesktopRestartSwitchCore -Profile $Profile -ExpectedKey $ExpectedKey -IdleConfirmed $IdleConfirmed -Trace $Trace -CloseSeconds $CloseSeconds -ConnectSeconds $ConnectSeconds}
    if(-not $IdleConfirmed){$Trace.phase='idle_required';throw 'idle_required'}
    $Trace.phase='restart_preflight'
    Assert-Configuration;[void](Assert-PetRestartTarget $Profile)
    $backend=Get-PetRestartBackend
    $rows=@(Get-PetRestartClientRows);$blockers=@(Get-PetRestartBlockers $backend $rows)
    if(@($blockers|Where-Object kind -eq 'other_client').Count -gt 0){throw 'desktop_other_client'}
    $identities=@(Get-PetManagedDaemonIdentities $rows | Where-Object {$_.role -eq 'daemon.pid'})
    if($identities.Count -eq 0 -or $Profile.key -eq $ExpectedKey){return Start-PetDesktopRestartSwitchCore -Profile $Profile -ExpectedKey $ExpectedKey -IdleConfirmed $IdleConfirmed -Trace $Trace -CloseSeconds $CloseSeconds -ConnectSeconds $ConnectSeconds}
    [void](Get-PetDesktopLaunchSpec $backend)
    if((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -ne $ExpectedKey){throw 'source_changed'}
    $restartNeeded=$false
    try{
        Invoke-PetManagedDaemonCommand $backend.BackendPath 'stop'
        $restartNeeded=$true
        $deadline=[DateTime]::UtcNow.AddSeconds(8)
        while(@($identities|Where-Object {Test-PetRestartProcessAlive $_.pid $_.created}).Count -gt 0){if([DateTime]::UtcNow -ge $deadline){throw 'desktop_shared_daemon_control_failed'};Start-Sleep -Milliseconds 150}
        Assert-PetNoOtherCodexClient $backend
        return Start-PetDesktopRestartSwitchCore -Profile $Profile -ExpectedKey $ExpectedKey -IdleConfirmed $IdleConfirmed -Trace $Trace -CloseSeconds $CloseSeconds -ConnectSeconds $ConnectSeconds
    }finally{
        if($restartNeeded){Invoke-PetManagedDaemonCommand $backend.BackendPath 'start'}
    }
}

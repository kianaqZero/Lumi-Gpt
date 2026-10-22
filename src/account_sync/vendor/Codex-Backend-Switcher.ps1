param([switch]$SelfTest, [switch]$InspectOnly, [switch]$LibraryOnly, [string]$PreviewPath)
$ErrorActionPreference = 'Stop'
$runBackendSelfTest=$SelfTest
$runBackendInspectOnly=$InspectOnly
$runBackendLibraryOnly=$LibraryOnly
. (Join-Path $PSScriptRoot 'Codex-Account-Switcher.ps1') -LibraryOnly

# Pause only the selected backend during the atomic auth file exchange.
# This prevents old refresh tokens overwriting the new account before exit.
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class CodexBackendExchange {
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr handle, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessTimes(IntPtr handle, out long created, out long exited, out long kernel, out long user);
    [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr handle);
    [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr handle);
    static void WriteAtomic(string path, string raw) {
        string temp=path+"."+Guid.NewGuid().ToString("N")+".tmp";
        try {
            File.WriteAllText(temp,raw,new UTF8Encoding(false));
            if(File.Exists(path)) File.Replace(temp,path,null);
            else File.Move(temp,path);
        } finally { if(File.Exists(temp)) File.Delete(temp); }
    }
    public static void SwapAndStop(int pid, long expectedCreated, string path, string target, string original) {
        IntPtr handle=OpenProcess(0x1000|0x0800|0x0001,false,pid);
        if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot access selected backend");
        bool paused=false, terminated=false, swapped=false;
        try {
            long created,exited,kernel,user;
            if(!GetProcessTimes(handle,out created,out exited,out kernel,out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if(created!=expectedCreated) throw new InvalidOperationException("Backend changed; retry detection");
            if(NtSuspendProcess(handle)!=0) throw new InvalidOperationException("Cannot pause backend; auth unchanged");
            paused=true;
            if(File.ReadAllText(path)!=original) throw new InvalidOperationException("Login changed during preparation; retry detection");
            WriteAtomic(path,target); swapped=true;
            if(!TerminateProcess(handle,0)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot stop selected backend");
            terminated=true;
        } catch {
            if(swapped && !terminated) WriteAtomic(path,original);
            throw;
        } finally {
            if(paused && !terminated) NtResumeProcess(handle);
            CloseHandle(handle);
        }
    }
}
'@

function Select-DesktopBackend($Rows) {
    $found = @()
    foreach ($row in $Rows) {
        if ($row.Name -ne 'codex.exe' -or
            $row.CommandLine -notmatch '(?:^|\s)app-server(?:\s|$)' -or
            $row.CommandLine -match '(?:^|\s)(?:exec-server|proxy|daemon)(?:\s|$)' -or
            $row.CommandLine -match '(?:^|\s)--listen(?:\s|=)(?!stdio://)') { continue }
        $parent = @($Rows | Where-Object { $_.ProcessId -eq $row.ParentProcessId })
        if ($parent.Count -ne 1 -or $parent[0].Name -notin @('ChatGPT.exe','Codex.exe')) { continue }
        $app = $parent[0]
        if (-not $app.ExecutablePath -or $app.ExecutablePath -notmatch '(?i)(?:OpenAI\.Codex_[^\\/]+|OpenAI[\\/](?:Codex|ChatGPT))[\\/]') { continue }
        if (@($Rows | Where-Object {$_.ProcessId -eq $app.ParentProcessId -and $_.Name -in @('ChatGPT.exe','Codex.exe')}).Count -gt 0) { continue }
        if (-not $row.ExecutablePath -or $row.ExecutablePath -notmatch '(?i)OpenAI[\\/]Codex[\\/]bin[\\/][^\\/]+[\\/]codex\.exe$') { continue }
        $found += [pscustomobject]@{BackendPid=[int]$row.ProcessId; DesktopPid=[int]$app.ProcessId;
            BackendPath=[string]$row.ExecutablePath; DesktopPath=[string]$app.ExecutablePath}
    }
    if ($found.Count -ne 1) { throw '没有找到唯一的 Codex 本地后端。可能存在多个实例、远程连接或版本不兼容。未修改登录记录。' }
    return $found[0]
}

function Get-DesktopBackend {
    $rows = @(Get-CimInstance Win32_Process | Where-Object {$_.Name -in @('codex.exe','ChatGPT.exe','Codex.exe')})
    $selected = Select-DesktopBackend $rows
    $process = Get-Process -Id $selected.BackendPid -ErrorAction Stop
    $desktop = Get-Process -Id $selected.DesktopPid -ErrorAction Stop
    if ($process.Path -ne $selected.BackendPath -or $desktop.Path -ne $selected.DesktopPath) { throw '进程已发生变化，请重新检测。' }
    $selected | Add-Member -NotePropertyName Created -NotePropertyValue ($process.StartTime.ToUniversalTime().ToFileTimeUtc())
    $selected | Add-Member -NotePropertyName DesktopCreated -NotePropertyValue ($desktop.StartTime.ToUniversalTime().ToFileTimeUtc())
    return $selected
}

function Start-BackendSwitch($Profile, [bool]$IdleConfirmed) {
    if (-not $IdleConfirmed) { throw '请先确认所有聊天、自动任务和正在执行的命令均已停止。' }
    Assert-Configuration
    if ($Profile.home -ne $script:CodexHome) { throw '账号记录属于另一份数据目录。' }
    $target = Unprotect-Text $Profile.encryptedAuth
    if ((Get-IdentityKey $target) -ne $Profile.key) { throw '账号快照校验失败，未进行切换。' }
    $auth = $target | ConvertFrom-Json
    $payload = $auth.tokens.access_token.Split('.')[1]
    if ($payload) {
        try {
            $payload = $payload.Replace('-','+').Replace('_','/')
            $payload += '=' * ((4 - $payload.Length % 4) % 4)
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
            if ($claims.exp -and [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) -lt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
                throw '目标账号的访问凭据已接近或超过有效期。请先用原版切换器进入该账号，再保存更新快照。'
            }
        } catch { if ($_.Exception.Message -like '目标账号*') { throw } }
    }
    $backend = Get-DesktopBackend
    $current = [IO.File]::ReadAllText($script:AuthPath)
    $currentKey = Get-IdentityKey $current
    Save-Profile $current '' | Out-Null
    if ($currentKey -eq $Profile.key) { $target = $current }
    $recovery = [ordered]@{home=$script:CodexHome; encryptedAuth=(Protect-Text $current)}
    Write-Atomic (Join-Path $script:Store 'backend-recovery.json') ($recovery | ConvertTo-Json)
    $verify = Get-DesktopBackend
    if ($verify.BackendPid -ne $backend.BackendPid -or $verify.Created -ne $backend.Created) { throw '后端已经变化，未切换。请重新检测。' }
    [CodexBackendExchange]::SwapAndStop($backend.BackendPid, $backend.Created, $script:AuthPath, $target, $current)
    return [pscustomobject]@{Previous=$backend; TargetKey=$Profile.key; Label=$Profile.label; Started=[DateTime]::UtcNow}
}

function Test-BackendReconnected($Pending, $Backend, [long]$CurrentDesktopCreated, [string]$DiskKey) {
    if ($Backend.DesktopPid -ne $Pending.Previous.DesktopPid -or
        $CurrentDesktopCreated -ne $Pending.Previous.DesktopCreated) { throw '桌面主进程发生变化，不能确认保留了原窗口。' }
    if ($DiskKey -ne $Pending.TargetKey) { throw '登录记录未保持在目标账号。请停止测试并恢复原账号。' }
    return ($Backend.BackendPid -ne $Pending.Previous.BackendPid -or $Backend.Created -ne $Pending.Previous.Created)
}

$script:CodexHome = if ($env:CODEX_HOME) {[IO.Path]::GetFullPath($env:CODEX_HOME)} else {Join-Path $env:USERPROFILE '.codex'}
$script:AuthPath = Join-Path $script:CodexHome 'auth.json'
$script:Store = Join-Path $env:LOCALAPPDATA 'CodexAccountSwitcher/profiles'
if ($runBackendLibraryOnly) { return }
if ($runBackendInspectOnly) {
    $backend = Get-DesktopBackend
    $profiles = if (Test-Path -LiteralPath $script:Store) {@(Get-Profiles).Count} else {0}
    Write-Output ('READ-ONLY: desktop=' + $backend.DesktopPid + '; local-backend=' + $backend.BackendPid + '; saved-profiles=' + $profiles)
    Write-Output 'No account file changed. No process stopped. No model request sent.'
    exit
}

if ($runBackendSelfTest) {
    $script:CodexHome = Join-Path $PSScriptRoot ('backend-test-' + [Guid]::NewGuid().ToString('N'))
    $script:Store = Join-Path $script:CodexHome 'profiles'
    $script:AuthPath = Join-Path $script:CodexHome 'auth.json'
    [IO.Directory]::CreateDirectory($script:Store) | Out-Null
    function Fake-Auth([string]$Id) {
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"sub":"'+$Id+'"}')).TrimEnd('=').Replace('+','-').Replace('/','_')
        return (@{auth_mode='chatgpt';tokens=@{account_id=$Id;id_token=('x.'+$payload+'.x');access_token='FAKE';refresh_token='FAKE'}} | ConvertTo-Json)
    }
    function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
    $fake = $null
    try {
        $rows = @(
            [pscustomobject]@{Name='ChatGPT.exe';ProcessId=100;ParentProcessId=1;ExecutablePath='C:\Program Files\WindowsApps\OpenAI.Codex_test\app\ChatGPT.exe'},
            [pscustomobject]@{Name='codex.exe';ProcessId=101;ParentProcessId=100;ExecutablePath='C:\Users\test\AppData\Local\OpenAI\Codex\bin\test\codex.exe';CommandLine='codex.exe -c x=true app-server'},
            [pscustomobject]@{Name='codex.exe';ProcessId=102;ParentProcessId=100;ExecutablePath='C:\Users\test\AppData\Local\OpenAI\Codex\bin\test\codex.exe';CommandLine='codex.exe exec-server --remote https://example.invalid'},
            [pscustomobject]@{Name='codex.exe';ProcessId=103;ParentProcessId=1;ExecutablePath='C:\Users\test\AppData\Local\OpenAI\Codex\bin\test\codex.exe';CommandLine='codex.exe app-server'}
        )
        Assert-True ((Select-DesktopBackend $rows).BackendPid -eq 101) 'Backend selection failed'
        $rejected=$false
        try { Select-DesktopBackend ($rows + $rows[1]) | Out-Null } catch { $rejected=$true }
        Assert-True $rejected 'Multiple backend guard failed'
        $rejected=$false
        try { Start-BackendSwitch $null $false | Out-Null } catch { $rejected=$true }
        Assert-True $rejected 'Idle guard failed'
        $a=Fake-Auth 'TEST-A'; $b=Fake-Auth 'TEST-B'
        $keyA=Save-Profile $a 'A'; $keyB=Save-Profile $b 'B'
        Write-Atomic $script:AuthPath $a
        $history=Join-Path $script:CodexHome 'history.jsonl'
        [IO.File]::WriteAllText($history,'TEST HISTORY')
        # Only this test-created sleep process is passed to native stop tests.
        $fake=Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 60') -WindowStyle Hidden -PassThru
        $fakeCreated=$fake.StartTime.ToUniversalTime().ToFileTimeUtc()
        $rejected=$false
        try { [CodexBackendExchange]::SwapAndStop($fake.Id,($fakeCreated+1),$script:AuthPath,$b,$a) } catch { $rejected=$true }
        Assert-True ($rejected -and [IO.File]::ReadAllText($script:AuthPath) -eq $a -and -not $fake.HasExited) 'PID reuse guard failed'
        $rejected=$false
        try { [CodexBackendExchange]::SwapAndStop($fake.Id,$fakeCreated,$script:AuthPath,$b,'WRONG SNAPSHOT') } catch { $rejected=$true }
        Assert-True ($rejected -and -not $fake.HasExited -and [IO.File]::ReadAllText($script:AuthPath) -eq $a) 'Concurrent login guard failed'
        [CodexBackendExchange]::SwapAndStop($fake.Id,$fakeCreated,$script:AuthPath,$b,$a)
        Assert-True ($fake.WaitForExit(5000)) 'Test backend did not exit'
        Assert-True ((Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))) -eq $keyB) 'Swap failed'
        Assert-True ([IO.File]::ReadAllText($history) -eq 'TEST HISTORY') 'History changed'
        $previous=[pscustomobject]@{BackendPid=101;Created=1;DesktopPid=100;DesktopCreated=99}
        $pending=[pscustomobject]@{Previous=$previous;TargetKey=$keyB}
        $replacement=[pscustomobject]@{BackendPid=104;Created=2;DesktopPid=100}
        Assert-True (Test-BackendReconnected $pending $replacement 99 $keyB) 'Reconnect check failed'
        $rejected=$false
        try { Test-BackendReconnected $pending $replacement 99 $keyA | Out-Null } catch { $rejected=$true }
        Assert-True $rejected 'Wrong account check failed'
        $rejected=$false
        try { Test-BackendReconnected $pending $replacement 98 $keyB | Out-Null } catch { $rejected=$true }
        Assert-True $rejected 'Desktop identity check failed'
        Write-Output 'PASS: precise backend selection, cloud exclusion, idle guard, PID identity, concurrent-login rejection, native isolated swap/stop, encrypted profiles, history preservation, reconnect checks. Real Codex untouched.'
    } finally {
        if ($fake -and -not $fake.HasExited) { $fake.Kill(); $fake.WaitForExit(5000) | Out-Null }
        if ($fake) { $fake.Dispose() }
        $resolved=[IO.Path]::GetFullPath($script:CodexHome)
        $testRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
        if ($resolved.StartsWith($testRoot,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('backend-test-')) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[IO.Directory]::CreateDirectory($script:Store) | Out-Null
$mutexName=if($PreviewPath){'Local\CodexAccountSwitcherPreview'}else{'Local\CodexAccountSwitcher'}
$mutex=New-Object Threading.Mutex($false,$mutexName)
if (-not $mutex.WaitOne(0)) {
    [Windows.Forms.MessageBox]::Show('请先关闭原版切换器，再打开后端试验版。','切换器已打开') | Out-Null
    $mutex.Dispose(); exit
}
$form=New-Object Windows.Forms.Form
$form.Text='Codex 后端切换器 · 试验版'
$form.Size=New-Object Drawing.Size(730,650)
$form.MinimumSize=$form.Size
$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Microsoft YaHei UI',10)
$intro=New-Object Windows.Forms.Label
$intro.SetBounds(22,18,665,60)
$intro.Text="保留 Codex 窗口和本地聊天，只重连本地后端。`r`n试验版：所有项目任务结束后再验证。"
$homeLabel=New-Object Windows.Forms.Label
$homeLabel.SetBounds(22,80,665,40)
$homeLabel.Text='共用数据目录：'+$script:CodexHome
$list=New-Object Windows.Forms.ListBox
$list.SetBounds(22,125,665,135)
$list.DisplayMember='label'
$detectButton=New-Object Windows.Forms.Button
$detectButton.SetBounds(22,273,215,36)
$detectButton.Text='检测后端（只读）'
$refreshButton=New-Object Windows.Forms.Button
$refreshButton.SetBounds(247,273,215,36)
$refreshButton.Text='更新当前账号快照'
$reloadButton=New-Object Windows.Forms.Button
$reloadButton.SetBounds(472,273,215,36)
$reloadButton.Text='刷新账号列表'
$idleBox=New-Object Windows.Forms.CheckBox
$idleBox.SetBounds(22,325,665,42)
$idleBox.Text='我已确认所有聊天、自动任务和运行命令均已停止'
$switchButton=New-Object Windows.Forms.Button
$switchButton.SetBounds(22,380,325,42)
$switchButton.Text='切换账号并重连后端'
$switchButton.Enabled=$false
$restoreButton=New-Object Windows.Forms.Button
$restoreButton.SetBounds(362,380,325,42)
$restoreButton.Text='恢复上一次账号并重连'
$restoreButton.Enabled=$false
$status=New-Object Windows.Forms.Label
$status.SetBounds(22,440,665,145)
$status.Text="直接读取原版工具保存的 A / B，无需重新添加。`r`n请先点只读检测。切换会结束整个本地后端；窗口保留。`r`n工具不能可靠自动判断任务空闲；请在所有任务结束后勾选确认。"
$script:Pending=$null
$timer=New-Object Windows.Forms.Timer
$timer.Interval=1000
function Reload-Profiles {
    $list.Items.Clear()
    foreach ($p in (Get-Profiles)) { $list.Items.Add($p) | Out-Null }
}
function Set-SwitchEnabled {
    $ready=$idleBox.Checked -and $null -eq $script:Pending
    $switchButton.Enabled=$ready
    $restoreButton.Enabled=$ready
    $refreshButton.Enabled=$null -eq $script:Pending
}
function Display-Failure {
    $status.Text=[string]$_.Exception.Message
    [Windows.Forms.MessageBox]::Show($status.Text,'未确认切换成功','OK','Information') | Out-Null
}
function Begin-Switch($Profile) {
    $status.Text='正在保存恢复记录并重连后端……'
    $form.Refresh()
    $script:Pending=Start-BackendSwitch $Profile $idleBox.Checked
    $idleBox.Checked=$false
    Set-SwitchEnabled
    $status.Text='登录记录已更换。正在等待 Codex 自动重连，窗口应保持打开……'
    $timer.Start()
}
$detectButton.Add_Click({
    try {
        $b=Get-DesktopBackend
        $status.Text="检测到桌面进程 $($b.DesktopPid)，本地后端 $($b.BackendPid)。`r`n检测没有更换账号或停止任何进程。所有任务结束后再切换。"
    } catch { Display-Failure }
})
$refreshButton.Add_Click({
    try {
        Assert-Configuration
        Save-Profile ([IO.File]::ReadAllText($script:AuthPath)) '' | Out-Null
        Reload-Profiles
        $status.Text='已更新当前登录快照并保留原账号名称。'
    } catch { Display-Failure }
})
$reloadButton.Add_Click({try {Reload-Profiles} catch {Display-Failure}})
$idleBox.Add_CheckedChanged({Set-SwitchEnabled})
$switchButton.Add_Click({
    try {
        if (-not $list.SelectedItem) {throw '请先选中已保存的账号。'}
        Begin-Switch $list.SelectedItem
    } catch {Display-Failure; Set-SwitchEnabled}
})
$restoreButton.Add_Click({
    try {
        $path=Join-Path $script:Store 'backend-recovery.json'
        if (-not [IO.File]::Exists($path)) {throw '尚无后端切换恢复记录。'}
        $record=[IO.File]::ReadAllText($path) | ConvertFrom-Json
        $raw=Unprotect-Text $record.encryptedAuth
        $key=Get-IdentityKey $raw
        $known=Get-Profiles | Where-Object {$_.key -eq $key} | Select-Object -First 1
        $profile=[pscustomobject]@{home=$record.home;key=$key;encryptedAuth=$record.encryptedAuth;
            label=$(if($known){$known.label}else{'恢复账号'})}
        Begin-Switch $profile
    } catch {Display-Failure; Set-SwitchEnabled}
})
$timer.Add_Tick({
    if (-not $script:Pending) {$timer.Stop();return}
    $p=$script:Pending
    try {
        $b=Get-DesktopBackend
        $diskKey=Get-IdentityKey ([IO.File]::ReadAllText($script:AuthPath))
        if (Test-BackendReconnected $p $b $b.DesktopCreated $diskKey) {
            $timer.Stop(); $script:Pending=$null
            $status.Text="检测到新的本地后端，桌面主进程仍是原来的。`r`n目标账号：$($p.Label)。请在 Codex 中确认账号 / 额度，再在原聊天发一条测试消息。`r`n这里只验证后端进程重新建立；在线登录、实际用量和续聊仍待你验证。"
            Reload-Profiles; Set-SwitchEnabled
        }
    } catch {
        if ($_.Exception.Message -notlike '没有找到唯一*') {
            $timer.Stop(); $script:Pending=$null; Display-Failure; Set-SwitchEnabled
        }
    }
    if ($script:Pending -and ([DateTime]::UtcNow-$p.Started).TotalSeconds -ge 30) {
        $timer.Stop(); $script:Pending=$null
        $status.Text="30 秒内未检测到新后端，不能确认切换成功。`r`n请在 Codex 的连接提示处点击重新连接，再点只读检测。`r`n若仍无法恢复，请用原版切换器退出 / 重开，或重新通过官方入口登录。"
        Set-SwitchEnabled
    }
})
$form.Add_FormClosing({
    if ($script:Pending) {
        $_.Cancel=$true
        $status.Text='正在观察重连结果，请等本次检测结束后关闭工具。'
    }
})
$form.Controls.AddRange(@($intro,$homeLabel,$list,$detectButton,$refreshButton,$reloadButton,$idleBox,$switchButton,$restoreButton,$status))
try {
    Reload-Profiles
    if($PreviewPath) {
        $form.ShowInTaskbar=$false
    $form.Opacity=0
    $form.Show()
        [Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try {$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save($PreviewPath)} finally {$bitmap.Dispose()}
        $form.Close()
    } else {[void]$form.ShowDialog()}
} finally {$timer.Stop();$timer.Dispose();$mutex.ReleaseMutex();$mutex.Dispose()}

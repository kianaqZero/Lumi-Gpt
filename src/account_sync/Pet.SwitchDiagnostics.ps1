# Safe diagnostics and process ownership only. No credential parsing or process termination.
. (Join-Path $PSScriptRoot 'Pet.InstallDetection.ps1')
function Get-PetRestartClientRows {
    return @(Get-CimInstance Win32_Process | Where-Object {$_.Name -in @('codex.exe','ChatGPT.exe','Codex.exe')})
}
function Get-PetRestartOwnedRows($Backend,$Rows) {
    $desktopFamily=[Collections.Generic.HashSet[int]]::new()
    [void]$desktopFamily.Add([int]$Backend.DesktopPid)
    # Chromium's crash handler can itself have a same-executable child.
    # Resolve ancestry from this exact desktop; an executable path alone is not ownership.
    do{
        $added=$false
        foreach($r in $Rows){
            if($r.Name -in @('ChatGPT.exe','Codex.exe') -and $r.ExecutablePath -eq $Backend.DesktopPath -and
                $desktopFamily.Contains([int]$r.ParentProcessId) -and $r.CommandLine -match '(?:^|\s)--type='){
                if($desktopFamily.Add([int]$r.ProcessId)){$added=$true}
            }
        }
    }while($added)
    foreach($r in $Rows){
        if($r.ProcessId -eq $Backend.DesktopPid -and $r.ExecutablePath -eq $Backend.DesktopPath){$r;continue}
        if($r.ProcessId -eq $Backend.BackendPid -and $r.ExecutablePath -eq $Backend.BackendPath -and $r.ParentProcessId -eq $Backend.DesktopPid){$r;continue}
        if($desktopFamily.Contains([int]$r.ProcessId) -and $r.ExecutablePath -eq $Backend.DesktopPath){$r;continue}
        if($r.Name -eq 'codex.exe' -and $r.ParentProcessId -eq $Backend.DesktopPid -and $r.ExecutablePath -eq $Backend.BackendPath -and $r.CommandLine -match '(?:^|\s)exec-server(?:\s|$)'){$r}
    }
}
function Get-PetOwnedRestartIdentities($Backend) {
    $rows=Get-PetRestartClientRows
    $owned=@(Get-PetRestartOwnedRows $Backend $rows)
    foreach($r in $owned){
        $p=Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue
        if(-not $p){continue}
        if($p.Path -ne $r.ExecutablePath){throw 'desktop_changed'}
        $created=$p.StartTime.ToUniversalTime().ToFileTimeUtc()
        if($created -lt $Backend.DesktopCreated){throw 'desktop_changed'}
        if($r.ProcessId -eq $Backend.DesktopPid -and $created -ne $Backend.DesktopCreated){throw 'desktop_changed'}
        if($r.ProcessId -eq $Backend.BackendPid -and $created -ne $Backend.Created){throw 'desktop_changed'}
        [pscustomobject]@{pid=[int]$r.ProcessId;created=[long]$created;path=[string]$r.ExecutablePath}
    }
}
function Wait-PetOwnedRestartExit($Backend,$Identities,[int]$Seconds=25) {
    $deadline=[DateTime]::UtcNow.AddSeconds($Seconds);$cleanSamples=0
    do{
        $alive=@($Identities | Where-Object {Test-PetRestartProcessAlive $_.pid $_.created})
        # Also observe late children of the selected desktop. Never silently exempt them after exit.
        try{$late=@(Get-PetRestartOwnedRows $Backend (Get-PetRestartClientRows))}catch{throw 'desktop_process_scan_failed'}
        if($alive.Count -eq 0 -and $late.Count -eq 0){$cleanSamples++;if($cleanSamples -ge 2){return}}
        else{$cleanSamples=0}
        if([DateTime]::UtcNow -ge $deadline){throw 'desktop_process_drain_timeout'}
        Start-Sleep -Milliseconds 200
    }while($true)
}
function Get-PetSwitchFailureDetail($ErrorRecord) {
    $allowed=@('desktop_process_identity_unavailable','desktop_process_scan_failed','desktop_shared_daemon','desktop_shared_daemon_control_failed','desktop_other_client','desktop_backend_unavailable','desktop_process_drain_timeout','desktop_home_mismatch','desktop_launch_unsupported','desktop_changed','desktop_quit_unavailable','desktop_quit_ambiguous','desktop_close_rejected','desktop_close_timeout','restart_target_invalid','restart_target_expired','frontend_unconfirmed','source_changed','frontend_reconnect_timeout')
    $message=[string]$ErrorRecord.Exception.Message
    if($message -in $allowed){return $message}
    return 'unclassified'
}
function Get-PetSwitchFailureMessage([string]$Detail,[string]$Stage) {
    switch($Detail){
        'desktop_process_identity_unavailable' {return 'Codex 退出期间未能核验剩余进程，未交换账号。请从原快捷方式打开 Codex，再刷新检测；不会强制结束进程。'}
        'desktop_process_scan_failed' {return 'Codex 退出期间进程列表读取失败，未交换账号。请从原快捷方式打开 Codex，再刷新检测。'}
        'desktop_shared_daemon' {return 'Codex 后台连接信息已变化，尚未切号。请刷新检测，确认本机和远程任务均结束后重新切换。'}
        'desktop_shared_daemon_control_failed' {return 'Codex 后台连接未确认正常停止或恢复，已停止操作；请刷新检测核对当前登录，勿重复切号。'}
        'desktop_other_client' {return '检测到不属于当前 Codex 窗口的客户端，已停止切号；不会关闭其他项目的客户端。'}
        'desktop_backend_unavailable' {return '没有找到唯一的本地 Codex 后端，未切换账号。可能是后端断开、多个窗口或远程连接；刷新检测不会启动后端。'}
        'desktop_process_drain_timeout' {return '已请求退出 Codex，但属于原窗口的进程仍未全部结束；未交换账号。已停止，不会强制结束进程。'}
        'desktop_home_mismatch' {return 'Codex 注册启动使用的账号目录与桌宠不一致，未退出或切号。'}
        'desktop_launch_unsupported' {return '当前 Codex 安装没有可核验的注册启动入口，未退出或切号。'}
        'desktop_changed' {return '检测期间 Codex 窗口或后端进程发生变化，已停止；请刷新检测。'}
        'desktop_quit_unavailable' {return '未找到可核验的 Codex 退出应用菜单，未切号；不会用强制关闭替代。'}
        'desktop_quit_ambiguous' {return '检测到多个退出菜单，无法确认操作对象，未切号。'}
        'desktop_close_rejected' {return 'Codex 没有接受正常退出请求，未切换账号。'}
        'restart_target_invalid' {return '所选账号快照校验失败或属于另一目录，未退出或切号。'}
        'restart_target_expired' {return '所选账号的访问凭据已过期或接近过期，未退出或切号。请正常登录该账号后重新保存快照。'}
        'source_changed' {return '当前登录记录已被其他操作改变，已停止并丢弃旧额度；请刷新检测。'}
    }
    switch($Stage){
        'restart_preflight' {return '切号预检查未通过，尚未退出 Codex 或交换账号。诊断代码：'+$Detail+'。'}
        'desktop_close' {return '退出应用操作未完成，未交换账号。诊断代码：'+$Detail+'。'}
        'desktop_drain' {return '等待原窗口进程结束未完成，未交换账号。诊断代码：'+$Detail+'。'}
        default {return $null}
    }
}

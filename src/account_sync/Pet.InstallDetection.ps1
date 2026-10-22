# Read-only actual process discovery. Never infer ownership from C/E drive alone.
function Resolve-PetLinkedExecutable([string]$Executable) {
    if(-not $Executable){return ''}
    $full=[IO.Path]::GetFullPath($Executable)
    $ancestor=Split-Path $full -Parent
    for($i=0;$ancestor -and $i -lt 16;$i++){
        $item=Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.PSObject.Properties.Name -contains 'Target' -and $item.Target){
            $targets=@($item.Target)
            if($targets.Count -ne 1){return $full}
            $target=[string]$targets[0]
            if(-not [IO.Path]::IsPathRooted($target)){$target=Join-Path (Split-Path $ancestor -Parent) $target}
            $suffix=$full.Substring($ancestor.TrimEnd('\').Length).TrimStart('\')
            return [IO.Path]::GetFullPath((Join-Path $target $suffix))
        }
        $next=Split-Path $ancestor -Parent;if($next -eq $ancestor){break};$ancestor=$next
    }
    return $full
}
function Get-PetManagedDaemonIdentities($Rows) {
    if(-not (Get-Variable -Name CodexHome -Scope Script -ErrorAction SilentlyContinue) -or -not $script:CodexHome){return @()}
    $root=[IO.Path]::GetFullPath($script:CodexHome).TrimEnd('\')
    $allowed=Join-Path $root 'packages\app-server-daemon\releases'
    $result=@()
    foreach($name in @('daemon.pid','daemon-updater.pid')){
        $file=Join-Path $root ('app-server-daemon\'+$name)
        try{
            if(-not [IO.File]::Exists($file) -or ([IO.FileInfo]$file).Length -gt 4096){continue}
            $record=[IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json
            $match=@($Rows|Where-Object {$_.ProcessId -eq [int]$record.pid})
            if($match.Count -ne 1){continue};$row=$match[0]
            $resolved=Resolve-PetLinkedExecutable ([string]$row.ExecutablePath)
            if($row.Name -ne 'codex.exe' -or -not $resolved.StartsWith($allowed+'\',[StringComparison]::OrdinalIgnoreCase) -or $resolved -notmatch '\\[0-9A-Za-z_.-]+\\bin\\codex\.exe$'){continue}
            if($row.CommandLine -notmatch '(?:^|\s)app-server(?:\s|$)'){continue}
            if($name -eq 'daemon-updater.pid' -and $row.CommandLine -notmatch '(?:^|\s)daemon(?:\s|$)'){continue}
            if($name -eq 'daemon.pid' -and $row.CommandLine -notmatch '--listen(?:=|\s+)unix://'){continue}
            $p=Get-Process -Id $row.ProcessId -ErrorAction Stop
            if($p.StartTime.ToUniversalTime().ToFileTimeUtc() -ne [long]$record.processStartTime -or $p.Path -ne $row.ExecutablePath){continue}
            $result+=@([pscustomobject]@{pid=[int]$row.ProcessId;created=[long]$record.processStartTime;path=[string]$row.ExecutablePath;role=$name})
        }catch{} # Unverifiable processes remain foreign and block exchange.
    }
    return $result
}
function Get-PetRestartBlockers($Backend,$Rows=$null) {
    if($null -eq $Rows){$Rows=@(Get-PetRestartClientRows)}
    $owned=@();if($Backend){$owned=@(Get-PetRestartOwnedRows $Backend $Rows)}
    $daemon=@(Get-PetManagedDaemonIdentities $Rows);$ownedIds=@($owned|ForEach-Object {$_.ProcessId})
    foreach($row in $Rows){
        if($ownedIds -contains $row.ProcessId){continue}
        $known=@($daemon|Where-Object pid -eq $row.ProcessId)
        # The registered updater has no account task and survives daemon stop.
        if($known.Count -eq 1 -and $known[0].role -eq 'daemon-updater.pid'){continue}
        [pscustomobject]@{pid=[int]$row.ProcessId;kind=if($known.Count -eq 1){'shared_daemon'}else{'other_client'};name=[string]$row.Name}
    }
}
function Get-PetCodexInstallationDetection($Backend) {
    $rows=@(Get-PetRestartClientRows);$blockers=@(Get-PetRestartBlockers $Backend $rows)
    [pscustomobject]@{desktop_pid=$Backend.DesktopPid;desktop_path=$Backend.DesktopPath;backend_pid=$Backend.BackendPid;backend_path=$Backend.BackendPath;backend_actual_path=(Resolve-PetLinkedExecutable $Backend.BackendPath);codex_home=$script:CodexHome;blockers=$blockers;shared_daemon_present=(@($blockers|Where-Object kind -eq 'shared_daemon').Count -gt 0);other_client_present=(@($blockers|Where-Object kind -eq 'other_client').Count -gt 0)}
}
function Invoke-PetManagedDaemonCommand([string]$Executable,[ValidateSet('stop','start')][string]$Action) {
    $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=$Executable;$psi.Arguments='app-server daemon '+$Action
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.EnvironmentVariables['CODEX_HOME']=$script:CodexHome
    $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
    try{
        [void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
        # Official grace defaults to 60s and supports up to 300s, plus lock wait.
        if(-not $p.WaitForExit(750000)){throw 'desktop_shared_daemon_control_failed'}
        if($p.ExitCode -ne 0){throw 'desktop_shared_daemon_control_failed'}
    }finally{$p.Dispose()}
}

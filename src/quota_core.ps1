Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Get-AppRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

function Test-CodexHomeReady {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    $c1 = Join-Path $Path 'packages\standalone\current\bin\codex.exe'
    $c2 = Join-Path $Path 'bin\codex.exe'
    if (Test-Path -LiteralPath $c1) { return $true }
    if (Test-Path -LiteralPath $c2) { return $true }
    $hit = Get-ChildItem -LiteralPath $Path -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$hit
}

function Get-PreviousCodexHomeObjects {
    $root = Get-AppRoot
    $bases = @()
    $p1 = Split-Path -Parent $root
    $p2 = if ($p1) { Split-Path -Parent $p1 } else { $null }
    $p3 = if ($p2) { Split-Path -Parent $p2 } else { $null }
    foreach ($b in @($p1,$p2,$p3)) {
        if ($b -and (Test-Path -LiteralPath $b) -and -not ($bases -contains $b)) {
            $bases += $b
        }
    }

    $found = @()
    foreach ($base in $bases) {
        try {
            $dirs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'gpt_quota_pet_v0.4*' -and $_.FullName -ne $root })
            foreach ($dir in $dirs) {
                $candidates = @((Join-Path $dir.FullName 'runtime\codex_home'))
                try {
                    $nested = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue)
                    foreach ($n in $nested) {
                        $candidates += (Join-Path $n.FullName 'runtime\codex_home')
                    }
                } catch {}

                foreach ($candidate in $candidates) {
                    if (Test-CodexHomeReady $candidate) {
                        $item = Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
                        $stamp = if ($item) { $item.LastWriteTimeUtc } else { [DateTime]::MinValue }
                        $found += [pscustomobject]@{ Path=$candidate; Kind='PREVIOUS_BUILD'; Stamp=$stamp }
                    }
                }
            }
        } catch {}
    }

    # PowerShell 5.1 is happier with plain arrays here than Generic.List[object].
    # Sort newest first, then de-duplicate by path without Group-Object/list binder edge cases.
    $ordered = @($found | Sort-Object -Property Stamp -Descending)
    $result = @()
    $seenPaths = @{}
    foreach ($entry in $ordered) {
        if ($null -eq $entry -or -not $entry.Path) { continue }
        $k = $entry.Path.ToLowerInvariant()
        if (-not $seenPaths.ContainsKey($k)) {
            $seenPaths[$k] = $true
            $result += $entry
        }
    }
    return $result
}

function Get-CodexHomeCandidates {
    $root = Get-AppRoot
    $items = @()
    $seen = @{}

    $own = Join-Path $root 'runtime\codex_home'
    if (Test-CodexHomeReady $own) {
        $items += [pscustomobject]@{ Path=$own; Kind='LOCAL'; Stamp=[DateTime]::MaxValue }
        $seen[$own.ToLowerInvariant()] = $true
    }

    if ($env:GPT_QUOTA_PET_CODEX_HOME -and (Test-CodexHomeReady $env:GPT_QUOTA_PET_CODEX_HOME)) {
        $key = $env:GPT_QUOTA_PET_CODEX_HOME.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $items += [pscustomobject]@{ Path=$env:GPT_QUOTA_PET_CODEX_HOME; Kind='ENV'; Stamp=[DateTime]::MaxValue.AddSeconds(-1) }
            $seen[$key] = $true
        }
    }

    $previous = @(Get-PreviousCodexHomeObjects)
    foreach ($obj in $previous) {
        if ($null -eq $obj -or -not $obj.Path) { continue }
        $key = $obj.Path.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $items += $obj
            $seen[$key] = $true
        }
    }

    return $items
}

function Get-PreviousCodexHomes {
    return @(Get-PreviousCodexHomeObjects | Select-Object -ExpandProperty Path)
}

function Get-CodexHome {
    if ($script:ActiveCodexHome -and (Test-CodexHomeReady $script:ActiveCodexHome)) { return $script:ActiveCodexHome }
    $candidates = @(Get-CodexHomeCandidates)
    if ($candidates.Count -gt 0) { return $candidates[0].Path }
    return (Join-Path (Get-AppRoot) 'runtime\codex_home')
}

function Get-CodexHomeKind {
    $active = Get-CodexHome
    foreach ($c in @(Get-CodexHomeCandidates)) {
        if ($c.Path -eq $active) { return $c.Kind }
    }
    return 'MISSING'
}

function Find-CodexExeInHome {
    param([string]$CodexHome)
    if (-not $CodexHome) { return $null }
    $candidates = @(
        (Join-Path $CodexHome 'packages\standalone\current\bin\codex.exe'),
        (Join-Path $CodexHome 'bin\codex.exe')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    if (Test-Path -LiteralPath $CodexHome) {
        $hit = Get-ChildItem -LiteralPath $CodexHome -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-LocalCodexExe {
    return Find-CodexExeInHome (Get-CodexHome)
}

$script:ActiveCodexHome = $null
function Has-JsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return [bool]($Object.PSObject.Properties.Name -contains $Name)
}

function Get-JsonProperty {
    param($Object, [string]$Name, $Default = $null)
    if (Has-JsonProperty $Object $Name) { return $Object.$Name }
    return $Default
}

function Read-JsonRpcResponse {
    param(
        [Parameter(Mandatory=$true)]$Reader,
        [Parameter(Mandatory=$true)][int]$Id,
        [int]$TimeoutMs = 12000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = [int][Math]::Max(100, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $task = $Reader.ReadLineAsync()
        if (-not $task.Wait($remaining)) { break }
        $line = $task.Result
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if (-not $line.StartsWith('{')) { continue }
        try { $obj = $line | ConvertFrom-Json } catch { continue }
        # Only accept a JSON-RPC response, not a server request carrying its own id.
        if ((Has-JsonProperty $obj 'id') -and -not (Has-JsonProperty $obj 'method')) {
            try {
                if ([int]$obj.id -eq $Id) { return $obj }
            } catch {}
        }
    }
    throw "Timed out waiting for app-server response id=$Id"
}

function Send-JsonRpc {
    param($Writer, [hashtable]$Message)
    $json = $Message | ConvertTo-Json -Compress -Depth 16
    $Writer.WriteLine($json)
    $Writer.Flush()
}

function Throw-IfRpcError {
    param($Response, [string]$Stage)
    if ($null -eq $Response) { throw "$Stage returned no response" }
    if (Has-JsonProperty $Response 'error') {
        $err = Get-JsonProperty $Response 'error'
        if ($null -ne $err) {
            throw ($Stage + ' failed: ' + ($err | ConvertTo-Json -Compress -Depth 8))
        }
    }
    if (-not (Has-JsonProperty $Response 'result')) {
        throw "$Stage response did not contain a result object"
    }
}

function Get-PlanFromSnapshot {
    param($AccountResult, $RateLimitResult)
    $account = Get-JsonProperty $AccountResult 'account'
    if ($account -and (Has-JsonProperty $account 'planType')) {
        $v = [string](Get-JsonProperty $account 'planType')
        if ($v) { return $v }
    }
    $snap = Get-JsonProperty $RateLimitResult 'rateLimits'
    if ($snap -and (Has-JsonProperty $snap 'planType')) {
        $v = [string](Get-JsonProperty $snap 'planType')
        if ($v) { return $v }
    }
    return $null
}

function Invoke-CodexAccountSnapshotForHome {
    param([Parameter(Mandatory=$true)][string]$CodexHome)
    $codex = Find-CodexExeInHome $CodexHome
    if (-not $codex) {
        return [pscustomobject]@{ ok=$false; state='runtime_missing'; stage='runtime'; message='OpenAI Codex runtime is not installed.' }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $codex
    $psi.Arguments = 'app-server --listen stdio://'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = Get-AppRoot
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stage = 'start'
    try {
        $writer = $proc.StandardInput
        $reader = $proc.StandardOutput

        $stage = 'initialize'
        Send-JsonRpc $writer @{method='initialize'; id=1; params=@{clientInfo=@{name='gpt_quota_pet'; title='GPT Quota Pet'; version='0.4.6'}; capabilities=@{experimentalApi=$true}}}
        $init = Read-JsonRpcResponse $reader 1 15000
        Throw-IfRpcError $init 'initialize'
        Send-JsonRpc $writer @{method='initialized'}

        $stage = 'account/read'
        Send-JsonRpc $writer @{method='account/read'; id=2; params=@{refreshToken=$false}}
        $acct = Read-JsonRpcResponse $reader 2 15000
        Throw-IfRpcError $acct 'account/read'
        $acctResult = Get-JsonProperty $acct 'result'
        $account = Get-JsonProperty $acctResult 'account'
        if ($null -eq $account) {
            return [pscustomobject]@{ ok=$false; state='not_logged_in'; stage=$stage; message='ChatGPT login is required.' }
        }

        $stage = 'account/rateLimits/read'
        Send-JsonRpc $writer @{method='account/rateLimits/read'; id=3; params=@{excludeResetCreditDetails=$true}}
        $rl = Read-JsonRpcResponse $reader 3 20000
        Throw-IfRpcError $rl 'account/rateLimits/read'
        $rlResult = Get-JsonProperty $rl 'result'

        $plan = Get-PlanFromSnapshot $acctResult $rlResult
        $authType = $null
        if (Has-JsonProperty $account 'type') { $authType = [string](Get-JsonProperty $account 'type') }

        $windows = New-Object System.Collections.Generic.List[object]
        function Add-Window($w, $label) {
            if ($null -eq $w) { return }
            if (-not (Has-JsonProperty $w 'usedPercent')) { return }
            if (-not (Has-JsonProperty $w 'windowDurationMins')) { return }
            $durRaw = Get-JsonProperty $w 'windowDurationMins'
            if ($null -eq $durRaw) { return }
            $usedRaw = Get-JsonProperty $w 'usedPercent'
            if ($null -eq $usedRaw) { return }
            $dur = [double]$durRaw
            $used = [double]$usedRaw
            $reset = $null
            if (Has-JsonProperty $w 'resetsAt') {
                $resetRaw = Get-JsonProperty $w 'resetsAt'
                if ($null -ne $resetRaw) { $reset = [int64]$resetRaw }
            }
            $key = "${dur}|${reset}|${used}"
            if (-not ($windows | Where-Object { $_.key -eq $key })) {
                $windows.Add([pscustomobject]@{ key=$key; label=$label; duration=$dur; used=$used; reset=$reset })
            }
        }

        $single = Get-JsonProperty $rlResult 'rateLimits'
        if ($single) {
            Add-Window (Get-JsonProperty $single 'primary') 'rateLimits:primary'
            Add-Window (Get-JsonProperty $single 'secondary') 'rateLimits:secondary'
        }

        $byId = Get-JsonProperty $rlResult 'rateLimitsByLimitId'
        if ($byId) {
            foreach ($p in $byId.PSObject.Properties) {
                Add-Window (Get-JsonProperty $p.Value 'primary') ($p.Name + ':primary')
                Add-Window (Get-JsonProperty $p.Value 'secondary') ($p.Name + ':secondary')
            }
        }

        $sorted = @($windows | Sort-Object duration)
        if ($sorted.Count -eq 0) {
            return [pscustomobject]@{ ok=$false; state='no_rate_limits'; stage=$stage; plan=$plan; message='Logged in, but account/rateLimits/read returned no usable rate-limit windows.' }
        }

        # Identify windows by duration instead of assuming primary=5h and secondary=weekly.
        # Codex may legitimately return only the weekly (10080-minute) bucket.
        $session = $null
        $weekly = $null
        $sessionCandidates = @($sorted | Where-Object { $_.duration -lt 1440 })
        $weeklyCandidates = @($sorted | Where-Object { $_.duration -ge 1440 })
        if ($sessionCandidates.Count -gt 0) { $session = $sessionCandidates[0] }
        if ($weeklyCandidates.Count -gt 0) { $weekly = $weeklyCandidates[-1] }
        if (-not $session -and -not $weekly) {
            if ($sorted.Count -eq 1) { $session = $sorted[0] }
            else { $session = $sorted[0]; $weekly = $sorted[-1] }
        }

        function Normalize-Window($w) {
            if (-not $w) { return $null }
            $remaining = [Math]::Max(0, [Math]::Min(100, (100.0 - [double]$w.used)))
            $resetIso = $null
            $resetLocal = $null
            if ($w.reset) {
                try {
                    $dto = [DateTimeOffset]::FromUnixTimeSeconds([int64]$w.reset)
                    $resetIso = $dto.UtcDateTime.ToString('o')
                    $resetLocal = $dto.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
                } catch {}
            }
            return [pscustomobject]@{
                used_percent = [Math]::Round([double]$w.used, 1)
                remaining_percent = [Math]::Round($remaining, 1)
                window_minutes = [int][Math]::Round([double]$w.duration)
                resets_at = $w.reset
                reset_iso = $resetIso
                reset_local = $resetLocal
            }
        }

        return [pscustomobject]@{
            ok = $true
            state = 'online'
            stage = 'complete'
            plan = $plan
            auth_type = $authType
            session = Normalize-Window $session
            weekly = Normalize-Window $weekly
            checked_at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    catch {
        $stderrTail = ''
        try {
            if ($proc.StandardError) {
                $task = $proc.StandardError.ReadToEndAsync()
                if ($task.Wait(500)) { $stderrTail = ($task.Result -replace '[\r\n]+',' ').Trim() }
            }
        } catch {}
        $msg = $_.Exception.Message
        if ($stderrTail) {
            if ($stderrTail.Length -gt 500) { $stderrTail = $stderrTail.Substring([Math]::Max(0,$stderrTail.Length-500)) }
            $msg = $msg + ' | app-server: ' + $stderrTail
        }
        return [pscustomobject]@{ ok=$false; state='error'; stage=$stage; message=$msg }
    }
    finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        try { $proc.Dispose() } catch {}
    }
}


function New-ObjectWithExtras {
    param(
        [Parameter(Mandatory=$true)]$InputObject,
        [hashtable]$Extras
    )

    # Windows PowerShell 5.1 can be finicky with Add-Member parameter sets
    # when the input object comes from a pipeline. Build a fresh PSCustomObject
    # instead so diagnostics never fail merely while attaching metadata.
    $map = [ordered]@{}
    if ($null -ne $InputObject) {
        foreach ($prop in @($InputObject.PSObject.Properties)) {
            if ($null -ne $prop -and $prop.Name) {
                $map[$prop.Name] = $prop.Value
            }
        }
    }
    if ($null -ne $Extras) {
        foreach ($key in @($Extras.Keys)) {
            $map[[string]$key] = $Extras[$key]
        }
    }
    return [pscustomobject]$map
}

function Invoke-CodexAccountSnapshot {
    # Keep this a plain PowerShell array for Windows PowerShell 5.1.
    $attempts = @()
    $firstFailure = $null

    # Prefer a runtime already proven to work in this process.
    if ($script:ActiveCodexHome -and (Test-CodexHomeReady $script:ActiveCodexHome)) {
        $cached = Invoke-CodexAccountSnapshotForHome -CodexHome $script:ActiveCodexHome
        if ($cached.ok) {
            return (New-ObjectWithExtras -InputObject $cached -Extras @{
                codex_home = $script:ActiveCodexHome
                runtime_source = 'CACHED'
                attempts = @()
            })
        }
        $script:ActiveCodexHome = $null
    }

    $candidates = @(Get-CodexHomeCandidates)
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            ok=$false
            state='runtime_missing'
            stage='runtime'
            message='OpenAI Codex runtime is not installed.'
            attempts=@()
        }
    }

    foreach ($candidate in $candidates) {
        $result = Invoke-CodexAccountSnapshotForHome -CodexHome $candidate.Path
        $attempts += [pscustomobject]@{
            path=$candidate.Path
            kind=$candidate.Kind
            state=$result.state
            stage=$result.stage
        }

        if ($result.ok) {
            $script:ActiveCodexHome = $candidate.Path
            return (New-ObjectWithExtras -InputObject $result -Extras @{
                codex_home = $candidate.Path
                runtime_source = $candidate.Kind
                attempts = @($attempts)
            })
        }

        if ($null -eq $firstFailure) { $firstFailure = $result }
        # A runtime can contain codex.exe but no login. Keep probing older pet builds.
        # Other per-runtime failures are also non-fatal during migration.
        continue
    }

    if ($null -eq $firstFailure) {
        $firstFailure = [pscustomobject]@{
            ok=$false
            state='error'
            stage='runtime_select'
            message='No usable Codex runtime was found.'
        }
    }

    return (New-ObjectWithExtras -InputObject $firstFailure -Extras @{
        attempts = @($attempts)
    })
}

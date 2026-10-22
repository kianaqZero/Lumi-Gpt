Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

function Get-AppRoot {
    if ($PSScriptRoot) { return $PSScriptRoot }
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
}

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

function Invoke-PetSelectedAccountQuota {
    param([string]$CodexHome,[string]$CodexExecutable,[string]$AccessToken,[string]$AccountId,[string]$ConsumeCreditId='',[string]$RequestId='',[scriptblock]$BeforeConsume={})
    $codex = $CodexExecutable
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
    $psi.WorkingDirectory = $CodexHome
    $psi.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    foreach($keyName in @('OPENAI_API_KEY','CODEX_API_KEY','OPENAI_BASE_URL')) {
        $psi.EnvironmentVariables.Remove($keyName)
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $discardedStderr = $proc.StandardError.ReadToEndAsync()
    $consumeOutcome=$null
    $stage = 'start'
    try {
        $writer = $proc.StandardInput
        $reader = $proc.StandardOutput

        $stage = 'initialize'
        Send-JsonRpc $writer @{method='initialize'; id=1; params=@{clientInfo=@{name='gpt_quota_pet'; title='GPT Quota Pet'; version='0.4.6'}; capabilities=@{experimentalApi=$true}}}
        $init = Read-JsonRpcResponse $reader 1 15000
        Throw-IfRpcError $init 'initialize'
        Send-JsonRpc $writer @{method='initialized'}

        $stage = 'external_account_login'
        Send-JsonRpc $writer @{method='account/login/start';id=4;params=@{type='chatgptAuthTokens';accessToken=$AccessToken;chatgptAccountId=$AccountId}}
        $login = Read-JsonRpcResponse $reader 4 15000
        Throw-IfRpcError $login 'external_account_login'

        $stage = 'account/read'
        Send-JsonRpc $writer @{method='account/read'; id=2; params=@{refreshToken=$false}}
        $acct = Read-JsonRpcResponse $reader 2 15000
        Throw-IfRpcError $acct 'account/read'
        $acctResult = Get-JsonProperty $acct 'result'
        $account = Get-JsonProperty $acctResult 'account'
        if ($null -eq $account) {
            return [pscustomobject]@{ ok=$false; state='not_logged_in'; stage=$stage; message='ChatGPT login is required.' }
        }
        if ([string](Get-JsonProperty $account 'type') -ne 'chatgpt') {
            return [pscustomobject]@{ok=$false;state='error';stage=$stage;consume_outcome=$consumeOutcome;message='额度查询没有确认 ChatGPT 登录，已停止。'}
        }

        $stage = 'account/rateLimits/read'
        Send-JsonRpc $writer @{method='account/rateLimits/read'; id=3; params=@{excludeResetCreditDetails=$false}}
        $rl = Read-JsonRpcResponse $reader 3 20000
        Throw-IfRpcError $rl 'account/rateLimits/read'
        $rlResult = Get-JsonProperty $rl 'result'
        $consumeOutcome=$null
        if($ConsumeCreditId){
            $stage='consume_preflight'
            $cards=ConvertTo-LumiResetCards $rlResult
            $selected=@($cards.cards | Where-Object {$_.id -ceq $ConsumeCreditId -and $_.redeemable})
            if($selected.Count -ne 1 -or $RequestId -notmatch '^[a-fA-F0-9-]{36}$'){throw 'Invalid card or attempt'}
            $null=& $BeforeConsume
            $stage='consume'
            Send-JsonRpc $writer @{method='account/rateLimitResetCredit/consume';id=5;params=@{creditId=$ConsumeCreditId;idempotencyKey=$RequestId}}
            $consumed=Read-JsonRpcResponse $reader 5 20000
            Throw-IfRpcError $consumed 'consume'
            $consumeOutcome=[string](Get-JsonProperty (Get-JsonProperty $consumed 'result') 'outcome')
            if($consumeOutcome -notin @('reset','alreadyRedeemed','nothingToReset','noCredit')){throw 'Unknown outcome'}
            $stage='consume_refresh'
            Send-JsonRpc $writer @{method='account/rateLimits/read';id=6}
            $after=Read-JsonRpcResponse $reader 6 15000
            Throw-IfRpcError $after 'consume refresh'
            $rlResult=Get-JsonProperty $after 'result'
        }

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
            consume_outcome = $consumeOutcome
            reset_cards = ConvertTo-LumiResetCards $rlResult
            session = Normalize-Window $session
            weekly = Normalize-Window $weekly
            checked_at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
    }
    catch {
        return [pscustomobject]@{ok=$false;state='error';stage=$stage;consume_outcome=$consumeOutcome;message='账号额度读取未通过。请检查 Codex 登录；此原型要求外部 token 接口可用。'}
    }
    finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
        try { $proc.Dispose() } catch {}
    }
}

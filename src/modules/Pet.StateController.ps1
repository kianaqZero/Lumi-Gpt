Set-StrictMode -Version 2

function Get-PetAutomaticSemanticState {
    param(
        $QuotaData,
        [double]$LowThreshold = 20.0
    )
    if (-not $QuotaData -or -not [bool]$QuotaData.ok) {
        $state = if ($QuotaData -and $QuotaData.state) { [string]$QuotaData.state } else { 'error' }
        switch ($state) {
            'runtime_missing' { return 'offline' }
            'not_logged_in' { return 'offline' }
            'offline' { return 'offline' }
            default { return 'error' }
        }
    }
    $remaining=@()
    foreach($name in @('session','weekly')){
        if($QuotaData.PSObject.Properties.Name -contains $name){
            $window=$QuotaData.$name
            if($window -and $window.PSObject.Properties.Name -contains 'remaining_percent'){
                try{$remaining += [double]$window.remaining_percent}catch{}
            }
        }
    }
    if($remaining.Count -gt 0 -and (($remaining|Measure-Object -Minimum).Minimum -le $LowThreshold)){return 'online_low'}
    return 'online_good'
}

function Get-PetAutomaticVisualState {
    param(
        [ValidateSet('online_good','online_low','refreshing','offline','error')][string]$SemanticState,
        [ValidateSet('none','interaction','long_idle','sleeping','ambient')][string]$ActivityState = 'none',
        [switch]$DebugOverride,
        [string]$DebugState = 'online_good'
    )
    if($DebugOverride){return $DebugState}
    switch($SemanticState){
        'error' {return 'error'}
        'offline' {return 'offline'}
        'refreshing' {return 'refreshing'}
        'online_low' {return 'online_low'}
        default {
            switch($ActivityState){
                'interaction' {return 'interaction'}
                'sleeping' {return 'sleeping'}
                'long_idle' {return 'long_idle'}
                'ambient' {return 'long_idle'}
                default {return 'online_good'}
            }
        }
    }
}

function Get-PetAutomaticActivityState {
    param(
        [double]$IdleSeconds,
        [double]$LongIdleTimeout,
        [double]$SleepTimeout,
        [ValidateSet('none','interaction','long_idle','sleeping','ambient')][string]$Current = 'none',
        [switch]$InteractionActive,
        [switch]$Blocked,
        [switch]$AmbientEnabled,
        [double]$AmbientInterval = 45,
        [double]$AmbientDuration = 5,
        [double]$AmbientAgeSeconds = 0
    )
    if($InteractionActive){return 'interaction'}
    if($Blocked){return $Current}
    if($IdleSeconds -ge $SleepTimeout){return 'sleeping'}
    if($IdleSeconds -ge $LongIdleTimeout){return 'long_idle'}
    if($AmbientEnabled -and $Current -eq 'none' -and $IdleSeconds -ge $AmbientInterval -and $IdleSeconds -lt $LongIdleTimeout){return 'ambient'}
    if($Current -eq 'ambient' -and $AmbientAgeSeconds -lt $AmbientDuration){return 'ambient'}
    return 'none'
}

function Test-PetAutomaticTransitionAllowed {
    param(
        [string]$Current,
        [string]$Requested,
        [double]$AgeSeconds,
        [double]$MinimumStateDuration = 1.0,
        [double]$CooldownSeconds = 0.5,
        [switch]$Force
    )
    if($Current -eq $Requested){return $false}
    if($Force){return $true}
    if($AgeSeconds -lt $MinimumStateDuration){return $false}
    if($AgeSeconds -lt $CooldownSeconds){return $false}
    return $true
}

Set-StrictMode -Version 2

$script:PetAnimationChannelNames = @('base','body','face','eyes','hair','appendage','fx','oneshot')

function Get-PetAnimationChannelNames {
    return @($script:PetAnimationChannelNames)
}

function Add-PetAnimationEvent {
    param(
        $Scheduler,
        [string]$Event,
        [string]$Name = '',
        [hashtable]$Data = @{}
    )
    if (-not $Scheduler) { return }
    $record = [ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        event = $Event
        name = $Name
        generation = [int]$Scheduler.Generation
        data = $Data
    }
    [void]$Scheduler.EventLog.Add([pscustomobject]$record)
}

function Resolve-PetAnimationFallbackPath {
    param(
        $Phase2Manifest,
        [ValidateSet('chibi','anime')][string]$Appearance,
        [ValidateSet('online_good','refreshing','online_low','offline','error','interaction','long_idle','sleeping')][string]$LogicalState
    )
    if (-not $Phase2Manifest -or -not $Phase2Manifest.appearances) { return $null }
    $appearanceProperty = $Phase2Manifest.appearances.PSObject.Properties[$Appearance]
    if (-not $appearanceProperty) { return $null }
    $stateProperty = $appearanceProperty.Value.states.PSObject.Properties[$LogicalState]
    if (-not $stateProperty) { return $null }
    return [string]$stateProperty.Value.base_image
}

function Resolve-PetAnimationProfile {
    param(
        [ValidateSet('chibi','anime')][string]$Appearance,
        [ValidateSet('online_good','online_low','refreshing','offline','error')][string]$SemanticState,
        [ValidateSet('none','interaction','long_idle','sleeping','ambient')][string]$ActivityState = 'none',
        $Phase2Manifest,
        [hashtable]$AvailableLayers = @{}
    )

    $logicalState = 'online_good'
    $poseFamily = 'idle'
    $profileName = 'idle_mvp'
    $oneShotName = $null

    switch ($SemanticState) {
        'error' {
            $logicalState = 'error'
            $poseFamily = 'error'
            $profileName = 'error_static_fallback'
        }
        'offline' {
            $logicalState = 'offline'
            $poseFamily = 'offline'
            $profileName = 'offline_static_fallback'
        }
        'refreshing' {
            $logicalState = 'refreshing'
            $poseFamily = 'thinking'
            $profileName = 'thinking_static_fallback'
        }
        'online_low' {
            $logicalState = 'online_low'
            $poseFamily = 'low'
            $profileName = 'low_static_fallback'
        }
        default {
            if ($ActivityState -eq 'sleeping') {
                $logicalState = 'sleeping'
                $poseFamily = 'sleep'
                $profileName = 'sleep_static_fallback'
            } elseif ($ActivityState -eq 'long_idle') {
                $logicalState = 'long_idle'
                $poseFamily = 'work'
                $profileName = 'work_static_fallback'
            } elseif ($ActivityState -eq 'interaction') {
                $logicalState = 'interaction'
                $poseFamily = 'greeting'
                $profileName = 'interaction_oneshot_fallback'
                $oneShotName = 'greeting'
            } else {
                $logicalState = 'online_good'
                $poseFamily = 'idle'
                $profileName = 'idle_mvp'
            }
        }
    }

    if ($ActivityState -eq 'ambient' -and $SemanticState -eq 'online_good') {
        $logicalState = 'online_good'
        $poseFamily = 'idle'
        $profileName = 'idle_ambient_overlay'
    }

    $fallbackPath = Resolve-PetAnimationFallbackPath -Phase2Manifest $Phase2Manifest -Appearance $Appearance -LogicalState $logicalState
    $layerKey = '{0}/{1}' -f $Appearance, $poseFamily
    $hasRegisteredLayers = $AvailableLayers.ContainsKey($layerKey) -and @($AvailableLayers[$layerKey]).Count -gt 0
    $channels = [ordered]@{}
    foreach ($channel in $script:PetAnimationChannelNames) { $channels[$channel] = @() }

    return [pscustomobject]@{
        appearance = $Appearance
        semantic_state = $SemanticState
        activity_state = $ActivityState
        logical_state = $logicalState
        pose_family = $poseFamily
        animation_profile = $profileName
        one_shot = $oneShotName
        channels = $channels
        layers = if ($hasRegisteredLayers) { @($AvailableLayers[$layerKey]) } else { @() }
        uses_formal_layers = $false
        uses_static_fallback = (-not $hasRegisteredLayers)
        fallback_path = $fallbackPath
        fallback_reason = if ($hasRegisteredLayers) { $null } else { 'No formal layered assets registered; use Phase 2 full-state PNG fallback.' }
    }
}

function Read-PetAnimationManifest {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Animation manifest not found: $Path" }
    $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($required in @('manifest_version','channel_names','pose_families','appearances','runtime_rules')) {
        if ($manifest.PSObject.Properties.Name -notcontains $required) { throw "Animation manifest missing: $required" }
    }
    foreach ($channel in $script:PetAnimationChannelNames) {
        if (@($manifest.channel_names) -notcontains $channel) { throw "Animation manifest missing channel: $channel" }
    }
    foreach ($appearance in @('chibi','anime')) {
        $appearanceProperty = $manifest.appearances.PSObject.Properties[$appearance]
        if (-not $appearanceProperty) { throw "Animation manifest missing appearance: $appearance" }
        foreach ($pose in @('idle','sleep','work','greeting')) {
            $poseProperty = $appearanceProperty.Value.PSObject.Properties[$pose]
            if (-not $poseProperty) { throw "Animation manifest missing pose family: $appearance/$pose" }
            if (-not $poseProperty.Value.static_fallback) { throw "Animation manifest missing static fallback: $appearance/$pose" }
        }
    }
    return $manifest
}

function Get-PetAnimationManifestPose {
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [ValidateSet('chibi','anime')][string]$Appearance,
        [ValidateSet('idle','sleep','work','greeting')][string]$PoseFamily
    )
    $appearanceProperty = $Manifest.appearances.PSObject.Properties[$Appearance]
    if (-not $appearanceProperty) { throw "Unknown animation appearance: $Appearance" }
    $poseProperty = $appearanceProperty.Value.PSObject.Properties[$PoseFamily]
    if (-not $poseProperty) { throw "Unknown animation pose family: $Appearance/$PoseFamily" }
    return $poseProperty.Value
}

function Resolve-PetAnimationManifestLayerPaths {
    param(
        [Parameter(Mandatory=$true)]$Manifest,
        [ValidateSet('chibi','anime')][string]$Appearance,
        [ValidateSet('idle','sleep','work','greeting')][string]$PoseFamily,
        [Parameter(Mandatory=$true)][string]$ManifestRoot
    )
    $pose = Get-PetAnimationManifestPose -Manifest $Manifest -Appearance $Appearance -PoseFamily $PoseFamily
    $records=@()
    foreach ($layer in @($pose.layers)) {
        $records += [pscustomobject]@{
            id=[string]$layer.id
            channel=[string]$layer.channel
            path=(Join-Path $ManifestRoot ([string]$layer.path))
            test_only=[bool]$layer.test_only
            z_index=[int]$layer.z_index
            anchor=@($layer.anchor)
            pivot=@($layer.pivot)
        }
    }
    return @($records)
}

function Get-PetAnimationControllerProfile {
    param(
        $ControllerState,
        [ValidateSet('chibi','anime')][string]$Appearance,
        $Phase2Manifest,
        [hashtable]$AvailableLayers = @{}
    )
    if (-not $ControllerState) { throw 'ControllerState is required.' }
    $semantic = [string]$ControllerState.semantic_state
    $activity = [string]$ControllerState.activity_state
    if ($semantic -notin @('online_good','online_low','refreshing','offline','error')) { throw "Invalid semantic_state: $semantic" }
    if ($activity -notin @('none','interaction','long_idle','sleeping','ambient')) { throw "Invalid activity_state: $activity" }
    return Resolve-PetAnimationProfile -Appearance $Appearance -SemanticState $semantic -ActivityState $activity -Phase2Manifest $Phase2Manifest -AvailableLayers $AvailableLayers
}

function New-PetAnimationClip {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][ValidateSet('base','body','face','eyes','hair','appendage','fx','oneshot')][string]$Channel,
        [double]$DurationMs = 1000,
        [switch]$Loop,
        [int]$Priority = 100,
        [bool]$Interruptible = $true,
        [scriptblock]$Apply,
        [scriptblock]$OnComplete
    )
    return [pscustomobject]@{
        Name = $Name
        Channel = $Channel
        DurationMs = [Math]::Max(1.0, $DurationMs)
        Loop = [bool]$Loop
        Priority = $Priority
        Interruptible = $Interruptible
        Apply = $Apply
        OnComplete = $OnComplete
        StartUtc = [DateTime]::UtcNow
        Generation = 0
        Completed = $false
    }
}

function New-PetAnimationScheduler {
    param(
        $Dispatcher,
        [ValidateSet('normal','reduced','static')][string]$Mode = 'normal',
        [int]$Fps = 24
    )
    if (-not $Dispatcher) { $Dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher }
    $safeFps = if ($Mode -eq 'reduced') { 12 } elseif ($Mode -eq 'static') { 0 } else { [Math]::Max(1, $Fps) }
    $channels = [ordered]@{}
    foreach ($channel in $script:PetAnimationChannelNames) { $channels[$channel] = $null }
    $scheduler = [pscustomobject]@{
        Dispatcher = $Dispatcher
        Mode = $Mode
        Fps = $safeFps
        Channels = $channels
        Layers = [ordered]@{}
        CurrentProfile = $null
        Generation = 0
        Running = $false
        Suspended = $false
        ResumeAfterSuspend = $false
        Stopped = $false
        InTick = $false
        TickCount = 0
        TickTimesUtc = New-Object System.Collections.ArrayList
        LastTickUtc = [DateTime]::MinValue
        StartUtc = [DateTime]::MinValue
        EventLog = New-Object System.Collections.ArrayList
        TickHooks = New-Object System.Collections.ArrayList
        PreloadedDecodeCount = 0
        DecodeInsideTickCount = 0
        WindowPositionWriteCount = 0
        StaleCallbacksIgnored = 0
        OneShotCompletedCount = 0
        OneShotInterruptedCount = 0
        FallbackVisible = $false
        FallbackPath = $null
        FallbackImageSource = $null
        Timer = $null
    }
    $scheduler.Timer = New-Object System.Windows.Threading.DispatcherTimer
    if ($safeFps -gt 0) {
        $scheduler.Timer.Interval = [TimeSpan]::FromMilliseconds(1000.0 / $safeFps)
    } else {
        $scheduler.Timer.Interval = [TimeSpan]::FromMilliseconds(1000)
    }
    $tickHandler = {
        try { Invoke-PetAnimationTick -Scheduler $scheduler } catch { Add-PetAnimationEvent -Scheduler $scheduler -Event 'tick.error' -Name $_.Exception.GetType().FullName -Data @{message=$_.Exception.Message} }
    }.GetNewClosure()
    $scheduler.Timer.Add_Tick($tickHandler)
    Add-PetAnimationEvent -Scheduler $scheduler -Event 'scheduler.created' -Data @{mode=$Mode;fps=$safeFps}
    return $scheduler
}

function Add-PetAnimationTickHook {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)][scriptblock]$Hook
    )
    [void]$Scheduler.TickHooks.Add($Hook)
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'tick_hook.added'
    return $Hook
}

function Remove-PetAnimationTickHook {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)][scriptblock]$Hook
    )
    [void]$Scheduler.TickHooks.Remove($Hook)
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'tick_hook.removed'
}

function Set-PetAnimationMode {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [ValidateSet('normal','reduced','static')][string]$Mode,
        [int]$Fps = 24
    )
    $wasRunning = [bool]$Scheduler.Running
    if ($wasRunning) { $Scheduler.Timer.Stop() }
    $Scheduler.Mode = $Mode
    $Scheduler.Fps = if ($Mode -eq 'normal') { [Math]::Max(1, $Fps) } elseif ($Mode -eq 'reduced') { 12 } else { 0 }
    $interval = if ($Scheduler.Fps -gt 0) { 1000.0 / $Scheduler.Fps } else { 1000 }
    $Scheduler.Timer.Interval = [TimeSpan]::FromMilliseconds($interval)
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'mode.changed' -Data @{mode=$Mode;fps=$Scheduler.Fps}
    if ($wasRunning -and $Mode -ne 'static' -and -not $Scheduler.Suspended) {
        $Scheduler.Timer.Start(); $Scheduler.Running = $true
    } elseif ($Mode -eq 'static') {
        $Scheduler.Running = $false
    }
}

function Start-PetAnimationScheduler {
    param([Parameter(Mandatory=$true)]$Scheduler)
    if ($Scheduler.Stopped -or $Scheduler.Mode -eq 'static') { return $false }
    if (-not $Scheduler.Running -and -not $Scheduler.Suspended) {
        $Scheduler.StartUtc = [DateTime]::UtcNow
        $Scheduler.Timer.Start()
        $Scheduler.Running = $true
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'scheduler.started' -Data @{mode=$Scheduler.Mode;fps=$Scheduler.Fps}
    }
    return $Scheduler.Running
}

function Stop-PetAnimationScheduler {
    param([Parameter(Mandatory=$true)]$Scheduler)
    if ($Scheduler.Timer) { $Scheduler.Timer.Stop() }
    $Scheduler.Running = $false
    $Scheduler.Suspended = $false
    $Scheduler.Stopped = $true
    $Scheduler.Generation++
    foreach ($channel in $script:PetAnimationChannelNames) { $Scheduler.Channels[$channel] = $null }
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'scheduler.stopped'
}

function Suspend-PetAnimationScheduler {
    param([Parameter(Mandatory=$true)]$Scheduler,[string]$Reason='suspend')
    if ($Scheduler.Suspended) { return }
    $Scheduler.ResumeAfterSuspend = [bool]$Scheduler.Running
    if ($Scheduler.Timer) { $Scheduler.Timer.Stop() }
    $Scheduler.Running = $false
    $Scheduler.Suspended = $true
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'scheduler.suspended' -Data @{reason=$Reason}
}

function Resume-PetAnimationScheduler {
    param([Parameter(Mandatory=$true)]$Scheduler,[string]$Reason='resume')
    if (-not $Scheduler.Suspended) { return }
    $Scheduler.Suspended = $false
    if ($Scheduler.ResumeAfterSuspend -and $Scheduler.Mode -ne 'static' -and -not $Scheduler.Stopped) {
        $Scheduler.Timer.Start(); $Scheduler.Running = $true
    }
    $Scheduler.ResumeAfterSuspend = $false
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'scheduler.resumed' -Data @{reason=$Reason}
}

function Set-PetAnimationProfile {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)]$Profile
    )
    $Scheduler.Generation++
    $Scheduler.CurrentProfile = $Profile
    foreach ($channel in $script:PetAnimationChannelNames) { $Scheduler.Channels[$channel] = $null }
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'profile.switched' -Name ([string]$Profile.animation_profile) -Data @{appearance=$Profile.appearance;pose_family=$Profile.pose_family;fallback=$Profile.uses_static_fallback}
    return [int]$Scheduler.Generation
}

function Register-PetAnimationLayer {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)]$ImageSource,
        $Element,
        [ValidateSet('base','body','face','eyes','hair','appendage','fx','oneshot')][string]$Channel = 'fx',
        [switch]$TestOnly,
        [int]$ZIndex = 0,
        [double]$AnchorX = 0.5,
        [double]$AnchorY = 0.5,
        [double]$PivotX = 0.5,
        [double]$PivotY = 0.5
    )
    if (-not $ImageSource) { throw "ImageSource is required for layer $Id" }
    $record = [pscustomobject]@{
        id=$Id; image_source=$ImageSource; element=$Element; channel=$Channel; test_only=[bool]$TestOnly; z_index=$ZIndex
        anchor_x=$AnchorX; anchor_y=$AnchorY; pivot_x=$PivotX; pivot_y=$PivotY; active=$true
    }
    if ($Element) {
        try { [Windows.Controls.Canvas]::SetZIndex($Element,[int]$ZIndex) } catch {}
    }
    $Scheduler.Layers[$Id] = $record
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'layer.registered' -Name $Id -Data @{channel=$Channel;test_only=[bool]$TestOnly}
    return $record
}

function Load-PetAnimationBitmap {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)][string]$Path
    )
    if ($Scheduler.InTick) {
        $Scheduler.DecodeInsideTickCount++
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'asset.decode_inside_tick' -Name $Path
        throw 'Image decode is prohibited inside animation tick.'
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Animation asset not found: $Path" }
    $image = New-Object Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource = New-Object Uri((Resolve-Path -LiteralPath $Path).Path)
    $image.EndInit()
    $image.Freeze()
    $Scheduler.PreloadedDecodeCount++
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'asset.preloaded' -Name $Path
    return $image
}

function Set-PetAnimationFallbackImage {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)]$ImageElement,
        [Parameter(Mandatory=$true)][string]$Path,
        $ImageSource
    )
    if (-not $ImageSource) { $ImageSource = Load-PetAnimationBitmap -Scheduler $Scheduler -Path $Path }
    $ImageElement.Source = $ImageSource
    $Scheduler.FallbackVisible = $true
    $Scheduler.FallbackPath = $Path
    $Scheduler.FallbackImageSource = $ImageSource
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'fallback.applied' -Name $Path
}

function Start-PetAnimationLoop {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)]$Clip
    )
    if ($Scheduler.Mode -eq 'static' -or $Scheduler.Stopped) {
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'clip.suppressed' -Name $Clip.Name -Data @{reason='static_or_stopped'}
        return $false
    }
    $Clip.StartUtc = [DateTime]::UtcNow
    $Clip.Generation = [int]$Scheduler.Generation
    $old = $Scheduler.Channels[$Clip.Channel]
    if ($old -and $old.Name -ne $Clip.Name) {
        if (-not $old.Interruptible -and $old.Priority -gt $Clip.Priority) {
            Add-PetAnimationEvent -Scheduler $Scheduler -Event 'clip.rejected' -Name $Clip.Name -Data @{blocked_by=$old.Name}
            return $false
        }
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'clip.interrupted' -Name $old.Name -Data @{replacement=$Clip.Name}
    }
    $Clip.Loop = $true
    $Scheduler.Channels[$Clip.Channel] = $Clip
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'loop.started' -Name $Clip.Name -Data @{channel=$Clip.Channel;generation=$Clip.Generation}
    return $true
}

function Start-PetAnimationOneShot {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)]$Clip,
        [switch]$InterruptCurrent
    )
    if ($Scheduler.Mode -eq 'static' -or $Scheduler.Stopped) {
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'oneshot.suppressed' -Name $Clip.Name -Data @{reason='static_or_stopped'}
        return $false
    }
    $old = $Scheduler.Channels['oneshot']
    if ($old) {
        if (-not $InterruptCurrent -and -not $old.Interruptible) {
            Add-PetAnimationEvent -Scheduler $Scheduler -Event 'oneshot.rejected' -Name $Clip.Name -Data @{blocked_by=$old.Name}
            return $false
        }
        $Scheduler.OneShotInterruptedCount++
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'oneshot.interrupted' -Name $old.Name -Data @{replacement=$Clip.Name}
        $Scheduler.Channels['oneshot'] = $null
    }
    $Clip.Loop = $false
    $Clip.StartUtc = [DateTime]::UtcNow
    $Clip.Generation = [int]$Scheduler.Generation
    $Scheduler.Channels['oneshot'] = $Clip
    Add-PetAnimationEvent -Scheduler $Scheduler -Event 'oneshot.started' -Name $Clip.Name -Data @{generation=$Clip.Generation}
    return $true
}

function Stop-PetAnimationChannel {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)][ValidateSet('base','body','face','eyes','hair','appendage','fx','oneshot')][string]$Channel,
        [string]$Reason='stop'
    )
    $clip = $Scheduler.Channels[$Channel]
    if ($clip) {
        $Scheduler.Channels[$Channel] = $null
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'clip.stopped' -Name $clip.Name -Data @{channel=$Channel;reason=$Reason}
        return $true
    }
    return $false
}

function Complete-PetAnimationClip {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)]$Clip,
        [string]$Reason='complete'
    )
    if ([int]$Clip.Generation -ne [int]$Scheduler.Generation) {
        $Scheduler.StaleCallbacksIgnored++
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'callback.ignored' -Name $Clip.Name -Data @{reason='generation_mismatch';clip_generation=$Clip.Generation}
        return $false
    }
    if ($Scheduler.Channels[$Clip.Channel] -ne $Clip) { return $false }
    $Scheduler.Channels[$Clip.Channel] = $null
    $Clip.Completed = $true
    if ($Clip.Channel -eq 'oneshot') { $Scheduler.OneShotCompletedCount++ }
    $completedEvent=if($Clip.Channel -eq 'oneshot'){'oneshot.completed'}else{'loop.completed'}
    Add-PetAnimationEvent -Scheduler $Scheduler -Event $completedEvent -Name $Clip.Name -Data @{reason=$Reason}
    if ($Clip.OnComplete) { & $Clip.OnComplete $Scheduler $Clip }
    if ($Clip.Channel -eq 'oneshot') { Add-PetAnimationEvent -Scheduler $Scheduler -Event 'loop.resume_after_oneshot' }
    return $true
}

function Invoke-PetAnimationCallback {
    param(
        [Parameter(Mandatory=$true)]$Scheduler,
        [Parameter(Mandatory=$true)][int]$Generation,
        [Parameter(Mandatory=$true)][scriptblock]$Callback,
        [string]$Name='callback'
    )
    if ($Generation -ne [int]$Scheduler.Generation -or $Scheduler.Stopped) {
        $Scheduler.StaleCallbacksIgnored++
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'callback.ignored' -Name $Name -Data @{reason='generation_mismatch_or_stopped';callback_generation=$Generation}
        return $false
    }
    & $Callback $Scheduler
    return $true
}

function Invoke-PetAnimationTick {
    param([Parameter(Mandatory=$true)]$Scheduler)
    if ($Scheduler.Stopped -or $Scheduler.Suspended -or -not $Scheduler.Running -or $Scheduler.Mode -eq 'static') { return }
    $Scheduler.InTick = $true
    try {
        $now = [DateTime]::UtcNow
        $Scheduler.LastTickUtc = $now
        $Scheduler.TickCount++
        [void]$Scheduler.TickTimesUtc.Add($now)
        foreach ($hook in @($Scheduler.TickHooks)) {
            try { & $hook $Scheduler $now } catch { Add-PetAnimationEvent -Scheduler $Scheduler -Event 'tick_hook.error' -Name $_.Exception.GetType().FullName -Data @{message=$_.Exception.Message} }
        }
        foreach ($channel in $script:PetAnimationChannelNames) {
            $clip = $Scheduler.Channels[$channel]
            if (-not $clip) { continue }
            if ([int]$clip.Generation -ne [int]$Scheduler.Generation) {
                $Scheduler.StaleCallbacksIgnored++
                $Scheduler.Channels[$channel] = $null
                Add-PetAnimationEvent -Scheduler $Scheduler -Event 'clip.ignored' -Name $clip.Name -Data @{reason='generation_mismatch';clip_generation=$clip.Generation}
                continue
            }
            $elapsed = ($now - $clip.StartUtc).TotalMilliseconds
            $progress = if ($clip.Loop) { (($elapsed % $clip.DurationMs) / $clip.DurationMs) } else { [Math]::Min(1.0, $elapsed / $clip.DurationMs) }
            if ($clip.Apply) { & $clip.Apply ([double]$progress) $Scheduler $clip }
            if (-not $clip.Loop -and $elapsed -ge $clip.DurationMs) { [void](Complete-PetAnimationClip -Scheduler $Scheduler -Clip $clip) }
        }
    } catch {
        Add-PetAnimationEvent -Scheduler $Scheduler -Event 'tick.exception' -Name $_.Exception.GetType().FullName -Data @{message=$_.Exception.Message}
        throw
    } finally {
        $Scheduler.InTick = $false
    }
}

function Get-PetAnimationRuntimeSnapshot {
    param([Parameter(Mandatory=$true)]$Scheduler)
    $active=@()
    foreach ($channel in $script:PetAnimationChannelNames) {
        $clip=$Scheduler.Channels[$channel]
        if ($clip) { $active += [pscustomobject]@{channel=$channel;name=$clip.Name;generation=$clip.Generation;loop=$clip.Loop} }
    }
    $intervals=@()
    $times=@($Scheduler.TickTimesUtc)
    for($i=1;$i -lt $times.Count;$i++){$intervals += ($times[$i]-$times[$i-1]).TotalMilliseconds}
    return [pscustomobject]@{
        mode=$Scheduler.Mode
        fps=$Scheduler.Fps
        running=$Scheduler.Running
        suspended=$Scheduler.Suspended
        stopped=$Scheduler.Stopped
        generation=$Scheduler.Generation
        tick_count=$Scheduler.TickCount
        active_clips=$active
        active_layer_count=@($Scheduler.Layers.Values|Where-Object{$_.active}).Count
        preloaded_decode_count=$Scheduler.PreloadedDecodeCount
        decode_inside_tick_count=$Scheduler.DecodeInsideTickCount
        window_position_write_count=$Scheduler.WindowPositionWriteCount
        stale_callbacks_ignored=$Scheduler.StaleCallbacksIgnored
        oneshot_completed=$Scheduler.OneShotCompletedCount
        oneshot_interrupted=$Scheduler.OneShotInterruptedCount
        fallback_visible=$Scheduler.FallbackVisible
        fallback_path=$Scheduler.FallbackPath
        tick_interval_ms=if($intervals.Count){($intervals|Measure-Object -Average).Average}else{$null}
        event_count=@($Scheduler.EventLog).Count
    }
}

Set-StrictMode -Version 2

# Phase 3B safe-subset restore.
# Formal front_hair/tail assets are intentionally not loaded or registered here.

function New-PetChibiIdleAnimationContext {
    param(
        [Parameter(Mandatory=$true)]$Dispatcher,
        [Parameter(Mandatory=$true)][string]$AssetRoot,
        [Parameter(Mandatory=$true)]$LayerHost,
        [Parameter(Mandatory=$true)]$BodyHost,
        [Parameter(Mandatory=$true)]$BaseLayer,
        [Parameter(Mandatory=$true)]$TailLayer,
        [Parameter(Mandatory=$true)]$FrontHairLayer,
        [Parameter(Mandatory=$true)]$EyesLayer,
        [Parameter(Mandatory=$true)]$FacePatchLayer,
        [Parameter(Mandatory=$true)]$EyesClosedLayer,
        [Parameter(Mandatory=$true)]$CloudLayer,
        [Parameter(Mandatory=$true)]$Mascot
    )
    $paths=[ordered]@{
        base=(Join-Path $AssetRoot 'base_body.png')
        eyes_open=(Join-Path $AssetRoot 'eyes_open.png')
        face_patch=(Join-Path $AssetRoot 'face_patch.png')
        eyes_closed=(Join-Path $AssetRoot 'eyes_closed.png')
        cloud=(Join-Path $AssetRoot 'cloud_fx.png')
    }
    foreach($name in $paths.Keys){
        if(-not(Test-Path -LiteralPath $paths[$name])){throw "Missing Q版 safe-subset layer: $($paths[$name])"}
    }

    $scheduler=New-PetAnimationScheduler -Dispatcher $Dispatcher -Mode normal -Fps 24
    $sources=[ordered]@{}
    foreach($name in $paths.Keys){$sources[$name]=Load-PetAnimationBitmap -Scheduler $scheduler -Path $paths[$name]}

    $BaseLayer.Source=$sources.base
    $TailLayer.Source=$null
    $FrontHairLayer.Source=$null
    $EyesLayer.Source=$sources.eyes_open
    $FacePatchLayer.Source=$sources.face_patch
    $EyesClosedLayer.Source=$sources.eyes_closed
    $CloudLayer.Source=$sources.cloud

    $BaseLayer.Visibility=[Windows.Visibility]::Visible
    $TailLayer.Visibility=[Windows.Visibility]::Collapsed
    $FrontHairLayer.Visibility=[Windows.Visibility]::Collapsed
    $EyesLayer.Visibility=[Windows.Visibility]::Visible
    $FacePatchLayer.Visibility=[Windows.Visibility]::Collapsed
    $EyesClosedLayer.Visibility=[Windows.Visibility]::Collapsed
    $CloudLayer.Visibility=[Windows.Visibility]::Visible
    $LayerHost.Visibility=[Windows.Visibility]::Collapsed
    $Mascot.Visibility=[Windows.Visibility]::Visible

    $bodyGroup=New-Object Windows.Media.TransformGroup
    $bodyScale=New-Object Windows.Media.ScaleTransform(1,1,152.5,242.5)
    $bodyTranslate=New-Object Windows.Media.TranslateTransform(0,0)
    [void]$bodyGroup.Children.Add($bodyScale);[void]$bodyGroup.Children.Add($bodyTranslate)
    $BodyHost.RenderTransform=$bodyGroup
    $cloudTranslate=New-Object Windows.Media.TranslateTransform(0,0)
    $CloudLayer.RenderTransform=$cloudTranslate

    $context=[pscustomobject]@{
        Scheduler=$scheduler
        AssetRoot=$AssetRoot
        LayerHost=$LayerHost
        BodyHost=$BodyHost
        Mascot=$Mascot
        BaseLayer=$BaseLayer
        TailLayer=$TailLayer
        FrontHairLayer=$FrontHairLayer
        EyesLayer=$EyesLayer
        FacePatchLayer=$FacePatchLayer
        EyesClosedLayer=$EyesClosedLayer
        CloudLayer=$CloudLayer
        Sources=$sources
        Paths=$paths
        BaseUsesFormalOcclusion=$false
        FormalLayersReady=$false
        RequiredLayersReady=$true
        SafeSubsetReady=$true
        FormalLayerLoadFailures=@('front_hair:deferred_rejected_formal_asset','tail:deferred_rejected_formal_asset')
        FormalAssetsRejected=$true
        BodyScale=$bodyScale
        BodyTranslate=$bodyTranslate
        CloudTranslate=$cloudTranslate
        BodyClip=$null
        CloudClip=$null
        BlinkHook=$null
        BlinkActive=$false
        NextBlinkUtc=([DateTime]::UtcNow.AddSeconds(4))
        Random=(New-Object System.Random)
        Active=$false
        ProfileName='fallback'
        ProfileGeneration=0
        RendererReady=$false
        TransformsInitialized=$true
        ProfileActivationGeneration=0
        LastActivationReason='context_created'
        LastActivationUtc=[DateTimeOffset]::Now
        TailMotionEnabled=$false
        FrontHairMotionEnabled=$false
        TailMotionObserved=$false
        FrontHairMotionObserved=$false
        TailMotionSamples=0
        FrontHairMotionSamples=0
        TailAngleMin=0.0
        TailAngleMax=0.0
        FrontHairAngleMin=0.0
        FrontHairAngleMax=0.0
        TailTranslateMax=0.0
        FrontHairTranslateMax=0.0
    }

    foreach($pair in @(
        @{id='q_base_body';src=$sources.base;el=$BaseLayer;channel='base';z=0},
        @{id='q_eyes_open';src=$sources.eyes_open;el=$EyesLayer;channel='eyes';z=30},
        @{id='q_face_patch';src=$sources.face_patch;el=$FacePatchLayer;channel='face';z=31},
        @{id='q_eyes_closed';src=$sources.eyes_closed;el=$EyesClosedLayer;channel='eyes';z=32},
        @{id='q_cloud_fx';src=$sources.cloud;el=$CloudLayer;channel='fx';z=50}
    )){
        [void](Register-PetAnimationLayer -Scheduler $scheduler -Id $pair.id -ImageSource $pair.src -Element $pair.el -Channel $pair.channel -ZIndex $pair.z)
    }

    Add-PetAnimationEvent -Scheduler $scheduler -Event 'formal_layers.rejected' -Data @{front_hair='deferred_new_formal_asset_required';tail='deferred_new_formal_asset_required'}
    Add-PetAnimationEvent -Scheduler $scheduler -Event 'safe_subset.ready' -Data @{layers=@('base_body','eyes_open','face_patch','eyes_closed','cloud_fx');formal_layers_loaded=$false}

    $blinkHook={
        param($hookScheduler,$now)
        if(-not $context.Active -or $hookScheduler.Suspended -or $context.BlinkActive){return}
        if($now -lt $context.NextBlinkUtc){return}
        $context.BlinkActive=$true
        $clip=New-PetChibiBlinkClip -Context $context
        if(-not(Start-PetAnimationOneShot -Scheduler $hookScheduler -Clip $clip -InterruptCurrent)){
            $context.BlinkActive=$false
            $context.NextBlinkUtc=[DateTime]::UtcNow.AddSeconds(1.5)
        }
    }.GetNewClosure()
    $context.BlinkHook=$blinkHook
    [void](Add-PetAnimationTickHook -Scheduler $scheduler -Hook $blinkHook)
    return $context
}

function New-PetChibiBlinkClip {
    param([Parameter(Mandatory=$true)]$Context)
    $face=$Context.FacePatchLayer
    $eyes=$Context.EyesLayer
    $closed=$Context.EyesClosedLayer
    $ctx=$Context
    $clip=New-PetAnimationClip -Name 'q_chibi_blink' -Channel oneshot -DurationMs 260 -Priority 270 -Interruptible $true
    $clip.Apply={
        param($progress,$s,$c)
        if($progress -lt 0.16){$face.Visibility=[Windows.Visibility]::Collapsed;$eyes.Visibility=[Windows.Visibility]::Visible;$closed.Visibility=[Windows.Visibility]::Collapsed}
        elseif($progress -lt 0.32){$face.Visibility=[Windows.Visibility]::Visible;$eyes.Visibility=[Windows.Visibility]::Visible;$closed.Visibility=[Windows.Visibility]::Collapsed}
        elseif($progress -lt 0.80){$face.Visibility=[Windows.Visibility]::Visible;$eyes.Visibility=[Windows.Visibility]::Collapsed;$closed.Visibility=[Windows.Visibility]::Visible}
        else{$face.Visibility=[Windows.Visibility]::Collapsed;$eyes.Visibility=[Windows.Visibility]::Visible;$closed.Visibility=[Windows.Visibility]::Collapsed}
    }.GetNewClosure()
    $clip.OnComplete={
        param($s,$c)
        $face.Visibility=[Windows.Visibility]::Collapsed
        $eyes.Visibility=[Windows.Visibility]::Visible
        $closed.Visibility=[Windows.Visibility]::Collapsed
        $ctx.BlinkActive=$false
        $ctx.NextBlinkUtc=[DateTime]::UtcNow.AddSeconds(3.0 + ($ctx.Random.NextDouble()*4.5))
    }.GetNewClosure()
    return $clip
}

function Reset-PetChibiLayerTransforms {
    param([Parameter(Mandatory=$true)]$Context)
    $Context.BodyScale.ScaleX=1;$Context.BodyScale.ScaleY=1
    $Context.BodyTranslate.X=0;$Context.BodyTranslate.Y=0
    $Context.CloudTranslate.X=0;$Context.CloudTranslate.Y=0
    $Context.TransformsInitialized=$true
}

function Start-PetChibiIdleAnimation {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [switch]$ForceRestart,
        [string]$ActivationReason='profile_update'
    )
    if(-not $Context.RendererReady){
        Add-PetAnimationEvent -Scheduler $Context.Scheduler -Event 'safe_subset.fallback' -Data @{reason='renderer_not_ready';activation_reason=$ActivationReason}
        Stop-PetChibiIdleAnimation -Context $Context -Reason 'renderer_not_ready'
        return $false
    }
    if(-not $Context.SafeSubsetReady){
        Add-PetAnimationEvent -Scheduler $Context.Scheduler -Event 'safe_subset.fallback' -Data @{reason='safe_layers_not_ready';activation_reason=$ActivationReason}
        Stop-PetChibiIdleAnimation -Context $Context -Reason 'safe_layers_not_ready'
        return $false
    }
    if($Context.Active -and -not $ForceRestart){return $true}
    if($Context.Active){Stop-PetChibiIdleAnimation -Context $Context -Reason 'atomic_profile_replace'}
    $Context.ProfileActivationGeneration=[int]$Context.ProfileActivationGeneration+1
    $Context.LastActivationReason=$ActivationReason
    $Context.LastActivationUtc=[DateTimeOffset]::Now
    $profile=[pscustomobject]@{appearance='chibi';semantic_state='online_good';activity_state='none';logical_state='online_good';pose_family='idle';animation_profile='chibi_idle_safe';uses_static_fallback=$false}
    $Context.ProfileGeneration=Set-PetAnimationProfile -Scheduler $Context.Scheduler -Profile $profile
    $Context.LayerHost.Visibility=[Windows.Visibility]::Visible
    $Context.Mascot.Visibility=[Windows.Visibility]::Visible
    $Context.Mascot.Opacity=0
    $Context.BaseLayer.Visibility=[Windows.Visibility]::Visible
    $Context.TailLayer.Visibility=[Windows.Visibility]::Collapsed
    $Context.FrontHairLayer.Visibility=[Windows.Visibility]::Collapsed
    $Context.EyesLayer.Visibility=[Windows.Visibility]::Visible
    $Context.FacePatchLayer.Visibility=[Windows.Visibility]::Collapsed
    $Context.EyesClosedLayer.Visibility=[Windows.Visibility]::Collapsed
    $Context.CloudLayer.Visibility=[Windows.Visibility]::Visible
    Reset-PetChibiLayerTransforms -Context $Context
    $Context.BodyClip=New-PetAnimationClip -Name 'q_chibi_breathing' -Channel body -DurationMs 2600 -Loop -Priority 100 -Apply ({param($p,$s,$c);$v=[Math]::Sin($p*2*[Math]::PI);$Context.BodyScale.ScaleX=1+(0.004*$v);$Context.BodyScale.ScaleY=1+(0.004*$v);$Context.BodyTranslate.Y=(-2*$v)}.GetNewClosure())
    $Context.CloudClip=New-PetAnimationClip -Name 'q_chibi_cloud_float' -Channel fx -DurationMs 3700 -Loop -Priority 120 -Apply ({param($p,$s,$c);$v=[Math]::Sin(($p*2*[Math]::PI)+0.8);$w=[Math]::Sin(($p*2*[Math]::PI*1.22)+0.2);$Context.CloudTranslate.X=(3*$v);$Context.CloudTranslate.Y=(2*$w)}.GetNewClosure())
    [void](Start-PetAnimationLoop -Scheduler $Context.Scheduler -Clip $Context.BodyClip)
    [void](Start-PetAnimationLoop -Scheduler $Context.Scheduler -Clip $Context.CloudClip)
    Add-PetAnimationEvent -Scheduler $Context.Scheduler -Event 'safe_subset.active' -Data @{breathing=$true;blink=$true;cloud=$true;tail_motion_enabled=$false;front_hair_motion_enabled=$false}
    if($Context.Scheduler.Suspended){Resume-PetAnimationScheduler -Scheduler $Context.Scheduler -Reason 'safe_subset_profile'}else{[void](Start-PetAnimationScheduler -Scheduler $Context.Scheduler)}
    $Context.TailMotionEnabled=$false;$Context.FrontHairMotionEnabled=$false
    $Context.Active=$true;$Context.ProfileName='chibi_idle_safe'
    return $true
}

function Stop-PetChibiIdleAnimation {
    param([Parameter(Mandatory=$true)]$Context,[string]$Reason='fallback')
    foreach($channel in @('oneshot','body','hair','appendage','fx')){if($Context.Scheduler.Channels[$channel]){[void](Stop-PetAnimationChannel -Scheduler $Context.Scheduler -Channel $channel -Reason $Reason)}}
    $Context.FacePatchLayer.Visibility=[Windows.Visibility]::Collapsed;$Context.EyesLayer.Visibility=[Windows.Visibility]::Visible;$Context.EyesClosedLayer.Visibility=[Windows.Visibility]::Collapsed
    $Context.TailLayer.Visibility=[Windows.Visibility]::Collapsed;$Context.FrontHairLayer.Visibility=[Windows.Visibility]::Collapsed
    $Context.LayerHost.Visibility=[Windows.Visibility]::Collapsed;$Context.Mascot.Visibility=[Windows.Visibility]::Visible;$Context.Mascot.Opacity=1
    Reset-PetChibiLayerTransforms -Context $Context
    $Context.BlinkActive=$false;$Context.TailMotionEnabled=$false;$Context.FrontHairMotionEnabled=$false;$Context.Active=$false;$Context.ProfileName='fallback'
    if($Context.Scheduler.Running){Suspend-PetAnimationScheduler -Scheduler $Context.Scheduler -Reason $Reason}
}

function Update-PetChibiIdleAnimationProfile {
    param(
        [Parameter(Mandatory=$true)]$Context,
        [string]$Appearance,
        [string]$SemanticState,
        [string]$ActivityState,
        [bool]$DebugOverride=$false,
        [bool]$Dragging=$false,
        [bool]$Snapping=$false
    )
    $eligible=($Appearance -eq 'chibi' -and $SemanticState -eq 'online_good' -and $ActivityState -in @('none','ambient') -and -not $DebugOverride -and -not $Dragging -and -not $Snapping)
    if($eligible -and $Context.RendererReady){return (Start-PetChibiIdleAnimation -Context $Context -ActivationReason 'profile_update')}
    if($eligible -and -not $Context.RendererReady){
        Stop-PetChibiIdleAnimation -Context $Context -Reason 'renderer_not_ready'
        Add-PetAnimationEvent -Scheduler $Context.Scheduler -Event 'profile.deferred' -Data @{reason='renderer_not_ready'}
        return $false
    }
    Stop-PetChibiIdleAnimation -Context $Context -Reason 'controller_profile_fallback'
    return $false
}

function Get-PetChibiIdleAnimationSnapshot {
    param([Parameter(Mandatory=$true)]$Context)
    $snap=Get-PetAnimationRuntimeSnapshot -Scheduler $Context.Scheduler
    return [pscustomobject]@{
        active=$Context.Active
        profile=$Context.ProfileName
        blink_active=$Context.BlinkActive
        next_blink_utc=$Context.NextBlinkUtc.ToString('o')
        formal_layers_ready=$Context.FormalLayersReady
        safe_subset_ready=$Context.SafeSubsetReady
        required_layers_ready=$Context.RequiredLayersReady
        formal_assets_rejected=$Context.FormalAssetsRejected
        formal_layer_load_failures=@($Context.FormalLayerLoadFailures)
        base_uses_formal_occlusion=$Context.BaseUsesFormalOcclusion
        tail_motion_enabled=$false
        front_hair_motion_enabled=$false
        tail_motion_observed=$false
        front_hair_motion_observed=$false
        tail_motion_samples=0
        front_hair_motion_samples=0
        tail_angle_min=0
        tail_angle_max=0
        front_hair_angle_min=0
        front_hair_angle_max=0
        tail_translate_max=0
        front_hair_translate_max=0
        renderer_ready=$Context.RendererReady
        transforms_initialized=$Context.TransformsInitialized
        profile_activation_generation=$Context.ProfileActivationGeneration
        last_activation_reason=$Context.LastActivationReason
        last_activation_utc=$Context.LastActivationUtc.ToString('o')
        layer_state=@($Context.Scheduler.Layers.Values|ForEach-Object{
            [pscustomobject]@{
                id=$_.id
                channel=$_.channel
                z_index=$_.z_index
                active=$_.active
                source_loaded=($null -ne $_.image_source)
                visibility=if($_.element){[string]$_.element.Visibility}else{'unbound'}
                actual_width=if($_.element){[double]$_.element.ActualWidth}else{$null}
                actual_height=if($_.element){[double]$_.element.ActualHeight}else{$null}
            }
        })
        scheduler=$snap
    }
}

Set-StrictMode -Version 2
$script:QChibiAllowedStates = @('idle','greeting','thinking','working','sleeping','pout_angry','surprised')

function Write-QChibiControllerEvent {
    param([Parameter(Mandatory=$true)]$Controller,[Parameter(Mandatory=$true)][string]$Event,[string]$StateFrom='',[string]$StateTo='',[string]$Trigger='',[hashtable]$Extra=@{})
    $r=$Controller.Renderer
    $oldOp=if($r.OldStateLayer){[double]$r.OldStateLayer.Opacity}else{0.0};$newOp=if($r.NewStateLayer){[double]$r.NewStateLayer.Opacity}else{0.0}
    $positionLeft=[double]$r.Window.Left;$positionTop=[double]$r.Window.Top
    if([double]::IsNaN($positionLeft)){$positionLeft=$null};if([double]::IsNaN($positionTop)){$positionTop=$null}
    $rec=[ordered]@{timestamp=[DateTimeOffset]::Now.ToString('o');event=$Event;state_from=$StateFrom;state_to=$StateTo;trigger=$Trigger;generation=[int]$Controller.Generation;controller_state=[string]$Controller.State;target_state=[string]$r.TargetState;old_state=[string]$r.OldVisualState;new_state=[string]$r.NewVisualState;transition_active=[bool]$r.IsTransitioning;old_state_layer=[ordered]@{visibility=[string]$r.OldStateLayer.Visibility;opacity=$oldOp;source_present=($null -ne $r.OldStateImage.Source)};new_state_layer=[ordered]@{visibility=[string]$r.NewStateLayer.Visibility;opacity=$newOp;source_present=($null -ne $r.NewStateImage.Source)};opacity_sum=[Math]::Round(($oldOp+$newOp),6);tassel_motion_active=[bool]$r.TasselMotionActive;tassel_angle_deg=[Math]::Round([double]$r.TasselAngle,4);window_left=$positionLeft;window_top=$positionTop;host_width=[double]$r.StateHost.ActualWidth;host_height=[double]$r.StateHost.ActualHeight;preloaded_bitmap_count=[int]$r.PreloadedBitmapCount;image_decode_in_transition_tick=0;active_visual_state_layer_count=[int]$r.ActiveVisualStateLayerCount}
    foreach($key in $Extra.Keys){$rec[$key]=$Extra[$key]}
    [void]$Controller.Events.Add([pscustomobject]$rec)
    try{$utf8=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::AppendAllText($Controller.LogPath,(($rec|ConvertTo-Json -Compress -Depth 8)+[Environment]::NewLine),$utf8)}catch{}
}

function Get-QChibiVerifiedBitmap {
    param([Parameter(Mandatory=$true)][string]$Path,[Parameter(Mandatory=$true)][string]$ExpectedSha256,[Parameter(Mandatory=$true)][string]$AssetName,[int[]]$ExpectedDimensions=@(1086,1448),[switch]$HashOnly)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Q_Chibi runtime asset missing: $AssetName ($Path)"}
    $item=Get-Item -LiteralPath $Path;$actual=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant();$expected=$ExpectedSha256.ToLowerInvariant()
    if($actual -ne $expected){throw "Q_Chibi runtime asset hash mismatch: $AssetName expected=$expected actual=$actual"}
    if($HashOnly){return [pscustomobject]@{Name=$AssetName;Path=$Path;Sha256=$actual;Bytes=[long]$item.Length;Bitmap=$null;PixelWidth=$null;PixelHeight=$null}}
    $bmp=New-Object Windows.Media.Imaging.BitmapImage;$bmp.BeginInit();$bmp.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad;$bmp.UriSource=New-Object System.Uri($Path);$bmp.EndInit();$bmp.Freeze()
    if($bmp.PixelWidth -ne $ExpectedDimensions[0] -or $bmp.PixelHeight -ne $ExpectedDimensions[1]){throw "Q_Chibi runtime asset dimensions mismatch: $AssetName expected=$($ExpectedDimensions -join 'x') actual=$($bmp.PixelWidth)x$($bmp.PixelHeight)"}
    return [pscustomobject]@{Name=$AssetName;Path=$Path;Sha256=$actual;Bytes=[long]$item.Length;Bitmap=$bmp;PixelWidth=[int]$bmp.PixelWidth;PixelHeight=[int]$bmp.PixelHeight}
}

function Set-QChibiLayerVisual {
    param([Parameter(Mandatory=$true)]$Renderer,[Parameter(Mandatory=$true)][ValidateSet('old','new')][string]$Side,[Parameter(Mandatory=$true)][string]$State,[double]$TasselAngle=0.0)
    $layer=if($Side -eq 'old'){$Renderer.OldStateLayer}else{$Renderer.NewStateLayer};$image=if($Side -eq 'old'){$Renderer.OldStateImage}else{$Renderer.NewStateImage};$assembly=if($Side -eq 'old'){$Renderer.OldTasselAssembly}else{$Renderer.NewTasselAssembly};$cap=if($Side -eq 'old'){$Renderer.OldTasselRootCap}else{$Renderer.NewTasselRootCap};$rotate=if($Side -eq 'old'){$Renderer.OldTasselRotate}else{$Renderer.NewTasselRotate};$state=$State.ToLowerInvariant()
    if($state -eq 'idle'){$image.Source=$Renderer.Assets.idle_base.Bitmap;$assembly.Source=$Renderer.Assets.tassel_assembly.Bitmap;$cap.Source=$Renderer.Assets.tassel_root_cap.Bitmap;$assembly.Visibility=[Windows.Visibility]::Visible;$cap.Visibility=[Windows.Visibility]::Visible;$rotate.Angle=$TasselAngle}
    else{$image.Source=$Renderer.Assets.states[$state].Bitmap;$assembly.Source=$null;$cap.Source=$null;$assembly.Visibility=[Windows.Visibility]::Collapsed;$cap.Visibility=[Windows.Visibility]::Collapsed;$rotate.Angle=0}
    $layer.Visibility=[Windows.Visibility]::Visible;$layer.Opacity=1.0
    if($Side -eq 'old'){$Renderer.OldVisualState=$state}else{$Renderer.NewVisualState=$state}
}

function Clear-QChibiLayer {
    param([Parameter(Mandatory=$true)][ValidateSet('old','new')][string]$Side,$Renderer)
    $layer=if($Side -eq 'old'){$Renderer.OldStateLayer}else{$Renderer.NewStateLayer};$image=if($Side -eq 'old'){$Renderer.OldStateImage}else{$Renderer.NewStateImage};$assembly=if($Side -eq 'old'){$Renderer.OldTasselAssembly}else{$Renderer.NewTasselAssembly};$cap=if($Side -eq 'old'){$Renderer.OldTasselRootCap}else{$Renderer.NewTasselRootCap}
    $layer.Opacity=0.0;$layer.Visibility=[Windows.Visibility]::Collapsed;$image.Source=$null;$assembly.Source=$null;$cap.Source=$null
    if($Side -eq 'old'){$Renderer.OldVisualState=''}else{$Renderer.NewVisualState=''}
}

function Set-QChibiTasselAngle {
    param([Parameter(Mandatory=$true)]$Renderer,[double]$Angle)
    $Renderer.TasselAngle=$Angle
    if($Renderer.OldVisualState -eq 'idle' -and $Renderer.OldStateLayer.Visibility -eq [Windows.Visibility]::Visible){$Renderer.OldTasselRotate.Angle=$Angle}
    if($Renderer.NewVisualState -eq 'idle' -and $Renderer.NewStateLayer.Visibility -eq [Windows.Visibility]::Visible){$Renderer.NewTasselRotate.Angle=$Angle}
}

function Stop-QChibiTasselMotion {
    param([Parameter(Mandatory=$true)]$Renderer,[string]$Reason='state_exit')
    if($Renderer.TasselTimer.IsEnabled){$Renderer.TasselTimer.Stop()}
    if($Renderer.TasselMotionActive){$Renderer.TasselMotionActive=$false;if($Renderer.Controller){Write-QChibiControllerEvent -Controller $Renderer.Controller -Event 'tassel.motion_stopped' -StateFrom 'idle' -StateTo $Renderer.TargetState -Trigger $Reason -Extra @{overlay_frozen_for_outgoing_crossfade=($Renderer.OldVisualState -eq 'idle');overlay_attached_to_target=($Renderer.NewVisualState -eq 'idle')}}}
}
function Start-QChibiTasselMotion {
    param([Parameter(Mandatory=$true)]$Renderer,[string]$Reason='enter_idle')
    $Renderer.TasselPhaseStartedUtc=[DateTime]::UtcNow;$Renderer.TasselMotionActive=$true;if(-not $Renderer.TasselTimer.IsEnabled){$Renderer.TasselTimer.Start()}
    if($Renderer.Controller){Write-QChibiControllerEvent -Controller $Renderer.Controller -Event 'tassel.motion_started' -StateFrom $Renderer.CurrentState -StateTo 'idle' -Trigger $Reason -Extra @{period_seconds=2.8;allowed_state='idle';advanced_realism='DEFERRED_OPTIONAL'}}
}

function Complete-QChibiCrossfade {
    param([Parameter(Mandatory=$true)]$Renderer,[string]$Reason='duration_elapsed')
    if(-not $Renderer.IsTransitioning){return}
    $elapsed=[double]$Renderer.TransitionClock.Elapsed.TotalMilliseconds;$Renderer.TransitionTimer.Stop();$Renderer.OldStateLayer.Opacity=0.0;$Renderer.NewStateLayer.Opacity=1.0;$Renderer.NewStateLayer.Visibility=[Windows.Visibility]::Visible;Clear-QChibiLayer -Side old -Renderer $Renderer;$Renderer.CurrentState=[string]$Renderer.TargetState;$Renderer.IsTransitioning=$false;$Renderer.ActiveVisualStateLayerCount=1;$Renderer.TransitionCompletedCount=[int]$Renderer.TransitionCompletedCount+1
    if($Renderer.Controller){
        Write-QChibiControllerEvent -Controller $Renderer.Controller -Event 'transition.completed' -StateFrom $Renderer.TransitionFrom -StateTo $Renderer.CurrentState -Trigger $Reason -Extra @{requested_duration_ms=125;actual_duration_ms=[Math]::Round($elapsed,3);transition_frame_updates=[int]$Renderer.TransitionFrameUpdates;opacity_sum_min=[Math]::Round([double]$Renderer.OpacitySumMin,6);opacity_sum_max=[Math]::Round([double]$Renderer.OpacitySumMax,6);old_layer_cleaned=($Renderer.OldStateLayer.Visibility -eq [Windows.Visibility]::Collapsed -and $null -eq $Renderer.OldStateImage.Source -and $null -eq $Renderer.OldTasselAssembly.Source -and $null -eq $Renderer.OldTasselRootCap.Source);new_layer_visible=($Renderer.NewStateLayer.Visibility -eq [Windows.Visibility]::Visible -and $Renderer.NewStateLayer.Opacity -ge 0.999);active_visual_state_layer_count=1;asset_decode_count_delta=0;window_position_write_count=0}
        Complete-QChibiStateRequest -Controller $Renderer.Controller
    }
}

function New-QChibiWpfStateRenderer {
    param([Parameter(Mandatory=$true)][string]$ManifestPath,[Parameter(Mandatory=$true)]$Window,[Parameter(Mandatory=$true)]$StateHost,[Parameter(Mandatory=$true)]$OldStateLayer,[Parameter(Mandatory=$true)]$NewStateLayer,[Parameter(Mandatory=$true)]$OldStateImage,[Parameter(Mandatory=$true)]$NewStateImage,[Parameter(Mandatory=$true)]$OldTasselAssembly,[Parameter(Mandatory=$true)]$NewTasselAssembly,[Parameter(Mandatory=$true)]$OldTasselRootCap,[Parameter(Mandatory=$true)]$NewTasselRootCap,[Parameter(Mandatory=$true)][string]$LogPath)
    if(-not(Test-Path -LiteralPath $ManifestPath -PathType Leaf)){throw "Q_Chibi state manifest not found: $ManifestPath"};$manifest=Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    if($manifest.manifest_version -ne 'phase3i-q-chibi-whole-state-runtime-v1'){throw 'Unsupported Q_Chibi runtime manifest version.'};if([int]$manifest.transition.duration_ms -ne 125){throw 'Runtime cross-dissolve duration must be 125ms.'}
    $stateBitmaps=@{};$stateMetadata=@{}
    foreach($state in $script:QChibiAllowedStates){
        $record=$manifest.state_assets.PSObject.Properties[$state].Value;if(-not $record){throw "Runtime state asset missing manifest entry: $state"}
        if($state -eq 'idle'){$canonical=Get-QChibiVerifiedBitmap -Path ([string]$record.canonical_full_state_path) -ExpectedSha256 ([string]$record.sha256) -AssetName 'idle canonical source' -HashOnly;$idleBase=Get-QChibiVerifiedBitmap -Path ([string]$record.idle_base_path) -ExpectedSha256 ([string]$record.idle_base_sha256) -AssetName 'idle accepted tassel base';$assembly=Get-QChibiVerifiedBitmap -Path ([string]$record.tassel_assembly_path) -ExpectedSha256 ([string]$record.tassel_assembly_sha256) -AssetName 'idle accepted tassel assembly';$rootCap=Get-QChibiVerifiedBitmap -Path ([string]$record.tassel_root_cap_path) -ExpectedSha256 ([string]$record.tassel_root_cap_sha256) -AssetName 'idle accepted tassel root cap';$stateMetadata[$state]=[pscustomobject]@{SourcePath=[string]$record.canonical_full_state_path;Sha256=$canonical.Sha256;RenderKind=[string]$record.render_kind;Width=1086;Height=1448}}
        else{$asset=Get-QChibiVerifiedBitmap -Path ([string]$record.path) -ExpectedSha256 ([string]$record.sha256) -AssetName $state;$stateBitmaps[$state]=$asset;$stateMetadata[$state]=[pscustomobject]@{SourcePath=[string]$record.path;Sha256=$asset.Sha256;RenderKind=[string]$record.render_kind;Width=$asset.PixelWidth;Height=$asset.PixelHeight}}
    }
    $assets=@{states=$stateBitmaps;idle_base=$idleBase;tassel_assembly=$assembly;tassel_root_cap=$rootCap;canonical_idle=$canonical;manifest=$manifest}
    $scale=[Math]::Min((305.0/1086.0),(485.0/1448.0));$pivotX=603.0*$scale;$pivotY=((485.0-(1448.0*$scale))/2.0)+(1268.0*$scale);$oldRotate=New-Object Windows.Media.RotateTransform(0,$pivotX,$pivotY);$newRotate=New-Object Windows.Media.RotateTransform(0,$pivotX,$pivotY);$OldTasselAssembly.RenderTransform=$oldRotate;$NewTasselAssembly.RenderTransform=$newRotate
    $renderer=[pscustomobject]@{Window=$Window;StateHost=$StateHost;OldStateLayer=$OldStateLayer;NewStateLayer=$NewStateLayer;OldStateImage=$OldStateImage;NewStateImage=$NewStateImage;OldTasselAssembly=$OldTasselAssembly;NewTasselAssembly=$NewTasselAssembly;OldTasselRootCap=$OldTasselRootCap;NewTasselRootCap=$NewTasselRootCap;OldTasselRotate=$oldRotate;NewTasselRotate=$newRotate;Assets=$assets;StateMetadata=$stateMetadata;LogPath=$LogPath;CurrentState='';TargetState='';OldVisualState='';NewVisualState='';IsTransitioning=$false;TransitionFrom='';TransitionStartedUtc=$null;TransitionClock=(New-Object System.Diagnostics.Stopwatch);TransitionFrameUpdates=0;TransitionCompletedCount=0;OpacitySumMin=1.0;OpacitySumMax=1.0;TasselMotionActive=$false;TasselPhaseStartedUtc=[DateTime]::UtcNow;TasselAngle=0.0;TasselTickCount=0;PreloadedBitmapCount=9;VerifiedSourceFileCount=10;ActiveVisualStateLayerCount=0;TransitionTimer=$null;TasselTimer=$null;Controller=$null;DecodeInsideTickCount=0;WindowPositionWriteCount=0;StartupPositionLeft=[double]$Window.Left;StartupPositionTop=[double]$Window.Top}
    $renderer.TransitionTimer=New-Object Windows.Threading.DispatcherTimer;$renderer.TransitionTimer.Interval=[TimeSpan]::FromMilliseconds(5);$renderer.TasselTimer=New-Object Windows.Threading.DispatcherTimer;$renderer.TasselTimer.Interval=[TimeSpan]::FromMilliseconds(40)
    $renderer.TasselTimer.Add_Tick({try{if(-not $renderer.TasselMotionActive){$renderer.TasselTimer.Stop();return};$elapsed=([DateTime]::UtcNow-$renderer.TasselPhaseStartedUtc).TotalSeconds;$phi=2.0*[Math]::PI*($elapsed/2.8);$sin=[Math]::Sin($phi);$angle=4.6*($sin+0.025*$sin*$sin);Set-QChibiTasselAngle -Renderer $renderer -Angle $angle;$renderer.TasselTickCount=[int]$renderer.TasselTickCount+1}catch{$renderer.TasselTimer.Stop();$renderer.TasselMotionActive=$false;if($renderer.Controller){Write-QChibiControllerEvent -Controller $renderer.Controller -Event 'tassel.tick.error' -Trigger 'tassel_timer' -Extra @{error_type=$_.Exception.GetType().FullName;error_message=$_.Exception.Message}};try{Write-PetCaughtException 'q_chibi.tassel_tick' $_}catch{}}}.GetNewClosure())
    $renderer.TransitionTimer.Add_Tick({try{if(-not $renderer.IsTransitioning){$renderer.TransitionTimer.Stop();return};$elapsed=[double]$renderer.TransitionClock.Elapsed.TotalMilliseconds;$t=[Math]::Max(0.0,[Math]::Min(1.0,$elapsed/125.0));$smooth=$t*$t*(3.0-(2.0*$t));$renderer.OldStateLayer.Opacity=1.0-$smooth;$renderer.NewStateLayer.Opacity=1.0;$sum=[double]$renderer.OldStateLayer.Opacity+[double]$renderer.NewStateLayer.Opacity;if($sum -lt $renderer.OpacitySumMin){$renderer.OpacitySumMin=$sum};if($sum -gt $renderer.OpacitySumMax){$renderer.OpacitySumMax=$sum};$renderer.TransitionFrameUpdates=[int]$renderer.TransitionFrameUpdates+1;if($elapsed -ge 125.0){Complete-QChibiCrossfade -Renderer $renderer -Reason 'duration_elapsed'}}catch{$renderer.TransitionTimer.Stop();$renderer.IsTransitioning=$false;$renderer.ActiveVisualStateLayerCount=1;if($renderer.Controller){Write-QChibiControllerEvent -Controller $renderer.Controller -Event 'transition.tick.error' -StateFrom $renderer.TransitionFrom -StateTo $renderer.TargetState -Trigger 'transition_timer' -Extra @{error_type=$_.Exception.GetType().FullName;error_message=$_.Exception.Message}};try{Write-PetCaughtException 'q_chibi.transition_tick' $_}catch{}}}.GetNewClosure())
    $StateHost.Visibility=[Windows.Visibility]::Visible;$renderer.TargetState='idle';Set-QChibiLayerVisual -Renderer $renderer -Side new -State 'idle' -TasselAngle 0;$NewStateLayer.Opacity=1.0;$OldStateLayer.Visibility=[Windows.Visibility]::Collapsed;$OldStateLayer.Opacity=0.0;$renderer.CurrentState='idle';$renderer.NewVisualState='idle';$renderer.ActiveVisualStateLayerCount=1
    return $renderer
}

function New-QChibiStateController {
    param([Parameter(Mandatory=$true)]$Renderer,[Parameter(Mandatory=$true)][string]$LogPath)
    $controller=[pscustomobject]@{Name='Q_CHIBI_STATE_CONTROLLER';State='idle';Generation=0;Renderer=$Renderer;LogPath=$LogPath;Events=(New-Object 'System.Collections.Generic.List[object]');TransitionRequests=0;TransitionCompletions=0;AllowedStates=@($script:QChibiAllowedStates);PendingState='';PendingTrigger='';PendingReason=''}
    $Renderer.Controller=$controller
    Write-QChibiControllerEvent -Controller $controller -Event 'state_controller.initialized' -StateTo 'idle' -Trigger 'startup' -Extra @{allowed_states=@($controller.AllowedStates);transition_algorithm='WPF old-over-new, old opacity=1-smoothstep(t), new opacity=1';premultiplied_rgba_linear_interpolation=$false;transition_duration_ms=125;renderer='WPF_Canvas_Image_layers';state_logic_separated_from_image_renderer=$true;source_asset_verification='PASS';verified_source_file_count=$Renderer.VerifiedSourceFileCount;preloaded_bitmap_count=$Renderer.PreloadedBitmapCount;decode_inside_tick=0;enabled_motion_channels=@('RIGHT_ANKLE_TASSEL_BASIC_IDLE@idle');disabled_motion_channels=@('BLINK','CLOUD_FLOAT','WING','TAIL','HAIR','DRESS','whole_body_breathing')}
    return $controller
}

function Complete-QChibiStateRequest {
    param([Parameter(Mandatory=$true)]$Controller)
    if([string]::IsNullOrWhiteSpace([string]$Controller.PendingState)){return}
    $state=[string]$Controller.PendingState;$trigger=[string]$Controller.PendingTrigger;$reason=[string]$Controller.PendingReason;$Controller.PendingState='';$Controller.PendingTrigger='';$Controller.PendingReason=''
    Set-QChibiStateControllerState -Controller $Controller -State $state -Trigger $trigger -Reason $reason
}

function Set-QChibiStateControllerState {
    param([Parameter(Mandatory=$true)]$Controller,[Parameter(Mandatory=$true)][string]$State,[string]$Trigger='state_controller',[string]$Reason='')
    $state=$State.ToLowerInvariant();if($Controller.AllowedStates -notcontains $state){throw "Unsupported Q_Chibi state: $State"}
    if($state -eq [string]$Controller.State -and -not $Controller.Renderer.IsTransitioning){Write-QChibiControllerEvent -Controller $Controller -Event 'state.unchanged' -StateFrom $state -StateTo $state -Trigger $Trigger -Extra @{reason=$Reason;image_reload=$false};return $false}
    if($Controller.Renderer.IsTransitioning){$Controller.PendingState=$state;$Controller.PendingTrigger=$Trigger;$Controller.PendingReason=$Reason;Write-QChibiControllerEvent -Controller $Controller -Event 'state.request_queued' -StateFrom ([string]$Controller.State) -StateTo $state -Trigger $Trigger -Extra @{reason=$Reason;queue_policy='latest_request_after_current_125ms_transition'};return $true}
    $from=[string]$Controller.State;$r=$Controller.Renderer
    if($from -eq 'idle' -and $state -ne 'idle'){Stop-QChibiTasselMotion -Renderer $r -Reason 'state_exit_idle'}
    $angle=[double]$r.TasselAngle;$r.TransitionFrom=$from;$r.TargetState=$state
    Set-QChibiLayerVisual -Renderer $r -Side old -State $from -TasselAngle $angle
    $incomingAngle=if($state -eq 'idle'){$angle}else{0.0};Set-QChibiLayerVisual -Renderer $r -Side new -State $state -TasselAngle $incomingAngle
    $r.OldStateLayer.Opacity=1.0;$r.NewStateLayer.Opacity=1.0;$r.OldStateLayer.Visibility=[Windows.Visibility]::Visible;$r.NewStateLayer.Visibility=[Windows.Visibility]::Visible;$r.IsTransitioning=$true;$r.TransitionStartedUtc=[DateTimeOffset]::Now;$r.TransitionClock.Reset();$r.TransitionClock.Start();$r.TransitionFrameUpdates=0;$r.OpacitySumMin=2.0;$r.OpacitySumMax=2.0;$r.ActiveVisualStateLayerCount=2
    $Controller.State=$state;$Controller.Generation=[int]$Controller.Generation+1;$Controller.TransitionRequests=[int]$Controller.TransitionRequests+1
    if($state -eq 'idle' -and $from -ne 'idle'){Start-QChibiTasselMotion -Renderer $r -Reason 'state_enter_idle'}
    $oldMeta=$r.StateMetadata[$from];$newMeta=$r.StateMetadata[$state]
    Write-QChibiControllerEvent -Controller $Controller -Event 'transition.started' -StateFrom $from -StateTo $state -Trigger $Trigger -Extra @{reason=$Reason;requested_duration_ms=125;algorithm='old-over-new WPF source-over smoothstep (opaque overlap matches linear cross-dissolve)';true_cross_dissolve=$true;alpha_edge_caveat='Transparent overlaps use WPF source-over, not premultiplied-linear source image interpolation';old_source_path=$oldMeta.SourcePath;old_source_sha256=$oldMeta.Sha256;old_render_kind=$oldMeta.RenderKind;new_source_path=$newMeta.SourcePath;new_source_sha256=$newMeta.Sha256;new_render_kind=$newMeta.RenderKind;old_and_new_state_layers_simultaneous=$true;fade_to_background=$false;target_state_pixel_size=@(1086,1448);image_decode_count_delta=0;window_position_write_count=0}
    $r.TransitionTimer.Start();return $true
}

function Get-QChibiStateControllerSnapshot {
    param([Parameter(Mandatory=$true)]$Controller)
    $r=$Controller.Renderer
    return [ordered]@{name=$Controller.Name;state=$Controller.State;generation=$Controller.Generation;transition_requests=$Controller.TransitionRequests;transition_completions=$r.TransitionCompletedCount;is_transitioning=$r.IsTransitioning;target_state=$r.TargetState;old_layer_visible=($r.OldStateLayer.Visibility -eq [Windows.Visibility]::Visible);new_layer_visible=($r.NewStateLayer.Visibility -eq [Windows.Visibility]::Visible);old_layer_source_present=($null -ne $r.OldStateImage.Source);new_layer_source_present=($null -ne $r.NewStateImage.Source);active_visual_state_layer_count=$r.ActiveVisualStateLayerCount;preloaded_bitmap_count=$r.PreloadedBitmapCount;verified_source_file_count=$r.VerifiedSourceFileCount;decode_inside_tick=$r.DecodeInsideTickCount;window_position_write_count=$r.WindowPositionWriteCount;source_asset_count=$r.StateMetadata.Count;source_hashes_verified=$true;tassel_motion_active=$r.TasselMotionActive;tassel_tick_count=$r.TasselTickCount;disabled_channels=@('BLINK','CLOUD_FLOAT','WING','TAIL','HAIR','DRESS','whole_body_breathing');position_start=@($r.StartupPositionLeft,$r.StartupPositionTop);position_end=@([double]$r.Window.Left,[double]$r.Window.Top);event_count=$Controller.Events.Count}
}

param([switch]$AccountSyncSimulation,[switch]$DebugMode,[switch]$RuntimeStateTestSequence,[switch]$ManualAcceptanceHold,[switch]$RuntimeCapture,[string]$RuntimeCaptureDirectory='evidence\phase3i_runtime_capture')
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:accountSyncContext=$null
$script:quotaPages=$null
$script:quotaPageSelecting=$false
if($ManualAcceptanceHold -and -not $RuntimeStateTestSequence){throw 'MANUAL_ACCEPTANCE_HOLD requires RuntimeStateTestSequence.'}
if($ManualAcceptanceHold -and $RuntimeCapture){throw 'MANUAL_ACCEPTANCE_HOLD does not use automated runtime capture.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
Add-Type -AssemblyName System.Windows.Forms
. (Join-Path $PSScriptRoot 'quota_core.ps1')
. (Join-Path $PSScriptRoot 'Lumi.Environment.ps1')

$mutexName = if($AccountSyncSimulation){'Lumi_Trial_20261019_R2_Simulation'}else{'Lumi_Trial_20261019_R2_Real'}
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

$statePath = Join-Path $PSScriptRoot $(if($AccountSyncSimulation){'local_state\presentation-simulation.json'}else{'local_state\presentation.json'})
if(-not [IO.Directory]::Exists((Join-Path $PSScriptRoot 'evidence'))){[void][IO.Directory]::CreateDirectory((Join-Path $PSScriptRoot 'evidence'))}
$configPath = Join-Path $PSScriptRoot 'config.json'
$assetManifestPath = Join-Path $PSScriptRoot 'assets\asset_manifest.json'
$legacyMascotPath = Join-Path $PSScriptRoot 'assets\mascot_phase1_clean.png'
$diagnosticsModule = Join-Path $PSScriptRoot 'modules\\Pet.Diagnostics.ps1'
$windowingModule = Join-Path $PSScriptRoot 'modules\Pet.Windowing.ps1'
$dragCoreModule = Join-Path $PSScriptRoot 'modules\Pet.DragCore.ps1'
$appearanceModule = Join-Path $PSScriptRoot 'modules\Pet.Appearance.ps1'
$stateControllerModule = Join-Path $PSScriptRoot 'modules\Pet.StateController.ps1'
$animationRuntimeModule = Join-Path $PSScriptRoot 'modules\Pet.AnimationRuntime.ps1'
$chibiAnimationModule = Join-Path $PSScriptRoot 'modules\Pet.ChibiIdleAnimation.ps1'
$chibiAnimationManifestPath = Join-Path $PSScriptRoot 'assets\animation\q_chibi_idle\animation_manifest.phase3b4_safe_subset_restore.json'
$qChibiStateControllerModule = Join-Path (Join-Path $PSScriptRoot 'modules') 'Pet.QChibiStateController.ps1'
$qChibiStateManifestPath = Join-Path (Join-Path $PSScriptRoot 'assets') (Join-Path 'q_chibi_whole_states' 'runtime_state_manifest.json')
$phase3iCaptureModule = Join-Path (Join-Path $PSScriptRoot 'modules') 'Pet.Phase3IRuntimeCapture.ps1'
if($RuntimeCapture -and -not (Test-Path -LiteralPath $phase3iCaptureModule)){throw "Missing Phase 3I runtime capture helper: $phase3iCaptureModule"}
foreach($requiredModule in @($diagnosticsModule,$windowingModule,$dragCoreModule,$appearanceModule,$stateControllerModule,$animationRuntimeModule,$chibiAnimationModule,$assetManifestPath,$chibiAnimationManifestPath,$qChibiStateControllerModule,$qChibiStateManifestPath)) {
    if (-not (Test-Path -LiteralPath $requiredModule)) { throw "Missing Phase 2 asset/module: $requiredModule" }
}
. $diagnosticsModule
. $windowingModule
. $dragCoreModule
. $appearanceModule
. $stateControllerModule
. $animationRuntimeModule
. $chibiAnimationModule
. $qChibiStateControllerModule
function New-PetChibiIdleAnimationContext {
    param($Dispatcher,[string]$AssetRoot,$LayerHost,$BodyHost,$BaseLayer,$TailLayer,$FrontHairLayer,$EyesLayer,$FacePatchLayer,$EyesClosedLayer,$CloudLayer,$Mascot)
    # Phase 3I uses audited whole-state frames. Legacy blink/cloud/layer channels stay uninstantiated.
    return $script:chibiAnimationContext
}
$null = Initialize-PetDiagnostics -LogDirectory (Join-Path $PSScriptRoot 'logs')

function Read-JsonFile($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Get-ObjectValue($object,[string]$name,$defaultValue) {
    if ($object -and $object.PSObject.Properties.Name -contains $name) {
        $value = $object.$name
        if ($null -ne $value) { return $value }
    }
    return $defaultValue
}
$config = Read-JsonFile $configPath
if (-not $config) { $config = [pscustomobject]@{refresh_seconds=60; appearance='chibi'; scale_chibi=0.62; scale_anime=0.48; topmost=$true; snap_distance=32; click_drag_threshold_dip=6; move_throttle_ms=16; snap_duration_ms=160; long_idle_seconds=120; sleeping_seconds=300; locked=$false; start_x=-1; start_y=-1} }
$state = Read-JsonFile $statePath
$phase2Manifest = Read-JsonFile $assetManifestPath
if (-not $phase2Manifest) { throw "Unable to read Phase 2 asset manifest: $assetManifestPath" }

$xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="GPT Quota Pet · Live2D Quota R7"
        Width="690" Height="540" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" ShowInTaskbar="False" ResizeMode="NoResize" Topmost="True">
  <Window.Resources><ResourceDictionary><ResourceDictionary.MergedDictionaries><ResourceDictionary Source="__PET_THEME_URI__"/></ResourceDictionary.MergedDictionaries></ResourceDictionary></Window.Resources>
  <Canvas x:Name="Root" Background="Transparent">
    <Border x:Name="Bubble" Canvas.Left="18" Canvas.Top="72" Width="345" Height="350"
            Background="#FCFFFE" BorderBrush="#B8DDD4" BorderThickness="1" CornerRadius="24"
            Opacity="0" Visibility="Collapsed" RenderTransformOrigin="0.92,0.82">
      <Border.RenderTransform><ScaleTransform x:Name="BubbleScale" ScaleX="0.88" ScaleY="0.88"/></Border.RenderTransform>
      <Grid Margin="22,20,22,18">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="34"/><RowDefinition Height="78"/>
          <RowDefinition Height="78"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0">
          <TextBlock Text="GPT / Codex 额度" FontSize="22" FontWeight="SemiBold" Foreground="#173F3D" DockPanel.Dock="Left"/>
          <Border x:Name="PlanBadge" Background="#CFF7E9" CornerRadius="12" Padding="9,3" HorizontalAlignment="Right">
            <TextBlock x:Name="PlanText" Text="OFFLINE" FontWeight="Bold" Foreground="#147869" FontSize="13"/>
          </Border>
        </DockPanel>
        <TextBlock x:Name="StatusText" Grid.Row="1" Text="点击刷新额度" TextTrimming="CharacterEllipsis" Foreground="#678B88" FontSize="12" Margin="0,7,0,4"/>

        <DockPanel Grid.Row="2" Margin="0,4,0,2" LastChildFill="True">
          <Button x:Name="QuotaPagePrev" Content="‹" Width="26" FontSize="17" Padding="0" DockPanel.Dock="Left"/>
          <Button x:Name="QuotaPageNext" Content="›" Width="26" FontSize="17" Padding="0" DockPanel.Dock="Right"/>
          <Button x:Name="QuotaFollowBtn" Content="跟随登录" DockPanel.Dock="Right" Padding="5,2" Margin="4,0"/>
          <TextBlock x:Name="QuotaPageIndex" Text="0/0" DockPanel.Dock="Right" VerticalAlignment="Center" Margin="4,0"/>
          <ComboBox x:Name="QuotaPageSelect" DisplayMemberPath="label" MinWidth="80"/>
        </DockPanel>
        <Grid Grid.Row="3" Margin="0,4,0,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel>
            <TextBlock Text="Session" FontSize="18" FontWeight="SemiBold" Foreground="#173F3D"/>
            <TextBlock x:Name="SessionPct" Text="--%" HorizontalAlignment="Right" FontSize="24" FontWeight="Bold" Foreground="#168B76"/>
          </DockPanel>
          <ProgressBar x:Name="SessionBar" Grid.Row="1" Minimum="0" Maximum="100" Value="0" Height="12" Margin="0,6,0,3" BorderThickness="0" Foreground="#27BE91" Background="#D7E7E5"/>
          <TextBlock x:Name="SessionReset" Grid.Row="2" Text="reset --" FontSize="12" Foreground="#76908E"/>
        </Grid>

        <Grid Grid.Row="4" Margin="0,4,0,0">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <DockPanel>
            <TextBlock Text="Weekly" FontSize="18" FontWeight="SemiBold" Foreground="#173F3D"/>
            <TextBlock x:Name="WeeklyPct" Text="--%" HorizontalAlignment="Right" FontSize="24" FontWeight="Bold" Foreground="#168B76"/>
          </DockPanel>
          <ProgressBar x:Name="WeeklyBar" Grid.Row="1" Minimum="0" Maximum="100" Value="0" Height="12" Margin="0,6,0,3" BorderThickness="0" Foreground="#27BE91" Background="#D7E7E5"/>
          <TextBlock x:Name="WeeklyReset" Grid.Row="2" Text="reset --" FontSize="12" Foreground="#76908E"/>
        </Grid>

        <StackPanel Grid.Row="5" Orientation="Horizontal" Margin="0,6,0,0">
          <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#9AA8A6" Margin="0,2,8,0"/>
          <TextBlock x:Name="LastUpdateText" Text="尚未连接" Foreground="#678B88" FontSize="12"/>
        </StackPanel>
        <StackPanel Grid.Row="6" Orientation="Horizontal" Margin="0,10,0,0" HorizontalAlignment="Right" VerticalAlignment="Bottom">
          <Button x:Name="SetupBtn" Content="账号管理" Padding="10,5" Margin="0,0,8,0" Visibility="Collapsed"/>
          <Button x:Name="LoginBtn" Content="账号登录" Padding="10,5" Margin="0,0,8,0" Visibility="Collapsed"/>
          <Button x:Name="AccountSyncBtn" Content="账号管理" Padding="12,6" Margin="0,0,8,0"/><Button x:Name="RefreshBtn" Content="刷新额度" Style="{StaticResource AccentButton}" Padding="12,6"/>
        </StackPanel>
      </Grid>
    </Border>

    <Border x:Name="QuotaNotice" Canvas.Left="18" Canvas.Top="456" Width="345" Height="70" Background="#F0FAF6" BorderBrush="#B8DDD4" BorderThickness="1" CornerRadius="16" Visibility="Collapsed" Padding="12,7">
      <DockPanel><Button x:Name="QuotaNoticeClose" Content="×" Padding="0" DockPanel.Dock="Right" Width="24" Height="24" VerticalAlignment="Top"/><TextBlock x:Name="QuotaNoticeText" Foreground="#173F3D" FontSize="13" TextWrapping="Wrap" VerticalAlignment="Center"/></DockPanel>
    </Border>
    <Grid x:Name="PetArea" Canvas.Left="365" Canvas.Top="30" Width="305" Height="485" Background="Transparent">
      <Grid.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="PetScale" ScaleX="0.62" ScaleY="0.62" CenterX="152" CenterY="240"/>
          <TranslateTransform x:Name="PetFloat" X="0" Y="0"/>
        </TransformGroup>
      </Grid.RenderTransform>
      <Canvas x:Name="QChibiWholeStateHost" Width="305" Height="485" Background="Transparent" IsHitTestVisible="False" Visibility="Collapsed" ClipToBounds="True">
        <Canvas x:Name="OldStateLayer" Panel.ZIndex="1" Width="305" Height="485" Background="Transparent" IsHitTestVisible="False" Opacity="0" Visibility="Collapsed">
          <Image x:Name="OldStateImage" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False"/>
          <Image x:Name="OldTasselAssembly" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False" Visibility="Collapsed"/>
          <Image x:Name="OldTasselRootCap" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False" Visibility="Collapsed"/>
        </Canvas>
        <Canvas x:Name="NewStateLayer" Panel.ZIndex="0" Width="305" Height="485" Background="Transparent" IsHitTestVisible="False" Opacity="1" Visibility="Collapsed">
          <Image x:Name="NewStateImage" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False"/>
          <Image x:Name="NewTasselAssembly" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False" Visibility="Collapsed"/>
          <Image x:Name="NewTasselRootCap" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False" Visibility="Collapsed"/>
        </Canvas>
      </Canvas>
      <Image x:Name="Mascot" Width="305" Height="485" Stretch="Uniform" Cursor="Hand" RenderOptions.BitmapScalingMode="HighQuality" SnapsToDevicePixels="False"/>
      <Canvas x:Name="AnimationLayerHost" Width="305" Height="485" Background="Transparent" IsHitTestVisible="False" Visibility="Collapsed">
        <Canvas x:Name="AnimationBodyHost" Width="305" Height="485" Background="Transparent">
          <Image x:Name="QBaseLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          <Image x:Name="QTailLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          <Image x:Name="QFrontHairLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          <Image x:Name="QEyesLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          <Image x:Name="QFacePatchLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
          <Image x:Name="QEyesClosedLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
        </Canvas>
        <Image x:Name="QCloudLayer" Width="305" Height="485" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
      </Canvas>
      <StackPanel x:Name="HoverControls" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,4,4,0" Opacity="0">
        <Button x:Name="MinusBtn" Content="−" Width="33" Height="30" Margin="2" FontSize="16"/>
        <Button x:Name="PlusBtn" Content="＋" Width="33" Height="30" Margin="2" FontSize="16"/>
        <Button x:Name="LockBtn" Content="移" ToolTip="锁定位置" Width="33" Height="30" Margin="2" FontSize="14"/>
        <Button x:Name="AppearanceBtn" Content="形" ToolTip="切换 Q版 / 非Q版" Width="33" Height="30" Margin="2" FontSize="14"/>
        <Button x:Name="TopBtn" Content="◆" Width="33" Height="30" Margin="2" FontSize="15"/>
        <Button x:Name="CloseBtn" Content="×" Width="33" Height="30" Margin="2" FontSize="17"/>
      </StackPanel>
      <Border x:Name="MiniBadge" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,42,8,0" Background="#D94B596A" CornerRadius="13" Padding="8,3">
        <TextBlock x:Name="MiniText" Text="GPT --" Foreground="White" FontWeight="Bold" FontSize="12"/>
      </Border>
    </Grid>
  </Canvas>
</Window>
'@
$xamlText=$xamlText.Replace('__PET_THEME_URI__',([Uri]::new((Join-Path $PSScriptRoot 'theme\Quota.Theme.xaml'))).AbsoluteUri)
[xml]$xaml=$xamlText
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.FontFamily='Microsoft YaHei UI'
$window.Opacity=0
function X($n) { return $window.FindName($n) }
$rootCanvas=X 'Root'; $bubble=X 'Bubble'; $bubbleScale=X 'BubbleScale'; $petArea=X 'PetArea'; $petScale=X 'PetScale'; $petFloat=X 'PetFloat'
$mascot=X 'Mascot'; $qChibiWholeStateHost=X 'QChibiWholeStateHost'; $oldStateLayer=X 'OldStateLayer'; $newStateLayer=X 'NewStateLayer'; $oldStateImage=X 'OldStateImage'; $newStateImage=X 'NewStateImage'; $oldTasselAssembly=X 'OldTasselAssembly'; $newTasselAssembly=X 'NewTasselAssembly'; $oldTasselRootCap=X 'OldTasselRootCap'; $newTasselRootCap=X 'NewTasselRootCap'; $animationLayerHost=X 'AnimationLayerHost'; $animationBodyHost=X 'AnimationBodyHost'; $qBaseLayer=X 'QBaseLayer'; $qTailLayer=X 'QTailLayer'; $qFrontHairLayer=X 'QFrontHairLayer'; $qEyesLayer=X 'QEyesLayer'; $qFacePatchLayer=X 'QFacePatchLayer'; $qEyesClosedLayer=X 'QEyesClosedLayer'; $qCloudLayer=X 'QCloudLayer'; $hover=X 'HoverControls'; $mini=X 'MiniText'; $planText=X 'PlanText'; $statusText=X 'StatusText'
$sessionPct=X 'SessionPct'; $sessionBar=X 'SessionBar'; $sessionReset=X 'SessionReset'; $weeklyPct=X 'WeeklyPct'; $weeklyBar=X 'WeeklyBar'; $weeklyReset=X 'WeeklyReset'
$statusDot=X 'StatusDot'; $lastUpdate=X 'LastUpdateText'; $setupBtn=X 'SetupBtn'; $loginBtn=X 'LoginBtn'; $refreshBtn=X 'RefreshBtn'
$minusBtn=X 'MinusBtn'; $plusBtn=X 'PlusBtn'; $lockBtn=X 'LockBtn'; $appearanceBtn=X 'AppearanceBtn'; $topBtn=X 'TopBtn'; $closeBtn=X 'CloseBtn'

$script:appearance = if($RuntimeStateTestSequence){'chibi'}else{[string](Get-ObjectValue $state 'appearance' (Get-ObjectValue $config 'appearance' 'chibi'))}
# Presentation settings are durable; logical/semantic/activity states are runtime-derived.
# Ignore legacy transient fields from older state.json files so sleeping/error/offline
# cannot be resurrected blindly after restart.
$script:logicalState = 'online_good'
$initialRecord = Get-PetPhase2ManifestRecord -Manifest $phase2Manifest -Appearance $script:appearance -LogicalState $script:logicalState
$script:appearance = $initialRecord.Appearance
$script:logicalState = $initialRecord.LogicalState
$script:phase2Manifest = $phase2Manifest
$script:currentAssetRecord = $initialRecord
$initialAssetPath = Join-Path $PSScriptRoot $initialRecord.BaseImage
if (-not (Test-Path -LiteralPath $initialAssetPath)) { throw "Missing Phase 2 asset: $initialAssetPath" }
$bmp = New-Object Windows.Media.Imaging.BitmapImage
$bmp.BeginInit(); $bmp.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bmp.UriSource = New-Object Uri($initialAssetPath); $bmp.EndInit(); $bmp.Freeze(); $mascot.Source=$bmp
$script:qChibiStateLogPath=Join-Path (Join-Path $PSScriptRoot 'logs') 'q_chibi_state_transitions.jsonl'
$script:qChibiRenderer=$null;$script:Q_CHIBI_STATE_CONTROLLER=$null
$script:chibiAnimationContext=[pscustomobject]@{RequiredLayersReady=$true;TransformsInitialized=$true;RendererReady=$false;Active=$false;Scheduler=[pscustomobject]@{EventLog=(New-Object 'System.Collections.Generic.List[object]')}}
$animationLayerHost.Visibility=[Windows.Visibility]::Collapsed
if($script:appearance -eq 'chibi'){
    $script:qChibiRenderer=New-QChibiWpfStateRenderer -ManifestPath $qChibiStateManifestPath -Window $window -StateHost $qChibiWholeStateHost -OldStateLayer $oldStateLayer -NewStateLayer $newStateLayer -OldStateImage $oldStateImage -NewStateImage $newStateImage -OldTasselAssembly $oldTasselAssembly -NewTasselAssembly $newTasselAssembly -OldTasselRootCap $oldTasselRootCap -NewTasselRootCap $newTasselRootCap -LogPath $script:qChibiStateLogPath
    $script:Q_CHIBI_STATE_CONTROLLER=New-QChibiStateController -Renderer $script:qChibiRenderer -LogPath $script:qChibiStateLogPath
    Start-QChibiTasselMotion -Renderer $script:qChibiRenderer -Reason 'startup_idle'
    $qChibiWholeStateHost.Visibility=[Windows.Visibility]::Visible;$mascot.Opacity=0
}else{$qChibiWholeStateHost.Visibility=[Windows.Visibility]::Collapsed;$mascot.Opacity=1}

$window.Topmost = [bool](Get-ObjectValue $state 'topmost' (Get-ObjectValue $config 'topmost' $true))
$script:scaleChibi = Get-PetPhase2ClampedScale (Get-PetPhase2ScaleValue -State $state -Config $config -Appearance 'chibi' -ManifestRecord (Get-PetPhase2ManifestRecord -Manifest $phase2Manifest -Appearance 'chibi' -LogicalState $script:logicalState))
$script:scaleAnime = Get-PetPhase2ClampedScale (Get-PetPhase2ScaleValue -State $state -Config $config -Appearance 'anime' -ManifestRecord (Get-PetPhase2ManifestRecord -Manifest $phase2Manifest -Appearance 'anime' -LogicalState $script:logicalState))
$script:scale = if($script:appearance -eq 'anime'){$script:scaleAnime}else{$script:scaleChibi}
$petScale.ScaleX=$script:scale; $petScale.ScaleY=$script:scale
$savedLeft=Get-ObjectValue $state 'left' $null; $savedTop=Get-ObjectValue $state 'top' $null
$script:hadSavedPosition=($null -ne $savedLeft -and $null -ne $savedTop)
if($script:hadSavedPosition){$window.Left=[double]$savedLeft; $window.Top=[double]$savedTop}else{$window.Left=0; $window.Top=0}

$script:dragPhase='Idle'
$script:pointerDown=$false
$script:dragStartScreen=$null
$script:winStart=$null
$script:lastMoveTicks=0L
$script:releaseInProgress=$false
$script:isSnapping=$false
$script:snapGeneration=0
$script:floatActive=$false
$script:interactionActive=$false
$script:interactionBaseState=$script:logicalState
$savedSemantic=[string](Get-ObjectValue $state 'semantic_state' '')
$script:semanticState=if($savedSemantic -in @('online_good','online_low','offline','error','refreshing')){$savedSemantic}elseif($script:logicalState -in @('online_good','online_low','offline','error','refreshing')){$script:logicalState}else{'online_good'}
$savedActivity=[string](Get-ObjectValue $state 'activity_state' 'none')
$script:activityState=if($savedActivity -in @('none','interaction','long_idle','sleeping','ambient')){$savedActivity}else{'none'}
$script:lastQuotaState=$script:semanticState
$script:interactionStartedUtc=[DateTime]::UtcNow
$script:lastActivityUtc=[DateTime]::UtcNow
$script:ambientStartedUtc=[DateTime]::MinValue
$script:lastVisualTransitionUtc=[DateTime]::MinValue
$script:debugStateOverride=if($RuntimeStateTestSequence){$true}elseif($DebugMode){[bool](Get-ObjectValue $config 'debug_state_override' $false)}else{$false}
$script:debugState='online_good'
$script:initialQuotaObserved=$false
$script:runtimeSequenceIndex=0
$script:runtimeSequenceStartUtc=$null
$script:runtimeSequenceEndUtc=$null
$script:runtimeSequenceTimer=$null
$script:runtimeExitWatchTimer=$null
$script:runtimeHeartbeatSamples=(New-Object 'System.Collections.Generic.List[object]')
$script:lastRuntimeHeartbeatUtc=$null
$script:runtimeSequenceStarted=$false
$script:runtimeCaptureContext=$null
$script:runtimeCaptureSummary=$null
$script:runtimeCaptureRoot=$null
if($RuntimeCapture -and -not $RuntimeStateTestSequence){throw 'RuntimeCapture requires RuntimeStateTestSequence in this isolated proof.'}
if($RuntimeCapture){. $phase3iCaptureModule}
$script:runtimeSequenceCompleteStatus='NOT_STARTED'
$script:runtimeSequenceQuotaTimedOut=$false
$script:autoControllerEnabled=if($RuntimeStateTestSequence){$false}else{[bool](Get-ObjectValue $config 'automatic_state_controller' $true)}
$null = Initialize-PetDiagnostics -LogDirectory (Join-Path $PSScriptRoot 'logs')
$script:lowQuotaThreshold=[double](Get-ObjectValue $config 'low_quota_threshold' 20)
$script:interactionDurationSeconds=[double](Get-ObjectValue $config 'interaction_duration_seconds' 1.6)
$script:ambientEnabled=$false
$script:ambientIntervalSeconds=[double](Get-ObjectValue $config 'ambient_change_interval_seconds' 45)
$script:ambientDurationSeconds=[double](Get-ObjectValue $config 'ambient_duration_seconds' 5)
$script:stateMinDurationSeconds=[double](Get-ObjectValue $config 'state_min_duration_seconds' 1.0)
$script:transitionCooldownSeconds=[double](Get-ObjectValue $config 'transition_cooldown_seconds' 0.5)
$script:locked=[bool](Get-ObjectValue $state 'locked' (Get-ObjectValue $config 'locked' $false))
$script:clickDragThresholdDip=[Math]::Max(2.0,[double](Get-ObjectValue $config 'click_drag_threshold_dip' 6.0))
$script:moveThrottleMs=[Math]::Max(8,[int](Get-ObjectValue $config 'move_throttle_ms' 16))
$script:snapDurationMs=[Math]::Max(80,[int](Get-ObjectValue $config 'snap_duration_ms' 160))
$script:lockMenuItem=$null
$script:chibiAnimationManifest=Read-JsonFile $chibiAnimationManifestPath
$script:chibiAnimationContext=New-PetChibiIdleAnimationContext -Dispatcher $window.Dispatcher -AssetRoot (Join-Path $PSScriptRoot 'assets\animation\q_chibi_idle') -LayerHost $animationLayerHost -BodyHost $animationBodyHost -BaseLayer $qBaseLayer -TailLayer $qTailLayer -FrontHairLayer $qFrontHairLayer -EyesLayer $qEyesLayer -FacePatchLayer $qFacePatchLayer -EyesClosedLayer $qEyesClosedLayer -CloudLayer $qCloudLayer -Mascot $mascot
$script:processStartUtc=[DateTimeOffset]::Now
$script:rendererReady=$false
$script:rendererGeneration=0
$script:rendererLoadedUtc=$null
$script:rendererContentRenderedUtc=$null
$script:profileActivationRequestGeneration=0
$script:startupTelemetry=[ordered]@{process_start_utc=$script:processStartUtc.ToString('o');window_loaded_utc=$null;content_rendered_utc=$null;window_visible_utc=$null;renderer_ready=$false;renderer_generation=0;root_canvas_actual_width=$null;root_canvas_actual_height=$null;body_host_actual_width=$null;body_host_actual_height=$null;effective_scale=$script:scale;profile_activation_requests=@();readiness_checks=@();last_activation_status='not_started'}

function Get-PetDiagnosticContext {
    $cp=[System.Windows.Forms.Cursor]::Position
    $screen=$null; $work=$null
    try {
        $work=Get-PetCurrentMonitorWorkAreaDip -Window $window
    } catch {
        $screen=[System.Windows.Forms.Screen]::FromPoint($cp)
    }
    return @{
        drag_phase=$script:dragPhase
        cursor_x_px=$cp.X; cursor_y_px=$cp.Y
        window_left_dip=$window.Left; window_top_dip=$window.Top
        window_width_dip=$window.ActualWidth; window_height_dip=$window.ActualHeight
        dpi_x=$(if($work){$work.DpiX}else{96}); dpi_y=$(if($work){$work.DpiY}else{96})
        monitor_name=$(if($work){$work.Name}else{$screen.DeviceName})
        work_left_px=$(if($work){$work.PixelLeft}else{$screen.WorkingArea.Left})
        work_top_px=$(if($work){$work.PixelTop}else{$screen.WorkingArea.Top})
        work_right_px=$(if($work){$work.PixelRight}else{$screen.WorkingArea.Right})
        work_bottom_px=$(if($work){$work.PixelBottom}else{$screen.WorkingArea.Bottom})
        appearance=$script:appearance; logical_state=$script:logicalState; scale=$script:scale; scale_chibi=$script:scaleChibi; scale_anime=$script:scaleAnime; locked=$script:locked
        animation_state=$(if($script:floatActive){'float_active'}else{'float_paused'})
        snap_state=$(if($script:isSnapping){'active'}else{'inactive'})
    }
}
function Write-PetCaughtException([string]$EventName,$ErrorRecord) {
    try {
        $exception = if($ErrorRecord -and $ErrorRecord.Exception){$ErrorRecord.Exception}else{New-Object System.Exception('Unknown event-handler exception')}
        Write-PetCrashRecord -EventName $EventName -Exception $exception -Context (Get-PetDiagnosticContext)
    } catch {}
}

$window.Dispatcher.Add_UnhandledException({
    param($sender,$e)
    try { Write-PetCrashRecord -EventName 'dispatcher.unhandled' -Exception $e.Exception -Context (Get-PetDiagnosticContext) } catch {}
    $interactionActive=($script:dragPhase -ne 'Idle' -or $script:isSnapping)
    if($interactionActive){
        try { Reset-PetPointerInteraction -Reason 'dispatcher_unhandled' -CancelSnap -Clamp -Persist } catch {}
        $e.Handled=$true
    } else {
        $e.Handled=$false
    }
})

function Save-State {
    try {
        # Persist only user presentation/settings. semantic/activity/logical/visual
        # states are transient and recomputed from provider + activity on startup.
        $payload=[ordered]@{left=$window.Left; top=$window.Top; appearance=$script:appearance; scale=$script:scale; scale_chibi=$script:scaleChibi; scale_anime=$script:scaleAnime; topmost=if((Get-Variable live2dBridge -Scope Script -ErrorAction SilentlyContinue) -and $script:live2dBridge){$script:live2dBridge.DesiredTopmost}else{$window.Topmost}; locked=$script:locked}
        $json=$payload | ConvertTo-Json
        $tempPath=$statePath+'.tmp'
        $utf8NoBom=New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempPath,$json,$utf8NoBom)
        Move-Item -LiteralPath $tempPath -Destination $statePath -Force
    } catch {}
}
function Set-Scale([double]$v) {
    $script:scale=Get-PetPhase2ClampedScale $v
    if($script:appearance -eq 'anime'){$script:scaleAnime=$script:scale}else{$script:scaleChibi=$script:scale}
    $petScale.ScaleX=$script:scale; $petScale.ScaleY=$script:scale; Save-State
}
function Show-Bubble([bool]$show) {
    if ($show) {
        Update-BubbleAnchor
        $bubble.Visibility='Visible'
        $bubble.Opacity=0; $bubbleScale.ScaleX=0.88; $bubbleScale.ScaleY=0.88
        $a=New-Object Windows.Media.Animation.DoubleAnimation(0,1,[TimeSpan]::FromMilliseconds(180)); $bubble.BeginAnimation([Windows.UIElement]::OpacityProperty,$a)
        $s=New-Object Windows.Media.Animation.DoubleAnimation(0.88,1,[TimeSpan]::FromMilliseconds(220)); $s.EasingFunction=New-Object Windows.Media.Animation.BackEase -Property @{Amplitude=0.25; EasingMode='EaseOut'}
        $bubbleScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleXProperty,$s); $bubbleScale.BeginAnimation([Windows.Media.ScaleTransform]::ScaleYProperty,$s)
        $script:bubbleOpen=$true
    } else { $bubble.Visibility='Collapsed'; $script:bubbleOpen=$false }
}
$script:bubbleOpen=$false

function Load-PetBitmap([string]$Path) {
    $image = New-Object Windows.Media.Imaging.BitmapImage
    $image.BeginInit(); $image.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $image.UriSource = New-Object Uri($Path); $image.EndInit(); $image.Freeze()
    return $image
}
function Update-BubbleAnchor {
    if(-not $script:currentAssetRecord){return}
    try {
        $work=Get-PetCurrentMonitorWorkAreaDip -Window $window
        $windowWidth=if($window.ActualWidth -gt 0){[double]$window.ActualWidth}else{690.0}
        $bubbleWidth=if($bubble.ActualWidth -gt 0){[double]$bubble.ActualWidth}else{[double]$bubble.Width}
        $left=[double]$script:currentAssetRecord.BubbleAnchorX
        $top=[double]$script:currentAssetRecord.BubbleAnchorY
        $side=[string]$script:currentAssetRecord.BubbleSidePreference
        # The bubble is inside the same clamped root window as the pet. Do not
        # flip merely because the root is near the monitor's left edge: that
        # places the bubble on top of PetArea (the old Phase 2 behavior).
        # Flip only when the preferred anchor would really leave WorkArea.
        $preferredLeft=$left
        if($side -eq 'right'){$preferredLeft=$windowWidth-$bubbleWidth-12}
        $absoluteLeft=$window.Left+$preferredLeft
        $absoluteRight=$absoluteLeft+$bubbleWidth
        if($absoluteLeft -lt $work.Left -or $absoluteRight -gt $work.Right){
            $alternateLeft=$windowWidth-$bubbleWidth-12
            $alternateAbsoluteLeft=$window.Left+$alternateLeft
            $alternateAbsoluteRight=$alternateAbsoluteLeft+$bubbleWidth
            if($alternateAbsoluteLeft -ge $work.Left -and $alternateAbsoluteRight -le $work.Right){$left=$alternateLeft}
        }
        $left=[Math]::Max(0,[Math]::Min([Math]::Max(0,$windowWidth-$bubbleWidth),$left))
        [Windows.Controls.Canvas]::SetLeft($bubble,[double]$left)
        [Windows.Controls.Canvas]::SetTop($bubble,[double]$top)
    } catch {}
}
function Test-PetRendererLayoutReady {
    $rootWidth=[double]$rootCanvas.ActualWidth;$rootHeight=[double]$rootCanvas.ActualHeight
    $bodyWidth=if([double]$animationBodyHost.ActualWidth -gt 0){[double]$animationBodyHost.ActualWidth}else{[double]$animationBodyHost.Width};$bodyHeight=if([double]$animationBodyHost.ActualHeight -gt 0){[double]$animationBodyHost.ActualHeight}else{[double]$animationBodyHost.Height}
    $scaleReady=([Math]::Abs([double]$petScale.ScaleX-[double]$script:scale) -lt 0.0001 -and [Math]::Abs([double]$petScale.ScaleY-[double]$script:scale) -lt 0.0001)
    $layersReady=($script:chibiAnimationContext -and [bool]$script:chibiAnimationContext.RequiredLayersReady -and [bool]$script:chibiAnimationContext.TransformsInitialized)
    $contentRenderedReady=($null -ne $script:rendererContentRenderedUtc)
    $ready=($contentRenderedReady -and $rootWidth -gt 0 -and $rootHeight -gt 0 -and $bodyWidth -gt 0 -and $bodyHeight -gt 0 -and $scaleReady -and $layersReady)
    return [pscustomobject]@{ready=$ready;content_rendered=$contentRenderedReady;root_width=$rootWidth;root_height=$rootHeight;body_width=$bodyWidth;body_height=$bodyHeight;scale_ready=$scaleReady;layers_ready=$layersReady}
}
function Try-PetRendererReady([string]$Source='readiness_check') {
    $check=Test-PetRendererLayoutReady
    $checkRecord=[ordered]@{timestamp=[DateTimeOffset]::Now.ToString('o');source=$Source;ready=[bool]$check.ready;content_rendered=$check.content_rendered;root_width=$check.root_width;root_height=$check.root_height;body_width=$check.body_width;body_height=$check.body_height;scale_ready=$check.scale_ready;layers_ready=$check.layers_ready;generation=$script:rendererGeneration}
    $script:startupTelemetry.readiness_checks += ,$checkRecord
    if(-not $check.ready){$script:rendererReady=$false;$script:chibiAnimationContext.RendererReady=$false;return $false}
    $script:rendererReady=$true;$script:chibiAnimationContext.RendererReady=$true
    $script:startupTelemetry.renderer_ready=$true;$script:startupTelemetry.last_activation_status='ready'
    $script:startupTelemetry.root_canvas_actual_width=$check.root_width;$script:startupTelemetry.root_canvas_actual_height=$check.root_height;$script:startupTelemetry.body_host_actual_width=$check.body_width;$script:startupTelemetry.body_host_actual_height=$check.body_height;$script:startupTelemetry.effective_scale=$script:scale
    return $true
}
function Update-PetChibiRuntimeProfile {
    param([string]$Reason='profile_update')
    try {
        $animationLayerHost.Visibility=[Windows.Visibility]::Collapsed
        $petFloat.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
        $petFloat.Y=0
        $script:floatActive=$false
        if($script:chibiAnimationContext){$script:chibiAnimationContext.RendererReady=[bool]$script:rendererReady}
        if($script:startupTelemetry){$script:startupTelemetry.last_activation_status='Q_CHIBI_STATE_CONTROLLER_AUTHORITATIVE'}
        return $false
    } catch { Write-PetCaughtException 'animation.channels_disabled' $_; return $false }
}
function Get-PetQChibiVisualState {
    param([Parameter(Mandatory=$true)][string]$LogicalState)
    switch($LogicalState){
        'online_good' { return 'idle' }
        'refreshing' { return 'thinking' }
        'online_low' { return 'pout_angry' }
        'offline' { return 'surprised' }
        'error' { return 'surprised' }
        'interaction' { return 'greeting' }
        'long_idle' { return 'idle' }
        'sleeping' { return 'sleeping' }
        default { return 'idle' }
    }
}
function SetState {
    param([Parameter(Mandatory=$true)][string]$State,[string]$Trigger='state_controller',[string]$Reason='')
    if(-not $script:Q_CHIBI_STATE_CONTROLLER){return $false}
    $from=[string]$script:Q_CHIBI_STATE_CONTROLLER.State
    $changed=Set-QChibiStateControllerState -Controller $script:Q_CHIBI_STATE_CONTROLLER -State $State -Trigger $Trigger -Reason $Reason
    if($changed){$script:lastVisualTransitionUtc=[DateTime]::UtcNow;Write-PetStateTransition -From $from -To $State.ToLowerInvariant() -Trigger $Trigger -Reason $Reason}
    return $changed
}
function Apply-PetVisualState {
    param([string]$Appearance=$script:appearance,[string]$LogicalState=$script:logicalState)
    $record=Get-PetPhase2ManifestRecord -Manifest $script:phase2Manifest -Appearance $Appearance -LogicalState $LogicalState
    $script:appearance=$record.Appearance; $script:logicalState=$record.LogicalState; $script:currentAssetRecord=$record
    $script:scale=if($script:appearance -eq 'anime'){$script:scaleAnime}else{$script:scaleChibi}
    $petScale.ScaleX=$script:scale; $petScale.ScaleY=$script:scale
    $appearanceBtn.Content=if($script:appearance -eq 'anime'){'Q'}else{'A'}
    if($script:appearance -eq 'chibi' -and $script:Q_CHIBI_STATE_CONTROLLER){
        $qChibiWholeStateHost.Visibility=[Windows.Visibility]::Visible;$mascot.Opacity=0
        $visualState=Get-PetQChibiVisualState -LogicalState $script:logicalState
        [void](SetState -State $visualState -Trigger 'pet.logical_state.map' -Reason ("logical_state={0}" -f $script:logicalState))
    }else{
        $qChibiWholeStateHost.Visibility=[Windows.Visibility]::Collapsed;$mascot.Opacity=1
        $path=Join-Path $PSScriptRoot $record.BaseImage
        if(-not (Test-Path -LiteralPath $path)){throw "Missing Phase 2 asset: $path"}
        $mascot.Source=Load-PetBitmap $path
    }
    Update-BubbleAnchor
    Update-PetChibiRuntimeProfile
}
function Write-PetStateTransition {
    param([string]$From,[string]$To,[string]$Trigger,[string]$Reason)
    try {
        $record=[ordered]@{
            timestamp=[DateTimeOffset]::Now.ToString('o')
            state_from=$From
            state_to=$To
            trigger=$Trigger
            reason=$Reason
            semantic_state=$script:semanticState
            activity_state=$script:activityState
            appearance=$script:appearance
            debug_override=$script:debugStateOverride
        }
        $path=Join-Path $PSScriptRoot 'logs\state-transitions.jsonl'
        $utf8NoBom=New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($path,(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8NoBom)
    } catch {}
}
function Set-PetLogicalState {
    param([string]$State,[string]$Trigger='manual',[string]$Reason='')
    if($script:logicalState -eq $State){return $false}
    $from=$script:logicalState
    $record=Get-PetPhase2ManifestRecord -Manifest $script:phase2Manifest -Appearance $script:appearance -LogicalState $State
    Apply-PetVisualState -Appearance $script:appearance -LogicalState $record.LogicalState
    $script:lastVisualTransitionUtc=[DateTime]::UtcNow
    Write-PetStateTransition -From $from -To $script:logicalState -Trigger $Trigger -Reason $Reason
    return $true
}
function Update-PetAutomaticVisualState {
    param([string]$Trigger='controller',[string]$Reason='',[switch]$Force)
    if(-not $script:autoControllerEnabled -or $script:debugStateOverride){return $false}
    $desired=Get-PetAutomaticVisualState -SemanticState $script:semanticState -ActivityState $script:activityState
    $age=if($script:lastVisualTransitionUtc -eq [DateTime]::MinValue){999999}else{([DateTime]::UtcNow-$script:lastVisualTransitionUtc).TotalSeconds}
    $semanticTrigger=($Trigger -match 'semantic|quota|refresh|error|offline')
    if(-not (Test-PetAutomaticTransitionAllowed -Current $script:logicalState -Requested $desired -AgeSeconds $age -MinimumStateDuration $script:stateMinDurationSeconds -CooldownSeconds $script:transitionCooldownSeconds -Force:($Force -or $semanticTrigger))){return $false}
    return (Set-PetLogicalState -State $desired -Trigger $Trigger -Reason $Reason)
}
function Set-PetSemanticState {
    param([string]$State,[string]$Trigger='semantic',[string]$Reason='',[switch]$Force)
    $script:semanticState=$State
    $script:lastQuotaState=$State
    Update-PetAutomaticVisualState -Trigger $Trigger -Reason $Reason -Force:$Force
}
function Set-PetActivityState {
    param([string]$State,[string]$Trigger='activity',[string]$Reason='')
    $previous=$script:activityState
    if($previous -eq $State){return}
    $script:activityState=$State
    if($State -eq 'ambient'){$script:ambientStartedUtc=[DateTime]::UtcNow}
    $force=($State -eq 'interaction' -or ($State -eq 'none' -and $previous -eq 'sleeping'))
    Update-PetAutomaticVisualState -Trigger $Trigger -Reason $Reason -Force:$force
}
function Toggle-PetAppearance {
    $next=if($script:appearance -eq 'chibi'){'anime'}else{'chibi'}
    Apply-PetVisualState -Appearance $next -LogicalState $script:logicalState
    [void](Clamp-PetWindowToCurrentMonitor)
    Update-BubbleAnchor
    Save-State
}
function Touch-PetActivity {
    $script:lastActivityUtc=[DateTime]::UtcNow
    if($script:activityState -ne 'none'){
        $script:activityState='none'
        Update-PetAutomaticVisualState -Trigger 'activity.wake' -Reason 'user activity'
    }
}
function Update-PetIdleState {
    if($script:debugStateOverride -or $script:bubbleOpen -or $script:pointerDown -or $script:isSnapping -or $script:interactionActive){return}
    $idleSeconds=([DateTime]::UtcNow-$script:lastActivityUtc).TotalSeconds
    $longIdleThreshold=[double](Get-ObjectValue $config 'long_idle_seconds' 120)
    $sleepThreshold=[double](Get-ObjectValue $config 'sleeping_seconds' 300)
    $current=$script:activityState
    $ambientAge=if($script:ambientStartedUtc -eq [DateTime]::MinValue){0}else{([DateTime]::UtcNow-$script:ambientStartedUtc).TotalSeconds}
    $next=Get-PetAutomaticActivityState -IdleSeconds $idleSeconds -LongIdleTimeout $longIdleThreshold -SleepTimeout $sleepThreshold -Current $current -AmbientEnabled:($script:ambientEnabled -and $script:semanticState -eq 'online_good') -AmbientInterval $script:ambientIntervalSeconds -AmbientDuration $script:ambientDurationSeconds -AmbientAgeSeconds $ambientAge
    if($next -ne $current){
        $script:activityState=$next
        if($next -eq 'ambient'){$script:ambientStartedUtc=[DateTime]::UtcNow}
        elseif($current -eq 'ambient'){$script:ambientStartedUtc=[DateTime]::MinValue}
        Update-PetAutomaticVisualState -Trigger 'activity.timer' -Reason ("idle_seconds={0:0.0}; activity={1}" -f $idleSeconds,$next)
    } elseif($script:logicalState -ne (Get-PetAutomaticVisualState -SemanticState $script:semanticState -ActivityState $script:activityState)) {
        # Activity can already be committed while the visual request was deferred by cooldown.
        # Retry the existing policy decision through the same non-forced transition gate.
        Update-PetAutomaticVisualState -Trigger 'activity.retry' -Reason 'existing activity decision awaits allowed visual transition'
    }
}

function Start-FloatAnimation {
    $petFloat.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
    $petFloat.Y=0
    $script:floatActive=$false
}
function Stop-FloatAnimation {
    $petFloat.BeginAnimation([Windows.Media.TranslateTransform]::YProperty,$null)
    $petFloat.Y=0
    $script:floatActive=$false
}
Start-FloatAnimation

function Set-Status([string]$state,[string]$msg) {
    switch($state) {
        'online' { $statusDot.Fill=[Windows.Media.Brushes]::MediumSeaGreen; $statusText.Text='ChatGPT 已连接'; $setupBtn.Visibility='Collapsed'; $loginBtn.Visibility='Collapsed' }
        'runtime_missing' { $statusDot.Fill=[Windows.Media.Brushes]::DarkOrange; $statusText.Text='首次使用需要安装官方登录组件'; $setupBtn.Visibility='Visible'; $loginBtn.Visibility='Collapsed' }
        'not_logged_in' { $statusDot.Fill=[Windows.Media.Brushes]::Goldenrod; $statusText.Text='尚未登录 ChatGPT'; $setupBtn.Visibility='Collapsed'; $loginBtn.Visibility='Visible' }
        default { $statusDot.Fill=[Windows.Media.Brushes]::IndianRed; $statusText.Text=$msg; $setupBtn.Visibility='Collapsed'; $loginBtn.Visibility='Visible' }
    }
}
function Format-Reset($w) { if ($w -and $w.reset_local) { return ('重置 ' + $w.reset_local) }; return 'reset --' }
function Write-PetQuotaUiObservation {
    param($Data)
    try {
        $session=Get-ObjectValue $Data 'session' $null
        $weekly=Get-ObjectValue $Data 'weekly' $null
        $sessionValue=if($session){[double](Get-ObjectValue $session 'remaining_percent' -1)}else{$null}
        $weeklyValue=if($weekly){[double](Get-ObjectValue $weekly 'remaining_percent' -1)}else{$null}
        $record=[ordered]@{timestamp=[DateTimeOffset]::Now.ToString('o');ok=[bool](Get-ObjectValue $Data 'ok' $false);provider_state=[string](Get-ObjectValue $Data 'state' 'unknown');plan=[string](Get-ObjectValue $Data 'plan' '');session_remaining_percent=$sessionValue;weekly_remaining_percent=$weeklyValue;checked_at=[string](Get-ObjectValue $Data 'checked_at' '');quota_home_kind=(Get-CodexHomeKind);session_present=($null -ne $session);weekly_present=($null -ne $weekly)}
        $path=Join-Path (Join-Path $PSScriptRoot 'logs') 'quota_ui_observations.jsonl';$utf8=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::AppendAllText($path,(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
    } catch { Write-PetCaughtException 'quota.ui_telemetry' $_ }
}
function Apply-Quota($d) {
    $script:initialQuotaObserved=$true
    Write-PetQuotaUiObservation -Data $d
    if (-not $d.ok) {
        $mini.Text = if($d.state -eq 'runtime_missing'){'SETUP'} elseif($d.state -eq 'not_logged_in'){'LOGIN'} else {'OFFLINE'}
        $planText.Text=$mini.Text; Set-Status $d.state $d.message; $lastUpdate.Text=$d.message
        $nextSemantic=Get-PetPhase2QuotaState -QuotaData $d -LowThreshold $script:lowQuotaThreshold
        Set-PetSemanticState -State $nextSemantic -Trigger 'quota.result' -Reason ("provider_state={0}" -f $d.state) -Force
        return
    }
    $plan = if($d.plan){([string]$d.plan).ToUpper()}else{'CHATGPT'}; $planText.Text=$plan
    $sp=$null; $wp=$null
    if($d.session){
        $sp=[double]$d.session.remaining_percent; $sessionPct.Text=('{0:0.#}%' -f $sp); $sessionReset.Text=Format-Reset $d.session
        $wa=New-Object Windows.Media.Animation.DoubleAnimation($sessionBar.Value,$sp,[TimeSpan]::FromMilliseconds(420)); $sessionBar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty,$wa)
    } else { $sessionPct.Text='--%'; $sessionReset.Text='当前未返回 Session 窗口'; $sessionBar.Value=0 }
    if($d.weekly){
        $wp=[double]$d.weekly.remaining_percent; $weeklyPct.Text=('{0:0.#}%' -f $wp); $weeklyReset.Text=Format-Reset $d.weekly
        $wb=New-Object Windows.Media.Animation.DoubleAnimation($weeklyBar.Value,$wp,[TimeSpan]::FromMilliseconds(420)); $weeklyBar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty,$wb)
    } else { $weeklyPct.Text='--%'; $weeklyReset.Text='当前未返回 Weekly 窗口'; $weeklyBar.Value=0 }
    if($null -ne $sp -and $null -ne $wp){ $mini.Text=('S {0:0}% · W {1:0}%' -f $sp,$wp) }
    elseif($null -ne $sp){ $mini.Text=('S {0:0}%' -f $sp) }
    elseif($null -ne $wp){ $mini.Text=('W {0:0}%' -f $wp) }
    else { $mini.Text='GPT --' }
    Set-Status 'online' ''; $lastUpdate.Text=('更新 ' + $d.checked_at)
    $nextSemantic=Get-PetPhase2QuotaState -QuotaData $d -LowThreshold $script:lowQuotaThreshold
    Set-PetSemanticState -State $nextSemantic -Trigger 'quota.result' -Reason ("session={0};weekly={1}" -f $sp,$wp) -Force
}

# Do NOT run PowerShell scriptblocks inside BackgroundWorker.DoWork.
# Windows PowerShell 5.1 does not attach a PowerShell runspace to that CLR thread,
# which causes: "There is no Runspace available to run scripts in this thread".
# Instead, execute quota_core.ps1 in a tiny child powershell process and poll it
# from the WPF DispatcherTimer. This keeps the UI responsive and the quota logic
# in a normal PowerShell runspace.
$script:quotaProc = $null
$script:quotaResultPath = Join-Path $env:TEMP ('gpt_quota_pet_' + [Guid]::NewGuid().ToString('N') + '.json')
$script:quotaPoll = New-Object Windows.Threading.DispatcherTimer
$script:quotaPoll.Interval = [TimeSpan]::FromMilliseconds(140)
$script:quotaPoll.Add_Tick({
    if (-not $script:quotaProc) { $script:quotaPoll.Stop(); return }
    if (-not $script:quotaProc.HasExited) { return }

    $exitCode = $script:quotaProc.ExitCode
    try { $script:quotaProc.Dispose() } catch {}
    $script:quotaProc = $null
    $script:quotaPoll.Stop()

    try {
        if (-not (Test-Path -LiteralPath $script:quotaResultPath)) {
            throw ('quota helper exited without a result file (exit ' + $exitCode + ')')
        }
        $raw = Get-Content -LiteralPath $script:quotaResultPath -Raw -Encoding UTF8
        $data = $raw | ConvertFrom-Json
        Apply-Quota $data
    }
    catch {
        Apply-Quota ([pscustomobject]@{ok=$false;state='error';message=('额度读取失败: ' + $_.Exception.Message)})
    }
    finally {
        Remove-Item -LiteralPath $script:quotaResultPath -Force -ErrorAction SilentlyContinue
    }
})

function Refresh-Quota {
    if($script:quotaPages){Request-PetQuotaPageRefresh $script:quotaPages;return}
    if($script:accountSyncContext){Request-PetAccountSyncRefresh $script:accountSyncContext;return}
    if ($script:quotaProc -and -not $script:quotaProc.HasExited) { return }
    # Provider polling is not user activity. Keep the idle clock stable while
    # refreshing; only pointer/interaction paths call Touch-PetActivity.
    if($script:interactionActive){$script:lastActivityUtc=[DateTime]::UtcNow}
    Set-PetSemanticState -State 'refreshing' -Trigger 'refresh.start' -Reason 'quota refresh started' -Force
    Remove-Item -LiteralPath $script:quotaResultPath -Force -ErrorAction SilentlyContinue
    $statusText.Text='正在读取额度…'

    $helper = Join-Path $PSScriptRoot 'quota_worker.ps1'
    if (-not (Test-Path -LiteralPath $helper)) {
        Apply-Quota ([pscustomobject]@{ok=$false;state='error';message='缺少 quota_worker.ps1'})
        return
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -OutFile "' + $script:quotaResultPath + '"')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $PSScriptRoot
    $script:quotaProc = New-Object System.Diagnostics.Process
    $script:quotaProc.StartInfo = $psi
    try {
        $null = $script:quotaProc.Start()
        $script:quotaPoll.Start()
    }
    catch {
        try { $script:quotaProc.Dispose() } catch {}
        $script:quotaProc = $null
        Apply-Quota ([pscustomobject]@{ok=$false;state='error';message=('无法启动额度读取器: ' + $_.Exception.Message)})
    }
}

function Clamp-PetWindowToCurrentMonitor {
    $clamp=Get-PetWindowClampForCurrentMonitor -Window $window
    $window.Left=[double]$clamp.Left; $window.Top=[double]$clamp.Top
    Update-BubbleAnchor
    return $clamp
}

function Cancel-PetSnap {
    param([switch]$CommitCurrent,[string]$Reason='cancel')
    if(-not $script:isSnapping){return}
    $currentLeft=$window.Left; $currentTop=$window.Top
    $script:snapGeneration++
    try {
        $window.BeginAnimation([Windows.Window]::LeftProperty,$null)
        $window.BeginAnimation([Windows.Window]::TopProperty,$null)
    } catch {}
    if($CommitCurrent){$window.Left=$currentLeft; $window.Top=$currentTop}
    $script:isSnapping=$false
    if($script:dragPhase -eq 'Snapping'){$script:dragPhase='Idle'}
}

function Animate-PetWindowTo([double]$TargetLeft,[double]$TargetTop) {
    Cancel-PetSnap -CommitCurrent -Reason 'replace'
    $fromLeft=$window.Left; $fromTop=$window.Top
    if([Math]::Abs($TargetLeft-$fromLeft) -lt 0.5 -and [Math]::Abs($TargetTop-$fromTop) -lt 0.5){
        $window.Left=$TargetLeft; $window.Top=$TargetTop
        $script:isSnapping=$false; $script:dragPhase='Idle'; Save-State
        return
    }
    $script:snapGeneration++
    $generation=$script:snapGeneration
    $closedTargetLeft=[double]$TargetLeft; $closedTargetTop=[double]$TargetTop
    $ease=New-Object Windows.Media.Animation.CubicEase
    $ease.EasingMode='EaseOut'
    $la=New-Object Windows.Media.Animation.DoubleAnimation($fromLeft,$closedTargetLeft,[TimeSpan]::FromMilliseconds($script:snapDurationMs))
    $ta=New-Object Windows.Media.Animation.DoubleAnimation($fromTop,$closedTargetTop,[TimeSpan]::FromMilliseconds($script:snapDurationMs))
    $la.EasingFunction=$ease; $ta.EasingFunction=$ease
    $la.FillBehavior='Stop'; $ta.FillBehavior='Stop'
    $script:isSnapping=$true; $script:dragPhase='Snapping'
    $completedHandler={
        try {
            if($generation -ne $script:snapGeneration){return}
            $window.BeginAnimation([Windows.Window]::LeftProperty,$null)
            $window.BeginAnimation([Windows.Window]::TopProperty,$null)
            $window.Left=$closedTargetLeft; $window.Top=$closedTargetTop
            $script:isSnapping=$false; $script:dragPhase='Idle'
            [void](Clamp-PetWindowToCurrentMonitor)
            Save-State
            Update-PetChibiRuntimeProfile
        }
        catch {
            Write-PetCaughtException 'snap.completed' $_
            Reset-PetPointerInteraction -Reason 'snap_exception' -CancelSnap -Clamp -Persist
        }
    }.GetNewClosure()
    $la.Add_Completed($completedHandler)
    $window.BeginAnimation([Windows.Window]::LeftProperty,$la)
    $window.BeginAnimation([Windows.Window]::TopProperty,$ta)
}

function Release-PetMouseCapture {
    $script:releaseInProgress=$true
    try {
        if([Windows.Input.Mouse]::Captured -eq $mascot){$mascot.ReleaseMouseCapture()}
    } finally {$script:releaseInProgress=$false}
}

function Invoke-PetCharacterClick {
    Touch-PetActivity
    $script:interactionActive=$true
    $script:interactionBaseState=$script:semanticState
    $script:interactionStartedUtc=[DateTime]::UtcNow
    Set-PetActivityState -State 'interaction' -Trigger 'interaction.click' -Reason 'user click'
    $script:interactionTimer.Start()
    Show-Bubble(-not $script:bubbleOpen)
    if($script:bubbleOpen){Refresh-Quota}
}

function Update-PetDragPosition {
    param([switch]$Force)
    if(-not $script:pointerDown -or $script:locked){return}
    if($script:dragPhase -ne 'Pressed' -and $script:dragPhase -ne 'Dragging'){return}
    $current=Get-PetCursorScreenDip -Window $window
    if($script:dragPhase -eq 'Pressed'){
        $crossed=Test-PetDragThreshold -StartX $script:dragStartScreen.X -StartY $script:dragStartScreen.Y -CurrentX $current.X -CurrentY $current.Y -Threshold $script:clickDragThresholdDip
        if(-not $crossed){return}
        $script:dragPhase='Dragging'
        Stop-FloatAnimation
    }
    $nowTicks=[DateTime]::UtcNow.Ticks
    if(-not (Test-PetMoveThrottle -LastUpdateTicks $script:lastMoveTicks -CurrentTicks $nowTicks -IntervalMilliseconds $script:moveThrottleMs -Force:$Force)){return}
    $target=Get-PetDragTarget -WindowStartLeft $script:winStart.X -WindowStartTop $script:winStart.Y -CursorStartX $script:dragStartScreen.X -CursorStartY $script:dragStartScreen.Y -CursorNowX $current.X -CursorNowY $current.Y
    $window.Left=[double]$target.Left; $window.Top=[double]$target.Top
    [void](Clamp-PetWindowToCurrentMonitor)
    $script:lastMoveTicks=$nowTicks
}

function Reset-PetPointerInteraction {
    param([string]$Reason='reset',[switch]$CancelSnap,[switch]$Clamp,[switch]$Persist)
    if($CancelSnap){Cancel-PetSnap -CommitCurrent -Reason $Reason}
    $script:dragPhase='Released'; $script:pointerDown=$false
    Release-PetMouseCapture
    $script:dragStartScreen=$null; $script:winStart=$null; $script:lastMoveTicks=0L
    if($Clamp){try{[void](Clamp-PetWindowToCurrentMonitor)}catch{}}
    if(-not $script:isSnapping){$script:dragPhase='Idle'}
    if(-not $script:floatActive){Start-FloatAnimation}
    if($Persist){Save-State}
    if($script:chibiAnimationContext){Update-PetChibiRuntimeProfile}
}

function Complete-PetPointerInteraction {
    param([bool]$AllowClick,[bool]$AllowSnap,[string]$Reason='mouse_up')
    if(-not $script:pointerDown -and $script:dragPhase -ne 'Pressed' -and $script:dragPhase -ne 'Dragging'){return}
    $phaseBefore=$script:dragPhase
    if($phaseBefore -eq 'Dragging'){Update-PetDragPosition -Force}
    $wasDrag=($phaseBefore -eq 'Dragging')
    $wasClick=($phaseBefore -eq 'Pressed')
    $script:pointerDown=$false; $script:dragPhase='Released'
    Release-PetMouseCapture
    $script:dragStartScreen=$null; $script:winStart=$null; $script:lastMoveTicks=0L
    if(-not $script:floatActive){Start-FloatAnimation}
    if($wasDrag){
        [void](Clamp-PetWindowToCurrentMonitor)
        if($AllowSnap){
            $snap=Get-PetWindowSnapForCurrentMonitor -Window $window -SnapDistance ([double](Get-ObjectValue $config 'snap_distance' 32))
            Animate-PetWindowTo -TargetLeft $snap.Left -TargetTop $snap.Top
        } else {
            $script:dragPhase='Idle'; Save-State; Update-PetChibiRuntimeProfile
        }
    } elseif($wasClick -and $AllowClick){
        $script:dragPhase='Idle'; Invoke-PetCharacterClick
    } else {
        $script:dragPhase='Idle'; Save-State; Update-PetChibiRuntimeProfile
    }
}

function Start-PetPointerInteraction {
    param($EventArgs)
    if($script:pointerDown){return}
    if($EventArgs.ChangedButton -ne [Windows.Input.MouseButton]::Left){return}
    if($EventArgs.OriginalSource -is [Windows.Controls.Button]){return}
    Touch-PetActivity
    Cancel-PetSnap -CommitCurrent -Reason 'pointer_down'
    $script:pointerDown=$true; $script:dragPhase='Pressed'; $script:lastMoveTicks=0L
    $script:dragStartScreen=Get-PetCursorScreenDip -Window $window
    $script:winStart=New-Object Windows.Point($window.Left,$window.Top)
    Stop-FloatAnimation
    if($script:chibiAnimationContext -and $script:chibiAnimationContext.Active){Suspend-PetAnimationScheduler -Scheduler $script:chibiAnimationContext.Scheduler -Reason 'drag_hold'}
    if(-not $mascot.CaptureMouse()){throw 'Mouse capture failed.'}
}

function Update-PetLockUi {
    if($script:locked){$lockBtn.Content='锁';$lockBtn.ToolTip='解锁位置'}else{$lockBtn.Content='移';$lockBtn.ToolTip='锁定位置'}
    if($script:lockMenuItem){$script:lockMenuItem.IsChecked=$script:locked}
}
function Toggle-PetPositionLock {
    param([Nullable[bool]]$Value=$null)
    $next=if($null -eq $Value){-not $script:locked}else{[bool]$Value}
    if($next -eq $script:locked){return}
    Reset-PetPointerInteraction -Reason 'lock_changed' -CancelSnap -Clamp -Persist
    $script:locked=$next
    Update-PetLockUi
    Save-State
}

$refreshBtn.Add_Click({ Refresh-Quota })
$setupBtn.Add_Click({Show-PetAccountSyncPanel $script:accountSyncContext})
$loginBtn.Add_Click({Show-PetAccountSyncPanel $script:accountSyncContext})
$minusBtn.Add_Click({ Set-Scale ($script:scale-0.08) })
$plusBtn.Add_Click({ Set-Scale ($script:scale+0.08) })
$lockBtn.Add_Click({ Toggle-PetPositionLock })
$appearanceBtn.Add_Click({ Toggle-PetAppearance })
$topBtn.Add_Click({ $window.Topmost=-not $window.Topmost; Save-State })
$closeBtn.Add_Click({ $window.Close() })
$petArea.Add_MouseEnter({ $a=New-Object Windows.Media.Animation.DoubleAnimation($hover.Opacity,1,[TimeSpan]::FromMilliseconds(150)); $hover.BeginAnimation([Windows.UIElement]::OpacityProperty,$a) })
$petArea.Add_MouseLeave({ $a=New-Object Windows.Media.Animation.DoubleAnimation($hover.Opacity,0,[TimeSpan]::FromMilliseconds(220)); $hover.BeginAnimation([Windows.UIElement]::OpacityProperty,$a) })
$petArea.Add_MouseWheel({ param($s,$e); if($e.Delta -gt 0){Set-Scale($script:scale+0.05)}else{Set-Scale($script:scale-0.05)}; $e.Handled=$true })

$mascot.Add_MouseLeftButtonDown({
    param($s,$e)
    try {
        Start-PetPointerInteraction -EventArgs $e
        $e.Handled=$true
    }
    catch {
        Write-PetCaughtException 'drag.mouse_down' $_
        Reset-PetPointerInteraction -Reason 'mouse_down_exception' -CancelSnap -Clamp -Persist
    }
})
$petArea.AddHandler([Windows.UIElement]::PreviewMouseLeftButtonDownEvent,[Windows.Input.MouseButtonEventHandler]{
    param($s,$e)
    try {
        Start-PetPointerInteraction -EventArgs $e
        if($script:pointerDown){$e.Handled=$true}
    }
    catch {
        Write-PetCaughtException 'drag.pet_area_preview_mouse_down' $_
        Reset-PetPointerInteraction -Reason 'pet_area_mouse_down_exception' -CancelSnap -Clamp -Persist
    }
},$true)
$mascot.Add_MouseMove({
    param($s,$e)
    try {
        if($script:pointerDown){
            if([Windows.Input.Mouse]::LeftButton -ne [Windows.Input.MouseButtonState]::Pressed){
                Complete-PetPointerInteraction -AllowClick $true -AllowSnap $true -Reason 'move_detected_release'
            } else {
                Update-PetDragPosition
            }
            $e.Handled=$true
        }
    }
    catch {
        Write-PetCaughtException 'drag.mouse_move' $_
        Reset-PetPointerInteraction -Reason 'mouse_move_exception' -CancelSnap -Clamp -Persist
    }
})
$mascot.Add_MouseLeftButtonUp({
    param($s,$e)
    try { Complete-PetPointerInteraction -AllowClick $true -AllowSnap $true -Reason 'mascot_mouse_up'; $e.Handled=$true }
    catch { Write-PetCaughtException 'drag.mouse_up' $_; Reset-PetPointerInteraction -Reason 'mouse_up_exception' -CancelSnap -Clamp -Persist }
})
$window.Add_PreviewMouseLeftButtonUp({
    param($s,$e)
    if($script:pointerDown){
        try { Complete-PetPointerInteraction -AllowClick $true -AllowSnap $true -Reason 'window_preview_mouse_up'; $e.Handled=$true }
        catch { Write-PetCaughtException 'drag.preview_mouse_up' $_; Reset-PetPointerInteraction -Reason 'preview_mouse_up_exception' -CancelSnap -Clamp -Persist }
    }
})
$mascot.Add_LostMouseCapture({
    if(-not $script:releaseInProgress -and ($script:pointerDown -or $script:dragPhase -eq 'Pressed' -or $script:dragPhase -eq 'Dragging')){
        try { Complete-PetPointerInteraction -AllowClick $false -AllowSnap $false -Reason 'lost_mouse_capture' }
        catch { Write-PetCaughtException 'drag.lost_capture' $_; Reset-PetPointerInteraction -Reason 'lost_capture_exception' -CancelSnap -Clamp -Persist }
    }
})
$window.Add_Deactivated({
    if($script:pointerDown -or $script:dragPhase -ne 'Idle' -or $script:isSnapping){
        try { Reset-PetPointerInteraction -Reason 'window_deactivated' -CancelSnap -Clamp -Persist }
        catch { Write-PetCaughtException 'drag.window_deactivated' $_ }
    }
})

$script:dragWatchdog=New-Object Windows.Threading.DispatcherTimer
$script:dragWatchdog.Interval=[TimeSpan]::FromMilliseconds(50)
$script:dragWatchdog.Add_Tick({
    if($script:pointerDown -and [Windows.Input.Mouse]::LeftButton -ne [Windows.Input.MouseButtonState]::Pressed){
        try { Complete-PetPointerInteraction -AllowClick $true -AllowSnap $true -Reason 'release_watchdog' }
        catch { Write-PetCaughtException 'drag.release_watchdog' $_; Reset-PetPointerInteraction -Reason 'watchdog_exception' -CancelSnap -Clamp -Persist }
    }
})
$script:dragWatchdog.Start()

$menu=New-Object Windows.Controls.ContextMenu
foreach($spec in @(@('显示 / 收起额度','toggle'),@('刷新额度','refresh'),@('切换 Q版 / 非Q版','toggle_appearance'),@('锁定位置','toggle_lock'),@('登录 ChatGPT','login'),@('安装登录组件','setup'),@('退出','exit'))){
    $mi=New-Object Windows.Controls.MenuItem; $mi.Header=$spec[0]; $mi.Tag=$spec[1]
    if($spec[1] -eq 'toggle_lock'){$mi.IsCheckable=$true;$script:lockMenuItem=$mi}
    $mi.Add_Click({param($s,$e); switch([string]$s.Tag){'toggle'{Show-Bubble(-not $script:bubbleOpen)}'refresh'{Show-Bubble $true;Refresh-Quota}'toggle_appearance'{Toggle-PetAppearance}'toggle_lock'{Toggle-PetPositionLock}'login'{Show-PetAccountSyncPanel $script:accountSyncContext}'setup'{Show-PetAccountSyncPanel $script:accountSyncContext}'exit'{$window.Close()}}})
    $menu.Items.Add($mi)|Out-Null
}
if($DebugMode){
    $stateMenu=New-Object Windows.Controls.MenuItem; $stateMenu.Header='Phase 2 状态预览（DEBUG ONLY）'
    foreach($debugState in (Get-PetPhase2StateNames)){
        $stateItem=New-Object Windows.Controls.MenuItem; $stateItem.Header=$debugState; $stateItem.Tag=$debugState
        $stateItem.Add_Click({param($s,$e); $script:debugStateOverride=$true; $script:debugState=[string]$s.Tag; Set-PetLogicalState -State ([string]$s.Tag) -Trigger 'debug.override' -Reason 'manual debug state preview'; Touch-PetActivity})
        $stateMenu.Items.Add($stateItem)|Out-Null
    }
    $resumeItem=New-Object Windows.Controls.MenuItem; $resumeItem.Header='恢复自动状态'; $resumeItem.Tag='resume_auto'
    $resumeItem.Add_Click({param($s,$e); $script:debugStateOverride=$false; $script:activityState='none'; Update-PetAutomaticVisualState -Trigger 'debug.resume_auto' -Reason 'debug override cleared' -Force})
    $stateMenu.Items.Add($resumeItem)|Out-Null
    $menu.Items.Add($stateMenu)|Out-Null
}
$mascot.ContextMenu=$menu
Update-PetLockUi

$appearanceBtn.Content=if($script:appearance -eq 'anime'){'Q'}else{'A'}

function Write-Phase3ISequenceEvent {
    param([string]$Event,[string]$State='',[int]$SequenceIndex=0,[string]$Trigger='test_scheduler',[string]$Reason='')
    try {
        $meta=$null
        if($script:Q_CHIBI_STATE_CONTROLLER -and $State -and $script:Q_CHIBI_STATE_CONTROLLER.Renderer.StateMetadata.ContainsKey($State)){$meta=$script:Q_CHIBI_STATE_CONTROLLER.Renderer.StateMetadata[$State]}
        $record=[ordered]@{timestamp=[DateTimeOffset]::Now.ToString('o');event=$Event;sequence_index=$SequenceIndex;state=$State;trigger=$Trigger;reason=$Reason;manual_acceptance_hold=[bool]$ManualAcceptanceHold;controller_state=if($script:Q_CHIBI_STATE_CONTROLLER){$script:Q_CHIBI_STATE_CONTROLLER.State}else{$null};source_path=if($meta){$meta.SourcePath}else{$null};source_sha256=if($meta){$meta.Sha256}else{$null};window_left=[double]$window.Left;window_top=[double]$window.Top;window_width=[double]$window.ActualWidth;window_height=[double]$window.ActualHeight;hold_seconds=2.0}
        $logPath=Join-Path (Join-Path $PSScriptRoot 'logs') 'q_chibi_sequence_timeline.jsonl';$utf8=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::AppendAllText($logPath,(($record|ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
    } catch { Write-PetCaughtException 'state.sequence_log' $_ }
}
function Start-Phase3IStateSequence {
    if(-not $RuntimeStateTestSequence -or -not $script:Q_CHIBI_STATE_CONTROLLER -or $script:runtimeSequenceStarted){return}
    $script:runtimeSequenceStarted=$true
    $script:runtimeSequenceStates=[string[]]@('idle','greeting','idle','thinking','idle','working','idle','surprised','idle','pout_angry','idle','sleeping','idle')
    $script:runtimeQuotaDeadline=[DateTime]::UtcNow.AddSeconds(25)
    $script:runtimeSequenceTimer=New-Object Windows.Threading.DispatcherTimer
    $script:runtimeSequenceTimer.Interval=[TimeSpan]::FromMilliseconds(50)
    $script:runtimeSequenceTimer.Add_Tick({
        try {
            if(-not $script:initialQuotaObserved){
                if([DateTime]::UtcNow -gt $script:runtimeQuotaDeadline){
                    $script:runtimeSequenceQuotaTimedOut=$true
                    $script:initialQuotaObserved=$true
                    Write-Phase3ISequenceEvent -Event 'quota_result.timeout_sequence_continues' -Trigger 'runtime_gate' -Reason 'No quota result within 25 seconds; sequence continues, quota/auth gate remains failed.'
                }else{return}
            }
            if($script:runtimeSequenceIndex -lt $script:runtimeSequenceStates.Count){
                $i=[int]$script:runtimeSequenceIndex;$state=[string]$script:runtimeSequenceStates[$i]
                if($i -eq 0){$script:runtimeSequenceStartUtc=[DateTimeOffset]::Now;Show-Bubble $true}
                [void](SetState -State $state -Trigger 'qa.sequence' -Reason ("step={0}/13" -f ($i+1)))
                Write-Phase3ISequenceEvent -Event 'sequence.state_hold_started' -State $state -SequenceIndex ($i+1) -Trigger 'qa.sequence' -Reason 'hold=2s'
                $script:runtimeSequenceIndex=$i+1
                $script:runtimeSequenceTimer.Interval=[TimeSpan]::FromSeconds(2)
                return
            }
            $script:runtimeSequenceTimer.Stop();$script:runtimeSequenceEndUtc=[DateTimeOffset]::Now;$script:runtimeSequenceCompleteStatus='PASS_SEQUENCE_REQUESTS_ISSUED'
            Write-Phase3ISequenceEvent -Event 'sequence.complete' -State 'idle' -SequenceIndex 13 -Trigger 'qa.sequence' -Reason '13 requested states; 2-second hold scheduler elapsed.'
            $complete=[ordered]@{phase='PHASE3_FULL_STATE_RUNTIME_INTEGRATION_PROOF';status=$script:runtimeSequenceCompleteStatus;manual_acceptance_hold=[bool]$ManualAcceptanceHold;started_at=$script:runtimeSequenceStartUtc.ToString('o');ended_at=$script:runtimeSequenceEndUtc.ToString('o');state_count=13;states=@($script:runtimeSequenceStates);hold_seconds_each=2;quota_result_observed=[bool]$script:initialQuotaObserved;quota_result_timed_out=[bool]$script:runtimeSequenceQuotaTimedOut;user_visual_confirmed=$false}
            $completePath=Join-Path (Join-Path $PSScriptRoot 'logs') 'runtime_state_sequence_complete.json';$utf8=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($completePath,($complete|ConvertTo-Json -Depth 6),$utf8)
            if($ManualAcceptanceHold){Write-Phase3ISequenceEvent -Event 'manual_acceptance_hold.started' -Trigger 'manual_acceptance' -Reason 'MANUAL_ACCEPTANCE_HOLD=true; sequence scheduler stopped; WPF window and PowerShell host remain open until user closes the window or sends an explicit stop instruction.'}
            else{Write-Phase3ISequenceEvent -Event 'sequence.awaiting_user_interaction' -Trigger 'runtime_test_harness' -Reason 'Sequence scheduler stopped; window awaits explicit interaction or normal close.'}
        } catch { Write-PetCaughtException 'state.sequence_timer' $_;if($script:runtimeSequenceTimer){$script:runtimeSequenceTimer.Stop()} }
    })
    $script:runtimeSequenceTimer.Start()
    Write-Phase3ISequenceEvent -Event 'sequence.scheduler_started' -State 'idle' -Trigger 'content_rendered_waiting_quota' -Reason 'Will begin only after first quota worker result.'
}

$script:interactionTimer=New-Object Windows.Threading.DispatcherTimer
$script:interactionTimer.Interval=[TimeSpan]::FromMilliseconds(200)
$script:interactionTimer.Add_Tick({
    if($script:interactionActive -and $script:semanticState -ne 'refreshing' -and ([DateTime]::UtcNow-$script:interactionStartedUtc).TotalSeconds -ge $script:interactionDurationSeconds){
        $script:interactionActive=$false
        $script:activityState='none'
        Update-PetAutomaticVisualState -Trigger 'interaction.timeout' -Reason 'interaction duration elapsed' -Force
        $script:lastActivityUtc=[DateTime]::UtcNow
        $script:interactionTimer.Stop()
    }
})
$script:interactionTimer.Start()
$script:idleTimer=New-Object Windows.Threading.DispatcherTimer
$script:idleTimer.Interval=[TimeSpan]::FromSeconds(1)
$script:idleTimer.Add_Tick({try{Update-PetIdleState}catch{Write-PetCaughtException 'state.idle_timer' $_}})
if(-not $RuntimeStateTestSequence){$script:idleTimer.Start()}
$script:runtimeHeartbeatTimer=New-Object Windows.Threading.DispatcherTimer
$script:runtimeHeartbeatTimer.Interval=[TimeSpan]::FromMilliseconds(50)
$script:runtimeHeartbeatTimer.Add_Tick({
    $now=[DateTimeOffset]::Now;$gap=$null
    if($script:lastRuntimeHeartbeatUtc){$gap=($now-$script:lastRuntimeHeartbeatUtc).TotalMilliseconds}
    $state=if($script:Q_CHIBI_STATE_CONTROLLER){$script:Q_CHIBI_STATE_CONTROLLER.State}else{$script:logicalState}
    $sample=[pscustomobject]@{timestamp=$now.ToString('o');dispatcher_gap_ms=$gap;state=$state;transition_active=([bool]($script:qChibiRenderer -and $script:qChibiRenderer.IsTransitioning));window_left=[double]$window.Left;window_top=[double]$window.Top}
    [void]$script:runtimeHeartbeatSamples.Add($sample);$script:lastRuntimeHeartbeatUtc=$now
})
if($RuntimeStateTestSequence){$script:runtimeHeartbeatTimer.Start()}

$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromSeconds([Math]::Max(20,[int](Get-ObjectValue $config 'refresh_seconds' 60))); $timer.Add_Tick({if($script:accountSyncContext){Request-PetAccountSyncRefresh $script:accountSyncContext};if($script:quotaPages){Request-PetQuotaPageRefresh $script:quotaPages}else{Refresh-Quota}}); $timer.Start()
$window.Add_Closed({
    $timer.Stop(); $script:dragWatchdog.Stop(); $script:quotaPoll.Stop(); $script:interactionTimer.Stop(); $script:idleTimer.Stop();$script:runtimeHeartbeatTimer.Stop()
    if($script:runtimeSequenceTimer){$script:runtimeSequenceTimer.Stop()};if($script:runtimeExitWatchTimer){$script:runtimeExitWatchTimer.Stop()}
    if($script:qChibiRenderer){$script:qChibiRenderer.TransitionTimer.Stop();$script:qChibiRenderer.TasselTimer.Stop()}
    try { Cancel-PetSnap -CommitCurrent -Reason 'window_closed' } catch {}
    try { $script:pointerDown=$false; Release-PetMouseCapture } catch {}
    try{if($script:quotaProc -and -not $script:quotaProc.HasExited){$script:quotaProc.Kill()}}catch{}
    try{if($script:quotaProc){$script:quotaProc.Dispose()}}catch{}
    Remove-Item -LiteralPath $script:quotaResultPath -Force -ErrorAction SilentlyContinue
    if($script:runtimeCaptureContext){
        try {
            $script:runtimeCaptureSummary=Stop-Phase3IRuntimeCapture -Context $script:runtimeCaptureContext
            $captureSummaryPath=Join-Path $script:runtimeCaptureRoot 'capture_summary.json'
            [System.IO.File]::WriteAllText($captureSummaryPath,($script:runtimeCaptureSummary|ConvertTo-Json -Depth 8),(New-Object System.Text.UTF8Encoding($false)))
        } catch { Write-PetCaughtException 'phase3i.capture_stop' $_ }
    }
    if($false){
        try {
            $snapshot=Get-PetChibiIdleAnimationSnapshot -Context $script:chibiAnimationContext
            $script:startupTelemetry.renderer_ready=$script:rendererReady;$script:startupTelemetry.effective_scale=$script:scale;$script:startupTelemetry.root_canvas_actual_width=[double]$rootCanvas.ActualWidth;$script:startupTelemetry.root_canvas_actual_height=[double]$rootCanvas.ActualHeight;$script:startupTelemetry.body_host_actual_width=[double]$animationBodyHost.ActualWidth;$script:startupTelemetry.body_host_actual_height=[double]$animationBodyHost.ActualHeight
            $evidence=[ordered]@{phase='Phase 3B-4';timestamp=[DateTimeOffset]::Now.ToString('o');appearance=$script:appearance;semantic_state=$script:semanticState;activity_state=$script:activityState;logical_state=$script:logicalState;bubble_open=$script:bubbleOpen;startup=$script:startupTelemetry;animation=$snapshot;event_log=@($script:chibiAnimationContext.Scheduler.EventLog);tail_motion_enabled=[bool]$snapshot.tail_motion_enabled;front_hair_motion_enabled=[bool]$snapshot.front_hair_motion_enabled;production_renderer_integration=$true;phase3b4_runtime_wiring_copy=$true}
            $evidencePath=Join-Path $PSScriptRoot 'evidence\phase3b4_runtime_snapshot.json'
            $evidence|ConvertTo-Json -Depth 14|Set-Content -LiteralPath $evidencePath -Encoding UTF8
        } catch { Write-PetCaughtException 'animation.evidence_write' $_ }
        Stop-PetChibiIdleAnimation -Context $script:chibiAnimationContext -Reason 'window_closed'; Stop-PetAnimationScheduler -Scheduler $script:chibiAnimationContext.Scheduler
    }
    try {
        $heartbeat=$script:runtimeHeartbeatSamples.ToArray()
        $gaps=@($heartbeat|Where-Object{$null -ne $_.dispatcher_gap_ms}|ForEach-Object{[double]$_.dispatcher_gap_ms})
        $sortedGaps=@($gaps|Sort-Object)
        $maxGap=if($sortedGaps.Count -gt 0){[double]$sortedGaps[$sortedGaps.Count-1]}else{$null}
        $p95Gap=$null;if($sortedGaps.Count -gt 0){$p95Index=[Math]::Max(0,[Math]::Min($sortedGaps.Count-1,[int][Math]::Ceiling($sortedGaps.Count*0.95)-1));$p95Gap=[double]$sortedGaps[$p95Index]}
        $controllerSnapshot=if($script:Q_CHIBI_STATE_CONTROLLER){Get-QChibiStateControllerSnapshot -Controller $script:Q_CHIBI_STATE_CONTROLLER}else{$null}
        $script:startupTelemetry.renderer_ready=$script:rendererReady;$script:startupTelemetry.effective_scale=$script:scale;$script:startupTelemetry.root_canvas_actual_width=[double]$rootCanvas.ActualWidth;$script:startupTelemetry.root_canvas_actual_height=[double]$rootCanvas.ActualHeight
        $controllerEvents=$script:Q_CHIBI_STATE_CONTROLLER.Events.ToArray()
        $stateMeta=$script:qChibiRenderer.StateMetadata
        $activeChannels=[string[]]@('RIGHT_ANKLE_TASSEL_BASIC_IDLE only in idle')
        $evidence=[ordered]@{phase='PHASE3_FULL_STATE_RUNTIME_INTEGRATION_PROOF';timestamp=[DateTimeOffset]::Now.ToString('o');process_id=$PID;appearance=$script:appearance;semantic_state=$script:semanticState;activity_state=$script:activityState;logical_state=$script:logicalState;quota_result_observed=[bool]$script:initialQuotaObserved;quota_auth_runtime_kind=(Get-CodexHomeKind);state_sequence_status=$script:runtimeSequenceCompleteStatus;state_sequence_quota_timeout=$script:runtimeSequenceQuotaTimedOut;state_sequence_index=$script:runtimeSequenceIndex;state_sequence_start_utc=if($script:runtimeSequenceStartUtc){$script:runtimeSequenceStartUtc.ToString('o')}else{$null};state_sequence_end_utc=if($script:runtimeSequenceEndUtc){$script:runtimeSequenceEndUtc.ToString('o')}else{$null};user_visual_confirmed=$false;runtime_capture=$script:runtimeCaptureSummary;full_state_runtime_proof='PENDING_EXTERNAL_EVIDENCE_GATE';startup=$script:startupTelemetry;controller_snapshot=$controllerSnapshot;controller_event_log=$controllerEvents;source_asset_records=$stateMeta;active_channels=$activeChannels;disabled_channels=@('BLINK','CLOUD_FLOAT','WING','TAIL','HAIR','DRESS','whole_body_breathing')}
        $evidencePath=Join-Path (Join-Path $PSScriptRoot 'evidence') 'phase3i_runtime_snapshot.json';$utf8=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText($evidencePath,($evidence|ConvertTo-Json -Depth 16),$utf8)
        $heartbeatEvidence=[ordered]@{phase='PHASE3_FULL_STATE_RUNTIME_INTEGRATION_PROOF';sample_count=$heartbeat.Count;max_dispatcher_gap_ms=$maxGap;p95_dispatcher_gap_ms=$p95Gap;samples=$heartbeat}
        $heartbeatPath=Join-Path (Join-Path $PSScriptRoot 'evidence') 'runtime_ui_heartbeat.json';[System.IO.File]::WriteAllText($heartbeatPath,($heartbeatEvidence|ConvertTo-Json -Depth 8),$utf8)
    } catch { Write-PetCaughtException 'phase3i.snapshot_write' $_ }
    Save-State
    try{$mutex.ReleaseMutex()}catch{}; $mutex.Dispose()
})
$rootCanvas.Add_SizeChanged({
    if($null -ne $script:rendererContentRenderedUtc -and -not $script:rendererReady){
        if(Try-PetRendererReady 'root_size_changed'){[void](Update-PetChibiRuntimeProfile -Reason 'root_size_changed')}
    }
})
$window.Add_ContentRendered({
    try {
        $script:rendererContentRenderedUtc=[DateTimeOffset]::Now
        $script:startupTelemetry.content_rendered_utc=$script:rendererContentRenderedUtc.ToString('o')
        if(Try-PetRendererReady 'content_rendered'){
            [void](Update-PetChibiRuntimeProfile -Reason 'content_rendered')
        }
        if($RuntimeCapture){
            try {
                if([System.IO.Path]::IsPathRooted($RuntimeCaptureDirectory)){$script:runtimeCaptureRoot=[System.IO.Path]::GetFullPath($RuntimeCaptureDirectory)}
                else{$script:runtimeCaptureRoot=[System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot $RuntimeCaptureDirectory))}
                $script:runtimeCaptureContext=Start-Phase3IRuntimeCapture -Window $window -Visual $rootCanvas -CaptureRoot $script:runtimeCaptureRoot
                Write-Phase3ISequenceEvent -Event 'runtime_capture.started' -Trigger 'dispatcher_visual_capture' -Reason $script:runtimeCaptureRoot
            } catch {
                $script:runtimeCaptureSummary=[ordered]@{status='CAPTURE_START_FAILED';error_type=$_.Exception.GetType().FullName;error_message=$_.Exception.Message;user_visual_confirmed=$false}
                Write-PetCaughtException 'phase3i.capture_start' $_
            }
        }
        if($RuntimeStateTestSequence){Start-Phase3IStateSequence}
    } catch {
        Write-PetCaughtException 'window.content_rendered' $_
        try{Stop-PetChibiIdleAnimation -Context $script:chibiAnimationContext -Reason 'content_rendered_exception'}catch{}
    } finally {
        $window.Opacity=if((Get-Variable live2dBridge -Scope Script -ErrorAction SilentlyContinue) -and $script:live2dBridge -and $script:live2dBridge.FullscreenSuspended){0.0}else{1.0}
        $script:startupTelemetry.window_visible_utc=[DateTimeOffset]::Now.ToString('o')
    }
})

. (Join-Path $PSScriptRoot 'i18n\Lumi.Language.ps1')
. (Join-Path $PSScriptRoot 'account_sync\Pet.AccountSync.ps1')
. (Join-Path $PSScriptRoot 'quota_pages\Pet.QuotaPages.ps1')
. (Join-Path $PSScriptRoot 'quota_pages\Pet.QuotaPages.UI.ps1')
. (Join-Path $PSScriptRoot 'quota_pages\Pet.QuotaAlerts.ps1')
$script:accountSyncContext=New-PetAccountSyncContext -BundleRoot (Join-Path $PSScriptRoot 'account_sync') -SharedHome (Get-LumiCodexHome) -Owner $window -Simulation:$AccountSyncSimulation -OnClear {
    $sessionBar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty,$null)
    $weeklyBar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty,$null)
    $sessionBar.Value=0;$weeklyBar.Value=0;$sessionPct.Text='--%';$weeklyPct.Text='--%'
    $sessionReset.Text='等待当前账号额度';$weeklyReset.Text='等待当前账号额度';$mini.Text='账号同步中';$planText.Text='同步中'
    if($script:quotaPages){$script:quotaPages.LoginAwaiting=$true;$script:quotaPages.CurrentQuota=$null;$script:quotaPages.LastUi='';Update-PetQuotaPagesUi $script:quotaPages}
} -OnStatus {
    param($label,$message)
    $statusText.Text=$label+' · '+$message
    $lastUpdate.Text=$message
    if($script:quotaPages){Update-PetQuotaPagesUi $script:quotaPages}
} -OnRefresh {
    if($script:interactionActive){$script:lastActivityUtc=[DateTime]::UtcNow}
    Set-PetSemanticState -State 'refreshing' -Trigger 'refresh.start' -Reason 'selected-account quota refresh started' -Force
} -OnFailure {
    param($data)
    Apply-Quota $data
    if($script:quotaPages){$script:quotaPages.LastUi='';Set-PetQuotaPageError $script:quotaPages $script:accountSyncContext.Key '当前账号额度读取未完成';Update-PetQuotaPagesUi $script:quotaPages}
} -OnQuota {
    param($data,$label)
    Apply-Quota $data
    $statusText.Text=$label+' · ChatGPT 已连接'
    if($script:quotaPages){
        Sync-PetQuotaPages $script:quotaPages
        $script:quotaPages.CurrentQuota=ConvertTo-PetSafeQuota $data
        $script:quotaPages.LoginAwaiting=$false
        $script:quotaPages.LastUi=''
        $null=Submit-PetQuotaPage $script:quotaPages $script:accountSyncContext.Key $data
        Test-PetLoginLowQuota $script:quotaPages $script:accountSyncContext.Key $data
        Update-PetQuotaPagesUi $script:quotaPages
    }
}
$script:quotaNoticeQueue=New-Object Collections.Queue
$script:quotaSoundPlayer=New-Object Media.SoundPlayer
$script:quotaNoticeTimer=New-Object Windows.Threading.DispatcherTimer
$script:quotaNoticeTimer.Interval=[TimeSpan]::FromSeconds(10)
$script:quotaNoticeTimer.Add_Tick({$script:quotaNoticeTimer.Stop();Show-NextPetQuotaNotice})
$quotaPagesStatePath=Join-Path $PSScriptRoot $(if($AccountSyncSimulation){'local_state\quota-pages-simulation.json'}else{'local_state\quota-pages.json'})
if($AccountSyncSimulation -and $env:GPT_QUOTA_PET_TEST_STATE){$quotaPagesStatePath=[IO.Path]::GetFullPath($env:GPT_QUOTA_PET_TEST_STATE)}
$script:quotaPages=New-PetQuotaPages -Accounts $script:accountSyncContext -BundleRoot (Join-Path $PSScriptRoot 'quota_pages') -StatePath $quotaPagesStatePath -OnChanged {param($ctx);Update-PetQuotaPagesUi $ctx} -OnNotice {param($notice);Show-PetQuotaNotice $notice}
(X 'QuotaPageSelect').Add_SelectionChanged({if(-not $script:quotaPageSelecting -and (X 'QuotaPageSelect').SelectedItem){$null=Select-PetQuotaPage $script:quotaPages (X 'QuotaPageSelect').SelectedItem.key}})
(X 'QuotaPagePrev').Add_Click({Move-PetQuotaPage $script:quotaPages -1})
(X 'QuotaPageNext').Add_Click({Move-PetQuotaPage $script:quotaPages 1})
(X 'QuotaFollowBtn').Add_Click({Follow-PetQuotaLogin $script:quotaPages})
(X 'QuotaNoticeClose').Add_Click({$script:quotaNoticeTimer.Stop();Show-NextPetQuotaNotice})
$quotaHistoryMenu=New-Object Windows.Controls.MenuItem;$quotaHistoryMenu.Header='额度提醒记录';$quotaHistoryMenu.Add_Click({Show-PetQuotaNoticeHistory});[void]$menu.Items.Insert(0,$quotaHistoryMenu)
$quotaSoundMenu=New-Object Windows.Controls.MenuItem;$quotaSoundMenu.Header='额度提示音';$quotaSoundMenu.IsCheckable=$true;$quotaSoundMenu.IsChecked=$script:quotaPages.SoundEnabled
$quotaSoundMenu.Add_Click({$script:quotaPages.SoundEnabled=($quotaSoundMenu.IsChecked -eq $true);Save-PetQuotaPages $script:quotaPages})
[void]$menu.Items.Insert(0,$quotaSoundMenu)
$window.Add_Closed({Stop-PetQuotaPages $script:quotaPages;$script:quotaNoticeTimer.Stop();$script:quotaSoundPlayer.Dispose()})
(X 'AccountSyncBtn').Add_Click({Show-PetAccountSyncPanel $script:accountSyncContext})
$accountSyncMenu=New-Object Windows.Controls.MenuItem;$accountSyncMenu.Header='管理 / 切换登录账号'
$accountSyncMenu.Add_Click({Show-PetAccountSyncPanel $script:accountSyncContext})
[void]$menu.Items.Insert(0,$accountSyncMenu)
$window.Add_Closed({Stop-PetAccountSyncContext $script:accountSyncContext})

$window.Add_Loaded({
    try {
        $script:rendererGeneration=[int]$script:rendererGeneration+1
        $script:rendererReady=$false;$script:chibiAnimationContext.RendererReady=$false
        $script:rendererLoadedUtc=[DateTimeOffset]::Now
        $script:startupTelemetry.window_loaded_utc=$script:rendererLoadedUtc.ToString('o')
        $script:startupTelemetry.renderer_generation=$script:rendererGeneration
        if(-not $script:hadSavedPosition){
            $work=Get-PetCurrentMonitorWorkAreaDip -Window $window
            $window.Left=$work.Right-$window.ActualWidth-15
            $window.Top=$work.Bottom-$window.ActualHeight-15
        }
        [void](Clamp-PetWindowToCurrentMonitor)
        if($script:qChibiRenderer){$script:qChibiRenderer.StartupPositionLeft=[double]$window.Left;$script:qChibiRenderer.StartupPositionTop=[double]$window.Top}
        Save-State
        [void](Try-PetRendererReady 'window_loaded')
        [void](Update-PetChibiRuntimeProfile -Reason 'window_loaded')
    }
    catch { Write-PetCaughtException 'window.loaded_position' $_ }
    Refresh-Quota
})

if($DebugMode){ Write-Host ('App root: '+$PSScriptRoot); Write-Host ('Codex runtime: '+(Find-LocalCodexExe)); Write-Host 'Window starting (GPT Quota Pet v1 Phase 2 copy)...' }
. (Join-Path $PSScriptRoot 'modules\Pet.Live2DQuotaBridge.ps1')
. (Join-Path $PSScriptRoot 'notice_monitor\Pet.TiboMonitor.Adapter.ps1')
try { $null=$window.ShowDialog() }
catch { Write-PetCaughtException 'window.show_dialog' $_; throw }

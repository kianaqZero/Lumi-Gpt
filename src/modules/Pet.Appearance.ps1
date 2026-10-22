Set-StrictMode -Version 2

function Get-PetPhase2StateNames {
    return @('online_good','refreshing','online_low','offline','error','interaction','long_idle','sleeping')
}

function Get-PetPhase2ManifestRecord {
    param(
        $Manifest,
        [string]$Appearance,
        [string]$LogicalState
    )
    if (-not $Manifest -or -not $Manifest.appearances) { throw 'Phase 2 asset manifest is missing appearances.' }
    $appearanceProperty = $Manifest.appearances.PSObject.Properties[$Appearance]
    if (-not $appearanceProperty) {
        $Appearance = 'chibi'
        $appearanceProperty = $Manifest.appearances.PSObject.Properties[$Appearance]
    }
    $appearanceNode = $appearanceProperty.Value
    $stateProperty = $appearanceNode.states.PSObject.Properties[$LogicalState]
    if (-not $stateProperty) {
        $LogicalState = 'online_good'
        $stateProperty = $appearanceNode.states.PSObject.Properties[$LogicalState]
    }
    if (-not $stateProperty) { throw "Phase 2 asset missing: $Appearance/$LogicalState" }
    $record = $stateProperty.Value
    return [pscustomobject]@{
        Appearance = $Appearance
        LogicalState = $LogicalState
        BaseImage = [string]$record.base_image
        OptionalLayers = @($record.optional_layers)
        Anchor = @($record.anchor)
        BubbleAnchorX = [double]$record.bubble_anchor_x
        BubbleAnchorY = [double]$record.bubble_anchor_y
        BubbleSidePreference = [string]$record.bubble_side_preference
        DefaultScale = [double]$record.default_scale
    }
}

function Get-PetPhase2QuotaState {
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
    $remaining = @()
    foreach ($windowName in @('session','weekly')) {
        if ($QuotaData.PSObject.Properties.Name -contains $windowName) {
            $window = $QuotaData.$windowName
            if ($window -and $window.PSObject.Properties.Name -contains 'remaining_percent') {
                try { $remaining += [double]$window.remaining_percent } catch {}
            }
        }
    }
    if ($remaining.Count -gt 0 -and (($remaining | Measure-Object -Minimum).Minimum -le $LowThreshold)) {
        return 'online_low'
    }
    return 'online_good'
}

function Get-PetPhase2ScaleValue {
    param(
        $State,
        $Config,
        [string]$Appearance,
        $ManifestRecord
    )
    $name = if ($Appearance -eq 'anime') { 'scale_anime' } else { 'scale_chibi' }
    $fallback = if ($ManifestRecord) { [double]$ManifestRecord.DefaultScale } else { 0.62 }
    if ($State -and $State.PSObject.Properties.Name -contains $name -and $null -ne $State.$name) { return [double]$State.$name }
    if ($Config -and $Config.PSObject.Properties.Name -contains $name -and $null -ne $Config.$name) { return [double]$Config.$name }
    if ($State -and $State.PSObject.Properties.Name -contains 'scale' -and $Appearance -eq 'chibi' -and $null -ne $State.scale) { return [double]$State.scale }
    return $fallback
}

function Get-PetPhase2ClampedScale {
    param([double]$Value)
    return [Math]::Max(0.30, [Math]::Min(1.10, $Value))
}

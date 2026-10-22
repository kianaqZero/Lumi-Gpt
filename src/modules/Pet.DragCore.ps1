Set-StrictMode -Version 2

function Test-PetDragThreshold {
    param(
        [double]$StartX,
        [double]$StartY,
        [double]$CurrentX,
        [double]$CurrentY,
        [double]$Threshold
    )
    $dx = $CurrentX - $StartX
    $dy = $CurrentY - $StartY
    return (($dx * $dx) + ($dy * $dy)) -ge ($Threshold * $Threshold)
}

function Get-PetDragTarget {
    param(
        [double]$WindowStartLeft,
        [double]$WindowStartTop,
        [double]$CursorStartX,
        [double]$CursorStartY,
        [double]$CursorNowX,
        [double]$CursorNowY
    )
    return [pscustomobject]@{
        Left = $WindowStartLeft + ($CursorNowX - $CursorStartX)
        Top = $WindowStartTop + ($CursorNowY - $CursorStartY)
    }
}

function Test-PetMoveThrottle {
    param(
        [long]$LastUpdateTicks,
        [long]$CurrentTicks,
        [int]$IntervalMilliseconds,
        [switch]$Force
    )
    if ($Force) { return $true }
    if ($LastUpdateTicks -le 0) { return $true }
    $requiredTicks = [long]([Math]::Max(1, $IntervalMilliseconds) * [TimeSpan]::TicksPerMillisecond)
    return (($CurrentTicks - $LastUpdateTicks) -ge $requiredTicks)
}

Set-StrictMode -Version 2

function Get-PetClampedPosition {
    param(
        [double]$Left,
        [double]$Top,
        [double]$Width,
        [double]$Height,
        [double]$WorkLeft,
        [double]$WorkTop,
        [double]$WorkRight,
        [double]$WorkBottom
    )
    $maxLeft = $WorkRight - $Width
    $maxTop = $WorkBottom - $Height
    if ($maxLeft -lt $WorkLeft) { $maxLeft = $WorkLeft }
    if ($maxTop -lt $WorkTop) { $maxTop = $WorkTop }
    return [pscustomobject]@{
        Left = [Math]::Max($WorkLeft, [Math]::Min($maxLeft, $Left))
        Top = [Math]::Max($WorkTop, [Math]::Min($maxTop, $Top))
    }
}

function Get-PetSnapTarget {
    param(
        [double]$Left,
        [double]$Top,
        [double]$Width,
        [double]$Height,
        [double]$WorkLeft,
        [double]$WorkTop,
        [double]$WorkRight,
        [double]$WorkBottom,
        [double]$SnapDistance
    )
    $clamped = Get-PetClampedPosition -Left $Left -Top $Top -Width $Width -Height $Height -WorkLeft $WorkLeft -WorkTop $WorkTop -WorkRight $WorkRight -WorkBottom $WorkBottom
    $targetLeft = [double]$clamped.Left
    $targetTop = [double]$clamped.Top
    $rightTarget = $WorkRight - $Width
    $bottomTarget = $WorkBottom - $Height
    $snappedLeft = [Math]::Abs($Left - $WorkLeft) -le $SnapDistance
    $snappedRight = [Math]::Abs(($Left + $Width) - $WorkRight) -le $SnapDistance
    $snappedTop = [Math]::Abs($Top - $WorkTop) -le $SnapDistance
    $snappedBottom = [Math]::Abs(($Top + $Height) - $WorkBottom) -le $SnapDistance
    if ($snappedLeft) { $targetLeft = $WorkLeft }
    elseif ($snappedRight) { $targetLeft = $rightTarget }
    if ($snappedTop) { $targetTop = $WorkTop }
    elseif ($snappedBottom) { $targetTop = $bottomTarget }
    $final = Get-PetClampedPosition -Left $targetLeft -Top $targetTop -Width $Width -Height $Height -WorkLeft $WorkLeft -WorkTop $WorkTop -WorkRight $WorkRight -WorkBottom $WorkBottom
    return [pscustomobject]@{
        Left = [double]$final.Left
        Top = [double]$final.Top
        SnappedLeft = [bool]$snappedLeft
        SnappedRight = [bool]$snappedRight
        SnappedTop = [bool]$snappedTop
        SnappedBottom = [bool]$snappedBottom
        AnySnap = [bool]($snappedLeft -or $snappedRight -or $snappedTop -or $snappedBottom)
    }
}

function Convert-PetScreenPixelToAbsoluteDip {
    param($Window, [double]$PixelX, [double]$PixelY)
    $pixelPoint = New-Object Windows.Point($PixelX, $PixelY)
    $clientDip = $Window.PointFromScreen($pixelPoint)
    return (New-Object Windows.Point(($Window.Left + $clientDip.X), ($Window.Top + $clientDip.Y)))
}

function Get-PetCursorScreenDip {
    param($Window)
    $cursorPx = [System.Windows.Forms.Cursor]::Position
    return (Convert-PetScreenPixelToAbsoluteDip -Window $Window -PixelX $cursorPx.X -PixelY $cursorPx.Y)
}

function Get-PetCurrentMonitorWorkAreaDip {
    param($Window)
    $interop = New-Object System.Windows.Interop.WindowInteropHelper($Window)
    $handle = $interop.Handle
    if ($handle -eq [IntPtr]::Zero) { $handle = $interop.EnsureHandle() }
    $screen = [System.Windows.Forms.Screen]::FromHandle($handle)
    $area = $screen.WorkingArea
    $topLeft = Convert-PetScreenPixelToAbsoluteDip -Window $Window -PixelX $area.Left -PixelY $area.Top
    $bottomRight = Convert-PetScreenPixelToAbsoluteDip -Window $Window -PixelX $area.Right -PixelY $area.Bottom
    $dpiX=96.0; $dpiY=96.0
    try {
        $source=[Windows.PresentationSource]::FromVisual($Window)
        if($source -and $source.CompositionTarget){
            $dpiX=96.0*$source.CompositionTarget.TransformToDevice.M11
            $dpiY=96.0*$source.CompositionTarget.TransformToDevice.M22
        }
    } catch {}
    return [pscustomobject]@{
        Name = $screen.DeviceName
        Left = [double]$topLeft.X
        Top = [double]$topLeft.Y
        Right = [double]$bottomRight.X
        Bottom = [double]$bottomRight.Y
        PixelLeft = $area.Left
        PixelTop = $area.Top
        PixelRight = $area.Right
        PixelBottom = $area.Bottom
        DpiX = $dpiX
        DpiY = $dpiY
    }
}

function Get-PetWindowClampForCurrentMonitor {
    param($Window)
    $work = Get-PetCurrentMonitorWorkAreaDip -Window $Window
    $position = Get-PetClampedPosition -Left $Window.Left -Top $Window.Top -Width $Window.ActualWidth -Height $Window.ActualHeight -WorkLeft $work.Left -WorkTop $work.Top -WorkRight $work.Right -WorkBottom $work.Bottom
    return [pscustomobject]@{ Left=$position.Left; Top=$position.Top; WorkArea=$work }
}

function Get-PetWindowSnapForCurrentMonitor {
    param($Window, [double]$SnapDistance)
    $work = Get-PetCurrentMonitorWorkAreaDip -Window $Window
    $target = Get-PetSnapTarget -Left $Window.Left -Top $Window.Top -Width $Window.ActualWidth -Height $Window.ActualHeight -WorkLeft $work.Left -WorkTop $work.Top -WorkRight $work.Right -WorkBottom $work.Bottom -SnapDistance $SnapDistance
    return [pscustomobject]@{
        Left=$target.Left; Top=$target.Top
        SnappedLeft=$target.SnappedLeft; SnappedRight=$target.SnappedRight
        SnappedTop=$target.SnappedTop; SnappedBottom=$target.SnappedBottom
        AnySnap=$target.AnySnap; WorkArea=$work
    }
}

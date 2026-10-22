Set-StrictMode -Version 2

$script:PetDiagnosticLogPath = $null

function Protect-PetDiagnosticText {
    param([AllowNull()][object]$Text)
    if ($null -eq $Text) { return $null }
    $value = [string]$Text
    # Redact Bearer payloads first; otherwise an Authorization field match could
    # consume only the word "Bearer" and leave the credential behind.
    $value = [regex]::Replace(
        $value,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{6,}',
        'Bearer [REDACTED]'
    )
    # Redact credential-shaped values while retaining the field name for diagnosis.
    $value = [regex]::Replace(
        $value,
        '(?i)(["'']?(?:access_token|refresh_token|id_token|oauth_token|authorization)["'']?\s*[:=]\s*)("[^"]*"|''[^'']*''|[^,\s;}]+(?:\s+\[REDACTED\])?)',
        '$1"[REDACTED]"'
    )
    return $value
}

function Get-PetDiagnosticValue {
    param(
        [hashtable]$Context,
        [string]$Name,
        $Default = $null
    )
    if ($Context -and $Context.ContainsKey($Name)) { return $Context[$Name] }
    return $Default
}

function Initialize-PetDiagnostics {
    param([Parameter(Mandatory=$true)][string]$LogDirectory)
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
    }
    $script:PetDiagnosticLogPath = Join-Path $LogDirectory 'crash.log'
    return $script:PetDiagnosticLogPath
}

function Write-PetCrashRecord {
    param(
        [Parameter(Mandatory=$true)][string]$EventName,
        [Parameter(Mandatory=$true)][System.Exception]$Exception,
        [hashtable]$Context = @{}
    )
    if (-not $script:PetDiagnosticLogPath) { return }

    $stack = $Exception.StackTrace
    if (-not $stack -and $Exception.PSObject.Properties.Name -contains 'ScriptStackTrace') {
        $stack = $Exception.ScriptStackTrace
    }

    # Explicit whitelist only. Never serialize environment variables, command lines,
    # quota payloads, auth files, or arbitrary exception Data dictionaries.
    $record = [ordered]@{
        timestamp = [DateTimeOffset]::Now.ToString('o')
        event = Protect-PetDiagnosticText $EventName
        exception_type = Protect-PetDiagnosticText $Exception.GetType().FullName
        exception_message = Protect-PetDiagnosticText $Exception.Message
        exception_stack = Protect-PetDiagnosticText $stack
        drag_phase = Get-PetDiagnosticValue $Context 'drag_phase' 'Unknown'
        cursor_px = [ordered]@{
            x = Get-PetDiagnosticValue $Context 'cursor_x_px'
            y = Get-PetDiagnosticValue $Context 'cursor_y_px'
        }
        window_dip = [ordered]@{
            left = Get-PetDiagnosticValue $Context 'window_left_dip'
            top = Get-PetDiagnosticValue $Context 'window_top_dip'
            width = Get-PetDiagnosticValue $Context 'window_width_dip'
            height = Get-PetDiagnosticValue $Context 'window_height_dip'
        }
        dpi = [ordered]@{
            x = Get-PetDiagnosticValue $Context 'dpi_x'
            y = Get-PetDiagnosticValue $Context 'dpi_y'
        }
        monitor = [ordered]@{
            name = Protect-PetDiagnosticText (Get-PetDiagnosticValue $Context 'monitor_name')
            workarea_px = [ordered]@{
                left = Get-PetDiagnosticValue $Context 'work_left_px'
                top = Get-PetDiagnosticValue $Context 'work_top_px'
                right = Get-PetDiagnosticValue $Context 'work_right_px'
                bottom = Get-PetDiagnosticValue $Context 'work_bottom_px'
            }
        }
        appearance = Protect-PetDiagnosticText (Get-PetDiagnosticValue $Context 'appearance' 'legacy_anime')
        scale = Get-PetDiagnosticValue $Context 'scale'
        locked = [bool](Get-PetDiagnosticValue $Context 'locked' $false)
        animation_state = Protect-PetDiagnosticText (Get-PetDiagnosticValue $Context 'animation_state' 'unknown')
        snap_state = Protect-PetDiagnosticText (Get-PetDiagnosticValue $Context 'snap_state' 'unknown')
        process = [ordered]@{
            id = $PID
            powershell_version = $PSVersionTable.PSVersion.ToString()
        }
    }

    try {
        $json = $record | ConvertTo-Json -Depth 8 -Compress
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($script:PetDiagnosticLogPath, $json + [Environment]::NewLine, $utf8NoBom)
    }
    catch {
        # Diagnostics must never become a second crash path.
    }
}

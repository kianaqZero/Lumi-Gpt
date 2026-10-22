# Read-only installation detection for short-lived quota probes. No GUI process required.
function Find-PetQuotaRuntime {
    param([string]$SharedHome)
    $candidates=@()
    if($SharedHome){
        $candidates+=Join-Path $SharedHome 'packages\standalone\current\bin\codex.exe'
        $candidates+=Join-Path $SharedHome 'bin\codex.exe'
    }
    $installed=Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if(Test-Path -LiteralPath $installed -PathType Container){
        foreach($version in @(Get-ChildItem -LiteralPath $installed -Directory -ErrorAction SilentlyContinue | Where-Object {$_.Name -match '^[a-f0-9]{12,64}$'} | Sort-Object LastWriteTimeUtc -Descending)){
            $candidates+=Join-Path $version.FullName 'codex.exe'
        }
    }
    foreach($candidate in $candidates){
        if(-not (Test-Path -LiteralPath $candidate -PathType Leaf)){continue}
        $file=Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue;if(-not $file -or $file.Length -lt 1){continue}
        return [pscustomobject]@{path=$file.FullName;fingerprint=($file.FullName.ToLowerInvariant()+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks);source='installed_runtime';desktop_required=$false}
    }
    return $null
}

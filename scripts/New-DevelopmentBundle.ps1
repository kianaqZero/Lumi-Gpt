param([Parameter(Mandatory=$true)][string]$AssetBundlePath,[string]$Destination=(Join-Path (Split-Path $PSScriptRoot) 'bundle'))
$ErrorActionPreference='Stop'
$source=(Resolve-Path -LiteralPath $AssetBundlePath).Path
$dest=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $dest){throw 'Choose a new destination; existing bundles are never overwritten.'}
foreach($rel in @('runtime\electron\electron.exe','renderer\vendor\live2dcubismcore.min.js','models\original\MODEL_REGISTRY.json','assets\asset_manifest.json')){
    if(-not(Test-Path -LiteralPath (Join-Path $source $rel))){throw "Missing dependency in your licensed asset bundle: $rel"}
}
$null=New-Item -ItemType Directory -Path $dest
# Explicit asset/runtime allowlist. No credentials, profiles, sessions, logs or private bindings.
foreach($rel in @('assets','models','runtime','renderer\vendor','renderer\head_models','renderer\body_models','renderer\full_body_models','renderer\node_modules')){
    $p=Join-Path $source $rel
    if(Test-Path -LiteralPath $p){$parent=Split-Path (Join-Path $dest $rel);$null=New-Item -ItemType Directory -Path $parent -Force;Copy-Item -LiteralPath $p -Destination (Join-Path $dest $rel) -Recurse}
}
Get-ChildItem -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'src') -Force | Copy-Item -Destination $dest -Recurse
Write-Output "Development bundle prepared: $dest"
Write-Output 'No application was launched. Configure task binding before starting pet.ps1.'

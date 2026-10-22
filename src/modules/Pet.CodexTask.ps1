# Project-scoped task presentation, separate from quota/account semantic state.
$script:codexTaskFeedback=@{Key='';Until=[DateTimeOffset]::MinValue}
function Get-PetCodexTaskVisualState {
    param($Packet,[string]$Session,[int]$Owner,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow,[bool]$Manual=$false,[bool]$Fullscreen=$false)
    if(-not $Packet -or $Manual -or $Fullscreen){return $null}
    foreach($name in @('schema','session','owner_pid','published_utc','scope_verified','status','turn_id','event_utc','live')){if($Packet.PSObject.Properties.Name -notcontains $name){return $null}}
    if($Packet.schema -ne 1 -or $Packet.session -ne $Session -or $Packet.owner_pid -ne $Owner -or -not $Packet.scope_verified){return $null}
    try{$age=($Now-[DateTimeOffset]::Parse($Packet.published_utc)).TotalSeconds}catch{return $null}
    if($age -lt -2 -or $age -gt 8){return $null}
    # Prefer verified current work in any Codex project over the historical pinned chat.
    $taskRows=if($Packet.PSObject.Properties.Name -contains 'tasks'){@($Packet.tasks)}else{@()}
    foreach($task in $taskRows){
        if($task -and $task.status -eq 'active' -and $task.live){return $(if($task.activity -eq 'thinking'){'thinking'}else{'working'})}
    }
    foreach($task in $taskRows){
        if(-not $task -or $task.status -notin @('completed','failed','interrupted') -or -not $task.live){continue}
        $key=[string]$task.turn_id+':'+[string]$task.status
        if($script:codexTaskFeedback.Key -ne $key){
            try{$eventAge=($Now-[DateTimeOffset]::Parse($task.event_utc)).TotalSeconds}catch{continue}
            if($eventAge -lt -2 -or $eventAge -gt 10){continue}
            $script:codexTaskFeedback.Key=$key;$script:codexTaskFeedback.Until=$Now.AddSeconds(5)
        }
        if($Now -lt $script:codexTaskFeedback.Until){
            switch($task.status){'completed'{return 'greeting'} 'failed'{return 'pout_angry'} 'interrupted'{return 'thinking'}}
        }
    }
    if($Packet.status -eq 'active' -and $Packet.live){return 'working'}
    if($Packet.status -notin @('completed','failed','interrupted') -or -not $Packet.live){return $null}
    $key=[string]$Packet.turn_id+':'+[string]$Packet.status
    if($script:codexTaskFeedback.Key -ne $key){
        try{$eventAge=($Now-[DateTimeOffset]::Parse($Packet.event_utc)).TotalSeconds}catch{return $null}
        if($eventAge -lt -2 -or $eventAge -gt 10){return $null}
        $script:codexTaskFeedback.Key=$key
        $script:codexTaskFeedback.Until=$Now.AddSeconds(5)
    }
    if($Now -ge $script:codexTaskFeedback.Until){return $null}
    switch($Packet.status){'completed'{return 'greeting'} 'failed'{return 'pout_angry'} 'interrupted'{return 'thinking'}}
}
function Read-PetCodexTaskPacket {
    if(-not $script:live2dBridge){return $null}
    $file=Join-Path $script:live2dBridge.Root 'task-state.json'
    if(-not [IO.File]::Exists($file)){return $null}
    try{if(([IO.FileInfo]$file).Length -gt 65536){return $null};return ([IO.File]::ReadAllText($file,[Text.Encoding]::UTF8)|ConvertFrom-Json)}catch{return $null}
}

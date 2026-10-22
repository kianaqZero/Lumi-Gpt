param([ValidateSet('Feed','Original','ShortLink','Forecast','Timeline')][string]$Mode,[string]$Value)
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$response=$null;$stream=$null
try {
 if($Mode -eq 'Feed'){$uri='https://codex-reset.com/api/feed';$method='GET'}elseif($Mode -eq 'Forecast'){$uri='https://codex-reset.com/api/forecast?tz=Asia%2FSingapore';$method='GET'}elseif($Mode -eq 'Timeline'){$uri='https://codex-reset.com/api/timeline?locale=zh';$method='GET'}elseif($Mode -eq 'Original'){
  if($Value -notmatch '^[0-9]{15,22}$'){throw 'INVALID_REQUEST'}
  $uri='https://publish.x.com/oembed?url='+[Uri]::EscapeDataString('https://x.com/thsottiaux/status/'+$Value)+'&omit_script=true';$method='GET'
 }else{if($Value -cnotmatch '^https://t\.co/[a-zA-Z0-9]+$'){throw 'INVALID_REQUEST'};$uri=$Value;$method='HEAD'}
 $request=[Net.HttpWebRequest]::Create($uri);$request.Method=$method;$request.AllowAutoRedirect=$false;$request.Timeout=4000;$request.ReadWriteTimeout=4000;$request.UserAgent='Lumi-Desktop-Pet/0.3 (personal desktop; https://github.com/kianaqZero/Lumi-Gpt)';$request.Accept='application/json';$request.Credentials=$null
 $response=$request.GetResponse();$status=[int]$response.StatusCode;$body=''
 if($Mode -ne 'ShortLink'){
  $stream=$response.GetResponseStream();$buffer=New-Object byte[] 4096;$memory=[IO.MemoryStream]::new()
  try{while(($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$count -gt 1048576){throw 'OVERSIZED_SOURCE'};$memory.Write($buffer,0,$count)};$body=[Text.Encoding]::UTF8.GetString($memory.ToArray())}finally{$memory.Dispose()}
 }
 [pscustomobject]@{ok=$true;status=$status;headers=@{location=$response.Headers['Location'];retry_after=$response.Headers['Retry-After']};body=$body}|ConvertTo-Json -Depth 5 -Compress
}catch{
 $failed=$_.Exception.Response;$status=0;$retry=''
 if($failed){try{$status=[int]$failed.StatusCode;$retry=[string]$failed.Headers['Retry-After']}finally{$failed.Dispose()}}
 [pscustomobject]@{ok=$false;status=$status;headers=@{retry_after=$retry};code='PUBLIC_REQUEST_UNAVAILABLE'}|ConvertTo-Json -Depth 3 -Compress
}finally{if($stream){$stream.Dispose()};if($response){$response.Dispose()}}

function Get-LumiCardProperty($Object,[string]$Name,$Default=$null) {
    if($null -eq $Object){return $Default};$property=$Object.PSObject.Properties[$Name];if($null -eq $property){return $Default};return ,$property.Value
}
function ConvertTo-LumiResetCards($Response,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    $data=Get-LumiCardProperty $Response 'rateLimitResetCredits'
    if($null -eq $data){return [pscustomobject]@{state='not_returned';available_count=$null;details_known=$false;cards=@();checked_at=$Now.ToString('o')}}
    $count=Get-LumiCardProperty $data 'availableCount';$valid=($null -ne $count -and $count -is [ValueType] -and [double]$count -ge 0 -and [double]$count -eq [Math]::Floor([double]$count))
    if(-not $valid){return [pscustomobject]@{state='invalid_count';available_count=$null;details_known=$false;cards=@();checked_at=$Now.ToString('o')}}
    $rows=Get-LumiCardProperty $data 'credits';$cards=[Collections.Generic.List[object]]::new()
    if($null -ne $rows){foreach($row in @($rows)){
        $expiry=Get-LumiCardProperty $row 'expiresAt';$expiryIso=$null;$expiryLocal=$null;$expired=$false
        if($null -ne $expiry){try{$date=[DateTimeOffset]::FromUnixTimeSeconds([long]$expiry);$expiryIso=$date.ToString('o');$expiryLocal=$date.ToLocalTime().ToString('yyyy-MM-dd HH:mm');$expired=$Now -ge $date}catch{}}
        $status=[string](Get-LumiCardProperty $row 'status' 'unknown');$type=[string](Get-LumiCardProperty $row 'resetType' '')
        $label=if($expired){'已过期'}elseif($status -eq 'available' -and $type -eq 'codexRateLimits'){'可用'}elseif($status -in @('redeemed','consumed')){'已使用'}elseif($status -eq 'expired'){'已过期'}else{'状态待核对'}
        $creditId=[string](Get-LumiCardProperty $row 'id' '');$redeemable=($status -eq 'available' -and $type -eq 'codexRateLimits' -and -not $expired -and $creditId.Length -gt 0 -and $creditId.Length -le 256)
        $cards.Add([pscustomobject]@{id=$creditId;redeemable=$redeemable;status=$status;status_label=$label;reset_type=$type;expires_at=$expiryIso;expires_local=$expiryLocal;expiry_known=($null -ne $expiryIso);expired=$expired})
    }}
    return [pscustomobject]@{state='read';available_count=[long]$count;details_known=($null -ne $rows);cards=$cards.ToArray();checked_at=$Now.ToString('o');redemption_eligibility='not_checked';count_source='server_availableCount'}
}

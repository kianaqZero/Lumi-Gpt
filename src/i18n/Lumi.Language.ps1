# Per-application locale. Never changes Windows display language or account data.
if(-not ('LumiTranslationMemory' -as [type])){Add-Type @'
using System.Runtime.CompilerServices;
public static class LumiTranslationMemory {
 public class Record {public string Source; public string Rendered;}
 static ConditionalWeakTable<object,Record> values=new ConditionalWeakTable<object,Record>();
 public static Record Get(object key){return values.GetOrCreateValue(key);}
}
'@}
$script:LumiLanguageRoot=Split-Path $PSScriptRoot
$script:LumiLanguageCatalog=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'catalog.json'))|ConvertFrom-Json
$script:LumiLocale='zh';$script:LumiLanguageChecked=[DateTime]::MinValue
$script:LumiTranslationKeys=@($script:LumiLanguageCatalog.entries.PSObject.Properties.Name|Sort-Object Length -Descending)
$script:LumiTranslationRegex=[regex]::new((($script:LumiTranslationKeys|ForEach-Object{[regex]::Escape($_)}) -join '|'))
function Get-LumiLanguage {
 if(([DateTime]::UtcNow-$script:LumiLanguageChecked).TotalSeconds -lt 1){return $script:LumiLocale}
 $script:LumiLanguageChecked=[DateTime]::UtcNow
 try{$v=[IO.File]::ReadAllText((Join-Path $script:LumiLanguageRoot 'local_state\language.json'))|ConvertFrom-Json;if($v.locale -in @('zh','en','ja','ko')){$script:LumiLocale=$v.locale}}catch{}
 return $script:LumiLocale
}
function Set-LumiLanguage([string]$Locale){
 if($Locale -notin @('zh','en','ja','ko')){throw 'Unsupported locale'}
 $script:LumiLocale=$Locale;$script:LumiLanguageChecked=[DateTime]::UtcNow
}
function ConvertTo-LumiText([string]$Text){
 $locale=Get-LumiLanguage;if($locale -eq 'zh' -or -not $Text){return $Text}
 $entry=$script:LumiLanguageCatalog.entries.PSObject.Properties[$Text.Trim()]
 if($entry){return $Text.Replace($Text.Trim(),[string]$entry.Value.$locale)}
 foreach($p in $script:LumiLanguageCatalog.patterns){$re=[regex]::new($p.pattern);if($re.IsMatch($Text)){return $re.Replace($Text,[string]$p.$locale)}}
 $lookup=$script:LumiLanguageCatalog.entries;$targetLocale=$locale
 return $script:LumiTranslationRegex.Replace($Text,[Text.RegularExpressions.MatchEvaluator]{param($m);return [string]$lookup.PSObject.Properties[$m.Value].Value.$targetLocale}.GetNewClosure())
}
function Set-LumiWindowLanguage($Window){
 if(-not $Window){return}
 function Translate-LumiProperty($Element,[string]$Property){
  $current=$Element.$Property;if($current -isnot [string]){return}
  $key=if($Property -eq 'Text'){$Element}else{$Element.GetType().FullName+':'+[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Element)+':'+$Property}
  # Element-backed weak records avoid retaining closed windows.
  $memory=[LumiTranslationMemory]::Get($Element)
  if($null -eq $memory.Source -or $current -ne $memory.Rendered){$memory.Source=$current}
  $rendered=ConvertTo-LumiText $memory.Source;$memory.Rendered=$rendered
  if($current -ne $rendered){$Element.$Property=$rendered}
 }
 Translate-LumiProperty $Window 'Title'
 $queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue($Window);$visited=[Collections.Generic.HashSet[object]]::new()
 while($queue.Count){
  $e=$queue.Dequeue();if(-not $e -or -not $visited.Add($e)){continue}
  if($e -is [Windows.Controls.ComboBoxItem] -or $e -is [Windows.Controls.TextBox] -or $e -is [Windows.Documents.Hyperlink]){continue}
  if($e -is [Windows.Controls.TextBlock] -and -not ($e.Tag -eq 'LumiExternalContent') -and $e.Inlines.Count -le 1){Translate-LumiProperty $e 'Text'}
  elseif($e -is [Windows.Controls.HeaderedContentControl]){Translate-LumiProperty $e 'Header'}
  elseif($e -is [Windows.Controls.ContentControl]){Translate-LumiProperty $e 'Content'}
  if($e -is [Windows.DependencyObject]){foreach($child in [Windows.LogicalTreeHelper]::GetChildren($e)){if($child -is [Windows.DependencyObject]){$queue.Enqueue($child)}}}
 }
}

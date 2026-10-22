# Read-only foreground inspection; never activate, minimize or modify the other application.
if(-not ('PetForegroundNative' -as [type])){
Add-Type @'
using System;
using System.Text;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
public static class PetForegroundNative {
 [StructLayout(LayoutKind.Sequential)] public struct Rect { public int left,top,right,bottom; }
 [StructLayout(LayoutKind.Sequential)] public struct Point { public int x,y; }
 [StructLayout(LayoutKind.Sequential)] public struct Monitor { public int size; public Rect monitor,work; public uint flags; }
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h,ref Point p);
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point p,uint flags);
 public static bool SameMonitorAsPet(int x,int y){return MonitorFromWindow(GetForegroundWindow(),2)==MonitorFromPoint(new Point{x=x,y=y},2);}
 [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr h,ref Monitor m);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
 public static bool IsCaptureProcess(string name,string filename) {
  if(String.IsNullOrEmpty(name)||String.IsNullOrEmpty(filename))return false;
  name=Path.GetFileNameWithoutExtension(name);
  bool snip=String.Equals(name,"SnippingTool",StringComparison.OrdinalIgnoreCase)||String.Equals(name,"ScreenSketch",StringComparison.OrdinalIgnoreCase);
  bool clip=String.Equals(name,"ScreenClippingHost",StringComparison.OrdinalIgnoreCase);
  if(!snip&&!clip)return false;
  try {
   string file=Path.GetFullPath(filename);
   string windows=Environment.GetFolderPath(Environment.SpecialFolder.Windows);
   string programs=Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
   string basename=Path.GetFileNameWithoutExtension(file);
   if(!String.Equals(name,basename,StringComparison.OrdinalIgnoreCase))return false;
   if(snip&&file.StartsWith(Path.Combine(programs,@"WindowsApps\Microsoft.ScreenSketch_"),StringComparison.OrdinalIgnoreCase))return true;
   if(clip&&file.StartsWith(Path.Combine(windows,@"SystemApps\MicrosoftWindows.Client.CBS_"),StringComparison.OrdinalIgnoreCase))return true;
   return snip&&String.Equals(file,Path.Combine(windows,@"System32\SnippingTool.exe"),StringComparison.OrdinalIgnoreCase);
  } catch { return false; }
 }
 public static bool IsCaptureForeground() {
  uint pid;GetWindowThreadProcessId(GetForegroundWindow(),out pid);
  if(pid==0)return false;
  try {using(var p=Process.GetProcessById((int)pid)){
   string name=p.ProcessName;
   if(name!="SnippingTool"&&name!="ScreenClippingHost"&&name!="ScreenSketch")return false;
   return IsCaptureProcess(name,p.MainModule.FileName);
  }}catch{return false;}
 }
 public static string ForeignWindowToken(int ownerPid,int rendererPid) {
  IntPtr h=GetForegroundWindow();uint pid;GetWindowThreadProcessId(h,out pid);
  if(h==IntPtr.Zero||pid==ownerPid||pid==rendererPid)return "";
  var name=new StringBuilder(256);GetClassName(h,name,name.Capacity);
  if(name.ToString()=="Progman"||name.ToString()=="WorkerW"||name.ToString()=="Shell_TrayWnd")return "";
  return h.ToString();
 }
 public static bool IsOwnForeground(int ownerPid,int rendererPid) {
  IntPtr h=GetForegroundWindow();uint pid;
  if(h==IntPtr.Zero)return false;
  GetWindowThreadProcessId(h,out pid);
  return pid==ownerPid||pid==rendererPid;
 }
 public static bool IsShellForeground() {
  IntPtr h=GetForegroundWindow();
  if(h==IntPtr.Zero)return false;
  var name=new StringBuilder(256);GetClassName(h,name,name.Capacity);
  return name.ToString()=="Progman"||name.ToString()=="WorkerW"||name.ToString()=="Shell_TrayWnd";
 }
 public static bool IsForeignFullscreen(int ownerPid,int rendererPid) {
  IntPtr previous=SetThreadDpiAwarenessContext(new IntPtr(-4));
  try {
   IntPtr h=GetForegroundWindow();uint pid;GetWindowThreadProcessId(h,out pid);
   if(h==IntPtr.Zero||pid==ownerPid||pid==rendererPid||!IsWindowVisible(h)||IsIconic(h))return false;
   var name=new StringBuilder(256);GetClassName(h,name,name.Capacity);
   if(name.ToString()=="Progman"||name.ToString()=="WorkerW"||name.ToString()=="Shell_TrayWnd")return false;
   Rect client;var origin=new Point();var m=new Monitor();m.size=Marshal.SizeOf(typeof(Monitor));
   if(!GetClientRect(h,out client)||!ClientToScreen(h,ref origin)||!GetMonitorInfo(MonitorFromWindow(h,2),ref m))return false;
   return origin.x<=m.monitor.left+2&&origin.y<=m.monitor.top+2&&origin.x+client.right>=m.monitor.right-2&&origin.y+client.bottom>=m.monitor.bottom-2;
  } finally {if(previous!=IntPtr.Zero)SetThreadDpiAwarenessContext(previous);}
 }
}
'@
}
function Test-PetCaptureOverlay { return [PetForegroundNative]::IsCaptureForeground() }
function Test-PetCurrentForeignFullscreen {
    $b=$script:live2dBridge
    $rendererPid=if($b.Process){$b.Process.Id}else{0}
    return ([PetForegroundNative]::IsForeignFullscreen($PID,$rendererPid) -and [PetForegroundNative]::SameMonitorAsPet([int]($window.Left+575),[int]($window.Top+325)))
}
function Restore-PetExplicitPresentation {
    $b=$script:live2dBridge
    if(-not $b){return}
    $b.TrayMinimized=$false
    # A tray request rechecks current evidence rather than retaining a historic hidden flag.
    if(-not (Test-PetCaptureOverlay)){
        $fullscreen=Test-PetCurrentForeignFullscreen
        $b.ForeignWindowFullscreen=$fullscreen
        $b.ForegroundClearTicks=if($fullscreen){0}else{3}
        Set-PetFullscreenPresentation $fullscreen
    }
    $hidden=$b.FullscreenSuspended
    $window.Opacity=if($hidden){0.0}else{1.0}
    $window.IsHitTestVisible=-not $hidden
    $window.Topmost=$b.DesiredTopmost -and -not $hidden
    $b.ForegroundEpoch++
    $b.ExplicitRestoreEpoch++
}
function Update-PetFullscreenGuard {
    if(-not $script:live2dBridge){return}
    $b=$script:live2dBridge
    # Do not treat Win+Shift+S as a game and do not expose a pet already hidden for a game.
    if(Test-PetCaptureOverlay){return}
    $rendererPid=if($b.Process){$b.Process.Id}else{0}
    $token=[PetForegroundNative]::ForeignWindowToken($PID,$rendererPid)
    $fullscreen=[PetForegroundNative]::IsForeignFullscreen($PID,$rendererPid)
    # A full-screen app on another monitor must not hide this monitor's pet.
    if($fullscreen -and -not [PetForegroundNative]::SameMonitorAsPet([int]($window.Left+575),[int]($window.Top+325))){$fullscreen=$false}
    $ownForeground=[PetForegroundNative]::IsOwnForeground($PID,$rendererPid)
    $shellForeground=[PetForegroundNative]::IsShellForeground()
    if($token -and ($token -ne $b.ForeignWindowToken -or $fullscreen -ne $b.ForeignWindowFullscreen)){
        $b.ForeignWindowToken=$token;$b.ForeignWindowFullscreen=$fullscreen;$b.ForegroundEpoch++
    }
    # A brief focus switch to Lumi must not make a still-running game reappear
    # behind an always-on-top pet. Clear only after a verified non-fullscreen
    # foreign window or the desktop has taken foreground.
    if($fullscreen){$b.ForeignWindowFullscreen=$true}
    elseif($token -or $shellForeground){$b.ForeignWindowFullscreen=$false}
    elseif(-not $ownForeground){$b.ForeignWindowFullscreen=$false}
    Set-PetFullscreenPresentation ([bool]$b.ForeignWindowFullscreen)
}
function Set-PetFullscreenPresentation([bool]$Fullscreen) {
    if(-not $script:live2dBridge){return}
    $b=$script:live2dBridge
    # A full-screen app owns the monitor even when Lumi's normal preference is topmost.
    $fullscreen=$Fullscreen
    if($fullscreen){$b.ForegroundClearTicks=0}else{$b.ForegroundClearTicks++}
    $suspend=$fullscreen -or ($b.FullscreenSuspended -and $b.ForegroundClearTicks -lt 3)
    if($suspend -eq $b.FullscreenSuspended){return}
    $b.FullscreenSuspended=$suspend
    # Keep the ShowDialog owner alive; hide its contents and remove its z-order request.
    # The remembered user preference is separate from this temporary presentation state.
    $hidden=$suspend -or ($b.PSObject.Properties.Name -contains 'TrayMinimized' -and $b.TrayMinimized)
    $window.IsHitTestVisible=-not $hidden
    $window.Opacity=if($hidden){0.0}else{1.0}
    $window.Topmost=if($hidden){$false}else{$b.DesiredTopmost}
}

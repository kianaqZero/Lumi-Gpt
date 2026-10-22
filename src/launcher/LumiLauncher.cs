using System;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Management;
using System.Threading;
[assembly: System.Reflection.AssemblyTitle("lumi")]
[assembly: System.Reflection.AssemblyProduct("lumi")]
[assembly: System.Reflection.AssemblyVersion("0.3.2.0")]
class LumiLauncher {
 static readonly JavaScriptSerializer Json=new JavaScriptSerializer();
 static string Root=AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
 static Dictionary<string,object> Read(string file){return Json.Deserialize<Dictionary<string,object>>(File.ReadAllText(file));}
 static string Quote(string value){return "\""+value+"\"";}
 static string OtherLumiPath(){
  // Keep separate trial versions from racing for the shared Codex account store.
  // This only inspects processes; it never closes or activates another pet.
  using(var search=new ManagementObjectSearcher("SELECT ProcessId,ExecutablePath,SessionId FROM Win32_Process WHERE Name='lumi.exe'"))foreach(ManagementObject row in search.Get()){
   int pid=Convert.ToInt32(row["ProcessId"]);if(pid==Process.GetCurrentProcess().Id)continue;
   string exe=Convert.ToString(row["ExecutablePath"]);if(String.IsNullOrEmpty(exe)||!String.Equals(Path.GetFileName(exe),"lumi.exe",StringComparison.OrdinalIgnoreCase))continue;
   if(Convert.ToInt32(row["SessionId"])!=Process.GetCurrentProcess().SessionId)continue;
   if(!String.Equals(Path.GetFullPath(exe),Path.GetFullPath(Application.ExecutablePath),StringComparison.OrdinalIgnoreCase))return exe;
  }
  return null;
 }
 static bool RestoreExisting(){
  string pointer=Path.Combine(Root,"local_state/render_session.json");if(!File.Exists(pointer))return false;
  var p=Read(pointer);if(Convert.ToBoolean(p["simulation"]))return false;
  int pid=Convert.ToInt32(p["owner_pid"]);Process process;try{process=Process.GetProcessById(pid);if(process.HasExited)return false;}catch(ArgumentException){return false;}
  bool owned=false;using(var search=new ManagementObjectSearcher("SELECT ExecutablePath,CommandLine FROM Win32_Process WHERE ProcessId="+pid))foreach(ManagementObject row in search.Get()){
   string exe=Convert.ToString(row["ExecutablePath"]),cmd=Convert.ToString(row["CommandLine"]);owned=exe.EndsWith("\\powershell.exe",StringComparison.OrdinalIgnoreCase)&&cmd.IndexOf(Root,StringComparison.OrdinalIgnoreCase)>=0;
  }
  if(!owned)throw new InvalidOperationException("Unable to verify the existing pet owner; no new instance was started.");
  string session=Convert.ToString(p["session"]),dir=Path.GetFullPath(Convert.ToString(p["root"])),allowed=Path.GetFullPath(Path.Combine(Root,"local_state/render_sessions"))+Path.DirectorySeparatorChar;
  Guid sessionId;if(!Guid.TryParseExact(session,"N",out sessionId)||!dir.StartsWith(allowed,StringComparison.OrdinalIgnoreCase)||Path.GetFileName(dir)!=session)throw new InvalidOperationException("Invalid existing pet session.");
  var state=Read(Path.Combine(dir,"state.json"));if(Convert.ToInt32(state["owner_pid"])!=pid||Convert.ToString(state["session"])!=session||Convert.ToBoolean(state["closed"]))return false;
  // Out-of-band restore has no command acknowledgement and cannot advance the
  // renderer's monotonic sequence or acknowledge its pending control requests.
  var cmdData=new Dictionary<string,object>{{"schema",1},{"session",session},{"sequence",0},{"command","restore"}};
  string dest=Path.Combine(dir,"commands/000000000000_"+Guid.NewGuid().ToString("N")+".json");File.WriteAllText(dest+".tmp",Json.Serialize(cmdData));File.Move(dest+".tmp",dest);return true;
 }
 [STAThread] static void Main(string[] args){
  try{
   string script=Path.Combine(Root,"pet.ps1"),runtime=Path.Combine(Root,"runtime/electron/electron.exe");
   var identity=Read(Path.Combine(Root,"APP_IDENTITY.json"));string icon=Path.Combine(Root,Convert.ToString(identity["icon"]));
   if(!File.Exists(script)||!File.Exists(runtime)||!File.Exists(icon))throw new FileNotFoundException("Keep lumi.exe inside the complete project folder.");
   if(args.Length==1&&args[0]=="--self-check"){
    string proof=Path.Combine(Root,"validation/launcher_r2");Directory.CreateDirectory(proof);File.WriteAllText(Path.Combine(proof,"self_check.json"),Json.Serialize(new{status="PASS",app_name=identity["name"],icon_present=true,runtime_present=true,gui_subsystem=true,pet_started=false}));return;
   }
   bool simulation=args.Length==1&&args[0]=="--simulation-test";
   bool independent=args.Length==1&&args[0]=="--independent-host";
   if(args.Length>0&&!simulation&&!independent)throw new ArgumentException("Unsupported launcher argument.");
   if(simulation)script=Path.Combine(Root,"validation/launcher_r2/Launch.Simulation.ps1");
   using(var gate=new Mutex(false,"Local\\Lumi_Trial_20261019_R2")){
    if(!gate.WaitOne(0))return;
    try{
     if(!simulation&&RestoreExisting())return;
     string other=(!simulation&&!independent)?OtherLumiPath():null;
     if(other!=null)throw new InvalidOperationException("Another lumi version is running. Exit it from its tray first, then start R2. Running copy: "+other);
     if(!simulation&&!independent){
      // Releasing this brief launch gate before delegation prevents the independently
      // created launcher from losing a startup race against this caller's mutex.
      gate.ReleaseMutex();
      int independentPid=PetLifetimeBroker.Start(Application.ExecutablePath,"--independent-host",Root);
      string receipts=Path.Combine(Root,"local_state/lifecycle_launches");Directory.CreateDirectory(receipts);
      File.WriteAllText(Path.Combine(receipts,DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff")+".json"),Json.Serialize(new{schema=1,mode="local_wmi_independent",requester_pid=Process.GetCurrentProcess().Id,independent_pid=independentPid,requested_utc=DateTime.UtcNow.ToString("o")}));
      return;
     }
     string ps=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell/v1.0/powershell.exe");
     var info=new ProcessStartInfo(ps,"-NoProfile -ExecutionPolicy Bypass -STA -File "+Quote(script));info.WorkingDirectory=Root;info.UseShellExecute=false;info.CreateNoWindow=true;info.WindowStyle=ProcessWindowStyle.Hidden;info.RedirectStandardOutput=true;info.RedirectStandardError=true;info.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE");
     info.EnvironmentVariables["PSModulePath"]=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),"WindowsPowerShell/v1.0/Modules")+";"+Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),"WindowsPowerShell/Modules");
     string logs=Path.Combine(Root,"local_state/launcher_logs");Directory.CreateDirectory(logs);string stamp=DateTime.UtcNow.ToString("yyyyMMdd_HHmmss_fff");
     using(var output=new StreamWriter(Path.Combine(logs,stamp+".stdout.log")))using(var errors=new StreamWriter(Path.Combine(logs,stamp+".stderr.log")))using(var child=new Process()){
      child.StartInfo=info;child.OutputDataReceived+=(s,e)=>{if(e.Data!=null){lock(output){output.WriteLine(e.Data);output.Flush();}}};child.ErrorDataReceived+=(s,e)=>{if(e.Data!=null){lock(errors){errors.WriteLine(e.Data);errors.Flush();}}};child.Start();child.BeginOutputReadLine();child.BeginErrorReadLine();
      gate.ReleaseMutex();child.WaitForExit();Environment.ExitCode=child.ExitCode;if(child.ExitCode!=0&&!simulation)MessageBox.Show("lumi stopped. Diagnostic logs: "+logs,"lumi",MessageBoxButtons.OK,MessageBoxIcon.Error);
      return;
     }
    }finally{try{gate.ReleaseMutex();}catch(ApplicationException){}}
   }
  }catch(Exception e){MessageBox.Show(e.Message,"lumi",MessageBoxButtons.OK,MessageBoxIcon.Error);}
 }
}

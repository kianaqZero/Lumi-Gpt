using System;
using System.IO;
using System.Management;
using System.Diagnostics;
// Use the local Windows process provider instead of inheriting a caller's Job Object.
// No credentials or environment snapshot are passed through WMI.
public static class PetLifetimeBroker {
 public static int Start(string executable,string arguments,string directory) {
  executable=Path.GetFullPath(executable);directory=Path.GetFullPath(directory);
  if(!File.Exists(executable)||!Directory.Exists(directory)||executable.IndexOf('"')>=0)throw new InvalidOperationException("Invalid independent launch path");
  var startup=new ManagementClass("Win32_ProcessStartup").CreateInstance();
  try {
   startup["ShowWindow"]=(ushort)0;
   using(var processClass=new ManagementClass("Win32_Process"))using(var input=processClass.GetMethodParameters("Create")){
    input["CommandLine"]="\""+executable+"\""+(String.IsNullOrEmpty(arguments)?"":" "+arguments);
    input["CurrentDirectory"]=directory;input["ProcessStartupInformation"]=startup;
    using(var output=processClass.InvokeMethod("Create",input,null)){
     if(Convert.ToUInt32(output["ReturnValue"])!=0)throw new InvalidOperationException("Independent desktop launch rejected");
     int pid=checked((int)Convert.ToUInt32(output["ProcessId"]));if(pid<=0)throw new InvalidOperationException("Independent launch returned no process");
     using(var launched=Process.GetProcessById(pid))if(launched.SessionId!=Process.GetCurrentProcess().SessionId)throw new InvalidOperationException("Independent launch is outside the interactive user session");
     return pid;
    }
   }
  } finally {startup.Dispose();}
 }
}

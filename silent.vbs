' Silent launcher for probe-budget.ps1 (no console flash from the scheduled task)
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
  CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName) & _
  "\probe-budget.ps1""", 0, False

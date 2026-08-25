' Silent launcher for quota-tray.ps1 -- zero console flash (used by the desktop shortcut).
Dim shell, fso, dir
Set shell = CreateObject("Wscript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\quota-tray.ps1""", 0, False

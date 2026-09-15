' Start-Cockpit.vbs - launches the cockpit without any console window.
' (cmd.exe / powershell.exe would keep a console open; wscript.exe has none.)
Set sh = CreateObject("WScript.Shell")
dir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "Fabric-Cockpit.ps1""", 0, False

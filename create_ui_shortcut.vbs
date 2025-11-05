Dim W, FSO, repo, desk, L, icon
Set W   = CreateObject("WScript.Shell")
Set FSO = CreateObject("Scripting.FileSystemObject")

repo = FSO.GetAbsolutePathName(".")
desk = W.SpecialFolders("Desktop")

Set L = W.CreateShortcut(desk & "\JirehFaith SWP UI Launcher.lnk")
L.TargetPath = repo & "\Start_UI_Launcher.bat"
L.WorkingDirectory = repo

icon = ""
If FSO.FileExists(repo & "\assets\brand\top.ico") Then icon = repo & "\assets\brand\top.ico"
If icon = "" Then
  L.IconLocation = "%SystemRoot%\System32\shell32.dll,154"
Else
  L.IconLocation = icon
End If

L.WindowStyle = 7
L.Description = "Launch JirehFaith SWP UI"
L.Save

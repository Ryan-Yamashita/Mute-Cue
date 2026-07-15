Option Explicit

Dim shell, fileSystem, installRoot, currentPath, stream, releaseId, overlayPath, powershellPath, arguments, startupArgument, startedAtLogin
Set shell = CreateObject("Shell.Application")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
installRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
currentPath = fileSystem.BuildPath(installRoot, "current.txt")

If Not fileSystem.FileExists(currentPath) Then
    MsgBox "Mute Cue does not have an active installed version. Run the installer again.", vbCritical, "Mute Cue"
    WScript.Quit 1
End If

Set stream = fileSystem.OpenTextFile(currentPath, 1, False)
releaseId = Trim(stream.ReadLine)
stream.Close
If Len(releaseId) = 0 Or InStr(releaseId, "..") > 0 Or InStr(releaseId, "\") > 0 Or InStr(releaseId, "/") > 0 Or InStr(releaseId, ":") > 0 Then
    MsgBox "Mute Cue's active version marker is invalid. Run the installer again.", vbCritical, "Mute Cue"
    WScript.Quit 1
End If

overlayPath = fileSystem.BuildPath(fileSystem.BuildPath(fileSystem.BuildPath(installRoot, "versions"), releaseId), "BeacnMuteOverlay.ps1")
If Not fileSystem.FileExists(overlayPath) Then
    MsgBox "Mute Cue could not find the active application files. Run the installer again.", vbCritical, "Mute Cue"
    WScript.Quit 1
End If

powershellPath = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
startedAtLogin = False
For Each startupArgument In WScript.Arguments
    If LCase(Trim(CStr(startupArgument))) = "/startup" Then startedAtLogin = True
Next
arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & overlayPath & Chr(34) & " -StartupLauncherPath " & Chr(34) & WScript.ScriptFullName & Chr(34)
If startedAtLogin Then arguments = arguments & " -StartedAtLogin"
shell.ShellExecute powershellPath, arguments, fileSystem.GetParentFolderName(overlayPath), "open", 0

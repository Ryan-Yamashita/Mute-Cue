Option Explicit

Dim shell, fileSystem, scriptDir, overlayPath, powershellPath, arguments, startupArgument, startedAtLogin
Set shell = CreateObject("Shell.Application")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDir = fileSystem.GetParentFolderName(WScript.ScriptFullName)
overlayPath = fileSystem.BuildPath(scriptDir, "BeacnMuteOverlay.ps1")

If Not fileSystem.FileExists(overlayPath) Then
    MsgBox "Mute Cue could not find BeacnMuteOverlay.ps1.", vbCritical, "Mute Cue"
    WScript.Quit 1
End If

powershellPath = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
startedAtLogin = False
For Each startupArgument In WScript.Arguments
    If LCase(Trim(CStr(startupArgument))) = "/startup" Then startedAtLogin = True
Next
arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & overlayPath & Chr(34) & " -StartupLauncherPath " & Chr(34) & WScript.ScriptFullName & Chr(34)
If startedAtLogin Then arguments = arguments & " -StartedAtLogin"
shell.ShellExecute powershellPath, arguments, scriptDir, "open", 0

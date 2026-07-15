#define SourceDir GetEnv("MUTECUE_EXE_SOURCE")
#define OutputDir GetEnv("MUTECUE_EXE_OUTPUT")
#define AppVersion GetEnv("MUTECUE_EXE_VERSION")

[Setup]
AppId={{5A0EE8CF-044B-4E7C-8E76-EF10C5D0E94B}
AppName=Mute Cue
AppVersion={#AppVersion}
DefaultDirName={autopf}\Mute Cue
DefaultGroupName=Mute Cue
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDir}
OutputBaseFilename=MuteCue-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Mute Cue
Uninstallable=not IsSmokeTest
CreateUninstallRegKey=not IsSmokeTest

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: filesandordirs; Name: "{app}\versions"
Type: files; Name: "{app}\current.txt"
Type: files; Name: "{app}\current.txt.previous"
Type: files; Name: "{app}\install.json"
Type: files; Name: "{app}\Mute Cue.vbs"
Type: files; Name: "{app}\MuteCue.Startup.ps1"
Type: files; Name: "{app}\Uninstall Mute Cue.cmd"
Type: files; Name: "{app}\Uninstall-MuteCue.ps1"

[Icons]
Name: "{autoprograms}\Mute Cue"; Filename: "{app}\MuteCue.exe"
Name: "{autodesktop}\Mute Cue"; Filename: "{app}\MuteCue.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\MuteCue.exe"; Parameters: "--shutdown-for-update"; Flags: runhidden waituntilterminated runasoriginaluser; Check: ShouldRunMigrationHelper
Filename: "{app}\MuteCue.exe"; Description: "Launch Mute Cue"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function IsSmokeTest: Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount do
  begin
    if CompareText(ParamStr(Index), '/MUTECUE-SMOKE-TEST') = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function ShouldRunMigrationHelper: Boolean;
begin
  Result := not IsSmokeTest;
end;

#define SourceDir GetEnv("MUTECUE_EXE_SOURCE")
#define OutputDir GetEnv("MUTECUE_EXE_OUTPUT")
#define AppVersion GetEnv("MUTECUE_EXE_VERSION")

[Setup]
AppId={{5A0EE8CF-044B-4E7C-8E76-EF10C5D0E94B}
AppName=Mute Cue
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\MuteCue
DefaultGroupName=Mute Cue
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir={#OutputDir}
OutputBaseFilename=MuteCue-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayName=Mute Cue

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Mute Cue"; Filename: "{app}\MuteCue.exe"
Name: "{autodesktop}\Mute Cue"; Filename: "{app}\MuteCue.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Run]
Filename: "{app}\MuteCue.exe"; Description: "Launch Mute Cue"; Flags: nowait postinstall skipifsilent

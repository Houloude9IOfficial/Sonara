#define MyAppName "Sonara"
#ifndef MyAppVersion
#define MyAppVersion "1.0.0"
#endif
#define MyAppPublisher "Sonara"
#define MyAppExeName "sonara.exe"

[Setup]
AppId={{F5753FC4-986A-48AF-B85B-FE9D9D9BD1A7}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\Sonara
DefaultGroupName=Sonara
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=Sonara-{#MyAppVersion}-windows-x64-setup
SetupIconFile=..\..\apps\sonara\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\{#MyAppExeName}
VersionInfoVersion={#MyAppVersion}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "..\..\dist\Sonara-windows-x64-portable\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Sonara"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\Sonara"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch Sonara"; Flags: nowait postinstall skipifsilent

; Inno Setup script for Action Recorder (Windows).
; Build:  ISCC /DAppVersion=0.4.0 installer\ActionRecorder.iss   (after `dotnet publish` into artifacts\publish)
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6F2B1C0E-3D4A-4B7B-9A55-2F0C8E71D6A4}
AppName=Action Recorder
AppVersion={#AppVersion}
AppVerName=Action Recorder {#AppVersion}
AppPublisher=Action Recorder
AppPublisherURL=https://github.com/lucaslucas198/mac-action-recorder
AppSupportURL=https://github.com/lucaslucas198/mac-action-recorder/issues
DefaultDirName={autopf}\Action Recorder
DefaultGroupName=Action Recorder
DisableProgramGroupPage=yes
; Installs for the current user only, so no administrator prompt is needed and updates can run quietly.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\artifacts
OutputBaseFilename=ActionRecorder-Windows-Setup
SetupIconFile=..\src\ActionRecorder.App\Assets\app.ico
UninstallDisplayIcon={app}\ActionRecorder.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Action Recorder
VersionInfoDescription=Action Recorder setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "..\artifacts\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Action Recorder"; Filename: "{app}\ActionRecorder.exe"
Name: "{autodesktop}\Action Recorder"; Filename: "{app}\ActionRecorder.exe"; Tasks: desktopicon

[Run]
; Normal install: offer to open the app.
Filename: "{app}\ActionRecorder.exe"; Description: "Open Action Recorder"; Flags: nowait postinstall skipifsilent
; Quiet install (the in-app updater): open the app again automatically.
Filename: "{app}\ActionRecorder.exe"; Flags: nowait; Check: WizardSilent

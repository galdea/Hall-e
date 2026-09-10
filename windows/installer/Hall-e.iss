#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef PublishDir
  #define PublishDir "..\artifacts\publish\win-x64"
#endif
#ifndef OutputDir
  #define OutputDir "..\artifacts\release"
#endif

[Setup]
AppId={{73E8F867-FEB9-4C58-976C-9B653C832A61}
AppName=Hall-e
AppVersion={#AppVersion}
AppPublisher=IMBA
AppPublisherURL=https://hall-e.pages.dev
AppSupportURL=https://github.com/galdea/Hall-e/issues
AppUpdatesURL=https://hall-e.pages.dev
DefaultDirName={localappdata}\Programs\Hall-e
DefaultGroupName=Hall-e
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
OutputDir={#OutputDir}
OutputBaseFilename=Hall-e-{#AppVersion}-windows-x64-setup
SetupIconFile=..\HallE.Windows\Assets\hall-e.ico
UninstallDisplayIcon={app}\Hall-e.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile=..\..\LICENSE
CloseApplications=yes
RestartApplications=no
Uninstallable=yes
UninstallDisplayName=Hall-e

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Hall-e"; Filename: "{app}\Hall-e.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Hall-e"; Filename: "{app}\Hall-e.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Hall-e.exe"; Description: "{cm:LaunchProgram,Hall-e}"; Flags: nowait postinstall skipifsilent

; Deliberately no UninstallDelete entries: recordings, notes, and credentials
; live outside {app} and survive an uninstall or an in-place update.

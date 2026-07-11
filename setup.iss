[Setup]
AppName=Autonion Agent
AppVersion=2.0.4
DefaultDirName={autopf}\Autonion Agent
DefaultGroupName=Autonion
OutputBaseFilename=Autonion Agent
OutputDir=Output
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\autonion_cross_device.exe

[Dirs]
Name: "{commonappdata}\Autonion Agent\Unlock"; Permissions: users-modify

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "python\*"; DestDir: "{app}\python"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Autonion Agent"; Filename: "{app}\autonion_cross_device.exe"
Name: "{autodesktop}\Autonion Agent"; Filename: "{app}\autonion_cross_device.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Run]
Filename: "{cmd}"; Parameters: "/C schtasks /Create /TN ""Autonion Unlock Helper"" /SC ONDEMAND /RU SYSTEM /RL HIGHEST /TR """"{app}\autonion_unlock_helper.exe"" --request ""{commonappdata}\Autonion Agent\Unlock\request.json"" --status ""{commonappdata}\Autonion Agent\Unlock\status.json"""" /F"; Flags: runhidden
Filename: "{app}\autonion_cross_device.exe"; Description: "Launch Autonion Agent"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C schtasks /Delete /TN ""Autonion Unlock Helper"" /F"; Flags: runhidden

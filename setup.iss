[Setup]
AppName=Autonion Agent
AppVersion=2.0.5
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
Filename: "{cmd}"; Parameters: "/C schtasks /Delete /TN ""Autonion Unlock Helper"" /F"; Flags: runhidden waituntilterminated; StatusMsg: "Removing legacy unlock scheduled task..."
Filename: "{app}\autonion_unlock_helper.exe"; Parameters: "--install-service"; Flags: runhidden waituntilterminated; StatusMsg: "Installing unlock helper service..."
; Firewall rules for the native pre-login service (profile=any is critical for pre-login network state)
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (WebSocket)"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (mDNS In)"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (mDNS Out)"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (Service)"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Autonion Unlock Helper (WebSocket)"" dir=in action=allow protocol=TCP localport=4545 profile=any description=""Allows Android companion to connect to Autonion pre-login WebSocket"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Autonion Unlock Helper (mDNS In)"" dir=in action=allow protocol=UDP localport=5353 profile=any description=""Allows mDNS queries to reach Autonion pre-login service"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Autonion Unlock Helper (mDNS Out)"" dir=out action=allow protocol=UDP remoteport=5353 profile=any description=""Allows Autonion pre-login service to send mDNS announcements"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "netsh"; Parameters: "advfirewall firewall add rule name=""Autonion Unlock Helper (Service)"" dir=in action=allow profile=any program=""{app}\autonion_unlock_helper.exe"" description=""Allows all inbound connections to Autonion unlock helper service"""; Flags: runhidden waituntilterminated; StatusMsg: "Configuring firewall..."
Filename: "{app}\autonion_cross_device.exe"; Description: "Launch Autonion Agent"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\autonion_unlock_helper.exe"; Parameters: "--uninstall-service"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/C schtasks /Delete /TN ""Autonion Unlock Helper"" /F"; Flags: runhidden waituntilterminated
; Clean up firewall rules on uninstall
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (WebSocket)"""; Flags: runhidden waituntilterminated
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (mDNS In)"""; Flags: runhidden waituntilterminated
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (mDNS Out)"""; Flags: runhidden waituntilterminated
Filename: "netsh"; Parameters: "advfirewall firewall delete rule name=""Autonion Unlock Helper (Service)"""; Flags: runhidden waituntilterminated

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ProgramDataDir: String;
  LocalDataDir: String;
  RoamingDataDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    ProgramDataDir := ExpandConstant('{commonappdata}\Autonion Agent');
    LocalDataDir := ExpandConstant('{localappdata}\Autonion Agent');
    RoamingDataDir := ExpandConstant('{userappdata}\Autonion Agent');

    if DirExists(ProgramDataDir) or DirExists(LocalDataDir) or DirExists(RoamingDataDir) then
    begin
      if MsgBox('Do you want to keep your saved flows, unlock credentials, and application configuration for future reinstallations?' + #13#10#13#10 +
                '• Click "Yes" to KEEP your settings and credentials.' + #13#10 +
                '• Click "No" to REMOVE all configuration and saved data completely.',
                mbConfirmation, MB_YESNO or MB_DEFBUTTON1) = IDNO then
      begin
        if DirExists(ProgramDataDir) then
          DelTree(ProgramDataDir, True, True, True);
        if DirExists(LocalDataDir) then
          DelTree(LocalDataDir, True, True, True);
        if DirExists(RoamingDataDir) then
          DelTree(RoamingDataDir, True, True, True);
      end;
    end;
  end;
end;



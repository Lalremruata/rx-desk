; RxDesk — Windows installer (Inno Setup)
;
; Build the app first:
;   flutter build windows --release
; Then compile with installer\build_installer.ps1 (passes the app version from
; pubspec.yaml and the VC++ redistributable path/version).
;
; Output: build\installer\RxDesk-Setup-<version>.exe — a single self-contained
; file that also installs the Microsoft VC++ runtime when the PC lacks it.
;
; The app's database and backups live in the user's app-data folders, not in
; the install directory, so uninstalling never touches pharmacy records.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

; Path to vc_redist.x64.exe. build_installer.ps1 finds it in the Visual Studio
; install and passes /DVCRedist=... ; RxDesk and its printing plugin import
; MSVCP140 / VCRUNTIME140 / VCRUNTIME140_1, so the runtime is required.
#ifndef VCRedist
  #error "Pass /DVCRedist=<path to vc_redist.x64.exe> (build_installer.ps1 does this)"
#endif
; Minimum runtime version required (must be >= the MSVC toolset that built the app).
#ifndef VCRedistMinBld
  #define VCRedistMinMajor 14
  #define VCRedistMinMinor 51
  #define VCRedistMinBld   36247
#endif

#define AppName       "RxDesk"
#define AppPublisher  "RxDesk"
#define AppExeName    "rx_desk.exe"
#define BuildDir      "..\build\windows\x64\runner\Release"

[Setup]
; Do not change AppId between releases — it is how upgrades find the old install.
AppId={{3F8FF891-1EB4-488D-833F-3CEC7B4E0D98}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
SetupIconFile=..\windows\runner\resources\app_icon.ico
OutputDir=..\build\installer
OutputBaseFilename=RxDesk-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
MinVersion=10.0
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Extracted to a temp folder only if the runtime is missing/outdated; deleted after setup.
Source: "{#VCRedist}"; DestDir: "{tmp}"; DestName: "vc_redist.x64.exe"; Flags: deleteafterinstall; Check: VCRedistNeeded

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ Runtime..."; Flags: waituntilterminated; Check: VCRedistNeeded
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
var
  VCRedistChecked, VCRedistNeededResult: Boolean;

// True when the x64 VC++ 2015-2022+ runtime is absent or older than required.
function VCRedistNeeded: Boolean;
var
  Installed, Major, Minor, Bld: Cardinal;
  Key: String;
begin
  if not VCRedistChecked then
  begin
    Key := 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64';
    VCRedistNeededResult := True;
    if RegQueryDWordValue(HKLM64, Key, 'Installed', Installed) and (Installed = 1) and
       RegQueryDWordValue(HKLM64, Key, 'Major', Major) and
       RegQueryDWordValue(HKLM64, Key, 'Minor', Minor) and
       RegQueryDWordValue(HKLM64, Key, 'Bld', Bld) then
    begin
      if (Major > {#VCRedistMinMajor}) or
         ((Major = {#VCRedistMinMajor}) and (Minor > {#VCRedistMinMinor})) or
         ((Major = {#VCRedistMinMajor}) and (Minor = {#VCRedistMinMinor}) and (Bld >= {#VCRedistMinBld})) then
        VCRedistNeededResult := False;
    end;
    VCRedistChecked := True;
  end;
  Result := VCRedistNeededResult;
end;

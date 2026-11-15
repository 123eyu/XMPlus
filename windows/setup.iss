#ifndef AppVersion
  #error AppVersion must be supplied by tool/build_windows.ps1
#endif
#ifndef RuntimeDirectory
  #error RuntimeDirectory must be the verified dist runtime directory
#endif
#ifndef PackageOutputDirectory
  #error PackageOutputDirectory must be supplied by tool/build_windows.ps1
#endif

[Setup]
AppId={{684378F5-16A1-4C9A-BA9F-71D6709188B0}
AppName=XMPlus
AppVersion={#AppVersion}
AppPublisher=XMPlus contributors
AppPublisherURL=https://github.com/teikengstudio/XMPlus
AppSupportURL=https://github.com/teikengstudio/XMPlus/issues
DefaultDirName={localappdata}\Programs\XMPlus
DefaultGroupName=XMPlus
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
UsePreviousAppDir=yes
Uninstallable=not IsPortableUpdate
UninstallDisplayIcon={app}\XMPlus.exe
OutputDir={#PackageOutputDirectory}
OutputBaseFilename=XMPlus-{#AppVersion}-windows-x64-setup
SetupIconFile=runner\resources\app_icon.ico
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no

[Languages]
#if FileExists(AddBackslash(CompilerPath) + "Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#else
Name: "chinesesimplified"; MessagesFile: "runner\resources\ChineseSimplified.isl"
#endif
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked; Check: not IsPortableUpdate

[Files]
Source: "{#RuntimeDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\XMPlus"; Filename: "{app}\XMPlus.exe"; WorkingDir: "{app}"; Check: not IsPortableUpdate
Name: "{autodesktop}\XMPlus"; Filename: "{app}\XMPlus.exe"; WorkingDir: "{app}"; Tasks: desktopicon; Check: not IsPortableUpdate

[Run]
Filename: "{app}\XMPlus.exe"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,XMPlus}"; Flags: nowait postinstall skipifsilent runasoriginaluser; Check: not IsAppUpdate
Filename: "{app}\XMPlus.exe"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Check: IsAppUpdate

[CustomMessages]
english.UpdateWindowMissing=Cannot find the XMPlus window. Close XMPlus and run the installer again.
chinesesimplified.UpdateWindowMissing=未找到 XMPlus 窗口，请退出应用后重新安装。
english.UpdateWaitFailed=XMPlus did not exit. Close XMPlus and retry the update.
chinesesimplified.UpdateWaitFailed=XMPlus 尚未退出，请退出应用后重试。
english.UpdateDirectoryMismatch=The update destination does not match the running XMPlus application.
chinesesimplified.UpdateDirectoryMismatch=更新目录与当前应用不一致，请重新下载更新。

english.UpdateDirectoryUnavailable=Cannot write to the application directory. Close setup and choose a writable location.
chinesesimplified.UpdateDirectoryUnavailable=无法写入应用目录，请关闭安装程序后重试。
[Code]
function OpenProcess(Access: LongWord; Inherit: Boolean; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function GetWindowThreadProcessId(Window: HWND; var ProcessId: LongWord): LongWord;
  external 'GetWindowThreadProcessId@user32.dll stdcall';
function QueryFullProcessImageName(Process: THandle; Flags: LongWord; Name: String; var Size: LongWord): Boolean;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';
function CreateProbeFile(Name: String; Access, Share: LongWord; Security: THandle; Creation, Attributes: LongWord; Template: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';
function GetCurrentProcessId: LongWord;
  external 'GetCurrentProcessId@kernel32.dll stdcall';
function GetTickCount: LongWord;
  external 'GetTickCount@kernel32.dll stdcall';

function IsAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:UPDATE|0}') = '1';
end;

function IsPortableUpdate: Boolean;
begin
  Result := IsAppUpdate and (ExpandConstant('{param:PORTABLE|0}') = '1');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ProcessId, WindowProcessId, NameSize: LongWord;
  ProcessHandle, ProbeHandle: THandle;
  AppWindow: HWND;
  ImageName, Probe: String;
begin
  Result := '';
  if not IsAppUpdate then Exit;
  ProcessId := StrToIntDef(ExpandConstant('{param:UPDATEPID|0}'), 0);
  AppWindow := StrToInt64Def(ExpandConstant('{param:UPDATEHWND|0}'), 0);
  WindowProcessId := 0;
  GetWindowThreadProcessId(AppWindow, WindowProcessId);
  if (ProcessId = 0) or (WindowProcessId <> ProcessId) then begin
    Result := CustomMessage('UpdateWindowMissing');
    Exit;
  end;
  { SYNCHRONIZE and PROCESS_QUERY_LIMITED_INFORMATION; never terminate a process. }
  ProcessHandle := OpenProcess($00101000, False, ProcessId);
  if ProcessHandle = 0 then begin
    Result := CustomMessage('UpdateWindowMissing');
    Exit;
  end;
  try
    NameSize := 32768;
    SetLength(ImageName, NameSize);
    if not QueryFullProcessImageName(ProcessHandle, 0, ImageName, NameSize) then begin
      Result := CustomMessage('UpdateDirectoryMismatch');
      Exit;
    end;
    SetLength(ImageName, NameSize);
    if CompareText(ExpandFileName(ImageName), ExpandFileName(ExpandConstant('{app}\XMPlus.exe'))) <> 0 then begin
      Result := CustomMessage('UpdateDirectoryMismatch');
      Exit;
    end;
    Probe := ExpandConstant('{app}\.xmplus-update-write-') +
      IntToStr(GetCurrentProcessId) + '-' + IntToStr(GetTickCount) + '.tmp';
    { CREATE_NEW never overwrites an existing file; DELETE_ON_CLOSE removes only
      this probe, including if setup exits unexpectedly. }
    ProbeHandle := CreateProbeFile(Probe, $40000000, 0, 0, 1, $04000100, 0);
    if ProbeHandle = THandle(-1) then begin
      Result := CustomMessage('UpdateDirectoryUnavailable');
      Exit;
    end;
    if not CloseHandle(ProbeHandle) then begin
      Result := CustomMessage('UpdateDirectoryUnavailable');
      Exit;
    end;
    { Only after UAC and preparation succeed: Flutter performs normal shutdown,
      including its download confirmation and persistence, before files change. }
    PostMessage(AppWindow, $0010, $584D5055, 0);
    if WaitForSingleObject(ProcessHandle, 120000) <> 0 then
      Result := CustomMessage('UpdateWaitFailed');
  finally
    CloseHandle(ProcessHandle);
  end;
end;

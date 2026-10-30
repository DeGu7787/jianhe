; 笺盒 (JianHe) Windows 安装程序 — Inno Setup 6
; 构建前先执行 scripts\build_windows_release.ps1，
; 再用 ISCC 编译本脚本：ISCC.exe jianhe_installer.iss

#define MyAppName "笺盒"
#define MyAppNameEnglish "JianHe"
#define MyAppVersion "0.1.12"
#define MyAppPublisher "JianHe"
#define MyAppExeName "jianhe_desktop.exe"
#define MyAppId "DAA27BA4-A41E-4F82-9935-9F137FFA5469"

[Setup]
AppId={#MyAppId}
; 安装器语言即笺盒的界面语言：英文安装显示 JianHe，中文安装显示笺盒。
AppName={cm:AppDisplayName}
AppVersion={#MyAppVersion}
AppVerName={cm:AppDisplayName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppNameEnglish}
DefaultGroupName={cm:AppDisplayName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=JianHe-Setup-{#MyAppVersion}
OutputDir=..\dist
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 宿主窗口是 WS_EX_TOOLWINDOW|WS_EX_LAYERED 且应用多窗口（host + ball + orbit），
; Restart Manager 的 CloseApplications 无法可靠关闭它；统一走下方 [Code]
; 的 taskkill 流程（先优雅 WM_CLOSE 再强杀兜底）。
CloseApplications=no
RestartApplications=no
ChangesEnvironment=yes
; 每次手动安装都显示语言选择（默认按系统界面语言预选），所选语言会写入
; HKCU\Software\JianHe\InstallerLanguage，笺盒下次启动时据此切换界面语言。
; 关闭 UsePreviousLanguage，避免重装时沿用旧语言而跳过选择。
ShowLanguageDialog=yes
UsePreviousLanguage=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "translations\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[CustomMessages]
chinesesimplified.AppDisplayName={#MyAppName}
english.AppDisplayName={#MyAppNameEnglish}
chinesesimplified.UninstallShortcut=卸载{#MyAppName}
english.UninstallShortcut=Uninstall {#MyAppNameEnglish}
chinesesimplified.CliTaskGroup=外部 AI 接入
english.CliTaskGroup=External AI access
chinesesimplified.AddToPathTask=允许 Codex / Claude Code 等 AI 工具调用笺盒（将 JianHe CLI 添加到 PATH，安装后请重启这些工具或终端）
english.AddToPathTask=Let AI tools such as Codex / Claude Code use JianHe (adds JianHe CLI to PATH; restart those tools or your terminal after installing)
chinesesimplified.BackgroundSyncStopFailed=无法停用笺盒后台同步任务，请稍后重试安装。
english.BackgroundSyncStopFailed=Could not stop the JianHe background sync task. Please try installing again later.
chinesesimplified.DeleteUserDataPrompt=是否同时删除笺盒的本地数据（素材库、设置、备份与日志）？%n%n数据位置：%1%n%n删除后无法恢复，未开启云同步的数据将永久丢失。%n如果只是升级或重装并想保留数据，请选择"否"。
english.DeleteUserDataPrompt=Also delete JianHe's local data (library, settings, backups and logs)?%n%nData location: %1%n%nThis cannot be undone. Data that was not synced to the cloud will be lost permanently.%nIf you are only upgrading or reinstalling and want to keep your data, choose "No".
chinesesimplified.DeleteUserDataFailed=部分本地数据未能删除（可能仍有程序正在使用）。%n请关闭相关程序后手动删除该文件夹：%n%1
english.DeleteUserDataFailed=Some local data could not be deleted (it may still be in use).%nClose any programs using it and delete this folder manually:%n%1

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"
; 外部 AI（Codex / Claude Code 等）通过 PATH 上的 jianhe 命令接入笺盒，默认勾选。
; 不能用 checkedonce：它会在检测到已安装旧版本时把本项初始设为不勾选，
; 导致升级/重装时 PATH 不再写入。交互安装时 [Code] 的 CurPageChanged 还会再勾选一次。
Name: "addtopath"; Description: "{cm:AddToPathTask}"; GroupDescription: "{cm:CliTaskGroup}"

[Files]
Source: "..\build\windows\x64\runner\Release\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\cli\bundle\bin\jianhe.exe"; DestDir: "{app}\cli\bin"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\cli\bundle\lib\sqlite3.dll"; DestDir: "{app}\cli\lib"; Flags: ignoreversion
; 收集 Flutter 及所有 Windows 插件 DLL，避免新增插件后安装包遗漏运行库。
Source: "..\build\windows\x64\runner\Release\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\native_assets.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "..\build\windows\x64\runner\Release\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 换语言重装时，移除另一种语言留下的快捷方式（快捷方式名随安装语言变化）。
Type: files; Name: "{autoprograms}\{#MyAppNameEnglish}.lnk"; Languages: chinesesimplified
Type: files; Name: "{autoprograms}\Uninstall {#MyAppNameEnglish}.lnk"; Languages: chinesesimplified
Type: files; Name: "{autodesktop}\{#MyAppNameEnglish}.lnk"; Languages: chinesesimplified
Type: files; Name: "{autoprograms}\{#MyAppName}.lnk"; Languages: english
Type: files; Name: "{autoprograms}\卸载{#MyAppName}.lnk"; Languages: english
Type: files; Name: "{autodesktop}\{#MyAppName}.lnk"; Languages: english

[Icons]
Name: "{autoprograms}\{cm:AppDisplayName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autoprograms}\{cm:UninstallShortcut}"; Filename: "{uninstallexe}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{cm:AppDisplayName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{cm:AppDisplayName}}"; Flags: nowait postinstall skipifsilent
; 应用内自动更新以 /VERYSILENT /JIANHEUPDATE 启动安装包：静默安装会跳过上面那条，
; 这里在安装完成后重新打开笺盒（同时恢复安装开始时注销的后台同步任务）。
Filename: "{app}\{#MyAppExeName}"; Flags: nowait; Check: IsJianHeUpdate

[Code]
var
  AddToPathTaskPreselected: Boolean;

const
  JianHeRegistryKey = 'Software\JianHe';
  // 与 windows/runner/main.cpp 的 kJianHeForegroundInstanceMutex 一致。
  JianHeForegroundMutex = 'Local\JianHeDesktop-{#MyAppId}';

// 应用内自动更新传入 /JIANHEUPDATE（见 lib/features/app_update）。
function IsJianHeUpdate(): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/JIANHEUPDATE') = 0 then begin
      Result := True;
      Exit;
    end;
end;

// 自动更新时安装包由笺盒自身启动，笺盒随后正常退出（先保存未保存的草稿）。
// 等它退出再动文件，最多等 30 秒。
procedure WaitForJianHeToExit();
var
  I: Integer;
begin
  for I := 1 to 120 do begin
    if not CheckForMutexes(JianHeForegroundMutex) then
      Exit;
    Sleep(250);
  end;
  Log('JianHe did not exit within 30 seconds; closing it.');
end;

function UserPathContains(const Candidate: String): Boolean;
var
  CurrentPath: String;
begin
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', CurrentPath) then
    CurrentPath := '';
  Result := Pos(';' + Uppercase(Candidate) + ';',
                ';' + Uppercase(CurrentPath) + ';') > 0;
end;

procedure RemoveJianHeFromUserPath(); forward;

procedure AddJianHeToUserPath();
var
  CurrentPath: String;
  AppPath: String;
  AddedByInstaller: Cardinal;
begin
  if RegQueryDWordValue(HKCU, JianHeRegistryKey,
                        'InstallerAddedToPath', AddedByInstaller) and
     (AddedByInstaller = 1) then
    RemoveJianHeFromUserPath();
  AppPath := ExpandConstant('{app}\cli\bin');
  if UserPathContains(AppPath) then
    Exit;
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', CurrentPath) then
    CurrentPath := '';
  if (CurrentPath <> '') and (CurrentPath[Length(CurrentPath)] <> ';') then
    CurrentPath := CurrentPath + ';';
  RegWriteExpandStringValue(HKCU, 'Environment', 'Path', CurrentPath + AppPath);
  RegWriteDWordValue(HKCU, JianHeRegistryKey, 'InstallerAddedToPath', 1);
end;

procedure RemoveJianHeFromUserPath();
var
  CurrentPath: String;
  AppPath: String;
  LegacyAppPath: String;
  AddedByInstaller: Cardinal;
  Parts: TStringList;
  I: Integer;
begin
  if not RegQueryDWordValue(HKCU, JianHeRegistryKey,
                           'InstallerAddedToPath', AddedByInstaller) then
    Exit;
  if AddedByInstaller <> 1 then
    Exit;
  if not RegQueryStringValue(HKCU, 'Environment', 'Path', CurrentPath) then
    Exit;
  AppPath := ExpandConstant('{app}\cli\bin');
  LegacyAppPath := ExpandConstant('{app}');
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ';';
    Parts.QuoteChar := #0;
    Parts.DelimitedText := CurrentPath;
    for I := Parts.Count - 1 downto 0 do
      if (CompareText(Trim(Parts[I]), AppPath) = 0) or
         (CompareText(Trim(Parts[I]), LegacyAppPath) = 0) then
        Parts.Delete(I);
    RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Parts.DelimitedText);
    RegDeleteValue(HKCU, JianHeRegistryKey, 'InstallerAddedToPath');
  finally
    Parts.Free;
  end;
end;

// 悬浮球常驻运行时会锁住 exe/dll，不结束进程卸载就删不掉文件。
// 先发 WM_CLOSE 让 Flutter/SQLite 正常退出落盘，超时再强制结束兜底。
// CLI（jianhe.exe，常被 Codex 等工具调用）同样会锁住自身文件和 jianhe.db，
// 它是控制台程序、不响应 WM_CLOSE，直接结束；SQLite WAL 可安全承受进程中断。
// 自动更新时安装包是笺盒启动的子进程：带 /T 会按进程树把安装包自己也结束，
// 所以更新模式只结束 jianhe_desktop.exe 本身。
procedure KillRunningJianHe();
var
  ResultCode: Integer;
  TreeFlag: String;
begin
  if IsJianHeUpdate() then
    TreeFlag := ''
  else
    TreeFlag := ' /T';
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM jianhe_desktop.exe' + TreeFlag,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Sleep(3000);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM jianhe_desktop.exe /F' + TreeFlag,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM jianhe.exe /F /T',
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

// 用户数据（jianhe.db 及 -wal/-shm、迁移备份、error.log 等）位于
// %APPDATA%\JianHe，不在 {app} 内，Inno Setup 默认卸载不会删除它，
// 导致"卸载后重装"仍打开旧库。这里由用户选择是否一并删除，默认保留。
// 静默卸载（/SILENT、/VERYSILENT）一律保留，避免脚本化卸载误删数据。
procedure DeleteUserDataIfRequested();
var
  DataDir: String;
begin
  DataDir := ExpandConstant('{userappdata}\{#MyAppNameEnglish}');
  if not DirExists(DataDir) then
    Exit;
  if UninstallSilent() then
    Exit;
  if MsgBox(FmtMessage(CustomMessage('DeleteUserDataPrompt'), [DataDir]),
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) <> IDYES then
    Exit;
  if not DelTree(DataDir, True, True, True) then
    MsgBox(FmtMessage(CustomMessage('DeleteUserDataFailed'), [DataDir]),
           mbError, MB_OK);
  RegDeleteKeyIncludingSubkeys(HKCU, JianHeRegistryKey);
end;

function RemoveBackgroundSyncTask(): Boolean;
var
  ResultCode: Integer;
  ExePath: String;
begin
  ExePath := ExpandConstant('{app}\jianhe_desktop.exe');
  if not FileExists(ExePath) then begin
    Result := True;
    Exit;
  end;
  Result := Exec(ExePath, '--unregister-background-sync --silent',
                 ExpandConstant('{app}'), SW_HIDE,
                 ewWaitUntilTerminated, ResultCode) and (ResultCode = 0);
end;

function InstalledVersionSupportsBackgroundSync(): Boolean;
var
  Supported: Cardinal;
begin
  Result := RegQueryDWordValue(HKCU, JianHeRegistryKey,
                               'BackgroundSyncTaskSupport', Supported) and
            (Supported = 1);
end;

// UsePreviousTasks 默认开启：上次安装取消过"添加到 PATH"的用户，重装时会
// 沿用"不勾选"。外部 AI 接入依赖它，所以交互安装首次进入任务页时强制勾选
// （只做一次，用户返回上一步再进来时保留其手动选择）。静默安装/自动更新
// 不显示该页，仍沿用上次选择，不擅自改动用户环境。
procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpSelectTasks) and (not AddToPathTaskPreselected) then begin
    WizardSelectTasks('addtopath');
    AddToPathTaskPreselected := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then begin
    if IsJianHeUpdate() then
      WaitForJianHeToExit();
    // Disable the trigger before killing the current process, otherwise a
    // 15-minute task can relaunch it while setup is replacing exe/dll files.
    // Pre-feature releases do not understand the unregister switch and would
    // launch normally, so only invoke it for a version that wrote the marker.
    if InstalledVersionSupportsBackgroundSync() and
       (not RemoveBackgroundSyncTask()) then
      RaiseException(CustomMessage('BackgroundSyncStopFailed'));
    KillRunningJianHe();
  end;
  if CurStep = ssPostInstall then begin
    RegWriteDWordValue(HKCU, JianHeRegistryKey,
                       'BackgroundSyncTaskSupport', 1);
    // 手动安装时用户在语言对话框里做了选择，交给笺盒作为界面语言（见
    // windows/runner/installer_language_handoff.cpp，启动时读取后删除）。
    // 自动更新和脚本化静默安装没有经过选择，不改动用户在应用内的设置。
    if (not IsJianHeUpdate()) and (not WizardSilent()) then
      RegWriteStringValue(HKCU, JianHeRegistryKey, 'InstallerLanguage',
                          ActiveLanguage());
    if WizardIsTaskSelected('addtopath') then
      AddJianHeToUserPath();
  end;
end;

procedure CurUninstallStepChanged(CurStep: TUninstallStep);
begin
  if CurStep = usUninstall then begin
    // Remove the trigger first so it cannot relaunch the process between
    // taskkill and file deletion. Uninstall still proceeds on cleanup error.
    if not RemoveBackgroundSyncTask() then
      Log('Failed to remove the JianHe background sync task.');
    KillRunningJianHe();
    RegDeleteValue(HKCU, JianHeRegistryKey, 'BackgroundSyncTaskSupport');
    RegDeleteValue(HKCU, JianHeRegistryKey, 'BackgroundSyncPending');
    RegDeleteValue(HKCU, JianHeRegistryKey, 'InstallerLanguage');
    RemoveJianHeFromUserPath();
  end;
  if CurStep = usPostUninstall then
    DeleteUserDataIfRequested();
end;

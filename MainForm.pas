unit MainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ComCtrls, StdCtrls,
  ExtCtrls, Menus, Registry, IniFiles, MMSystem, TypInfo, LCLType,
  NetworkTypes, Utilities, DiscoveryManager, MessageManager, FileTransferManager;

type

  { TFormMain }

  TFormMain = class(TForm)
    ButtonAttach: TButton;
    ButtonSend: TButton;
    CheckBoxStartStartup: TCheckBox;
    CheckBoxStartMinimized: TCheckBox;
    CheckBoxMinimizeClose: TCheckBox;
    CheckBoxSounds: TCheckBox;
    EditMessage: TEdit;
    GroupBoxSettings: TGroupBox;
    lblTransfers: TLabel;
    lblChat: TLabel;
    lblUsers: TLabel;
    ListViewUsers: TListView;
    ListViewTransfers: TListView;
    MemoChat: TMemo;
    MenuExit: TMenuItem;
    MenuRestore: TMenuItem;
    OpenDialog: TOpenDialog;
    PanelLeft: TPanel;
    PanelRight: TPanel;
    PanelInput: TPanel;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    StatusBar: TStatusBar;
    TrayIcon: TTrayIcon;
    TrayPopupMenu: TPopupMenu;
    procedure ButtonAttachClick(Sender: TObject);
    procedure ButtonSendClick(Sender: TObject);
    procedure CheckBoxStartStartupChange(Sender: TObject);
    procedure EditMessageKeyPress(Sender: TObject; var Key: Char);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuRestoreClick(Sender: TObject);
    procedure TrayIconDblClick(Sender: TObject);
  private
    FDiscovery: TDiscoveryManager;
    FMessage: TMessageManager;
    FTransfer: TFileTransferManager;
    FClosingFromTray: Boolean;
    FFirstShow: Boolean;

    { Settings load/save }
    procedure LoadSettings;
    procedure SaveSettings;
    procedure SetStartupRegistry(const Enable: Boolean);
    function GetStartupRegistry: Boolean;
    procedure PlayAlertSound;
    procedure SetTrayBalloonProperties(Tray: TTrayIcon; const ATitle, AText: string);

    { Thread-safe event handlers from managers }
    procedure OnUserJoined(const User: TOnlineUser);
    procedure OnUserLeft(const User: TOnlineUser);
    procedure OnUserListChanged(const Users: TUserList);
    procedure OnMessageReceived(const SenderName, IP, MsgText, Timestamp: string);
    procedure OnTransferProgress(const Progress: TTransferProgressRecord);
    
    procedure UpdateClientCount;
    procedure AppendToLog(const Msg: string);
  public
  end;

var
  FormMain: TFormMain;

implementation

{$R *.lfm}
{$R resource.rc}

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
var
  Png: TPortableNetworkGraphic;
  ResStream: TResourceStream;
begin
  Caption := 'LAN Broadcaster';
  FClosingFromTray := False;
  FFirstShow := True;
  
  { Load PNG from resource and set as Application Icon and Tray Icon }
  try
    if FindResource(HInstance, 'LANBROADCASTER_PNG', RT_RCDATA) <> 0 then
    begin
      Png := TPortableNetworkGraphic.Create;
      try
        ResStream := TResourceStream.Create(HInstance, 'LANBROADCASTER_PNG', RT_RCDATA);
        try
          Png.LoadFromStream(ResStream);
          Application.Icon.Assign(Png);
          TrayIcon.Icon.Assign(Png);
        finally
          ResStream.Free;
        end;
      finally
        Png.Free;
      end;
    end;
  except
    { Fallback if resource fails to load }
  end;
  
  { Initialize networking managers }
  FDiscovery := TDiscoveryManager.Create;
  FDiscovery.OnUserJoined := @OnUserJoined;
  FDiscovery.OnUserLeft := @OnUserLeft;
  FDiscovery.OnUserListChanged := @OnUserListChanged;

  FMessage := TMessageManager.Create;
  FMessage.OnMessageReceived := @OnMessageReceived;

  FTransfer := TFileTransferManager.Create;
  FTransfer.OnProgress := @OnTransferProgress;

  { Populate status bar defaults }
  StatusBar.Panels[0].Text := 'Local IP: ' + GetLocalIPAddress;
  StatusBar.Panels[1].Text := 'Clients: 0';
  StatusBar.Panels[2].Text := 'Status: Initializing...';

  { Load settings and registry startup flag }
  LoadSettings;

  try
    FDiscovery.Start;
    FMessage.Start;
    FTransfer.Start;
    StatusBar.Panels[2].Text := 'Status: Online & Scanning';
  except
    on E: Exception do
    begin
      StatusBar.Panels[2].Text := 'Status: Error - ' + E.Message;
      ShowMessage('Error starting network listeners: ' + E.Message);
    end;
  end;

  AppendToLog('System started. Machine name: ' + GetLocalComputerName);
end;

procedure TFormMain.FormDestroy(Sender: TObject);
begin
  SaveSettings;

  { Stop and clean up managers }
  FDiscovery.Free;
  FMessage.Free;
  FTransfer.Free;
end;

procedure TFormMain.FormShow(Sender: TObject);
begin
  if FFirstShow then
  begin
    FFirstShow := False;
    if CheckBoxStartMinimized.Checked then
    begin
      { Start in Tray }
      Hide;
      TrayIcon.Visible := True;
      { Exclude from taskbar }
      Application.ShowMainForm := False;
    end;
  end;
end;

procedure TFormMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FClosingFromTray then
  begin
    CanClose := True;
  end;
  if not FClosingFromTray and CheckBoxMinimizeClose.Checked then
  begin
    CanClose := False;
    Hide;
    TrayIcon.Visible := True;
    { Setup tray properties dynamically at runtime via TypInfo to prevent version mismatches }
    SetTrayBalloonProperties(TrayIcon, 'LAN Broadcaster', 'Application is minimized to the system tray.');
    { Show a subtle balloon hint only once to notify user it is in the tray }
    TrayIcon.ShowBalloonHint;
  end;
end;

procedure TFormMain.MenuRestoreClick(Sender: TObject);
begin
  Show;
  WindowState := wsNormal;
  Application.BringToFront;
end;

procedure TFormMain.MenuExitClick(Sender: TObject);
begin
  FClosingFromTray := True;
  Close;
end;

procedure TFormMain.TrayIconDblClick(Sender: TObject);
begin
  MenuRestore.Click;
end;

procedure TFormMain.CheckBoxStartStartupChange(Sender: TObject);
begin
  try
    SetStartupRegistry(CheckBoxStartStartup.Checked);
  except
    on E: Exception do
      ShowMessage('Could not update startup registry settings: ' + E.Message);
  end;
end;

procedure TFormMain.LoadSettings;
var
  Ini: TIniFile;
  IniPath: string;
begin
  IniPath := ChangeFileExt(ParamStr(0), '.ini');
  Ini := TIniFile.Create(IniPath);
  try
    CheckBoxStartMinimized.Checked := Ini.ReadBool('Settings', 'StartMinimized', False);
    CheckBoxMinimizeClose.Checked := Ini.ReadBool('Settings', 'MinimizeOnClose', True);
    CheckBoxSounds.Checked := Ini.ReadBool('Settings', 'EnableSounds', True);
  finally
    Ini.Free;
  end;

  { Registry startup value status }
  try
    CheckBoxStartStartup.Checked := GetStartupRegistry;
  except
    CheckBoxStartStartup.Checked := False;
  end;
end;

procedure TFormMain.SaveSettings;
var
  Ini: TIniFile;
  IniPath: string;
begin
  IniPath := ChangeFileExt(ParamStr(0), '.ini');
  Ini := TIniFile.Create(IniPath);
  try
    Ini.WriteBool('Settings', 'StartMinimized', CheckBoxStartMinimized.Checked);
    Ini.WriteBool('Settings', 'MinimizeOnClose', CheckBoxMinimizeClose.Checked);
    Ini.WriteBool('Settings', 'EnableSounds', CheckBoxSounds.Checked);
  finally
    Ini.Free;
  end;
end;

procedure TFormMain.SetStartupRegistry(const Enable: Boolean);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_WRITE);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKey('Software\Microsoft\Windows\CurrentVersion\Run', True) then
    begin
      if Enable then
        Reg.WriteString('LANBroadcaster', '"' + ParamStr(0) + '"')
      else
        Reg.DeleteValue('LANBroadcaster');
    end;
  finally
    Reg.Free;
  end;
end;

function TFormMain.GetStartupRegistry: Boolean;
var
  Reg: TRegistry;
begin
  Result := False;
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := HKEY_CURRENT_USER;
    if Reg.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Run') then
    begin
      Result := Reg.ValueExists('LANBroadcaster');
    end;
  finally
    Reg.Free;
  end;
end;

procedure TFormMain.PlayAlertSound;
begin
  if CheckBoxSounds.Checked then
  begin
    { Plays standard Windows sound asynchronously }
    PlaySound('SystemNotification', 0, SND_ALIAS or SND_ASYNC or SND_NODEFAULT);
  end;
end;

procedure TFormMain.ButtonSendClick(Sender: TObject);
var
  MsgText: string;
  Users: TUserList;
begin
  MsgText := Trim(EditMessage.Text);
  if MsgText = '' then Exit;

  Users := FDiscovery.GetUsersSnapshot;
  if Length(Users) = 0 then
  begin
    AppendToLog('No online clients found to send message.');
    Exit;
  end;

  FMessage.BroadcastMessage(MsgText, Users);
  AppendToLog('[' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '] (You): ' + MsgText);
  EditMessage.Clear;
  EditMessage.SetFocus;
end;

procedure TFormMain.ButtonAttachClick(Sender: TObject);
var
  Users: TUserList;
begin
  Users := FDiscovery.GetUsersSnapshot;
  if Length(Users) = 0 then
  begin
    ShowMessage('No online clients found to send file.');
    Exit;
  end;

  if OpenDialog.Execute then
  begin
    FTransfer.BroadcastFile(OpenDialog.FileName, Users);
    AppendToLog('Initiating broadcast of file: ' + ExtractFileName(OpenDialog.FileName));
  end;
end;

procedure TFormMain.EditMessageKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then { Enter Key }
  begin
    Key := #0;
    ButtonSend.Click;
  end;
end;

procedure TFormMain.OnUserJoined(const User: TOnlineUser);
begin
  AppendToLog('*** User came Online: ' + User.ComputerName + ' (' + User.IPAddress + ') ***');
  PlayAlertSound;
end;

procedure TFormMain.OnUserLeft(const User: TOnlineUser);
begin
  AppendToLog('*** User went Offline: ' + User.ComputerName + ' (' + User.IPAddress + ') ***');
  PlayAlertSound;
end;

procedure TFormMain.OnUserListChanged(const Users: TUserList);
var
  I: Integer;
  Item: TListItem;
begin
  ListViewUsers.Items.BeginUpdate;
  try
    ListViewUsers.Items.Clear;
    for I := 0 to High(Users) do
    begin
      Item := ListViewUsers.Items.Add;
      Item.Caption := Users[I].ComputerName;
      Item.SubItems.Add(Users[I].IPAddress);
      Item.SubItems.Add('Online');
    end;
  finally
    ListViewUsers.Items.EndUpdate;
  end;

  UpdateClientCount;
end;

procedure TFormMain.OnMessageReceived(const SenderName, IP, MsgText, Timestamp: string);
begin
  AppendToLog('[' + Timestamp + '] ' + SenderName + ' (' + IP + '): ' + MsgText);
  PlayAlertSound;
end;

procedure TFormMain.OnTransferProgress(const Progress: TTransferProgressRecord);
var
  I: Integer;
  Item: TListItem;
  Found: Boolean;
  Perc: Double;
  PercStr: string;
  DirectionStr: string;
begin
  Found := False;
  Item := nil;

  { Locate existing transfer row in list view }
  for I := 0 to ListViewTransfers.Items.Count - 1 do
  begin
    if ListViewTransfers.Items[I].Caption = Progress.TransferID then
    begin
      Item := ListViewTransfers.Items[I];
      Found := True;
      Break;
    end;
  end;

  { Add new row if not found }
  if not Found then
  begin
    Item := ListViewTransfers.Items.Add;
    Item.Caption := Progress.TransferID;
    
    if Progress.TransferType = ttUpload then
      DirectionStr := 'Upload'
    else
      DirectionStr := 'Download';
      
    Item.SubItems.Add(DirectionStr);
    Item.SubItems.Add(Progress.FileName);
    Item.SubItems.Add(FormatBytes(Progress.FileSize));
    Item.SubItems.Add('0%');
    Item.SubItems.Add(Progress.Status);
    Item.SubItems.Add(Progress.RemoteName + ' (' + Progress.RemoteIP + ')');
  end;

  { Update values }
  PercStr := '0%';
  if Progress.FileSize > 0 then
  begin
    Perc := (Progress.BytesTransferred / Progress.FileSize) * 100;
    PercStr := Format('%.1f%%', [Perc]);
    if Progress.FileSize = Progress.BytesTransferred then
      PercStr := '100%';
  end;

  Item.SubItems[3] := PercStr; { Progress Column }
  
  { Trigger notification if status transitioned to Completed }
  if (Progress.Status = 'Completed') and (Item.SubItems[4] <> 'Completed') then
  begin
    if Progress.TransferType = ttDownload then
    begin
      PlayAlertSound;
      ShowMessage('New file received: ' + Progress.FileName);
    end;
  end;
  
  Item.SubItems[4] := Progress.Status; { Status Column }
end;

procedure TFormMain.SetTrayBalloonProperties(Tray: TTrayIcon; const ATitle, AText: string);
begin
  if IsPublishedProp(Tray, 'BalloonText') then
    SetPropValue(Tray, 'BalloonText', AText)
  else if IsPublishedProp(Tray, 'BaloonText') then
    SetPropValue(Tray, 'BaloonText', AText);

  if IsPublishedProp(Tray, 'BalloonTitle') then
    SetPropValue(Tray, 'BalloonTitle', ATitle)
  else if IsPublishedProp(Tray, 'BaloonTitle') then
    SetPropValue(Tray, 'BaloonTitle', ATitle);
    
  if IsPublishedProp(Tray, 'BalloonFlags') then
    SetEnumProp(Tray, 'BalloonFlags', 'bfInfo')
  else if IsPublishedProp(Tray, 'BaloonFlags') then
    SetEnumProp(Tray, 'BaloonFlags', 'bfInfo');
end;

procedure TFormMain.UpdateClientCount;
begin
  StatusBar.Panels[1].Text := 'Clients: ' + IntToStr(ListViewUsers.Items.Count);
end;

procedure TFormMain.AppendToLog(const Msg: string);
begin
  MemoChat.Lines.Add(Msg);
end;

end.

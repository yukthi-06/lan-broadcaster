unit FileTransferManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, WinSock2,
  NetworkTypes, Utilities;

type
  TFileTransferManager = class;

  { Helper class to safely dispatch progress events to the GUI thread }
  TProgressNotification = class
  private
    FProgress: TTransferProgressRecord;
    FEvent: TTransferProgressEvent;
  public
    constructor Create(const AProgress: TTransferProgressRecord; AEvent: TTransferProgressEvent);
    procedure Run;
  end;

  { Worker thread to handle a single file upload to a target client }
  TFileUploadThread = class(TThread)
  private
    FFilePath: string;
    FTargetIP: string;
    FTargetName: string;
    FTransferID: string;
    FOnProgress: TTransferProgressEvent;
    
    procedure UpdateProgress(BytesSent: Int64; const Status: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const AFilePath, ATargetIP, ATargetName: string; AProgressEvent: TTransferProgressEvent);
  end;

  { Worker thread to handle a single file download from a client connection }
  TFileDownloadThread = class(TThread)
  private
    FSocket: TSocket;
    FIP: string;
    FManager: TFileTransferManager;
  protected
    procedure Execute; override;
  public
    constructor Create(ASocket: TSocket; const AIP: string; AManager: TFileTransferManager);
  end;

  { Listener thread that binds to TCP 5002 and accepts incoming download connections }
  TFileListenerThread = class(TThread)
  private
    FManager: TFileTransferManager;
    FSocket: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(AManager: TFileTransferManager);
    destructor Destroy; override;
  end;

  { TFileTransferManager runs the TCP server for downloads and spawns threads for uploads }
  TFileTransferManager = class
  private
    FListenerThread: TFileListenerThread;
    FOnProgress: TTransferProgressEvent;
    FActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    { Spawns a background upload thread for each target user }
    procedure BroadcastFile(const FilePath: string; const Targets: TUserList);

    { Thread-safe helper to send download progress updates to MainForm }
    procedure UpdateDownloadProgress(const TransferID, FileName: string; FileSize, BytesRec: Int64; const PeerIP, SenderName, Status: string);

    property OnProgress: TTransferProgressEvent read FOnProgress write FOnProgress;
    property Active: Boolean read FActive;
  end;

implementation

{ Socket Line Helper Functions }

procedure SendLine(FSocket: TSocket; const Line: string);
var
  S: string;
begin
  S := Line + #10;
  send(FSocket, @S[1], Length(S), 0);
end;

function RecvLine(FSocket: TSocket): string;
var
  C: Char;
  Res: Integer;
begin
  Result := '';
  while True do
  begin
    Res := recv(FSocket, @C, 1, 0);
    if Res <= 0 then Break;
    if C = #10 then Break;
    if C <> #13 then
      Result := Result + C;
  end;
end;

{ TProgressNotification }

constructor TProgressNotification.Create(const AProgress: TTransferProgressRecord; AEvent: TTransferProgressEvent);
begin
  FProgress := AProgress;
  FEvent := AEvent;
end;

procedure TProgressNotification.Run;
begin
  try
    if Assigned(FEvent) then
      FEvent(FProgress);
  finally
    Free;
  end;
end;

{ TFileUploadThread }

constructor TFileUploadThread.Create(const AFilePath, ATargetIP, ATargetName: string; AProgressEvent: TTransferProgressEvent);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FFilePath := AFilePath;
  FTargetIP := ATargetIP;
  FTargetName := ATargetName;
  FOnProgress := AProgressEvent;
  FTransferID := 'UP_' + FTargetIP + '_' + ExtractFileName(AFilePath) + '_' + FormatDateTime('hhmmss', Now);
end;

procedure TFileUploadThread.UpdateProgress(BytesSent: Int64; const Status: string);
var
  Progress: TTransferProgressRecord;
  Notifier: TProgressNotification;
begin
  if not Assigned(FOnProgress) then Exit;

  Progress.TransferID := FTransferID;
  Progress.FileName := ExtractFileName(FFilePath);
  Progress.FileSize := 0;
  try
    if FileExists(FFilePath) then
    begin
      with TFileStream.Create(FFilePath, fmOpenRead or fmShareDenyNone) do
      try
        Progress.FileSize := Size;
      finally
        Free;
      end;
    end;
  except
    Progress.FileSize := 0;
  end;

  Progress.BytesTransferred := BytesSent;
  Progress.TransferType := ttUpload;
  Progress.RemoteIP := FTargetIP;
  Progress.RemoteName := FTargetName;
  Progress.Status := Status;

  Notifier := TProgressNotification.Create(Progress, FOnProgress);
  TThread.Queue(nil, @Notifier.Run);
end;

procedure TFileUploadThread.Execute;
var
  WSAData: TWSAData;
  ClientSocket: TSocket;
  Addr: TSockAddrIn;
  FileStream: TFileStream;
  Buffer: array[0..65535] of Byte; { 64KB buffer }
  BytesRead: Integer;
  TotalBytesSent: Int64;
  Header: string;
  FileName: string;
  FileSize: Int64;
  ACK: string;
begin
  UpdateProgress(0, 'Connecting');

  if WSAStartup($0101, WSAData) <> 0 then
  begin
    UpdateProgress(0, 'Failed: WinSock Init');
    Exit;
  end;

  FileStream := nil;
  ClientSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  try
    if ClientSocket = INVALID_SOCKET then
    begin
      UpdateProgress(0, 'Failed: Socket Creation');
      Exit;
    end;

    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(PORT_TCP_FILE);
    Addr.sin_addr.s_addr := inet_addr(PChar(FTargetIP));

    if connect(ClientSocket, @Addr, SizeOf(Addr)) = SOCKET_ERROR then
    begin
      UpdateProgress(0, 'Failed: Connection Refused');
      closesocket(ClientSocket);
      Exit;
    end;

    if Terminated then
    begin
      closesocket(ClientSocket);
      Exit;
    end;

    try
      FileStream := TFileStream.Create(FFilePath, fmOpenRead or fmShareDenyWrite);
    except
      UpdateProgress(0, 'Failed: Cannot Open File');
      closesocket(ClientSocket);
      Exit;
    end;

    FileName := ExtractFileName(FFilePath);
    FileSize := FileStream.Size;
    Header := 'FILE|' + GetLocalComputerName + '|' + FileName + '|' + IntToStr(FileSize);
    
    { Write announcement header }
    SendLine(ClientSocket, Header);

    { Wait for acknowledgement from the receiver }
    ACK := RecvLine(ClientSocket);
    if ACK <> 'ACK' then
    begin
      UpdateProgress(0, 'Failed: Rejected by Remote');
      closesocket(ClientSocket);
      Exit;
    end;

    UpdateProgress(0, 'Transferring');

    TotalBytesSent := 0;
    while (TotalBytesSent < FileSize) and not Terminated do
    begin
      BytesRead := FileStream.Read(Buffer[0], SizeOf(Buffer));
      if BytesRead <= 0 then Break;

      if send(ClientSocket, @Buffer[0], BytesRead, 0) = SOCKET_ERROR then
      begin
        UpdateProgress(TotalBytesSent, 'Failed: Network Send Error');
        closesocket(ClientSocket);
        Exit;
      end;
      
      TotalBytesSent := TotalBytesSent + BytesRead;
      UpdateProgress(TotalBytesSent, 'Transferring');
    end;

    if Terminated then
      UpdateProgress(TotalBytesSent, 'Failed: Cancelled')
    else
      UpdateProgress(TotalBytesSent, 'Completed');

    closesocket(ClientSocket);

  finally
    if Assigned(FileStream) then
      FileStream.Free;
    WSACleanup;
  end;
end;

{ TFileDownloadThread }

constructor TFileDownloadThread.Create(ASocket: TSocket; const AIP: string; AManager: TFileTransferManager);
begin
  inherited Create(True);
  FSocket := ASocket;
  FIP := AIP;
  FManager := AManager;
  FreeOnTerminate := True;
end;

procedure TFileDownloadThread.Execute;
var
  HeaderLine: string;
  Parts: TStringList;
  SenderName: string;
  FileName: string;
  FileSize: Int64;
  SavePath: string;
  FileStream: TFileStream;
  Buffer: array[0..65535] of Byte; { 64KB buffer }
  BytesToRead: Integer;
  BytesRead: Integer;
  BytesReceived: Int64;
  TransferID: string;
begin
  FileStream := nil;
  try
    HeaderLine := RecvLine(FSocket);
    if Pos('FILE|', HeaderLine) <> 1 then
    begin
      closesocket(FSocket);
      Exit;
    end;

    Parts := TStringList.Create;
    try
      Parts.Delimiter := '|';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := HeaderLine;

      if Parts.Count < 4 then
      begin
        closesocket(FSocket);
        Exit;
      end;

      SenderName := Parts[1];
      FileName := Parts[2];
      FileSize := StrToInt64Def(Parts[3], 0);
    finally
      Parts.Free;
    end;

    TransferID := 'DN_' + FIP + '_' + FileName + '_' + FormatDateTime('hhmmss', Now);

    EnsureReceivedFilesDir;
    SavePath := GetReceivedFilesDir + PathDelim + FileName;

    FManager.UpdateDownloadProgress(TransferID, FileName, FileSize, 0, FIP, SenderName, 'Transferring');

    { Acknowledge header receipt }
    SendLine(FSocket, 'ACK');

    try
      FileStream := TFileStream.Create(SavePath, fmCreate);
    except
      FManager.UpdateDownloadProgress(TransferID, FileName, FileSize, 0, FIP, SenderName, 'Failed: Save File Open');
      closesocket(FSocket);
      Exit;
    end;

    BytesReceived := 0;
    while BytesReceived < FileSize do
    begin
      if Terminated then Break;

      BytesToRead := SizeOf(Buffer);
      if (FileSize - BytesReceived) < BytesToRead then
        BytesToRead := FileSize - BytesReceived;

      BytesRead := recv(FSocket, @Buffer[0], BytesToRead, 0);
      if BytesRead <= 0 then
      begin
        FManager.UpdateDownloadProgress(TransferID, FileName, FileSize, BytesReceived, FIP, SenderName, 'Failed: Disconnected');
        closesocket(FSocket);
        Exit;
      end;

      FileStream.Write(Buffer[0], BytesRead);
      BytesReceived := BytesReceived + BytesRead;

      FManager.UpdateDownloadProgress(TransferID, FileName, FileSize, BytesReceived, FIP, SenderName, 'Transferring');
    end;

    if Terminated then
      FManager.UpdateDownloadProgress(TransferID, FileName, FileSize, BytesReceived, FIP, SenderName, 'Failed: Cancelled')
    else
      FManager.UpdateDownloadProgress(TransferID, FileName, FileSize, BytesReceived, FIP, SenderName, 'Completed');

    closesocket(FSocket);

  finally
    if Assigned(FileStream) then
      FileStream.Free;
  end;
end;

{ TFileListenerThread }

constructor TFileListenerThread.Create(AManager: TFileTransferManager);
begin
  inherited Create(True);
  FManager := AManager;
  FSocket := INVALID_SOCKET;
  FreeOnTerminate := False;
end;

destructor TFileListenerThread.Destroy;
begin
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  inherited Destroy;
end;

procedure TFileListenerThread.Execute;
var
  WSAData: TWSAData;
  Addr: TSockAddrIn;
  ClientAddr: TSockAddrIn;
  ClientSize: Integer;
  ClientSocket: TSocket;
  OptVal: Integer;
  PeerIP: string;
  ClientHandler: TFileDownloadThread;
begin
  if WSAStartup($0101, WSAData) <> 0 then Exit;

  try
    FSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if FSocket = INVALID_SOCKET then Exit;

    OptVal := 1;
    setsockopt(FSocket, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal));

    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(PORT_TCP_FILE);
    Addr.sin_addr.s_addr := INADDR_ANY;

    if bind(FSocket, @Addr, SizeOf(Addr)) = SOCKET_ERROR then Exit;
    if listen(FSocket, SOMAXCONN) = SOCKET_ERROR then Exit;

    while not Terminated do
    begin
      ClientSize := SizeOf(ClientAddr);
      ClientSocket := accept(FSocket, @ClientAddr, @ClientSize);
      
      if ClientSocket <> INVALID_SOCKET then
      begin
        if Terminated then
        begin
          closesocket(ClientSocket);
          Break;
        end;

        PeerIP := StrPas(inet_ntoa(ClientAddr.sin_addr));
        ClientHandler := TFileDownloadThread.Create(ClientSocket, PeerIP, FManager);
        ClientHandler.Start;
      end
      else
      begin
        Break;
      end;
    end;

  finally
    if FSocket <> INVALID_SOCKET then
    begin
      closesocket(FSocket);
      FSocket := INVALID_SOCKET;
    end;
    WSACleanup;
  end;
end;

{ TFileTransferManager }

constructor TFileTransferManager.Create;
begin
  FActive := False;
end;

destructor TFileTransferManager.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TFileTransferManager.Start;
begin
  if FActive then Exit;

  FActive := True;
  FListenerThread := TFileListenerThread.Create(Self);
  FListenerThread.Start;
end;

procedure TFileTransferManager.Stop;
begin
  if not FActive then Exit;

  FActive := False;
  if Assigned(FListenerThread) then
  begin
    FListenerThread.Terminate;
    if FListenerThread.FSocket <> INVALID_SOCKET then
      closesocket(FListenerThread.FSocket);
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
end;

procedure TFileTransferManager.BroadcastFile(const FilePath: string; const Targets: TUserList);
var
  I: Integer;
  UploadThread: TFileUploadThread;
begin
  if (not FileExists(FilePath)) or (Length(Targets) = 0) then Exit;

  for I := 0 to High(Targets) do
  begin
    UploadThread := TFileUploadThread.Create(FilePath, Targets[I].IPAddress, Targets[I].ComputerName, FOnProgress);
    UploadThread.Start;
  end;
end;

procedure TFileTransferManager.UpdateDownloadProgress(const TransferID, FileName: string; FileSize, BytesRec: Int64; const PeerIP, SenderName, Status: string);
var
  Progress: TTransferProgressRecord;
  Notifier: TProgressNotification;
begin
  if Assigned(FOnProgress) then
  begin
    Progress.TransferID := TransferID;
    Progress.FileName := FileName;
    Progress.FileSize := FileSize;
    Progress.BytesTransferred := BytesRec;
    Progress.TransferType := ttDownload;
    Progress.RemoteIP := PeerIP;
    Progress.RemoteName := SenderName;
    Progress.Status := Status;

    Notifier := TProgressNotification.Create(Progress, FOnProgress);
    TThread.Queue(nil, @Notifier.Run);
  end;
end;

end.

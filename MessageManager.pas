unit MessageManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, WinSock2,
  NetworkTypes, Utilities;

type
  TMessageManager = class;

  { Notification helper class to safely dispatch received messages to the GUI thread }
  TMessageNotification = class
  private
    FSenderName: string;
    FIP: string;
    FMsgText: string;
    FTimestamp: string;
    FEvent: TMessageEvent;
  public
    constructor Create(const ASender, AIP, AMsg, ATimestamp: string; AEvent: TMessageEvent);
    procedure Run;
  end;

  { Connection handler thread to receive a message from a connected socket }
  TMessageClientThread = class(TThread)
  private
    FSocket: TSocket;
    FIP: string;
    FManager: TMessageManager;
  protected
    procedure Execute; override;
  public
    constructor Create(ASocket: TSocket; const AIP: string; AManager: TMessageManager);
  end;

  { Listener thread that binds to TCP 5001 and accepts incoming client connections }
  TMessageListenerThread = class(TThread)
  private
    FManager: TMessageManager;
    FSocket: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(AManager: TMessageManager);
    destructor Destroy; override;
  end;

  { Worker thread to distribute messages to all online users in the background }
  TMessageSendThread = class(TThread)
  private
    FMessageLine: string;
    FTargetIPs: array of string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AMessageLine: string; const ATargets: array of string);
  end;

  { TMessageManager coordinates the TCP message listener server and client broadcasts }
  TMessageManager = class
  private
    FListenerThread: TMessageListenerThread;
    FOnMessageReceived: TMessageEvent;
    FActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    { Dispatches the sending thread to broadcast to the provided IP list }
    procedure BroadcastMessage(const MsgText: string; const Targets: TUserList);
    
    { Processes a received message line }
    procedure ProcessMessageLine(const Line: string; const PeerIP: string);

    property OnMessageReceived: TMessageEvent read FOnMessageReceived write FOnMessageReceived;
    property Active: Boolean read FActive;
  end;

implementation

{ TMessageNotification }

constructor TMessageNotification.Create(const ASender, AIP, AMsg, ATimestamp: string; AEvent: TMessageEvent);
begin
  FSenderName := ASender;
  FIP := AIP;
  FMsgText := AMsg;
  FTimestamp := ATimestamp;
  FEvent := AEvent;
end;

procedure TMessageNotification.Run;
begin
  try
    if Assigned(FEvent) then
      FEvent(FSenderName, FIP, FMsgText, FTimestamp);
  finally
    Free;
  end;
end;

{ TMessageClientThread }

constructor TMessageClientThread.Create(ASocket: TSocket; const AIP: string; AManager: TMessageManager);
begin
  inherited Create(True);
  FSocket := ASocket;
  FIP := AIP;
  FManager := AManager;
  FreeOnTerminate := True;
end;

procedure TMessageClientThread.Execute;
var
  Buffer: array[0..4095] of Char;
  BytesRead: Integer;
  Line: string;
begin
  BytesRead := recv(FSocket, @Buffer[0], SizeOf(Buffer) - 1, 0);
  if BytesRead > 0 then
  begin
    Buffer[BytesRead] := #0;
    Line := StrPas(Buffer);
    FManager.ProcessMessageLine(Line, FIP);
  end;
  closesocket(FSocket);
end;

{ TMessageListenerThread }

constructor TMessageListenerThread.Create(AManager: TMessageManager);
begin
  inherited Create(True);
  FManager := AManager;
  FSocket := INVALID_SOCKET;
  FreeOnTerminate := False;
end;

destructor TMessageListenerThread.Destroy;
begin
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  inherited Destroy;
end;

procedure TMessageListenerThread.Execute;
var
  WSAData: TWSAData;
  Addr: TSockAddrIn;
  ClientAddr: TSockAddrIn;
  ClientSize: Integer;
  ClientSocket: TSocket;
  OptVal: Integer;
  PeerIP: string;
  ClientHandler: TMessageClientThread;
begin
  if WSAStartup($0101, WSAData) <> 0 then Exit;

  try
    FSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if FSocket = INVALID_SOCKET then Exit;

    OptVal := 1;
    setsockopt(FSocket, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal));

    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(PORT_TCP_MESSAGE);
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
        ClientHandler := TMessageClientThread.Create(ClientSocket, PeerIP, FManager);
        ClientHandler.Start;
      end
      else
      begin
        { If accept fails because the socket was closed, exit the loop }
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

{ TMessageSendThread }

constructor TMessageSendThread.Create(const AMessageLine: string; const ATargets: array of string);
var
  I: Integer;
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FMessageLine := AMessageLine;
  
  SetLength(FTargetIPs, Length(ATargets));
  for I := 0 to High(ATargets) do
    FTargetIPs[I] := ATargets[I];
end;

procedure TMessageSendThread.Execute;
var
  WSAData: TWSAData;
  ClientSocket: TSocket;
  Addr: TSockAddrIn;
  I: Integer;
begin
  if WSAStartup($0101, WSAData) <> 0 then Exit;

  try
    for I := 0 to High(FTargetIPs) do
    begin
      if Terminated then Exit;

      ClientSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
      if ClientSocket <> INVALID_SOCKET then
      begin
        FillChar(Addr, SizeOf(Addr), 0);
        Addr.sin_family := AF_INET;
        Addr.sin_port := htons(PORT_TCP_MESSAGE);
        Addr.sin_addr.s_addr := inet_addr(PChar(FTargetIPs[I]));

        { Connect with a brief timeout structure if desired, or standard blocking connect }
        if connect(ClientSocket, @Addr, SizeOf(Addr)) = 0 then
        begin
          send(ClientSocket, @FMessageLine[1], Length(FMessageLine), 0);
        end;
        closesocket(ClientSocket);
      end;
    end;
  finally
    WSACleanup;
  end;
end;

{ TMessageManager }

constructor TMessageManager.Create;
begin
  FActive := False;
end;

destructor TMessageManager.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TMessageManager.Start;
begin
  if FActive then Exit;

  FActive := True;
  FListenerThread := TMessageListenerThread.Create(Self);
  FListenerThread.Start;
end;

procedure TMessageManager.Stop;
begin
  if not FActive then Exit;

  FActive := False;
  if Assigned(FListenerThread) then
  begin
    FListenerThread.Terminate;
    { Close socket to break blocking accept call }
    if FListenerThread.FSocket <> INVALID_SOCKET then
      closesocket(FListenerThread.FSocket);
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;
end;

procedure TMessageManager.BroadcastMessage(const MsgText: string; const Targets: TUserList);
var
  I: Integer;
  TargetIPs: array of string;
  MessageLine: string;
  SendThread: TMessageSendThread;
  TimeStr: string;
begin
  if Length(Targets) = 0 then Exit;

  TimeStr := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now);
  MessageLine := 'MSG|' + GetLocalComputerName + '|' + TimeStr + '|' + MsgText;

  SetLength(TargetIPs, Length(Targets));
  for I := 0 to High(Targets) do
    TargetIPs[I] := Targets[I].IPAddress;

  SendThread := TMessageSendThread.Create(MessageLine, TargetIPs);
  SendThread.Start;
end;

procedure TMessageManager.ProcessMessageLine(const Line: string; const PeerIP: string);
var
  Parts: TStringList;
  Notifier: TMessageNotification;
begin
  if Pos('MSG|', Line) = 1 then
  begin
    Parts := TStringList.Create;
    try
      Parts.Delimiter := '|';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := Line;

      if (Parts.Count >= 4) and Assigned(FOnMessageReceived) then
      begin
        Notifier := TMessageNotification.Create(
          Parts[1],     { MachineName }
          PeerIP,       { IP }
          Parts[3],     { MsgText }
          Parts[2],     { Timestamp }
          FOnMessageReceived
        );
        TThread.Queue(nil, @Notifier.Run);
      end;
    finally
      Parts.Free;
    end;
  end;
end;

end.

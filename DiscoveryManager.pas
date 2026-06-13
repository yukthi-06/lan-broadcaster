unit DiscoveryManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, DateUtils, WinSock2,
  NetworkTypes, Utilities;

type
  TDiscoveryManager = class;

  { Notification class to safely queue user join/left events to the main thread }
  TUserNotification = class
  private
    FUser: TOnlineUser;
    FEvent: TUserEvent;
  public
    constructor Create(const AUser: TOnlineUser; AEvent: TUserEvent);
    procedure Run;
  end;

  { Notification class to safely queue user list updates to the main thread }
  TUserListNotification = class
  private
    FUsers: TUserList;
    FEvent: TUserListEvent;
  public
    constructor Create(const AUsers: TUserList; AEvent: TUserListEvent);
    procedure Run;
  end;

  { Thread that listens for incoming UDP broadcast discovery heartbeats }
  TUDPListenerThread = class(TThread)
  private
    FManager: TDiscoveryManager;
    FSocket: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(AManager: TDiscoveryManager);
    destructor Destroy; override;
  end;

  { Thread that periodically broadcasts discovery heartbeats and triggers user pruning }
  TDiscoveryBroadcastThread = class(TThread)
  private
    FManager: TDiscoveryManager;
    FInterval: Integer;
    procedure SendOnlineHeartbeat(const TargetIP: string = '255.255.255.255');
  protected
    procedure Execute; override;
  public
    constructor Create(AManager: TDiscoveryManager; IntervalMS: Integer);
  end;

  TDiscoveryManager = class
  private
    FListenerThread: TUDPListenerThread;
    FBroadcastThread: TDiscoveryBroadcastThread;
    FUsers: TUserList;
    FLock: TCriticalSection;
    FActive: Boolean;

    FOnUserJoined: TUserEvent;
    FOnUserLeft: TUserEvent;
    FOnUserListChanged: TUserListEvent;

    procedure ProcessIncomingMsg(const Msg: string; const PeerIP: string);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    { Thread-safe verification and removal of inactive users (> 15 seconds) }
    procedure CheckExpiredUsers;

    { Returns a snapshot of the current user list }
    function GetUsersSnapshot: TUserList;
    
    { Explicitly broadcast a DISCOVER packet to request immediate status from peers }
    procedure BroadcastDiscover;

    property OnUserJoined: TUserEvent read FOnUserJoined write FOnUserJoined;
    property OnUserLeft: TUserEvent read FOnUserLeft write FOnUserLeft;
    property OnUserListChanged: TUserListEvent read FOnUserListChanged write FOnUserListChanged;
    property Active: Boolean read FActive;
  end;

implementation

{ TUserNotification }

constructor TUserNotification.Create(const AUser: TOnlineUser; AEvent: TUserEvent);
begin
  FUser := AUser;
  FEvent := AEvent;
end;

procedure TUserNotification.Run;
begin
  try
    if Assigned(FEvent) then
      FEvent(FUser);
  finally
    Free;
  end;
end;

{ TUserListNotification }

constructor TUserListNotification.Create(const AUsers: TUserList; AEvent: TUserListEvent);
begin
  FUsers := AUsers;
  FEvent := AEvent;
end;

procedure TUserListNotification.Run;
begin
  try
    if Assigned(FEvent) then
      FEvent(FUsers);
  finally
    Free;
  end;
end;

{ TUDPListenerThread }

constructor TUDPListenerThread.Create(AManager: TDiscoveryManager);
begin
  inherited Create(True);
  FManager := AManager;
  FSocket := INVALID_SOCKET;
  FreeOnTerminate := False;
end;

destructor TUDPListenerThread.Destroy;
begin
  if FSocket <> INVALID_SOCKET then
    closesocket(FSocket);
  inherited Destroy;
end;

procedure TUDPListenerThread.Execute;
var
  WSAData: TWSAData;
  Addr: TSockAddrIn;
  ClientAddr: TSockAddrIn;
  ClientSize: Integer;
  Buffer: array[0..2047] of Char;
  BytesRead: Integer;
  OptVal: Integer;
  Timeout: Integer;
  PeerIP: string;
  ReceivedStr: string;
begin
  if WSAStartup($0101, WSAData) <> 0 then Exit;

  try
    FSocket := socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if FSocket = INVALID_SOCKET then Exit;

    { Enable address reuse so multiple instances on same PC can bind to port 5000 }
    OptVal := 1;
    setsockopt(FSocket, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal));

    { Bind to Port 5000 }
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(PORT_UDP_DISCOVERY);
    Addr.sin_addr.s_addr := INADDR_ANY;

    if bind(FSocket, @Addr, SizeOf(Addr)) = SOCKET_ERROR then Exit;

    { Set 1 second timeout on receive so thread checks for termination regularly }
    Timeout := 1000;
    setsockopt(FSocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));

    while not Terminated do
    begin
      ClientSize := SizeOf(ClientAddr);
      BytesRead := recvfrom(FSocket, @Buffer[0], SizeOf(Buffer) - 1, 0, @ClientAddr, @ClientSize);
      
      if (BytesRead > 0) and not Terminated then
      begin
        Buffer[BytesRead] := #0;
        ReceivedStr := StrPas(Buffer);
        PeerIP := StrPas(inet_ntoa(ClientAddr.sin_addr));
        FManager.ProcessIncomingMsg(ReceivedStr, PeerIP);
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

{ TDiscoveryBroadcastThread }

constructor TDiscoveryBroadcastThread.Create(AManager: TDiscoveryManager; IntervalMS: Integer);
begin
  inherited Create(True);
  FManager := AManager;
  FInterval := IntervalMS;
  FreeOnTerminate := False;
end;

procedure TDiscoveryBroadcastThread.SendOnlineHeartbeat(const TargetIP: string);
var
  WSAData: TWSAData;
  FSocket: TSocket;
  Addr: TSockAddrIn;
  Msg: string;
  OptVal: Integer;
begin
  if WSAStartup($0101, WSAData) <> 0 then Exit;
  try
    FSocket := socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if FSocket = INVALID_SOCKET then Exit;

    try
      OptVal := 1;
      if TargetIP = '255.255.255.255' then
        setsockopt(FSocket, SOL_SOCKET, SO_BROADCAST, @OptVal, SizeOf(OptVal));

      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      Addr.sin_port := htons(PORT_UDP_DISCOVERY);
      Addr.sin_addr.s_addr := inet_addr(PChar(TargetIP));

      Msg := 'ONLINE|' + GetLocalComputerName + '|' + GetLocalIPAddress;
      sendto(FSocket, @Msg[1], Length(Msg), 0, @Addr, SizeOf(Addr));
    finally
      closesocket(FSocket);
    end;
  finally
    WSACleanup;
  end;
end;

procedure TDiscoveryBroadcastThread.Execute;
var
  SleepCount: Integer;
begin
  try
    FManager.BroadcastDiscover;
  except
  end;

  while not Terminated do
  begin
    SleepCount := 0;
    while (SleepCount < FInterval) and not Terminated do
    begin
      Sleep(100);
      Inc(SleepCount, 100);
    end;

    if Terminated then Exit;

    try
      SendOnlineHeartbeat('255.255.255.255');
      FManager.CheckExpiredUsers;
    except
    end;
  end;
end;

{ TDiscoveryManager }

constructor TDiscoveryManager.Create;
begin
  FLock := TCriticalSection.Create;
  FActive := False;
  SetLength(FUsers, 0);
end;

destructor TDiscoveryManager.Destroy;
begin
  Stop;
  FLock.Free;
  inherited Destroy;
end;

procedure TDiscoveryManager.Start;
begin
  if FActive then Exit;

  FActive := True;
  
  FListenerThread := TUDPListenerThread.Create(Self);
  FListenerThread.Start;

  FBroadcastThread := TDiscoveryBroadcastThread.Create(Self, 5000);
  FBroadcastThread.Start;
end;

procedure TDiscoveryManager.Stop;
begin
  if not FActive then Exit;

  FActive := False;

  if Assigned(FBroadcastThread) then
  begin
    FBroadcastThread.Terminate;
    FBroadcastThread.WaitFor;
    FreeAndNil(FBroadcastThread);
  end;

  if Assigned(FListenerThread) then
  begin
    FListenerThread.Terminate;
    FListenerThread.WaitFor;
    FreeAndNil(FListenerThread);
  end;

  FLock.Enter;
  try
    SetLength(FUsers, 0);
  finally
    FLock.Leave;
  end;
end;

procedure TDiscoveryManager.BroadcastDiscover;
var
  WSAData: TWSAData;
  FSocket: TSocket;
  Addr: TSockAddrIn;
  Msg: string;
  OptVal: Integer;
begin
  if WSAStartup($0101, WSAData) <> 0 then Exit;
  try
    FSocket := socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if FSocket = INVALID_SOCKET then Exit;

    try
      OptVal := 1;
      setsockopt(FSocket, SOL_SOCKET, SO_BROADCAST, @OptVal, SizeOf(OptVal));

      FillChar(Addr, SizeOf(Addr), 0);
      Addr.sin_family := AF_INET;
      Addr.sin_port := htons(PORT_UDP_DISCOVERY);
      Addr.sin_addr.s_addr := INADDR_BROADCAST;

      Msg := 'DISCOVER';
      sendto(FSocket, @Msg[1], Length(Msg), 0, @Addr, SizeOf(Addr));
    finally
      closesocket(FSocket);
    end;
  finally
    WSACleanup;
  end;
end;

procedure TDiscoveryManager.ProcessIncomingMsg(const Msg: string; const PeerIP: string);
var
  Parts: TStringList;
  I: Integer;
  UserFound: Boolean;
  NewUser: TOnlineUser;
  ListChanged: Boolean;
  UserJoined: Boolean;
  JoinedUser: TOnlineUser;
  Notifier: TUserNotification;
  ListNotifier: TUserListNotification;
begin
  { Ignore discovery loopback from ourselves }
  if PeerIP = GetLocalIPAddress then Exit;

  if Msg = 'DISCOVER' then
  begin
    try
      { Reply directly to peer }
      FBroadcastThread.SendOnlineHeartbeat(PeerIP);
    except
    end;
    Exit;
  end;

  if Pos('ONLINE|', Msg) = 1 then
  begin
    Parts := TStringList.Create;
    try
      Parts.Delimiter := '|';
      Parts.StrictDelimiter := True;
      Parts.DelimitedText := Msg;

      if Parts.Count >= 3 then
      begin
        NewUser.ComputerName := Parts[1];
        NewUser.IPAddress := Parts[2];
        NewUser.LastSeen := Now;

        ListChanged := False;
        UserJoined := False;

        FLock.Enter;
        try
          UserFound := False;
          for I := 0 to High(FUsers) do
          begin
            if FUsers[I].IPAddress = NewUser.IPAddress then
            begin
              FUsers[I].ComputerName := NewUser.ComputerName;
              FUsers[I].LastSeen := NewUser.LastSeen;
              UserFound := True;
              Break;
            end;
          end;

          if not UserFound then
          begin
            SetLength(FUsers, Length(FUsers) + 1);
            FUsers[High(FUsers)] := NewUser;
            ListChanged := True;
            UserJoined := True;
            JoinedUser := NewUser;
          end;
        finally
          FLock.Leave;
        end;

        if UserJoined and Assigned(FOnUserJoined) then
        begin
          Notifier := TUserNotification.Create(JoinedUser, FOnUserJoined);
          TThread.Queue(nil, @Notifier.Run);
        end;

        if ListChanged and Assigned(FOnUserListChanged) then
        begin
          ListNotifier := TUserListNotification.Create(GetUsersSnapshot, FOnUserListChanged);
          TThread.Queue(nil, @ListNotifier.Run);
        end;
      end;
    finally
      Parts.Free;
    end;
  end;
end;

procedure TDiscoveryManager.CheckExpiredUsers;
var
  I, J: Integer;
  NowTime: TDateTime;
  ListChanged: Boolean;
  LeftUsers: array of TOnlineUser;
  CurrentSnapshot: TUserList;
  Notifier: TUserNotification;
  ListNotifier: TUserListNotification;
begin
  NowTime := Now;
  ListChanged := False;
  SetLength(LeftUsers, 0);

  FLock.Enter;
  try
    I := 0;
    while I < Length(FUsers) do
    begin
      { Prune user if no heartbeat received for > 15 seconds }
      if SecondsBetween(NowTime, FUsers[I].LastSeen) > 15 then
      begin
        SetLength(LeftUsers, Length(LeftUsers) + 1);
        LeftUsers[High(LeftUsers)] := FUsers[I];

        for J := I to Length(FUsers) - 2 do
          FUsers[J] := FUsers[J + 1];
        SetLength(FUsers, Length(FUsers) - 1);
        ListChanged := True;
      end
      else
        Inc(I);
    end;
  finally
    FLock.Leave;
  end;

  if ListChanged then
  begin
    CurrentSnapshot := GetUsersSnapshot;

    for I := 0 to High(LeftUsers) do
    begin
      if Assigned(FOnUserLeft) then
      begin
        Notifier := TUserNotification.Create(LeftUsers[I], FOnUserLeft);
        TThread.Queue(nil, @Notifier.Run);
      end;
    end;

    if Assigned(FOnUserListChanged) then
    begin
      ListNotifier := TUserListNotification.Create(CurrentSnapshot, FOnUserListChanged);
      TThread.Queue(nil, @ListNotifier.Run);
    end;
  end;
end;

function TDiscoveryManager.GetUsersSnapshot: TUserList;
var
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, Length(FUsers));
    for I := 0 to High(FUsers) do
      Result[I] := FUsers[I];
  finally
    FLock.Leave;
  end;
end;

end.

unit NetworkTypes;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  PORT_UDP_DISCOVERY = 5000;
  PORT_TCP_MESSAGE   = 5001;
  PORT_TCP_FILE      = 5002;

type
  { Record representing an online user discovered on the LAN }
  TOnlineUser = record
    ComputerName: string;
    IPAddress: string;
    LastSeen: TDateTime;
  end;

  TUserList = array of TOnlineUser;

  { Callback event types for UI updates from DiscoveryManager }
  TUserEvent = procedure(const User: TOnlineUser) of object;
  TUserListEvent = procedure(const Users: TUserList) of object;

  { Callback event type for incoming chat messages }
  TMessageEvent = procedure(const SenderName, IP, MsgText, Timestamp: string) of object;

  { Enumeration for the direction of a file transfer }
  TTransferType = (ttUpload, ttDownload);

  { Record for tracking upload and download progress }
  TTransferProgressRecord = record
    TransferID: string;       { Unique ID for this transfer }
    FileName: string;
    FileSize: Int64;
    BytesTransferred: Int64;
    TransferType: TTransferType;
    RemoteIP: string;
    RemoteName: string;
    Status: string;           { "Pending", "Transferring", "Completed", "Failed" }
  end;

  TTransferProgressEvent = procedure(const Progress: TTransferProgressRecord) of object;

implementation

end.

unit Utilities;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

{ Returns the network name of the local computer }
function GetLocalComputerName: string;

{ Returns the primary local IPv4 address }
function GetLocalIPAddress: string;

{ Formats a byte size into human readable string (KB, MB, GB) }
function FormatBytes(const Bytes: Int64): string;

{ Safely returns the absolute path to the ReceivedFiles directory }
function GetReceivedFilesDir: string;

{ Ensures the ReceivedFiles directory exists on the disk }
procedure EnsureReceivedFilesDir;

implementation

uses
  Windows, WinSock2;

function GetLocalComputerName: string;
var
  Buffer: array[0..255] of Char;
  Size: DWORD;
begin
  Size := SizeOf(Buffer);
  if GetComputerName(Buffer, Size) then
    Result := StrPas(Buffer)
  else
    Result := 'UnknownPC';
end;

function GetLocalIPAddress: string;
var
  WSAData: TWSAData;
  HostName: array[0..255] of Char;
  HostEnt: PHostEnt;
  Addr: PInAddr;
begin
  Result := '127.0.0.1';
  if WSAStartup($0101, WSAData) = 0 then
  begin
    try
      if GetHostName(HostName, SizeOf(HostName)) = 0 then
      begin
        HostEnt := GetHostByName(HostName);
        if HostEnt <> nil then
        begin
          Addr := PInAddr(HostEnt^.h_addr_list^);
          if Addr <> nil then
            Result := string(inet_ntoa(Addr^));
        end;
      end;
    finally
      WSACleanup;
    end;
  end;
end;

function FormatBytes(const Bytes: Int64): string;
const
  KB = 1024;
  MB = 1024 * KB;
  GB = 1024 * MB;
begin
  if Bytes >= GB then
    Result := Format('%.2f GB', [Bytes / GB])
  else if Bytes >= MB then
    Result := Format('%.2f MB', [Bytes / MB])
  else if Bytes >= KB then
    Result := Format('%.2f KB', [Bytes / KB])
  else
    Result := Format('%d Bytes', [Bytes]);
end;

function GetReceivedFilesDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'ReceivedFiles';
end;

procedure EnsureReceivedFilesDir;
var
  Path: string;
begin
  Path := GetReceivedFilesDir;
  if not DirectoryExists(Path) then
    ForceDirectories(Path);
end;

end.

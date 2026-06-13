C:\Windows\System32\taskkill.exe /IM LANBroadcaster.exe /F
del LANBroadcaster.exe

call SP.bat
title Lazarus Build
CALL %LAZARUS_HOME%\lazbuild.exe LANBroadcaster.lpi
CALL %LAZARUS_HOME%\fpc\3.2.2\bin\x86_64-win64\strip.exe LANBroadcaster.exe

start LANBroadcaster.exe

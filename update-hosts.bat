@echo off
echo Adding localhost entries to hosts file...
echo 127.0.0.1 dev-official.localhost >> %WINDIR%\System32\drivers\etc\hosts
echo 127.0.0.1 vc-dev-official.localhost >> %WINDIR%\System32\drivers\etc\hosts
echo 127.0.0.1 vcbknd-dev-official.localhost >> %WINDIR%\System32\drivers\etc\hosts
echo Hosts file updated successfully!
pause

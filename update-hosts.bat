@echo off
echo Adding localhost entries to hosts file...
echo 127.0.0.1 staging-official.vr2fit.com >> %WINDIR%\System32\drivers\etc\hosts
echo 127.0.0.1 vc-staging-official.vr2fit.com >> %WINDIR%\System32\drivers\etc\hosts
echo 127.0.0.1 vcbknd-staging-official.vr2fit.com >> %WINDIR%\System32\drivers\etc\hosts
echo Hosts file updated successfully!
pause

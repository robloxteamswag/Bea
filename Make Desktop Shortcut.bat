@echo off
rem Run me once on any computer — puts a "Bea's Play" shortcut on the Desktop.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ws = New-Object -ComObject WScript.Shell; $d = [Environment]::GetFolderPath('Desktop'); $l = $ws.CreateShortcut((Join-Path $d 'Bea''s Play.lnk')); $l.TargetPath = '%~dp0Start Beas Play.bat'; $l.WorkingDirectory = '%~dp0'; $l.IconLocation = '%~dp0bea.ico'; $l.Description = 'Bea''s Play - learning games'; $l.Save()"
echo.
echo  Done! "Bea's Play" is now on your Desktop.
echo.
pause

@echo off
rem Starts weg in cmd and PowerShell.
rem Limitation: cmd replaces %VARIABLE% in the paths. Delete such names from Git Bash.
setlocal
rem Relative paths are relative to the current folder. The script itself leaves it, so that it does not lock the target.
set "WEG_CWD=%CD%"
cd /d "%SystemRoot%"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\.local\share\weg\weg.ps1" %*
exit /b %ERRORLEVEL%

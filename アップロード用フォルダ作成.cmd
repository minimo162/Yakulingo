@echo off
rem Build a clean folder for uploading to the shared folder.
rem The working tree is never modified.
rem Drop a folder onto this file to choose where the new folder is created.
rem With no argument the new folder is created on the desktop.
rem ASCII only: this file is read by cmd.exe under the console code page.
setlocal
title YakuLingo upload folder

set "HERE=%~dp0"
set "SCRIPT=%HERE%New-YakuUploadFolder.ps1"

if not exist "%SCRIPT%" (
  echo New-YakuUploadFolder.ps1 was not found next to this file:
  echo   %HERE%
  echo.
  pause
  exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

if "%~1"=="" (
  "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SourceRoot "%HERE%."
) else (
  "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -SourceRoot "%HERE%." -DestinationParent "%~1"
)
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo Failed. Please check the message above.
)
pause
exit /b %CODE%

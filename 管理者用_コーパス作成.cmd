@echo off
rem YakuLingo corpus builder (administrators only).
rem Opens the corpus admin page. General users must not use this launcher.
rem ASCII only: this file is read by cmd.exe under the console code page.
setlocal
title YakuLingo - Corpus Builder (admin)

set "SHARED=%~dp0"
set "BOOT=%TEMP%\YakuLingo-bootstrap.ps1"

copy /y "%SHARED%bootstrap.ps1" "%BOOT%" >nul
if errorlevel 1 (
  echo Failed to copy bootstrap.ps1 from the shared folder.
  pause
  exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -SharedRoot "%SHARED%." -Admin
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo YakuLingo stopped with an error. Please check the message above.
) else (
  echo YakuLingo stopped.
)
pause
exit /b %CODE%

@echo off
rem YakuLingo launcher. Copies bootstrap.ps1 locally and runs it.
rem ASCII only: this file is read by cmd.exe under the console code page.
setlocal
title YakuLingo

set "SHARED=%~dp0"
set "BOOT=%TEMP%\YakuLingo-bootstrap.ps1"

if not exist "%SHARED%bootstrap.ps1" (
  echo bootstrap.ps1 was not found next to this launcher:
  echo   %SHARED%
  echo Please contact the administrator.
  echo.
  pause
  exit /b 1
)

rem Run from a local copy so the share is not held open for the whole session.
copy /y "%SHARED%bootstrap.ps1" "%BOOT%" >nul
if errorlevel 1 (
  echo Failed to copy bootstrap.ps1 to "%BOOT%".
  echo.
  pause
  exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -SharedRoot "%SHARED%."
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo YakuLingo stopped with an error. Please check the message above.
  echo.
  pause
)
exit /b %CODE%

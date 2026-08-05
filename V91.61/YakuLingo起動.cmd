@echo off
rem Start this version in place, without the shared-folder bootstrap.
rem For maintenance and debugging. Normal users start from the shared root.
rem ASCII only: this file is read by cmd.exe under the console code page.
setlocal
title YakuLingo

set "HERE=%~dp0"
set "APP=%HERE%app\Start-YakuLingo.ps1"

if not exist "%APP%" (
  echo Start-YakuLingo.ps1 was not found:
  echo   %APP%
  echo Please extract the package again.
  echo.
  pause
  exit /b 1
)

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APP%"
set "CODE=%ERRORLEVEL%"

echo.
if not "%CODE%"=="0" (
  echo YakuLingo stopped with an error. Please check the message above.
) else (
  echo YakuLingo stopped.
)
pause
exit /b %CODE%

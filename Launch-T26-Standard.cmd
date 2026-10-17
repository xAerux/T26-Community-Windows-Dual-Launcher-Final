@echo off
setlocal
set "TERMINATOR_ROOT=%~dp0"
cd /d "%~dp0"
call "%~dp0Setup-T26.cmd"
if errorlevel 20 exit /b %ERRORLEVEL%
if errorlevel 10 exit /b %ERRORLEVEL%
"%~dp0Launcher\publish\Terminator.Launcher.exe"
set "RESULT=%ERRORLEVEL%"
endlocal & exit /b %RESULT%

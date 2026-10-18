@echo off
chcp 65001 >nul
setlocal

rem ---------- locate programmer_cli.exe ----------
set "PROG="
where programmer_cli.exe >nul 2>nul && set "PROG=programmer_cli.exe"
if not defined PROG if defined GOWIN_HOME if exist "%GOWIN_HOME%\Programmer\bin\programmer_cli.exe" set "PROG=%GOWIN_HOME%\Programmer\bin\programmer_cli.exe"
if not defined PROG for %%D in (C D E F) do (
    if exist "%%D:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" set "PROG=%%D:\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe"
)
if not defined PROG (
    echo [ERROR] programmer_cli.exe not found.
    echo Please set GOWIN_HOME to your Gowin install dir.
    pause
    exit /b 1
)

set "FS=%~dp0impl\pnr\day3.fs"
if not exist "%FS%" (
    echo [ERROR] Bitstream not found: %FS%
    echo Run 1_build.bat first.
    pause
    exit /b 1
)

echo ==========================================
echo   Download to FPGA (SRAM, lost on power off)
echo   Note: connect the board by USB first!
echo ==========================================
echo.
"%PROG%" --device GW2A-18C --run 2 --fsFile "%FS%"
echo.
echo ==========================================
echo   Done. "Finished." and exit code 0 = success.
echo ==========================================
pause

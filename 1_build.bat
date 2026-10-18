@echo off
chcp 65001 >nul
setlocal

rem ---------- locate gw_sh.exe ----------
set "GWSH="
where gw_sh.exe >nul 2>nul && set "GWSH=gw_sh.exe"
if not defined GWSH if defined GOWIN_HOME if exist "%GOWIN_HOME%\IDE\bin\gw_sh.exe" set "GWSH=%GOWIN_HOME%\IDE\bin\gw_sh.exe"
if not defined GWSH for %%D in (C D E F) do (
    if exist "%%D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" set "GWSH=%%D:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe"
)
if not defined GWSH (
    echo [ERROR] gw_sh.exe not found.
    echo Please set GOWIN_HOME to your Gowin install dir, e.g.
    echo     set GOWIN_HOME=D:\Gowin\Gowin_V1.9.11.03_Education_x64
    pause
    exit /b 1
)

echo ==========================================
echo   Build : synthesize + place ^& route
echo   Using : %GWSH%
echo ==========================================
echo.
"%GWSH%" "%~dp0build.tcl"
echo.
echo ==========================================
echo   Done. Look for "BUILD FINISHED" = success.
echo ==========================================
pause

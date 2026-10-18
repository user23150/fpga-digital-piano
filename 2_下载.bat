@echo off
chcp 65001 >nul
echo ============================================
echo   下载比特流到 FPGA（SRAM，掉电丢失）
echo ============================================
echo   注意：请先用 USB 线连好板子！
echo.
"D:\download\Gowin\Gowin_V1.9.11.03_Education_x64\Programmer\bin\programmer_cli.exe" --device GW2A-18C --run 2 --fsFile "%~dp0impl\pnr\day3.fs"
echo.
echo ============================================
echo   下载结束。看到 "Finished." 和退出码 0 就是成功。
echo ============================================
pause

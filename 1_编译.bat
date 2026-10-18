@echo off
chcp 65001 >nul
echo ============================================
echo   编译工程（综合 + 布局布线 + 生成比特流）
echo ============================================
echo.
"D:\download\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe" "%~dp0build.tcl"
echo.
echo ============================================
echo   编译结束。看到 BUILD FINISHED 就是成功。
echo ============================================
pause

@echo off
chcp 65001 >nul
set "NSSM=D:\software\win系统Git自动同步工具包-v2.16-20260831\Git自动同步工具包-v2.16-20260831\04-一键部署\nssm_bin\nssm.exe"
"%NSSM%" stop GitAutoSync_itcast_data_linux >nul 2>&1
"%NSSM%" remove GitAutoSync_itcast_data_linux confirm >nul 2>&1
"%NSSM%" install GitAutoSync_itcast_data_linux "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" "-NoProfile -ExecutionPolicy Bypass -File ""D:\linux\itcast_data_linux\git_sync_realtime_GitAutoSync_itcast_data_linux.ps1"""
"%NSSM%" set GitAutoSync_itcast_data_linux ObjectName LocalSystem
"%NSSM%" set GitAutoSync_itcast_data_linux AppDirectory "D:\linux\itcast_data_linux"
"%NSSM%" set GitAutoSync_itcast_data_linux Start SERVICE_AUTO_START
"%NSSM%" set GitAutoSync_itcast_data_linux AppExit Default Restart
"%NSSM%" set GitAutoSync_itcast_data_linux AppRestartDelay 5000
"%NSSM%" set GitAutoSync_itcast_data_linux AppStdout "D:\linux\itcast_data_linux\git_sync_service.log"
"%NSSM%" set GitAutoSync_itcast_data_linux AppStderr "D:\linux\itcast_data_linux\git_sync_service_err.log"
"%NSSM%" set GitAutoSync_itcast_data_linux AppRotateFiles 1
"%NSSM%" set GitAutoSync_itcast_data_linux AppRotateBytes 1048576
"%NSSM%" set GitAutoSync_itcast_data_linux AppEnvironmentExtra GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="D:/linux/itcast_data_linux"
"%NSSM%" start GitAutoSync_itcast_data_linux
echo.
pause

@echo off
REM ============================================================================
REM  record_storport.bat - record a clean StorPort IO timing trace and verify it
REM
REM  Run as Administrator on a PHYSICAL machine (SATA/SAS/storahci preferred).
REM  StorPort miniport timing is NOT available on VM "Msft Virtual Disk".
REM
REM  Usage:
REM    record_storport.bat <DbName> <BackupDrive> [WprpPath]
REM  Example:
REM    record_storport.bat AdventureWorks2025 D
REM    record_storport.bat MyDb D D:\tools\wpr_internal\StorPort.wprp
REM ============================================================================

setlocal

set "DB=%~1"
set "BAKDRV=%~2"
set "WPRP=%~3"

if "%DB%"=="" (
  echo ERROR: missing database name.
  echo   Usage: record_storport.bat ^<DbName^> ^<BackupDrive^> [WprpPath]
  exit /b 1
)
if "%BAKDRV%"=="" (
  echo ERROR: missing backup drive letter.
  echo   Usage: record_storport.bat ^<DbName^> ^<BackupDrive^> [WprpPath]
  exit /b 1
)
if "%WPRP%"=="" set "WPRP=D:\tools\wpr_internal\StorPort.wprp"

REM --- locate xperf (adjust if your WPT path differs) ---
set "XPERF=C:\Tools\WPR\latest\latest\xperf.exe"
if not exist "%XPERF%" set "XPERF=C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe"

set "ETL=C:\Temp\storport_kw.etl"
set "STATS=C:\Temp\storport_kw_stats.txt"
set "BAK=%BAKDRV%:\test_storport_kw.bak"

if not exist C:\Temp md C:\Temp

echo.
echo === [1/5] Verifying wprp uses all-keyword StorPort provider ===
findstr /i "0xFFFFFFFFFFFFFFFF" "%WPRP%" >nul
if errorlevel 1 (
  echo WARNING: "%WPRP%" does not contain keyword 0xFFFFFFFFFFFFFFFF.
  echo          StorPort timing events may be filtered out. Update the wprp first.
)

echo.
echo === [2/5] Starting WPR (single self-contained profile, File mode) ===
wpr -cancel >nul 2>&1
wpr -start "%WPRP%!SqlCsiStorPortIO" -filemode
if errorlevel 1 (
  echo ERROR: wpr -start failed. Do NOT stack built-in profiles; use ONLY this one.
  exit /b 1
)
wpr -status | findstr /i "recording mode"

echo.
echo === [3/5] Running BACKUP DATABASE [%DB%] to %BAK% ===
sqlcmd -S localhost -E -b -Q "BACKUP DATABASE [%DB%] TO DISK = N'%BAK%' WITH INIT, COMPRESSION, STATS = 5;"
if errorlevel 1 (
  echo ERROR: backup failed. Stopping trace anyway.
)

echo.
echo === [4/5] Stopping WPR -> %ETL% ===
wpr -stop "%ETL%"

echo.
echo === [5/5] Verifying StorPort capture via xperf (bypasses WPA GUI) ===
if not exist "%XPERF%" (
  echo WARNING: xperf not found at "%XPERF%". Skipping verification.
  echo          Open "%ETL%" in WPA and check Disk Usage Is_Storport_Duration_Reliable.
  goto :done
)
"%XPERF%" -i "%ETL%" -tti -o "%STATS%" -a tracestats -detail >nul 2>&1
echo --- StorPort provider line(s) in %STATS% ---
findstr /i "c4636a1e StorPort" "%STATS%"
echo.
echo If the count next to {c4636a1e-...} Microsoft-Windows-StorPort is greater than 0
echo (especially Port/Dispatch + Port/Completion), capture SUCCEEDED.

:done
echo.
echo Done. Trace: %ETL%   Stats: %STATS%
endlocal

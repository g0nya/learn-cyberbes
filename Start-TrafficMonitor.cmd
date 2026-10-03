@echo off
where /q wt.exe
if errorlevel 1 (
    start "Network Traffic Monitor" /D "%~dp0." "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "%~dp0scripts\Watch-NetworkTraffic.ps1" -Interactive
) else (
    wt.exe -w new -d "%~dp0." "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -File "%~dp0scripts\Watch-NetworkTraffic.ps1" -Interactive
)

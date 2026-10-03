@echo off
setlocal
rem Only use existing runtimes, even if the user's launcher allows installs.
set "PYTHON_MANAGER_AUTOMATIC_INSTALL=false"
set "PYLAUNCHER_ALLOW_INSTALL="
set "PYLAUNCHER_ALWAYS_INSTALL="
if /i "%~1"=="--window" goto run
where /q wt.exe
if errorlevel 1 (
    start "Network Traffic Monitor" /D "%~dp0." cmd.exe /d /c call "%~f0" --window
) else (
    wt.exe -w new -d "%~dp0." cmd.exe /d /c call "%~f0" --window
)
exit /b

:run
pushd "%~dp0."
if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" -X utf8 traffic_monitor.py --interactive
    goto done
)
py -3 -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>&1
if not errorlevel 1 (
    py -3 -X utf8 traffic_monitor.py --interactive
    goto done
)
python -c "import sys; sys.exit(sys.version_info < (3, 10))" >nul 2>&1
if not errorlevel 1 (
    python -X utf8 traffic_monitor.py --interactive
    goto done
)
echo Python 3.10+ was not found. Install Python from https://www.python.org/downloads/windows/
echo Then create .venv and install requirements as described in README.md.
pause
popd
exit /b 1

:done
if errorlevel 1 (
    echo See README.md for Python and dependency setup. No packages were installed automatically.
    pause
)
popd

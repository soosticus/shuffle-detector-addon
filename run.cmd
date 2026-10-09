@echo off
rem Launch the companion from the source tree. Usage: run.cmd [--cli|--test|--setup] [args]
where py >nul 2>nul && (py -3 "%~dp0run.py" %* & exit /b %errorlevel%)
where python >nul 2>nul && (python "%~dp0run.py" %* & exit /b %errorlevel%)
echo Python 3.9+ not found. Install it from https://www.python.org/downloads/
exit /b 1

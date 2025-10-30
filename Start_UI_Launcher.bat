@echo off
setlocal
set "REPO=%~dp0"
set "SCRIPT=%REPO%tools\ui_launcher.py"
cd /d "%REPO%"

REM Try in order: py launcher, pythonw in PATH, python in PATH
where py >nul 2>nul && (start "" py -u "%SCRIPT%" & exit /b)
where pythonw >nul 2>nul && (for /f "delims=" %%P in ('where pythonw') do start "" "%%~P" "%SCRIPT%" & exit /b)
where python  >nul 2>nul && (for /f "delims=" %%P in ('where python')  do start "" "%%~P"  "%SCRIPT%" & exit /b)

REM Common venv paths (optional)
if exist "%REPO%.venv\Scripts\pythonw.exe" (start "" "%REPO%.venv\Scripts\pythonw.exe" "%SCRIPT%" & exit /b)
if exist "%REPO%venv\Scripts\pythonw.exe"  (start "" "%REPO%venv\Scripts\pythonw.exe"  "%SCRIPT%" & exit /b)

echo [ERROR] Python not found. Please install Python or activate your venv.
pause

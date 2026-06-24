@echo off
chcp 65001 >nul
cd /d "%~dp0"
python check_setup.py 2>nul || py check_setup.py
pause

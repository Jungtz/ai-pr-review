@echo off
chcp 65001 >nul 2>&1
set "SCRIPT_DIR=%~dp0"
node "%SCRIPT_DIR%bin\cli.mjs" verify %*

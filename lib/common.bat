@echo off
:: Shared utility subroutines for .bat scripts
:: Usage: call "%SCRIPT_DIR%\lib\common.bat" :subroutine [args...]
::
:: Subroutines:
::   :get_seconds <var>              — set <var> to seconds since midnight
::   :prompt_api_settings            — prompt for API config, sets API_BASE/API_KEY/API_MODEL
::   :read_usage <usage_file>        — read token usage from .usage file, sets INPUT_TOKENS/OUTPUT_TOKENS/COST_USD

goto %~1

:: ── Timer ────────────────────────────────────────────────

:get_seconds
for /f %%a in ('powershell -NoProfile -Command "[int][Math]::Floor(([DateTime]::Now - [DateTime]::Today).TotalSeconds)"') do set "%~2=%%a"
goto :eof

:: ── API Config Prompt ────────────────────────────────────

:prompt_api_settings
:: Requires: SCRIPT_DIR, API_CONFIG to be set by caller
:: Sets: API_BASE, API_KEY, API_MODEL

set "CACHED_BASE=http://localhost:11434/v1"
set "CACHED_KEY="
set "CACHED_MODEL=llama3"
if exist "!API_CONFIG!" (
    for /f "usebackq tokens=1,* delims==" %%a in ("!API_CONFIG!") do (
        if "%%a"=="API_BASE" set "CACHED_BASE=%%b"
        if "%%a"=="API_KEY" set "CACHED_KEY=%%b"
        if "%%a"=="API_MODEL" set "CACHED_MODEL=%%b"
    )
)

for /f "delims=" %%m in ('powershell -NoProfile -File "%SCRIPT_DIR%\lib\api-helper.ps1" -Action mask-key -ApiKey "!CACHED_KEY!"') do set "MASKED_KEY=%%m"

set "API_BASE=!CACHED_BASE!"
set /p "API_BASE=API Base URL [!CACHED_BASE!]: "
set "API_KEY=!CACHED_KEY!"
set /p "API_KEY=API Key [!MASKED_KEY!]: "
set "API_MODEL=!CACHED_MODEL!"
set /p "API_MODEL=Model 名稱 [!CACHED_MODEL!]: "

(
    echo API_BASE=!API_BASE!
    echo API_KEY=!API_KEY!
    echo API_MODEL=!API_MODEL!
) > "!API_CONFIG!"
goto :eof

:: ── Read Usage ───────────────────────────────────────────

:read_usage
:: Usage: call "...\common.bat" :read_usage "%USAGE_FILE%"
:: Sets: INPUT_TOKENS, OUTPUT_TOKENS, COST_USD
:: Deletes the usage file after reading

set "INPUT_TOKENS=0"
set "OUTPUT_TOKENS=0"
set "COST_USD=0"
if exist "%~2" (
    for /f "delims=" %%a in ('jq -r ".input_tokens // 0" "%~2" 2^>nul') do set "INPUT_TOKENS=%%a"
    for /f "delims=" %%a in ('jq -r ".output_tokens // 0" "%~2" 2^>nul') do set "OUTPUT_TOKENS=%%a"
    for /f "delims=" %%a in ('jq -r ".cost_usd // 0" "%~2" 2^>nul') do set "COST_USD=%%a"
    del /f "%~2" >nul 2>&1
)
goto :eof

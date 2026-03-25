@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: Pattern Evolution Script
:: Analyzes historical review/verify reports to suggest pattern improvements

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
cd /d "%SCRIPT_DIR%"

set "PROMPT_FILE=%SCRIPT_DIR%\prompts\evolve.md"
set "PATTERNS_DIR=%SCRIPT_DIR%\patterns"
set "RESULTS_DIR=%SCRIPT_DIR%\results"

call :get_seconds TOTAL_START

echo.
echo 🧬 Pattern Evolution
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: ============================================================
:: Step 1: 掃描報告
:: ============================================================
call :get_seconds STEP_START
echo 📡 [1/3] 掃描歷史報告...

set "REVIEW_COUNT=0"
set "VERIFY_COUNT=0"
for %%f in ("%RESULTS_DIR%\PR_*.md") do (
    echo %%~nf | findstr /v "_verify" >nul 2>&1 && set /a "REVIEW_COUNT+=1"
    echo %%~nf | findstr "_verify" >nul 2>&1 && set /a "VERIFY_COUNT+=1"
)

if %REVIEW_COUNT%==0 (
    echo    ❌ results\ 中沒有找到任何報告
    pause
    exit /b 1
)

call :get_seconds STEP_END
set /a "STEP_ELAPSED=STEP_END - STEP_START"
echo    ✓ %REVIEW_COUNT% 份 review 報告, %VERIFY_COUNT% 份驗證報告 (%STEP_ELAPSED%s)
echo.

:: 選擇 AI 引擎
echo 🤖 選擇分析引擎（建議使用較強模型，需跨報告歸納分析）：
echo   [1] Claude Opus（預設）
echo   [2] opencode
echo   [3] OpenAI 相容 API（Ollama / OpenRouter / 其他）
echo.
set "ENGINE_CHOICE=1"
set /p "ENGINE_CHOICE=選擇 [1/2/3]（直接 Enter 為 1）: "
if "%ENGINE_CHOICE%"=="1" set "ENGINE_NAME=Claude Opus"
if "%ENGINE_CHOICE%"=="2" set "ENGINE_NAME=opencode"
if "%ENGINE_CHOICE%"=="3" (
    echo.
    set "API_CONFIG=%SCRIPT_DIR%\.api-config"
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
    set "ENGINE_NAME=API (!API_MODEL!)"
)
echo    → 使用: %ENGINE_NAME%
echo.

:: ============================================================
:: Step 2: 組合 prompt
:: ============================================================
call :get_seconds STEP_START
echo 🔧 [2/3] 準備分析資料...

set "PROMPT_TMPFILE=%TEMP%\evolve_prompt_%RANDOM%.md"

:: 用 PowerShell 組合所有 patterns + 報告
powershell -NoProfile -Command ^
    "$template = Get-Content -Raw '%PROMPT_FILE%';" ^
    "$patterns = ''; " ^
    "Get-ChildItem '%PATTERNS_DIR%\*.md' | ForEach-Object { " ^
    "  $patterns += \"`n### File: patterns/$($_.Name)`n`n\" + (Get-Content -Raw $_.FullName) + \"`n`n---`n\" " ^
    "};" ^
    "$reports = '';" ^
    "Get-ChildItem '%RESULTS_DIR%\PR_*.md' | Where-Object { $_.Name -notmatch '_verify' } | Sort-Object Name | ForEach-Object {" ^
    "  $reports += \"`n### Review: $($_.Name)`n`n\" + (Get-Content -Raw $_.FullName) + \"`n`n---`n\";" ^
    "  $vf = $_.FullName -replace '\.md$','_verify.md';" ^
    "  if (Test-Path $vf) { $reports += \"`n### Verify: $(Split-Path $vf -Leaf)`n`n\" + (Get-Content -Raw $vf) + \"`n`n---`n\" }" ^
    "};" ^
    "$out = $template + \"`n`n## Current Patterns`n\" + $patterns + \"`n`n## Historical Reports`n\" + $reports;" ^
    "$size = [Math]::Round($out.Length / 1024);" ^
    "Write-Host \"   ✓ Prompt 大小: ${size}KB\";" ^
    "[System.IO.File]::WriteAllText('%PROMPT_TMPFILE%', $out, [System.Text.Encoding]::UTF8)"

call :get_seconds STEP_END
set /a "STEP_ELAPSED=STEP_END - STEP_START"
echo    (%STEP_ELAPSED%s)
echo.

:: ============================================================
:: Step 3: AI 分析
:: ============================================================
echo 🤖 [3/3] AI 分析中...（請等候）

set "AI_TMPFILE=%TEMP%\evolve_ai_%RANDOM%.md"
set "AI_RAW=%AI_TMPFILE%.raw"
set "AI_USAGE=%AI_TMPFILE%.usage"

call :get_seconds AI_START

if "%ENGINE_CHOICE%"=="2" (
    set "PROMPT_CONTENT="
    for /f "usebackq delims=" %%a in ("%PROMPT_TMPFILE%") do set "PROMPT_CONTENT=!PROMPT_CONTENT!%%a "
    opencode run --format json "!PROMPT_CONTENT!" > "%AI_RAW%" 2>nul
    jq -r "select(.type==\"text\") | .part.text // empty" "%AI_RAW%" > "%AI_TMPFILE%"
    jq -r "select(.type==\"step_finish\") | .part" "%AI_RAW%" > "%AI_RAW%.parts" 2>nul
    jq -s "last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}" "%AI_RAW%.parts" > "%AI_USAGE%" 2>nul
    del /f "%AI_RAW%.parts" >nul 2>&1
) else if "%ENGINE_CHOICE%"=="3" (
    powershell -NoProfile -File "%SCRIPT_DIR%\lib\api-helper.ps1" -Action call -ApiBase "!API_BASE!" -ApiKey "!API_KEY!" -Model "!API_MODEL!" -PromptFile "%PROMPT_TMPFILE%" -OutputFile "%AI_TMPFILE%"
    if errorlevel 1 (
        echo ❌ API 呼叫失敗
        type "%AI_TMPFILE%"
    )
    if exist "%AI_TMPFILE%.usage" (
        copy /y "%AI_TMPFILE%.usage" "%AI_USAGE%" >nul 2>&1
    ) else (
        echo {} > "%AI_USAGE%"
    )
) else (
    type "%PROMPT_TMPFILE%" | claude -p --model opus --output-format json > "%AI_RAW%"
    jq -r ".result // empty" "%AI_RAW%" > "%AI_TMPFILE%"
    jq "{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}" "%AI_RAW%" > "%AI_USAGE%" 2>nul
)
del /f "%AI_RAW%" >nul 2>&1
del /f "%PROMPT_TMPFILE%" >nul 2>&1

call :get_seconds AI_END
set /a "AI_ELAPSED=AI_END - AI_START"
echo    ✓ 分析完成 (%AI_ELAPSED%s)

:: 讀取 token 用量
set "INPUT_TOKENS=0"
set "OUTPUT_TOKENS=0"
set "COST_USD=0"
if exist "%AI_USAGE%" (
    for /f "delims=" %%a in ('jq -r ".input_tokens // 0" "%AI_USAGE%" 2^>nul') do set "INPUT_TOKENS=%%a"
    for /f "delims=" %%a in ('jq -r ".output_tokens // 0" "%AI_USAGE%" 2^>nul') do set "OUTPUT_TOKENS=%%a"
    for /f "delims=" %%a in ('jq -r ".cost_usd // 0" "%AI_USAGE%" 2^>nul') do set "COST_USD=%%a"
    del /f "%AI_USAGE%" >nul 2>&1
)

:: 總耗時
call :get_seconds TOTAL_END
set /a "TOTAL_ELAPSED=TOTAL_END - TOTAL_START"
set /a "TOTAL_MIN=TOTAL_ELAPSED / 60"
set /a "TOTAL_SEC=TOTAL_ELAPSED %% 60"
if %TOTAL_MIN% lss 10 set "TOTAL_MIN=0%TOTAL_MIN%"
if %TOTAL_SEC% lss 10 set "TOTAL_SEC=0%TOTAL_SEC%"

:: 儲存結果
for /f %%a in ('powershell -NoProfile -Command "Get-Date -Format 'yyMMddHHmmss'"') do set "TIMESTAMP=%%a"
set "OUTPUT_FILE=%RESULTS_DIR%\evolve_%TIMESTAMP%.md"

powershell -NoProfile -Command ^
    "$content = Get-Content -Raw '%AI_TMPFILE%';" ^
    "$footer = \"`n---`nModel: %ENGINE_NAME% | Total: %TOTAL_MIN%:%TOTAL_SEC% | Tokens: %INPUT_TOKENS% in / %OUTPUT_TOKENS% out | Cost: $%COST_USD%`nReports analyzed: %REVIEW_COUNT% review + %VERIFY_COUNT% verify`n\";" ^
    "[System.IO.File]::WriteAllText('%OUTPUT_FILE%', $content + $footer, [System.Text.Encoding]::UTF8)"

:: 輸出
echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.
type "%AI_TMPFILE%"
echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ✅ 建議報告已儲存至 %OUTPUT_FILE%
echo ⏱  總耗時 %TOTAL_MIN%:%TOTAL_SEC%
echo 📊 Tokens: %INPUT_TOKENS% in / %OUTPUT_TOKENS% out ^| 費用: $%COST_USD%

del /f "%AI_TMPFILE%" >nul 2>&1

echo.
echo 💡 請人工審閱建議後，手動更新 patterns\ 下的檔案
echo.
pause
exit /b 0

:: ============================================================
:get_seconds
for /f %%a in ('powershell -NoProfile -Command "[int][Math]::Floor(([DateTime]::Now - [DateTime]::Today).TotalSeconds)"') do set "%1=%%a"
goto :eof

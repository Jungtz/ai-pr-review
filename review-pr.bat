@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: 取得腳本所在目錄
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
cd /d "%SCRIPT_DIR%"

set "PROMPT_FILE=%SCRIPT_DIR%\prompts\review-pr.md"

:: 記錄開始時間（秒）
call "%SCRIPT_DIR%\lib\common.bat" :get_seconds TOTAL_START

:: ============================================================
:: Step 1: 輸入 PR 連結
:: ============================================================
echo 📋 請貼上 PR 連結：
set /p "PR_URL="

if "%PR_URL%"=="" (
    echo ❌ 未輸入 PR 連結
    pause
    exit /b 1
)

:: 解析 owner/repo 和 PR number
:: 從 URL 中提取 repo 和 PR number
for /f "tokens=1,2 delims=/" %%a in ('powershell -NoProfile -Command "if ('%PR_URL%' -match 'github\.com/([^/]+/[^/]+)') { $Matches[1] }"') do (
    set "REPO=%%a/%%b"
)
for /f %%a in ('powershell -NoProfile -Command "if ('%PR_URL%' -match '/pull/(\d+)') { $Matches[1] }"') do (
    set "PR_NUMBER=%%a"
)

if "%PR_NUMBER%"=="" (
    echo ❌ 無法解析 PR 連結
    pause
    exit /b 1
)
if "%REPO%"=="" (
    echo ❌ 無法解析 PR 連結
    pause
    exit /b 1
)

:: ============================================================
:: Step 2: 選擇 AI 引擎（讀取快取作為預設值）
:: ============================================================
set "API_CONFIG=%SCRIPT_DIR%\.api-config"
set "CACHED_ENGINE=1"
if exist "%API_CONFIG%" (
    for /f "usebackq tokens=1,* delims==" %%a in ("%API_CONFIG%") do (
        if "%%a"=="ENGINE" set "CACHED_ENGINE=%%b"
    )
)

echo.
echo 🤖 選擇 AI 引擎：
echo   [1] Claude Sonnet（正式 review）
echo   [2] Claude Opus（深度分析）
echo   [3] opencode
echo   [4] OpenAI 相容 API（Ollama / OpenRouter / 其他）
echo   [5] 自訂指令
echo.
set "ENGINE_CHOICE=!CACHED_ENGINE!"
set /p "ENGINE_CHOICE=選擇 [1/2/3/4/5]（直接 Enter 為 !CACHED_ENGINE!）: "

if "%ENGINE_CHOICE%"=="4" (
    echo.
    call "%SCRIPT_DIR%\lib\common.bat" :prompt_api_settings
)

if "%ENGINE_CHOICE%"=="5" (
    echo.
    echo 請輸入自訂指令（需支援 stdin 輸入，stdout 輸出）：
    echo 範例: claude -p --model haiku
    set /p "ENGINE_CHOICE="
)

if "%ENGINE_CHOICE%"=="1" set "ENGINE_NAME=Claude Sonnet"
if "%ENGINE_CHOICE%"=="2" set "ENGINE_NAME=Claude Opus"
if "%ENGINE_CHOICE%"=="3" set "ENGINE_NAME=opencode"
if "%ENGINE_CHOICE%"=="4" set "ENGINE_NAME=API (!API_MODEL!)"
if not "%ENGINE_CHOICE%"=="1" if not "%ENGINE_CHOICE%"=="2" if not "%ENGINE_CHOICE%"=="3" if not "%ENGINE_CHOICE%"=="4" set "ENGINE_NAME=%ENGINE_CHOICE%"

echo    → 使用: %ENGINE_NAME%

:: 快取引擎選擇
powershell -NoProfile -Command ^
    "$f = '%API_CONFIG%';" ^
    "if (Test-Path $f) { $lines = Get-Content $f | Where-Object { $_ -notmatch '^ENGINE=' }; $lines += 'ENGINE=%ENGINE_CHOICE%'; $lines | Set-Content $f }" ^
    "else { 'ENGINE=%ENGINE_CHOICE%' | Set-Content $f }"

for /f %%a in ('powershell -NoProfile -Command "Get-Date -Format 'yyMMddHHmmss'"') do set "TIMESTAMP=%%a"
set "FILENAME=results\PR_%PR_NUMBER%_%TIMESTAMP%.md"
if not exist "%SCRIPT_DIR%\results" mkdir "%SCRIPT_DIR%\results"

echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: ============================================================
:: Step 4+5: 並行取得 PR 資訊 + diff
:: ============================================================
call "%SCRIPT_DIR%\lib\common.bat" :get_seconds STEP_START
echo 📡 [1/3] 取得 PR 資訊 + diff...

set "META_TMPFILE=%TEMP%\pr_meta_%RANDOM%.json"
set "DIFF_TMPFILE=%TEMP%\pr_diff_%RANDOM%.txt"

:: 背景取得 diff
start /b cmd /c "gh pr diff %PR_NUMBER% --repo %REPO% > "%DIFF_TMPFILE%" 2>&1"

:: 前景取得 PR 資訊
gh pr view %PR_NUMBER% --repo %REPO% --json title,additions,deletions,changedFiles,state,author,baseRefName,headRefName > "%META_TMPFILE%" 2>&1
if errorlevel 1 (
    echo ❌ 無法取得 PR 資訊
    type "%META_TMPFILE%"
    del /f "%META_TMPFILE%" >nul 2>&1
    pause
    exit /b 1
)

for /f "delims=" %%a in ('jq -r ".title" "%META_TMPFILE%"') do set "PR_TITLE=%%a"
for /f "delims=" %%a in ('jq -r ".changedFiles" "%META_TMPFILE%"') do set "PR_FILES=%%a"
for /f "delims=" %%a in ('jq -r ".additions" "%META_TMPFILE%"') do set "PR_ADD=%%a"
for /f "delims=" %%a in ('jq -r ".deletions" "%META_TMPFILE%"') do set "PR_DEL=%%a"
for /f "delims=" %%a in ('jq -r ".headRefName" "%META_TMPFILE%"') do set "PR_HEAD_BRANCH=%%a"
echo    ✓ %PR_TITLE%
echo    ✓ %PR_FILES% 個檔案 ^| +%PR_ADD% -%PR_DEL%

:: 等待 diff 完成（檢查檔案是否寫完）
:wait_diff
powershell -NoProfile -Command "Start-Sleep -Milliseconds 200"
2>nul (>>"%DIFF_TMPFILE%" (call )) || goto :wait_diff

if not exist "%DIFF_TMPFILE%" (
    echo ❌ 無法取得 diff
    del /f "%META_TMPFILE%" >nul 2>&1
    pause
    exit /b 1
)

for /f %%a in ('find /c /v "" ^< "%DIFF_TMPFILE%"') do set "DIFF_LINES=%%a"
call "%SCRIPT_DIR%\lib\common.bat" :get_seconds STEP_END
set /a "STEP_ELAPSED=STEP_END - STEP_START"
echo    ✓ %DIFF_LINES% 行 diff (%STEP_ELAPSED%s)
echo.

:: ============================================================
:: Step 6: 偵測語言並組合 prompt
:: ============================================================
call "%SCRIPT_DIR%\lib\common.bat" :get_seconds STEP_START
echo 🔧 [2/3] 準備分析資料...

set "PROMPT_TMPFILE=%TEMP%\pr_prompt_%RANDOM%.md"
set "PATTERNS_DIR=%SCRIPT_DIR%\patterns"

:: 用 PowerShell 偵測語言、組合 patterns、替換模板
powershell -NoProfile -Command ^
    "$diff = Get-Content -Raw '%DIFF_TMPFILE%';" ^
    "$langs = @();" ^
    "if ($diff -match '\+\+\+ b/.*\.(js|ts|tsx|jsx|mjs|cjs)$') { $langs += 'javascript' };" ^
    "if ($diff -match '\+\+\+ b/.*\.py$') { $langs += 'python' };" ^
    "if ($diff -match '\+\+\+ b/.*\.go$') { $langs += 'go' };" ^
    "if ($diff -match '\+\+\+ b/.*\.php$') { $langs += 'php' };" ^
    "if ($langs.Count -gt 0) { Write-Host ('   ✓ 偵測語言: ' + ($langs -join ' ')) } else { Write-Host '   ✓ 使用通用 patterns' };" ^
    "$patterns = Get-Content -Raw '%PATTERNS_DIR%\base.md';" ^
    "foreach ($lang in $langs) {" ^
    "  $f = '%PATTERNS_DIR%\' + $lang + '.md';" ^
    "  if (Test-Path $f) { $patterns += \"`n`n\" + (Get-Content -Raw $f) }" ^
    "};" ^
    "$template = Get-Content -Raw '%PROMPT_FILE%';" ^
    "$template = $template.Replace('{{PATTERNS}}', $patterns);" ^
    "$meta = Get-Content -Raw '%META_TMPFILE%';" ^
    "$out = $template + \"`n`n## PR Metadata (JSON)`n`````json`n\" + $meta + \"`n`````n`n## PR Diff`n`````diff`n\" + $diff + \"`n`````n\";" ^
    "[System.IO.File]::WriteAllText('%PROMPT_TMPFILE%', $out, [System.Text.Encoding]::UTF8)"

call "%SCRIPT_DIR%\lib\common.bat" :get_seconds STEP_END
set /a "STEP_ELAPSED=STEP_END - STEP_START"
echo    ✓ 完成 (%STEP_ELAPSED%s)
echo.

:: 清理中間檔案
del /f "%META_TMPFILE%" >nul 2>&1
del /f "%DIFF_TMPFILE%" >nul 2>&1

:: ============================================================
:: Step 7: AI 分析
:: ============================================================
echo 🤖 [3/3] AI 分析中...（請等候）

set "AI_TMPFILE=%TEMP%\pr_ai_%RANDOM%.md"
set "AI_RAW=%AI_TMPFILE%.raw"
set "AI_USAGE=%AI_TMPFILE%.usage"

call "%SCRIPT_DIR%\lib\common.bat" :get_seconds AI_START

if "%ENGINE_CHOICE%"=="1" (
    type "%PROMPT_TMPFILE%" | claude -p --model sonnet --output-format json > "%AI_RAW%"
    jq -r ".result // empty" "%AI_RAW%" > "%AI_TMPFILE%"
    jq "{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}" "%AI_RAW%" > "%AI_USAGE%" 2>nul
    del /f "%AI_RAW%" >nul 2>&1
) else if "%ENGINE_CHOICE%"=="2" (
    type "%PROMPT_TMPFILE%" | claude -p --model opus --output-format json > "%AI_RAW%"
    jq -r ".result // empty" "%AI_RAW%" > "%AI_TMPFILE%"
    jq "{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}" "%AI_RAW%" > "%AI_USAGE%" 2>nul
    del /f "%AI_RAW%" >nul 2>&1
) else if "%ENGINE_CHOICE%"=="3" (
    set "PROMPT_CONTENT="
    for /f "usebackq delims=" %%a in ("%PROMPT_TMPFILE%") do set "PROMPT_CONTENT=!PROMPT_CONTENT!%%a "
    opencode run --format json "!PROMPT_CONTENT!" > "%AI_RAW%" 2>nul
    jq -r "select(.type==\"text\") | .part.text // empty" "%AI_RAW%" > "%AI_TMPFILE%"
    jq -r "select(.type==\"step_finish\") | .part" "%AI_RAW%" > "%AI_RAW%.parts" 2>nul
    jq -s "last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}" "%AI_RAW%.parts" > "%AI_USAGE%" 2>nul
    del /f "%AI_RAW%" >nul 2>&1
    del /f "%AI_RAW%.parts" >nul 2>&1
) else if "%ENGINE_CHOICE%"=="4" (
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
    type "%PROMPT_TMPFILE%" | %ENGINE_CHOICE% > "%AI_TMPFILE%"
    echo {} > "%AI_USAGE%"
)

call "%SCRIPT_DIR%\lib\common.bat" :get_seconds AI_END
set /a "AI_ELAPSED=AI_END - AI_START"
echo    ✓ 分析完成 (%AI_ELAPSED%s)

del /f "%PROMPT_TMPFILE%" >nul 2>&1

:: 總耗時
call "%SCRIPT_DIR%\lib\common.bat" :get_seconds TOTAL_END
set /a "TOTAL_ELAPSED=TOTAL_END - TOTAL_START"
set /a "TOTAL_MIN=TOTAL_ELAPSED / 60"
set /a "TOTAL_SEC=TOTAL_ELAPSED %% 60"
if %TOTAL_MIN% lss 10 set "TOTAL_MIN=0%TOTAL_MIN%"
if %TOTAL_SEC% lss 10 set "TOTAL_SEC=0%TOTAL_SEC%"

:: 讀取 token 用量
call "%SCRIPT_DIR%\lib\common.bat" :read_usage "%AI_USAGE%"

:: 寫入輸出檔案
set "OUTPUT_PATH=%SCRIPT_DIR%\%FILENAME%"

:: 用 PowerShell 組合最終輸出（包含 meta footer）
powershell -NoProfile -Command ^
    "$content = Get-Content -Raw '%AI_TMPFILE%';" ^
    "$footer = \"`n---`nModel: %ENGINE_NAME% | Total: %TOTAL_MIN%:%TOTAL_SEC% | Tokens: %INPUT_TOKENS% in / %OUTPUT_TOKENS% out | Cost: $%COST_USD%`n<!-- verify-meta: repo=%REPO% branch=%PR_HEAD_BRANCH% -->`n\";" ^
    "[System.IO.File]::WriteAllText('%OUTPUT_PATH%', $content + $footer, [System.Text.Encoding]::UTF8)"

echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.
:: 顯示彙整表
powershell -NoProfile -Command ^
    "$lines = Get-Content '%AI_TMPFILE%';" ^
    "$found = $false;" ^
    "foreach ($line in $lines) {" ^
    "  if ($line -match '(?i)^#+ *彙整表') { $found = $true };" ^
    "  if ($found) { Write-Host $line };" ^
    "}"
echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ✅ 完整報告已儲存至 %OUTPUT_PATH%
echo ⏱  總耗時 %TOTAL_MIN%:%TOTAL_SEC%
echo 📊 Tokens: %INPUT_TOKENS% in / %OUTPUT_TOKENS% out ^| 費用: $%COST_USD%

del /f "%AI_TMPFILE%" >nul 2>&1

:: ============================================================
:: Step 8: 檢查 🔴 問題，詢問是否驗證
:: ============================================================
set "BUG_COUNT=0"
for /f "delims=" %%a in ('powershell -NoProfile -Command ^
    "$c = Get-Content -Raw '%OUTPUT_PATH%';" ^
    "if ($c -match '統計.*🔴\s*(\d+)') { $Matches[1] } else { '0' }"') do set "BUG_COUNT=%%a"

if %BUG_COUNT% gtr 0 (
    echo.
    echo 🔍 發現 %BUG_COUNT% 個 🔴 BUG 級問題
    set "VERIFY=N"
    set /p "VERIFY=是否進行深度驗證？ [y/N]: "
    if /i "!VERIFY!"=="y" (
        :: 傳遞引擎選擇給 verify-bug
        if "%ENGINE_CHOICE%"=="1" set "PR_REVIEW_ENGINE=claude"
        if "%ENGINE_CHOICE%"=="2" set "PR_REVIEW_ENGINE=claude"
        if "%ENGINE_CHOICE%"=="3" set "PR_REVIEW_ENGINE=opencode"
        if "%ENGINE_CHOICE%"=="4" set "PR_REVIEW_ENGINE=api"
        call "%SCRIPT_DIR%\verify-bug.bat" "%OUTPUT_PATH%"
        exit /b 0
    ) else (
        echo 💡 稍後可執行: verify-bug.bat %FILENAME%
    )
) else (
    echo.
    echo ✅ 沒有 🔴 BUG 級問題
)

echo.
pause
exit /b 0


@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: 取得腳本所在目錄
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PROMPT_FILE=%SCRIPT_DIR%\prompts\verify-bug.md"
call :get_seconds TOTAL_START

:: ============================================================
:: Step 1: 取得報告檔案
:: ============================================================
set "REPORT_FILE=%~1"

if "%REPORT_FILE%"=="" (
    echo 📋 請輸入 review 報告檔案路徑：
    set /p "REPORT_FILE="
)

if "%REPORT_FILE%"=="" (
    echo ❌ 找不到檔案
    pause
    exit /b 1
)
if not exist "%REPORT_FILE%" (
    echo ❌ 找不到檔案: %REPORT_FILE%
    pause
    exit /b 1
)

:: ============================================================
:: 取得專案路徑：參數 > 報告 metadata auto-clone > 手動輸入
:: ============================================================
set "PROJECT_DIR=%~2"
set "CLONE_CLEANUP=false"

if "%PROJECT_DIR%"=="" (
    :: 嘗試從報告的 metadata 取得 repo 和 branch，自動 clone
    for /f "delims=" %%a in ('powershell -NoProfile -Command ^
        "$c = Get-Content -Raw '%REPORT_FILE%';" ^
        "if ($c -match 'verify-meta:\s*repo=(\S+)\s+branch=(\S+)') { $Matches[1] + '|' + $Matches[2] }"') do (
        for /f "tokens=1,2 delims=|" %%x in ("%%a") do (
            set "META_REPO=%%x"
            set "META_BRANCH=%%y"
        )
    )

    if defined META_REPO if defined META_BRANCH (
        echo 📂 從報告取得 repo: !META_REPO! ^(!META_BRANCH!^)
        echo    正在 clone...
        set "PROJECT_DIR=%TEMP%\verify_clone_%RANDOM%"
        gh repo clone "!META_REPO!" "!PROJECT_DIR!" -- --depth 1 --branch "!META_BRANCH!" --single-branch >nul 2>&1
        if errorlevel 1 (
            echo ❌ Clone 失敗
            if exist "!PROJECT_DIR!" rmdir /s /q "!PROJECT_DIR!"
            pause
            exit /b 1
        )
        set "CLONE_CLEANUP=true"
        echo    ✓ Clone 完成
    )
)

if "%PROJECT_DIR%"=="" (
    echo.
    echo 📂 請輸入專案路徑（驗證需要讀取原始碼）：
    set /p "PROJECT_DIR="
)

if "%PROJECT_DIR%"=="" (
    echo ❌ 無效的專案路徑
    pause
    exit /b 1
)
if not exist "%PROJECT_DIR%\" (
    echo ❌ 無效的專案路徑: %PROJECT_DIR%
    pause
    exit /b 1
)

:: 轉為絕對路徑
pushd "%PROJECT_DIR%"
set "PROJECT_DIR=%CD%"
popd
echo    → 專案: %PROJECT_DIR%

:: ============================================================
:: 選擇 AI 引擎（若從 review-pr 傳入則自動選擇）
:: ============================================================
if "%PR_REVIEW_ENGINE%"=="api" if defined API_BASE if defined API_MODEL (
    set "ENGINE_CHOICE=3"
    set "ENGINE_NAME=API (!API_MODEL!)"
    echo.
    echo 🤖 沿用 review 引擎: !ENGINE_NAME!
    goto :engine_selected
)

echo.
echo 🤖 選擇驗證引擎：
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
    :: 讀取快取設定作為預設值
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
    :: 遮罩 API Key 顯示
    for /f "delims=" %%m in ('powershell -NoProfile -File "%SCRIPT_DIR%\lib\api-helper.ps1" -Action mask-key -ApiKey "!CACHED_KEY!"') do set "MASKED_KEY=%%m"
    set "API_BASE=!CACHED_BASE!"
    set /p "API_BASE=API Base URL [!CACHED_BASE!]: "
    set "API_KEY=!CACHED_KEY!"
    set /p "API_KEY=API Key [!MASKED_KEY!]: "
    set "API_MODEL=!CACHED_MODEL!"
    set /p "API_MODEL=Model 名稱 [!CACHED_MODEL!]: "
    :: 寫入快取
    (
        echo API_BASE=!API_BASE!
        echo API_KEY=!API_KEY!
        echo API_MODEL=!API_MODEL!
    ) > "!API_CONFIG!"
    set "ENGINE_NAME=API (!API_MODEL!)"
)

:engine_selected
echo    → 使用: %ENGINE_NAME%

echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: ============================================================
:: Step 2: 提取 🔴 問題區塊
:: ============================================================
call :get_seconds STEP_START
echo 🔧 [1/2] 提取 🔴 BUG 級問題...

set "BUG_DIR=%TEMP%\verify_bugs_%RANDOM%"
mkdir "%BUG_DIR%" >nul 2>&1

:: 用 PowerShell 提取 🔴 區塊
powershell -NoProfile -Command ^
    "$lines = Get-Content '%REPORT_FILE%';" ^
    "$count = 0; $buf = '';" ^
    "foreach ($line in $lines) {" ^
    "  if ($line -match '🔴' -and $line -match '^[#*]') {" ^
    "    if ($buf -ne '') { $count++; [System.IO.File]::WriteAllText('%BUG_DIR%\bug_' + $count + '.txt', $buf, [System.Text.Encoding]::UTF8) };" ^
    "    $buf = $line;" ^
    "  } elseif (($line -match '🟡' -or $line -match '🟢' -or $line -match '(?i)^##+ *彙整表' -or $line -match '(?i)^##+ *判定結果') -and $line -match '^[#*]') {" ^
    "    if ($buf -ne '') { $count++; [System.IO.File]::WriteAllText('%BUG_DIR%\bug_' + $count + '.txt', $buf, [System.Text.Encoding]::UTF8) };" ^
    "    $buf = '';" ^
    "  } elseif ($buf -ne '') { $buf += \"`n\" + $line }" ^
    "};" ^
    "if ($buf -ne '') { $count++; [System.IO.File]::WriteAllText('%BUG_DIR%\bug_' + $count + '.txt', $buf, [System.Text.Encoding]::UTF8) };" ^
    "Write-Host $count"

:: 計算 bug 數量
set "BUG_COUNT=0"
for %%f in ("%BUG_DIR%\bug_*.txt") do set /a "BUG_COUNT+=1"

if %BUG_COUNT%==0 (
    echo    ✅ 沒有找到 🔴 BUG 級問題
    rmdir /s /q "%BUG_DIR%" >nul 2>&1
    pause
    exit /b 0
)

call :get_seconds STEP_END
set /a "STEP_ELAPSED=STEP_END - STEP_START"
echo    ✓ 找到 %BUG_COUNT% 個問題 (%STEP_ELAPSED%s)
echo.

:: 列出所有問題
set "ISSUE_NUM=0"
for %%f in ("%BUG_DIR%\bug_*.txt") do (
    set /a "ISSUE_NUM+=1"
    for /f "usebackq delims=" %%t in ("%%f") do (
        if !ISSUE_NUM! gtr 0 (
            set "TITLE=%%t"
            echo   [!ISSUE_NUM!] !TITLE:~0,80!
            set "ISSUE_NUM=-!ISSUE_NUM!"
        )
    )
    :: 恢復正數
    if !ISSUE_NUM! lss 0 set /a "ISSUE_NUM=-ISSUE_NUM"
)
echo.
echo   [a] 全部驗證
echo.
set "SELECTION=a"
set /p "SELECTION=選擇要驗證的問題（數字/a，直接 Enter 為全部）: "

echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.

:: ============================================================
:: Step 3: 逐一驗證
:: ============================================================
echo 🤖 [2/2] AI 深度驗證...
echo.

:: 準備輸出檔案
for %%f in ("%REPORT_FILE%") do set "REPORT_BASENAME=%%~nf"
set "VERIFY_FILENAME=%REPORT_BASENAME%_verify.md"
for %%f in ("%REPORT_FILE%") do set "REPORT_DIR=%%~dpf"
set "VERIFY_PATH=%REPORT_DIR%%VERIFY_FILENAME%"

:: 寫入報告頭
(
    echo ## 🔍 BUG 驗證報告
    echo.
    echo 來源報告: `%~nx1`
    echo.
) > "%VERIFY_PATH%"

set "PROMPT_TEMPLATE="
set "VERIFIED=0"
set "CONFIRMED=0"
set "FALSE_POSITIVE=0"
set "POTENTIAL=0"
set "TOTAL_INPUT_TOKENS=0"
set "TOTAL_OUTPUT_TOKENS=0"
set "TOTAL_COST_USD=0"

set "ISSUE_NUM=0"
for %%f in ("%BUG_DIR%\bug_*.txt") do (
    set /a "ISSUE_NUM+=1"

    :: 如果不是全部，檢查是否為選中的問題
    if not "!SELECTION!"=="a" (
        if not "!SELECTION!"=="!ISSUE_NUM!" goto :skip_issue
    )

    :: 讀取問題標題
    set "TITLE="
    for /f "usebackq delims=" %%t in ("%%f") do (
        if not defined TITLE set "TITLE=%%t"
    )
    echo    [!ISSUE_NUM!/%BUG_COUNT%] !TITLE:~0,70!

    :: 組合 prompt
    set "V_PROMPT=%TEMP%\verify_prompt_%RANDOM%.md"
    set "V_TMPFILE=%TEMP%\verify_out_%RANDOM%.md"
    set "V_RAW=!V_TMPFILE!.raw"
    set "V_USAGE=!V_TMPFILE!.usage"

    powershell -NoProfile -Command ^
        "$template = Get-Content -Raw '%PROMPT_FILE%';" ^
        "$issue = Get-Content -Raw '%%f';" ^
        "$out = $template + \"`n`n## The issue to verify`n`n\" + $issue;" ^
        "[System.IO.File]::WriteAllText('!V_PROMPT!', $out, [System.Text.Encoding]::UTF8)"

    call :get_seconds V_START

    if "!ENGINE_CHOICE!"=="1" (
        pushd "%PROJECT_DIR%"
        type "!V_PROMPT!" | claude -p --model opus --output-format json > "!V_RAW!"
        popd
        jq -r ".result // empty" "!V_RAW!" > "!V_TMPFILE!"
        jq "{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}" "!V_RAW!" > "!V_USAGE!" 2>nul
        del /f "!V_RAW!" >nul 2>&1
    ) else if "!ENGINE_CHOICE!"=="2" (
        set "V_CONTENT="
        for /f "usebackq delims=" %%c in ("!V_PROMPT!") do set "V_CONTENT=!V_CONTENT!%%c "
        pushd "%PROJECT_DIR%"
        opencode run --format json "!V_CONTENT!" > "!V_RAW!" 2>nul
        popd
        jq -r "select(.type==\"text\") | .part.text // empty" "!V_RAW!" > "!V_TMPFILE!"
        jq -r "select(.type==\"step_finish\") | .part" "!V_RAW!" > "!V_RAW!.parts" 2>nul
        jq -s "last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}" "!V_RAW!.parts" > "!V_USAGE!" 2>nul
        del /f "!V_RAW!" >nul 2>&1
        del /f "!V_RAW!.parts" >nul 2>&1
    ) else if "!ENGINE_CHOICE!"=="3" (
        pushd "%PROJECT_DIR%"
        powershell -NoProfile -File "%SCRIPT_DIR%\lib\api-helper.ps1" -Action call -ApiBase "!API_BASE!" -ApiKey "!API_KEY!" -Model "!API_MODEL!" -PromptFile "!V_PROMPT!" -OutputFile "!V_TMPFILE!"
        popd
        if exist "!V_TMPFILE!.usage" (
            copy /y "!V_TMPFILE!.usage" "!V_USAGE!" >nul 2>&1
        ) else (
            echo {} > "!V_USAGE!"
        )
    )

    call :get_seconds V_END
    set /a "V_ELAPSED=V_END - V_START"
    echo    ✓ 完成 (!V_ELAPSED!s)

    del /f "!V_PROMPT!" >nul 2>&1

    :: 統計結果
    set /a "VERIFIED+=1"
    findstr /c:"CONFIRMED" "!V_TMPFILE!" >nul 2>&1 && set /a "CONFIRMED+=1"
    findstr /c:"FALSE POSITIVE" "!V_TMPFILE!" >nul 2>&1 && set /a "FALSE_POSITIVE+=1"
    findstr /c:"POTENTIAL" "!V_TMPFILE!" >nul 2>&1 && set /a "POTENTIAL+=1"

    :: 累計 token 用量
    if exist "!V_USAGE!" (
        for /f "delims=" %%a in ('jq -r ".input_tokens // 0" "!V_USAGE!" 2^>nul') do set /a "TOTAL_INPUT_TOKENS+=%%a"
        for /f "delims=" %%a in ('jq -r ".output_tokens // 0" "!V_USAGE!" 2^>nul') do set /a "TOTAL_OUTPUT_TOKENS+=%%a"
        for /f "delims=" %%a in ('powershell -NoProfile -Command ^
            "$u = Get-Content -Raw '!V_USAGE!' | ConvertFrom-Json;" ^
            "$c = if ($u.cost_usd) { $u.cost_usd } else { 0 };" ^
            "Write-Host ([decimal]%TOTAL_COST_USD% + [decimal]$c)"') do set "TOTAL_COST_USD=%%a"
        del /f "!V_USAGE!" >nul 2>&1
    )

    :: 附加到驗證報告
    type "!V_TMPFILE!" >> "%VERIFY_PATH%"
    (
        echo.
        echo ---
        echo.
    ) >> "%VERIFY_PATH%"

    del /f "!V_TMPFILE!" >nul 2>&1
    echo.

    :skip_issue
)

:: 清理
rmdir /s /q "%BUG_DIR%" >nul 2>&1

:: 清理暫存 clone
if "%CLONE_CLEANUP%"=="true" (
    rmdir /s /q "%PROJECT_DIR%" >nul 2>&1
)

:: 總耗時
call :get_seconds TOTAL_END
set /a "TOTAL_ELAPSED=TOTAL_END - TOTAL_START"
set /a "TOTAL_MIN=TOTAL_ELAPSED / 60"
set /a "TOTAL_SEC=TOTAL_ELAPSED %% 60"
if %TOTAL_MIN% lss 10 set "TOTAL_MIN=0%TOTAL_MIN%"
if %TOTAL_SEC% lss 10 set "TOTAL_SEC=0%TOTAL_SEC%"

:: 附加統計摘要到報告
(
    echo ## 📊 驗證摘要
    echo.
    echo ^| 結論 ^| 數量 ^|
    echo ^|------^|------^|
    echo ^| 🔴 CONFIRMED（確認是 BUG） ^| %CONFIRMED% ^|
    echo ^| ✅ FALSE POSITIVE（誤報） ^| %FALSE_POSITIVE% ^|
    echo ^| ⚠️ POTENTIAL（潛在風險） ^| %POTENTIAL% ^|
    echo ^| **合計驗證** ^| **%VERIFIED%** ^|
    echo.
    echo ⏱ 驗證耗時 %TOTAL_MIN%:%TOTAL_SEC%
    echo.
    echo ^| 項目 ^| 數值 ^|
    echo ^|------^|------^|
    echo ^| Input tokens ^| %TOTAL_INPUT_TOKENS% ^|
    echo ^| Output tokens ^| %TOTAL_OUTPUT_TOKENS% ^|
    echo ^| 費用 ^| $%TOTAL_COST_USD% ^|
    echo.
    echo ---
    echo Model: %ENGINE_NAME% ^| Total: %TOTAL_MIN%:%TOTAL_SEC% ^| Tokens: %TOTAL_INPUT_TOKENS% in / %TOTAL_OUTPUT_TOKENS% out ^| Cost: $%TOTAL_COST_USD%
) >> "%VERIFY_PATH%"

:: 輸出摘要
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo.
echo 📊 驗證結果：
echo    🔴 CONFIRMED: %CONFIRMED%
echo    ✅ FALSE POSITIVE: %FALSE_POSITIVE%
echo    ⚠️  POTENTIAL: %POTENTIAL%
echo.
echo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ✅ 驗證報告已儲存至 %VERIFY_PATH%
echo ⏱  總耗時 %TOTAL_MIN%:%TOTAL_SEC%
echo 📊 Tokens: %TOTAL_INPUT_TOKENS% in / %TOTAL_OUTPUT_TOKENS% out ^| 費用: $%TOTAL_COST_USD%
echo.
pause
exit /b 0

:: ============================================================
:: 輔助函式：取得當前秒數（自午夜起算）
:: ============================================================
:get_seconds
for /f %%a in ('powershell -NoProfile -Command "[int][Math]::Floor(([DateTime]::Now - [DateTime]::Today).TotalSeconds)"') do set "%1=%%a"
goto :eof

# ai-pr-review

單檔零依賴 Node 18+ ESM CLI（無 package.json、無測試、無 lint）。

## 結構

- `bin/cli.mjs`：全部邏輯（約 1600 行），唯一需要改的程式檔
- `review-pr.bat` / `verify-bug.bat`（+ `.command`）：wrapper，只轉發給 `cli.mjs`，改功能不用碰
- `prompts/`：`review-pr.md` 的 `{{PATTERNS}}` 會被替換為 `patterns.md` 內容；改 prompt 語氣需維持「繁體中文輸出、英文保留程式碼／路徑／術語」
- `results/`：輸出報告（gitignore），`_verify.md`／`_chat.md` 由報告檔名衍生

## 驗證

唯一可用檢查：`node --check bin/cli.mjs`（Windows 用 `;` 串接，不用 `&&`）。
改完另用 grep 確認無殘留引用（例：刪函式後搜名字）。

## 不可破壞的約束

- Windows spawn：`resolveCommand`＋`quoteArg` 繞過 Node 在 win32 執行 `.cmd/.bat` 的 EINVAL；動 `sh()` 前先讀懂它
- prompt 一律走 stdin 餵入（Windows 命令列約 32KB 上限，diff 常超標），不可改為 argv 傳遞；唯一例外是原生聊天接管（`runNativeChat`）：上下文寫暫存檔，argv 只帶引用它的短 prompt
- `sh()` 一律整段收 Buffer、結束後一次 decode；review／verify 引擎（`runClaude`／`runOpencode`）不可改成逐 chunk 解析，UTF-8 中文會被 chunk 邊界切成 `�`
- review 報告尾的 `<!-- verify-meta: repo=… branch=… -->` 是 auto-clone 的資料源，改輸出格式時必須保留
- `.api-config` 存明文金鑰（已 gitignore）：不可印出、不可提交；`results/` 同樣不可提交

## 流程邏輯（改選單前先讀）

- `cmdReview` 入口若收到 `.md` 路徑，先經 `looksLikeReviewReport` 判定，屬實則二選一：`cmdShare`（分享）或 `cmdChatFromReport`（聊天；從檔名 PR 編號＋`verify-meta` 重抓 diff，取不到才問 PR 連結；抓到的是 PR 現況 diff，經 `diffNote` 告知 AI 可能與報告不一致），皆不跑 review；無效輸入重問
- `cmdReview` 結束進 `postReviewMenu`（驗證／聊天／結束／分享連結，可循環；動作完成後預設切回結束防誤觸）
- `cmdVerify`：單次批次驗證，一律全驗
- `cmdChat` 依引擎分流：claude／opencode 進場即 clone codebase（失敗才降級為報告＋diff），交給原生互動 CLI（`runNativeChat`，stdio 繼承；紀錄留在該 CLI 的 session，不寫 `_chat.md`）；API 引擎無法讀檔，不 clone，走內建串流迴圈（`chatViaApi`，寫 `_chat.md`）
- 原生接管：claude 帶 `--model`／`--effort`／`--add-dir`（`--add-dir` 為可變長度參數，後面須緊接旗標）；opencode v2 TUI 不收 `--model`（實測 v2.0.14），只有 v1 帶；無專案時 cwd 用暫存目錄，不可落在本工具目錄
- 原生接管的上下文檔：claude 放暫存目錄＋`--add-dir`；opencode 在自有暫存 clone 時寫進專案內（`.ai-pr-review-context.md`），結束只刪該檔，不可遞迴刪專案目錄；使用者自備專案不寫入
- `runOpenAICompat` 只有帶 `onText`（聊天）才送 `stream`，review／verify 維持一次性請求；串流遇 400 自動改一次性請求重試一次（400 在生成前，不耗 token）
- `cmdShare`：挑一份報告上傳為 gist（預設 secret，public 二次確認）；連結註記回檔尾 `<!-- share-meta: … -->`，勿與 `verify-meta` 解析搞混
- 引擎沿用不重選，驗證只升級（`upgradeForVerify`）；clone 本身不耗 token，讀檔才耗

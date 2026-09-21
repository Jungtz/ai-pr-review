# ai-pr-review

單檔零依賴 Node 18+ ESM CLI（無 package.json、無測試、無 lint）。

## 結構

- `bin/cli.mjs`：全部邏輯（約 1100 行），唯一需要改的程式檔
- `review-pr.bat` / `verify-bug.bat`（+ `.command`）：wrapper，只轉發給 `cli.mjs`，改功能不用碰
- `prompts/`：`review-pr.md` 的 `{{PATTERNS}}` 會被替換為 `patterns.md` 內容；改 prompt 語氣需維持「繁體中文輸出、英文保留程式碼／路徑／術語」
- `results/`：輸出報告（gitignore），`_verify.md`／`_chat.md` 由報告檔名衍生

## 驗證

唯一可用檢查：`node --check bin/cli.mjs`（Windows 用 `;` 串接，不用 `&&`）。
改完另用 grep 確認無殘留引用（例：刪函式後搜名字）。

## 不可破壞的約束

- Windows spawn：`resolveCommand`＋`quoteArg` 繞過 Node 在 win32 執行 `.cmd/.bat` 的 EINVAL；動 `sh()` 前先讀懂它
- prompt 一律走 stdin 餵入（Windows 命令列約 32KB 上限，diff 常超標），不可改為 argv 傳遞
- review 報告尾的 `<!-- verify-meta: repo=… branch=… -->` 是 auto-clone 的資料源，改輸出格式時必須保留
- `.api-config` 存明文金鑰（已 gitignore）：不可印出、不可提交；`results/` 同樣不可提交

## 流程邏輯（改選單前先讀）

- `cmdReview` 結束進 `postReviewMenu`（驗證／聊天／結束／分享連結，可循環；動作完成後預設切回結束防誤觸）
- `cmdVerify`：單次批次驗證，一律全驗；`cmdChat`：進場即 clone codebase，失敗才降級為報告＋diff
- `cmdShare`：挑一份報告上傳為 gist（預設 secret，public 二次確認）；連結註記回檔尾 `<!-- share-meta: … -->`，勿與 `verify-meta` 解析搞混
- 引擎沿用不重選，驗證只升級（`upgradeForVerify`）；clone 本身不耗 token，讀檔才耗

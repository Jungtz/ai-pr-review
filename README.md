# ai-pr-review

AI-powered GitHub PR review tool — 自動取得 PR diff，透過 AI 分析潛在問題，並可對 BUG 級問題進行深度驗證。

## 需求

| 工具 | 用途 | 安裝 |
|------|------|------|
| [gh](https://cli.github.com) | 取得 PR 資訊與 diff | `brew install gh` / `winget install GitHub.cli` |
| [jq](https://jqlang.github.io/jq) | 解析 JSON | `brew install jq` / `winget install jqlang.jq` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) | AI 引擎（預設） | `npm install -g @anthropic-ai/claude-code` |
| [opencode](https://opencode.ai) | AI 引擎（選用） | `npm install -g opencode-ai` |
| OpenAI 相容 API | AI 引擎（Ollama / OpenRouter / 其他） | 提供 API Base URL、API Key、Model 名稱 |

使用前請先登入 GitHub CLI：

```bash
gh auth login
```

## 檔案結構

```
ai-pr-review/
├── review-pr.command    # macOS 主程式（雙擊啟動，wrapper）
├── review-pr.bat        # Windows 主程式（雙擊啟動，wrapper）
├── verify-bug.command   # macOS BUG 驗證（wrapper）
├── verify-bug.bat       # Windows BUG 驗證（wrapper）
├── bin/
│   └── cli.mjs          # 實際邏輯（Node 18+，零依賴）
├── prompts/
│   ├── review-pr.md     # Review prompt 模板（含 {{PATTERNS}} 佔位符）
│   ├── verify-bug.md    # BUG 驗證 prompt 模板
│   └── patterns.md      # 通用 detection patterns（跨語言）
└── results/             # 輸出報告（.gitignore）
    ├── PR_*_.md         # Review 報告
    ├── PR_*_verify.md   # 驗證報告
    └── PR_*_chat.md     # 聊天紀錄
```

> 前置依賴：`node` (>= 18)、`gh` CLI；視所選引擎還需 `claude` 或 `opencode` 或 `curl`。

## 使用方式

### macOS

雙擊 `review-pr.command`，或在終端執行：

```bash
./review-pr.command
```

### Windows

雙擊 `review-pr.bat`，或在命令提示字元執行：

```cmd
review-pr.bat
```

## 流程

### Step 1：PR Review

```
📋 貼上 PR 連結
        ↓
🤖 選擇 AI 引擎
   [1] Claude Sonnet（預設）
   [2] Claude Opus（深度分析）
   [3] opencode
   [4] OpenAI 相容 API（Ollama / OpenRouter / 其他）
         ↓
📡 自動取得 PR 資訊 + diff（via gh CLI）
        ↓
🔧 載入通用 detection patterns
        ↓
🤖 AI 分析（區分商業邏輯意圖，優化 BUG 判定） → 產出 review 報告
        ↓
📊 顯示彙整表 + 儲存報告
        ↓
🔀 四選一（可循環操作）：
   [1] 深度驗證 / [2] 跟 AI 聊天 / [3] 結束 / [4] 產生分享連結
   有 🔴 BUG 預設為 [1]，動作完成後預設切回 [3]
```

### Step 2：BUG 驗證（verify-bug）

當 review 報告包含 🔴 BUG 級問題時，可進行深度驗證：

```
📋 輸入 review 報告路徑（或由 Step 1 自動帶入）
        ↓
📂 取得專案原始碼
   - 自動從報告 metadata 取得 repo/branch 並 clone
   - 或手動輸入本地專案路徑
        ↓
🤖 選擇驗證引擎
   [1] Claude Opus（預設）
   [2] opencode
   [3] OpenAI 相容 API（Ollama / OpenRouter / 其他）
        ↓
🔧 提取報告中所有 🔴 問題（一律全部驗證）
        ↓
🤖 AI 逐一讀取原始碼進行驗證
   - CONFIRMED：確認是 BUG
   - FALSE POSITIVE：誤報
   - POTENTIAL：潛在風險
        ↓
📊 輸出驗證摘要 + 儲存報告
```

### Step 3：AI 聊天（chat）

針對已完成的 review，與 AI 多輪問答（基於 review 報告 + 原始 diff）：

```
💬 進場即備好專案原始碼（與驗證同一套解析：報告 metadata 自動 clone）
        ↓
💬 多輪問答（沿用分析引擎，不重選；歷史上限 20 輪）
   追問 diff 細節直接答，超出 diff 範圍則讀原始碼查證
        ↓
   輸入 exit / quit / q 結束
        ↓
📝 聊天紀錄追加儲存 + 刪除暫存 clone 目錄
```

### Step 4：產生分享連結（GitHub Gist）

將本次 PR 已產生的報告上傳為 gist，取得可分享的連結：

```
🔗 選一份報告（review／驗證／聊天，有檔才列）
        ↓
🔒 選公開程度：secret（預設）/ public（需二次確認）
        ↓
⬆️ 上傳（沿用 gh 登入身分，歸屬跑的人帳號）→ 印出連結＋註記回報告尾
```

> 報告含 PR diff：secret gist 不公開列表，但拿到連結即可檢視；刪除後連結即失效。機密專案請先確認公司政策再分享。

## 輸出範例

Review 報告儲存為 `PR_{number}_{timestamp}.md`，包含：

- PR 總覽（標題、作者、分支、變更統計）
- 問題清單（🔴 BUG / 🟡 WARN / 🟢 NIT）
- 彙整表
- 判定結果（APPROVE / REQUEST CHANGES / COMMENT）

驗證報告儲存為 `PR_{number}_{timestamp}_verify.md`，包含：

- 每個 🔴 問題的驗證結論與分析過程
- 驗證摘要統計

聊天紀錄儲存為 `PR_{number}_{timestamp}_chat.md`（多次聊天則追加），包含：

- 逐輪問答
- 使用引擎與 tokens / 費用統計

## Detection Patterns

`prompts/patterns.md` 定義了通用的 detection checklist（邊界條件、邏輯錯誤、race condition、資源洩漏、安全問題等）。

語言特定的 pattern 不需要額外維護 — AI 本身已具備各語言的深度知識，通用 checklist 足以引導分析方向。

## 自訂 Prompt

- `prompts/review-pr.md` — Review 主模板，`{{PATTERNS}}` 佔位符會被替換為 `prompts/patterns.md` 的內容
- `prompts/verify-bug.md` — BUG 驗證 prompt 模板
- `prompts/patterns.md` — 通用 detection checklist，可自由修改
- `bin/cli.mjs` — 實際的 Node 邏輯（review / verify 兩個 sub-command）

## License

本專案採用 [MIT License](LICENSE) 開源授權。

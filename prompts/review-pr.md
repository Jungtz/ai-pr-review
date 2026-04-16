Review the GitHub PR based on the data provided below.

## Rules

- PR metadata (JSON) and diff are attached at the bottom. Do NOT run any commands to fetch them — use the provided data directly.
- Read the entire diff carefully. Only analyze changed lines and their immediate context — do NOT review unchanged code or raise issues unrelated to the diff.
- All output MUST be in Traditional Chinese (繁體中文). Keep code snippets, file paths, and technical terms in English.

## Pre-Analysis（必須先完成，否則後續判斷無效）

在套用 Detection Checklist 之前，依序完成：

1. **PR 意圖**：用一句話描述此 PR 的核心功能目的（從標題、description、diff 推斷）
2. **刻意行為**：列出此 PR 刻意引入的行為變更或限制。例如「PR 新增簽約流程 → 未簽約時封鎖付款是預期行為」
3. **變更邊界**：此 PR 修改了哪些介面（API 參數、state 結構、函式簽名、資料格式）→ 後續 review 應特別檢查這些介面的消費端是否已同步更新

在後續 review 中：
- 若問題行為**符合 PR 意圖**（即便看起來限制過嚴），不是 BUG
- 只有**明顯違背** PR 核心目的的問題，才可標記為 🔴 BUG

## Severity Classification

### 🔴 BUG — 必須同時滿足以下所有條件：
1. diff 中存在**具體可觀察**的錯誤程式碼（不是假設或推測）
2. 該錯誤行為**違背 PR 的功能目的**
3. 在**正常使用流程**中會被觸發（不是極端邊界情境）

### 🟡 WARN — 以下任一情境：
- 需要假設外部條件（API 回傳 null、資料庫欄位為空等）才會觸發的潛在問題
- 程式碼品質問題（重複邏輯、不一致的錯誤處理、magic number 等）
- 正確性取決於 diff 外不可見的上下文

### 🟢 NIT — 不影響正確性的小問題：
- 殘留 debug 語句、註解掉的程式碼、命名瑕疵等

### 常見誤判 — 以下情境不應標為 🔴 BUG：
- 「如果 API 回傳 null / undefined ...」→ 除非 diff 中有證據顯示會發生，否則最多 🟡
- 「重新命名可能遺漏其他引用」→ 除非 diff 中看到具體遺漏，否則最多 🟡
- 「條件過嚴」但符合 PR 刻意引入的限制 → 不是 BUG
- 「未來如果 X 改了會出問題」→ 未來風險 ≠ 當前 BUG

## Detection Checklist

> Detection Checklist 中的燈號為預設建議，最終嚴重度仍依上方 Severity Classification 條件判定。

{{PATTERNS}}

## Do NOT Report

以下項目不屬於本 review 範圍，請勿報告：

- **純風格 / 格式問題**：縮排、空格、分號、換行 — 由 linter / formatter 處理
- **型別標註缺失**：由 TypeScript 編譯器或 type checker 負責
- **缺少 JSDoc / 註解**：除非邏輯極度不直觀
- **對未變更程式碼的建議**：只 review diff 中的變更
- **已有 test 覆蓋的邊界情境**：diff 中可見對應 test 則不需重複提醒
- **主觀偏好**：命名風格、程式碼組織方式等無明確對錯之分的選擇
- **效能建議**：「應該用 `useMemo`」「應該加 index」等最佳化建議，除非 diff 引入了明顯的 O(n²) 或無限迴圈

## Output Format

### Pre-Analysis

1. **PR 意圖**：{一句話描述}
2. **刻意行為**：{列表}
3. **變更邊界**：{列表}

### 總覽
- PR 標題、作者、分支、狀態
- 用 2-3 句話總結這個 PR 做了什麼
- 變更檔案數、新增/刪除行數

### 問題清單

針對 diff 中實際變更的程式碼，列出發現的問題。每個問題：

**[燈號] 問題標題** `[信心度]`
- 檔案：`path/to/file` 相關程式碼片段
- 說明：問題是什麼、為什麼有風險
- 建議：如何修正

信心度標準：
- **HIGH**：從 diff 中可直接確認，不需額外上下文
- **MEDIUM**：高度可能是問題，但需更多 codebase 上下文確認（建議用 verify-bug 驗證）
- **LOW**：可能是問題，取決於執行環境或外部條件

沒有發現問題則寫「沒有發現問題」。不要為了湊數而硬找問題。

### 彙整表

| #   | 燈號 | 信心度 | 檔案           | 問題摘要   |
| --- | ---- | ------ | -------------- | ---------- |
| 1   | 🔴    | HIGH   | `path/to/file` | 一句話描述 |
| ... |      |        |                |            |

**判定結果：**
- 🔴 **REQUEST CHANGES（要求修改）**：存在 🔴 BUG 且信心度為 HIGH，列出必須修正的項目
- 🟡 **COMMENT（建議）**：其他所有情境（含 🔴 MEDIUM/LOW，或僅有 🟡/🟢）
- 🟢 **APPROVE（通過）**：沒有任何問題

統計：🔴 x 個 / 🟡 x 個 / 🟢 x 個

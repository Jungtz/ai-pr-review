Review the GitHub PR based on the data provided below.

## Instructions

- The PR metadata (JSON) and diff are already attached at the bottom of this prompt. Do NOT run any commands to fetch them — use the provided data directly.
- Read the entire diff carefully. Only analyze the changed lines and their immediate context — do NOT review unchanged code or raise issues unrelated to the diff.
- Review each changed line against the "Detection Checklist" below. Only report issues that actually appear in the diff.
- All output MUST be in Traditional Chinese (繁體中文). Keep code snippets, file paths, and technical terms in English.

## Detection Checklist

### 🔴 BUG-level patterns
- **Data loss via key collision**: `.reduce()` or `forEach` 使用語意為排序、順序的欄位（如 `sort`, `order`, `index`, `rank`, `position`）作為 object key（`acc[sort] = ...`）。這些欄位不保證唯一，重複時後者覆蓋前者，造成靜默資料遺失
- **Data structure format mismatch**: 資料格式從 array 改為 object（或反過來），但部分消費端仍用舊格式操作（如對 object 呼叫 `.map()`、`.length`，或對 array 用 `Object.entries()`）
- **API parameter silently dropped**: API 呼叫移除了參數（如 `lang`, `page`, `limit`）但未確認新 API 是否內建處理，可能導致回傳資料不符預期
- **Shared state mutation**: 多處引用同一個 object/array，其中一處修改會影響其他消費端
- **Null/undefined access**: 對可能為 `null` 或 `undefined` 的值存取屬性，缺少 optional chaining 或預設值

### 🟡 WARN-level patterns
- **Duplicated transformation logic**: 相同的資料轉換邏輯出現在多個檔案，應抽成共用 utility
- **Inconsistent filtering**: 同一份資料在某些消費端有過濾條件（如 `display === true`）但在其他地方沒有
- **Loading/error state not reset**: `isLoading` 在 `catch` 中設定但缺少 `finally`，成功路徑依賴其他 async call 重置
- **Hanging Promise**: Promise 建構式有 `reject` 參數但從未呼叫，若 callback 未觸發則 Promise 永遠 pending
- **Naming inconsistency**: 同一概念在不同檔案使用不同名稱（如 `payable` vs `paid` vs `payment`）

### 🟢 NIT-level patterns
- Deprecated 程式碼用註解包起來而非刪除（git history 可還原）
- 多餘空格、缺少檔案末尾換行
- 殘留的 console.log 或 debug 語句
- 未使用的變數或 import

## Output Format

### 總覽
- PR 標題、作者、分支、狀態
- 用 2-3 句話總結這個 PR 做了什麼
- 變更檔案數、新增/刪除行數

### 問題清單

只針對 diff 中實際變更的程式碼，列出發現的問題。每個問題用以下格式詳細說明：

**[燈號] 問題標題**
- 檔案：`path/to/file` 相關程式碼片段
- 說明：問題是什麼、為什麼有風險
- 建議：如何修正

如果沒有發現問題，直接寫「沒有發現問題」。不要為了湊數而硬找問題。

### 彙整表

在報告最末端輸出一個總結表格，讓人只看這張表就能掌握全貌：

| # | 燈號 | 檔案 | 問題摘要 |
|---|------|------|----------|
| 1 | 🔴 | `path/to/file` | 一句話描述 |
| 2 | 🟡 | `path/to/file` | 一句話描述 |
| ... | | | |

**判定結果：**
- 🟢 **APPROVE（通過）**：沒有 🔴 BUG 級問題
- 🔴 **REQUEST CHANGES（要求修改）**：有 🔴 BUG 級問題，列出必須修正的項目
- 🟡 **COMMENT（建議）**：只有 🟡 WARN / 🟢 NIT 級問題

統計：🔴 x 個 / 🟡 x 個 / 🟢 x 個

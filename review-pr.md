Review the GitHub PR based on the data provided below.

## Instructions

- The PR metadata (JSON) and diff are already attached at the bottom of this prompt. Do NOT run any commands to fetch them — use the provided data directly.
- Read the entire diff carefully. Only analyze the changed lines and their immediate context — do NOT review unchanged code or raise issues unrelated to the diff.
- Review each changed line against the "Detection Checklist" below. Only report issues that actually appear in the diff.
- All output MUST be in Traditional Chinese (繁體中文). Keep code snippets, file paths, and technical terms in English.

## Detection Checklist

### 🔴 BUG-level patterns

- **Data loss via key collision**: `.reduce()` or `forEach` 使用語意為排序、順序的欄位（如 `sort`, `order`, `index`, `rank`, `position`）作為 object key（`acc[sort] = ...`）。這些欄位不保證唯一，重複時後者覆蓋前者，造成靜默資料遺失

  <example>
  ❌ 有問題：
  ```js
  items.reduce((acc, item) => { acc[item.sort] = item; return acc; }, {})
  // sort=1 出現兩次 → 第二筆覆蓋第一筆，靜默遺失資料
  ```
  ✅ 正確：
  ```js
  items.reduce((acc, item) => { acc[item.id] = item; return acc; }, {})
  // 使用唯一識別欄位，或保持 array 結構
  ```
  </example>

- **Data structure format mismatch**: 資料格式從 array 改為 object（或反過來），但部分消費端仍用舊格式操作（如對 object 呼叫 `.map()`、`.length`，或對 array 用 `Object.entries()`）

  <example>
  ❌ 有問題：
  ```js
  // API 回傳從 array 改為 object
  const data = { a: 1, b: 2 }
  data.map(x => x + 1) // TypeError: data.map is not a function
  ```
  ✅ 正確：
  ```js
  Object.values(data).map(x => x + 1)
  // 或同步更新所有消費端
  ```
  </example>

- **API parameter silently dropped**: API 呼叫移除了參數（如 `lang`, `page`, `limit`）但未確認新 API 是否內建處理，可能導致回傳資料不符預期

  <example>
  ❌ 有問題：
  ```js
  // 舊：fetchItems({ lang: 'zh', page: 1, limit: 20 })
  // 新：fetchItems() ← lang 被移除，API 預設回傳英文資料
  ```
  ✅ 正確：
  ```js
  fetchItems({ lang: 'zh' })
  // 確認新 API 是否內建 lang 處理，若否則保留參數
  ```
  </example>

- **Shared state mutation**: 多處引用同一個 object/array，其中一處修改會影響其他消費端

  <example>
  ❌ 有問題：
  ```js
  const config = getDefaultConfig()
  config.timeout = 5000 // 修改了共用的 object reference
  ```
  ✅ 正確：
  ```js
  const config = { ...getDefaultConfig(), timeout: 5000 }
  ```
  </example>

- **Null/undefined access**: 對可能為 `null` 或 `undefined` 的值存取屬性，缺少 optional chaining 或預設值

  <example>
  ❌ 有問題：
  ```js
  const name = user.profile.name // user.profile 可能為 undefined
  ```
  ✅ 正確：
  ```js
  const name = user?.profile?.name ?? 'Unknown'
  ```
  </example>

### 🟡 WARN-level patterns

- **Duplicated transformation logic**: 相同的資料轉換邏輯出現在多個檔案，應抽成共用 utility

- **Inconsistent filtering**: 同一份資料在某些消費端有過濾條件（如 `display === true`）但在其他地方沒有

- **Loading/error state not reset**: `isLoading` 在 `catch` 中設定但缺少 `finally`，成功路徑依賴其他 async call 重置

  <example>
  ❌ 有問題：
  ```js
  try {
    setLoading(true)
    const data = await fetchData()
    setData(data)
    // 如果後續還有 async call 失敗，loading 永遠不會被重置
  } catch (e) {
    setLoading(false)
  }
  ```
  ✅ 正確：
  ```js
  try {
    setLoading(true)
    const data = await fetchData()
    setData(data)
  } catch (e) {
    setError(e)
  } finally {
    setLoading(false)
  }
  ```
  </example>

- **Hanging Promise**: Promise 建構式有 `reject` 參數但從未呼叫，若 callback 未觸發則 Promise 永遠 pending

- **Naming inconsistency**: 同一概念在不同檔案使用不同名稱（如 `payable` vs `paid` vs `payment`）

### 🟢 NIT-level patterns

- Deprecated 程式碼用註解包起來而非刪除（git history 可還原）
- 殘留的 console.log 或 debug 語句
- 未使用的變數或 import

## Do NOT Report

以下項目不屬於本 review 範圍，請勿報告：

- **純風格 / 格式問題**：縮排、空格、分號、換行等 — 這些由 linter / formatter 處理
- **型別標註缺失**：由 TypeScript 編譯器或 type checker 負責
- **缺少 JSDoc / 註解**：除非邏輯極度不直觀，否則不報告
- **對未變更程式碼的建議**：只 review diff 中的變更，不要對既有程式碼提意見
- **已有 test 覆蓋的邊界情境**：如果 diff 中可見對應 test，不需重複提醒
- **主觀偏好**：命名風格、程式碼組織方式等無明確對錯之分的選擇

## Output Format

### 總覽
- PR 標題、作者、分支、狀態
- 用 2-3 句話總結這個 PR 做了什麼
- 變更檔案數、新增/刪除行數

### 問題清單

只針對 diff 中實際變更的程式碼，列出發現的問題。每個問題用以下格式詳細說明：

**[燈號] 問題標題** `[信心度]`
- 檔案：`path/to/file` 相關程式碼片段
- 說明：問題是什麼、為什麼有風險
- 建議：如何修正

信心度標準：
- **HIGH**：從 diff 中可直接確認的問題，不需額外上下文
- **MEDIUM**：需要看更多 codebase 上下文才能確認（建議用 verify-bug 驗證）
- **LOW**：可能是問題，取決於執行環境或外部條件

如果沒有發現問題，直接寫「沒有發現問題」。不要為了湊數而硬找問題。

### 彙整表

在報告最末端輸出一個總結表格，讓人只看這張表就能掌握全貌：

| # | 燈號 | 信心度 | 檔案 | 問題摘要 |
|---|------|--------|------|----------|
| 1 | 🔴 | HIGH | `path/to/file` | 一句話描述 |
| 2 | 🟡 | MEDIUM | `path/to/file` | 一句話描述 |
| ... | | | | |

**判定結果：**
- 🟢 **APPROVE（通過）**：沒有 🔴 BUG 級問題
- 🔴 **REQUEST CHANGES（要求修改）**：有 🔴 BUG 級 HIGH/MEDIUM 信心度問題，列出必須修正的項目
- 🟡 **COMMENT（建議）**：只有 🟡 WARN / 🟢 NIT 級問題，或只有 LOW 信心度的 🔴 問題

統計：🔴 x 個 / 🟡 x 個 / 🟢 x 個

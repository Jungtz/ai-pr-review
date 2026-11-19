### 通用 Code Smell & Anti-patterns

- **Off-by-one / boundary error**: 迴圈或 slice 的邊界條件錯誤，導致多取或少取一筆資料

  <example>
  ❌ 有問題：
  ```
  for (i = 0; i <= len; i++)   // 應為 < len，多迭代一次
  items[1:]                     // 跳過第一筆，是否為預期行為？
  ```
  ✅ 正確：
  ```
  for (i = 0; i < len; i++)
  ```
  </example>

- **Condition logic error**: 條件判斷反轉（`&&` vs `||`）、缺少 else/default branch、或否定條件寫反。
  **注意：若條件行為與 PR 的功能目的一致（例如 PR 新增權限檢查，條件刻意變嚴），應視為刻意設計（Business Logic），不是 BUG。**

  <example>
  ❌ 有問題：
  ```
  if (a && b) { ... }   // 應為 a || b，導致條件過嚴永遠不進入
  ```
  </example>

- **Copy-paste error**: 複製相似區塊後漏改變數、欄位或條件，導致兩處引用同一個值

  <example>
  ❌ 有問題：
  ```
  const width = rect.width
  const height = rect.width   // 應為 rect.height
  ```
  </example>

- **Race condition**: 多個非同步操作之間存在隱含的順序依賴，但沒有明確等待或同步機制

- **Missing await / unhandled promise**: async 呼叫沒有 await 或沒有處理 rejection，導致後續程式在結果就緒前執行，或錯誤被吞掉

  <example>
  ❌ 有問題：
  ```
  const user = getUser(id)                     // getUser 是 async，user 實為 Promise
  items.forEach(async i => await save(i))      // forEach 不等待，外層以為已全部完成
  ```
  </example>

- **Error swallowed silently**: catch/except/recover 區塊為空或只有 log，沒有重新拋出或回傳錯誤狀態，導致上層無法得知失敗

  <example>
  ❌ 有問題：
  ```
  try { ... } catch (e) { console.log(e) }    // 呼叫端以為成功
  except Exception: pass                        // Python 靜默吞掉錯誤
  ```
  </example>

- **Resource leak**: 開啟的檔案、連線、subscription 沒有在所有路徑（包括 error path）中正確關閉或清理

- **Hardcoded secret / credential**: 程式碼中直接寫入 API key、密碼、token 等敏感資訊

- **Injection / unsafe input**: 未經驗證或跳脫的外部輸入直接拼進 SQL、shell 指令、HTML、檔案路徑。須能在 diff 中指出具體的輸入來源與落點，否則屬於泛用安全建議，不報

  <example>
  ❌ 有問題：
  ```
  db.query(`SELECT * FROM users WHERE id = ${req.query.id}`)   // SQL injection
  el.innerHTML = params.get('name')                             // XSS
  ```
  </example>

- **Duplicated logic**: 相同的邏輯出現在多處，應抽成共用函式

- **Inconsistent error handling**: 同一類操作在某些地方有錯誤處理，但在其他地方沒有

- **Magic number / string**: 程式碼中直接使用未命名的常數值，語意不明

- **Misleading / stale comment**: 註解描述的行為與程式碼實際行為矛盾（參數或邏輯已改但註解沒同步、註解宣稱的保證程式碼做不到），誤導後續維護者

  <example>
  ❌ 有問題：
  ```
  // 回傳快取結果，不會發出網路請求
  const data = await fetchUser(id)   // 實際每次都打 API
  ```
  </example>

- **Naming inconsistency**: 同一概念在不同檔案使用不同名稱

- Deprecated 程式碼用註解包起來而非刪除（git history 可還原）
- 殘留的 debug 語句（console.log、print、fmt.Println 等）
- 未使用的變數或 import

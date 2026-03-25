### 🔴 BUG-level patterns (JavaScript / TypeScript)

- **Data loss via key collision**: `.reduce()` 或 `forEach` 使用語意為排序、順序的欄位（如 `sort`, `order`, `index`, `rank`, `position`）作為 object key（`acc[sort] = ...`）。這些欄位不保證唯一，重複時後者覆蓋前者，造成靜默資料遺失

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
  ```
  </example>

- **API parameter silently dropped**: API 呼叫移除了參數（如 `lang`, `page`, `limit`）但未確認新 API 是否內建處理，可能導致回傳資料不符預期

  <example>
  ❌ 有問題：
  ```js
  // 舊：fetchItems({ lang: 'zh', page: 1, limit: 20 })
  // 新：fetchItems() ← lang 被移除，API 預設回傳英文資料
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

- **useEffect missing cleanup**: `useEffect` 中建立了 subscription、timer 或 event listener，但沒有 return cleanup function，導致 memory leak

  <example>
  ❌ 有問題：
  ```js
  useEffect(() => {
    const id = setInterval(poll, 5000)
    // 缺少 return () => clearInterval(id)
  }, [])
  ```
  </example>

- **useEffect missing dependency**: `useEffect` 使用了外部變數但 dependency array 中未列出，導致 stale closure

- **XSS via dangerouslySetInnerHTML**: 未經 sanitize 的使用者輸入直接傳入 `dangerouslySetInnerHTML` 或 `innerHTML`

### 🟡 WARN-level patterns (JavaScript / TypeScript)

- **Loading/error state not reset**: `isLoading` 在 `catch` 中設定但缺少 `finally`，成功路徑依賴其他 async call 重置

  <example>
  ❌ 有問題：
  ```js
  try {
    setLoading(true)
    const data = await fetchData()
    setData(data)
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
  } finally {
    setLoading(false)
  }
  ```
  </example>

- **Hanging Promise**: Promise 建構式有 `reject` 參數但從未呼叫，若 callback 未觸發則 Promise 永遠 pending

- **Inconsistent filtering**: 同一份資料在某些消費端有過濾條件（如 `display === true`）但在其他地方沒有

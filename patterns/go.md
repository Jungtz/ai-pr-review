### 🔴 BUG-level patterns (Go)

- **Unchecked error**: 函式回傳 `error` 但呼叫端用 `_` 忽略或完全沒檢查，導致錯誤靜默傳播

  <example>
  ❌ 有問題：
  ```go
  result, _ := doSomething()  // error 被忽略
  f, _ := os.Open(path)       // 如果開檔失敗，f 為 nil，後續 panic
  ```
  ✅ 正確：
  ```go
  result, err := doSomething()
  if err != nil {
      return fmt.Errorf("doSomething failed: %w", err)
  }
  ```
  </example>

- **Nil pointer dereference**: 未檢查 pointer 是否為 nil 就存取其成員，尤其在 error 非 nil 時 result pointer 通常為 nil

  <example>
  ❌ 有問題：
  ```go
  resp, err := http.Get(url)
  defer resp.Body.Close()  // 如果 err != nil，resp 為 nil → panic
  ```
  ✅ 正確：
  ```go
  resp, err := http.Get(url)
  if err != nil {
      return err
  }
  defer resp.Body.Close()
  ```
  </example>

- **Goroutine leak**: 啟動 goroutine 但沒有退出機制（context cancel、done channel），導致 goroutine 永遠阻塞

  <example>
  ❌ 有問題：
  ```go
  go func() {
      for msg := range ch {  // 如果 ch 永遠沒被 close，goroutine 永遠阻塞
          process(msg)
      }
  }()
  ```
  </example>

- **Loop variable capture in goroutine**: 在迴圈中啟動 goroutine 直接引用迴圈變數，所有 goroutine 可能都讀到最後一次迭代的值（Go < 1.22）

  <example>
  ❌ 有問題（Go < 1.22）：
  ```go
  for _, item := range items {
      go func() {
          process(item)  // 所有 goroutine 可能都用到最後一個 item
      }()
  }
  ```
  ✅ 正確：
  ```go
  for _, item := range items {
      go func(it Item) {
          process(it)
      }(item)
  }
  ```
  </example>

- **Data race on shared variable**: 多個 goroutine 存取同一個變數但沒有 mutex 或 channel 保護

- **Deferred call in loop**: 在迴圈中使用 `defer`，資源要到函式結束才釋放，而非每次迭代結束

  <example>
  ❌ 有問題：
  ```go
  for _, f := range files {
      fd, _ := os.Open(f)
      defer fd.Close()  // 所有檔案都要到函式結束才關閉
  }
  ```
  </example>

### 🟡 WARN-level patterns (Go)

- **Context not propagated**: 函式接收 `context.Context` 但傳 `context.Background()` 給下游呼叫，導致 cancel/timeout 無法傳播

- **Sync primitives copied**: 複製了包含 `sync.Mutex`、`sync.WaitGroup` 等的 struct，導致鎖失效

- **Unhandled channel close**: 從 channel 讀取時沒有檢查 `ok` 值，closed channel 回傳 zero value 可能被當作有效資料

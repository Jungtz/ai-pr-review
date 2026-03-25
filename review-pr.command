#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PROMPT_FILE="$SCRIPT_DIR/review-pr.md"
TOTAL_START=$SECONDS

# Timer helper: prints elapsed seconds for a step
step_time() {
  local start=$1
  local elapsed=$(( SECONDS - start ))
  echo "(${elapsed}s)"
}

# Spinner function
spin() {
  local pid=$1
  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local i=0
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( SECONDS - start ))
    local min=$(( elapsed / 60 ))
    local sec=$(( elapsed % 60 ))
    printf "\r   ⏳ 分析中 ${chars:i++%${#chars}:1} %02d:%02d " "$min" "$sec"
    sleep 0.1
  done
  local elapsed=$(( SECONDS - start ))
  printf "\r   ✓ 分析完成 (${elapsed}s)              \n"
}

# Run AI command based on engine choice
strip_ansi() {
  sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | sed $'s/\x1b\[[0-9;]*m//g'
}

run_ai() {
  local engine=$1
  local prompt_file=$2
  local output_file=$3
  local prompt_content
  prompt_content=$(cat "$prompt_file")
  local raw_file="${output_file}.raw"

  case "$engine" in
    1)
      echo "$prompt_content" | claude -p --model sonnet --output-format json > "$raw_file"
      jq -r '.result // empty' "$raw_file" > "$output_file"
      jq '{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}' "$raw_file" > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    2)
      echo "$prompt_content" | claude -p --model opus --output-format json > "$raw_file"
      jq -r '.result // empty' "$raw_file" > "$output_file"
      jq '{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}' "$raw_file" > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    3)
      opencode run --format json "$prompt_content" > "$raw_file" 2>/dev/null
      # 提取文字內容
      jq -r 'select(.type=="text") | .part.text // empty' "$raw_file" > "$output_file"
      # 提取 token 用量
      jq -r 'select(.type=="step_finish") | .part' "$raw_file" | jq -s 'last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}' > "${output_file}.usage" 2>/dev/null
      rm -f "$raw_file"
      ;;
    *) eval "$engine" < "$prompt_file" > "$output_file"; echo '{}' > "${output_file}.usage" ;;
  esac
}

ENGINE_LABELS=("" "Claude Sonnet" "Claude Opus" "opencode" "自訂")

# Step 1: 輸入 PR 連結
echo "📋 請貼上 PR 連結："
read -r PR_URL

if [ -z "$PR_URL" ]; then
  echo "❌ 未輸入 PR 連結"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

# 解析 owner/repo 和 PR number
REPO=$(echo "$PR_URL" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||')
PR_NUMBER=$(echo "$PR_URL" | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+')

if [ -z "$PR_NUMBER" ] || [ -z "$REPO" ]; then
  echo "❌ 無法解析 PR 連結"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

# Step 2: 選擇 AI 引擎
echo ""
echo "🤖 選擇 AI 引擎："
echo "  [1] Claude Sonnet（預設，正式 review）"
echo "  [2] Claude Opus（深度分析）"
echo "  [3] opencode"
echo "  [4] 自訂指令"
echo ""
read -r -p "選擇 [1/2/3/4]（直接 Enter 為 1）: " ENGINE_CHOICE
ENGINE_CHOICE=${ENGINE_CHOICE:-1}

if [ "$ENGINE_CHOICE" = "4" ]; then
  echo ""
  echo "請輸入自訂指令（需支援 stdin 輸入，stdout 輸出）："
  echo "範例: claude -p --model haiku"
  read -r ENGINE_CHOICE
fi

echo "   → 使用: ${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}"

# Step 3: 選擇輸出方式
TIMESTAMP=$(date +%y%m%d%H%M%S)
FILENAME="PR_${PR_NUMBER}_${TIMESTAMP}.md"

echo ""
echo "📄 輸出方式："
echo "  [1] 儲存為 ${FILENAME}（預設）"
echo "  [2] 用 less 預覽"
echo ""
read -r -p "選擇 [1/2]（直接 Enter 為 1）: " OUTPUT_CHOICE
OUTPUT_CHOICE=${OUTPUT_CHOICE:-1}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 4: 取得 PR 資訊
STEP_START=$SECONDS
echo "📡 [1/4] 取得 PR 資訊..."
PR_META=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json title,additions,deletions,changedFiles,state,author,baseRefName,headRefName 2>&1)
if [ $? -ne 0 ]; then
  echo "❌ 無法取得 PR 資訊: $PR_META"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

PR_TITLE=$(echo "$PR_META" | jq -r '.title')
PR_FILES=$(echo "$PR_META" | jq -r '.changedFiles')
PR_ADD=$(echo "$PR_META" | jq -r '.additions')
PR_DEL=$(echo "$PR_META" | jq -r '.deletions')
PR_HEAD_BRANCH=$(echo "$PR_META" | jq -r '.headRefName')
echo "   ✓ ${PR_TITLE}"
echo "   ✓ ${PR_FILES} 個檔案 | +${PR_ADD} -${PR_DEL} $(step_time $STEP_START)"
echo ""

# Step 5: 取得 PR diff
STEP_START=$SECONDS
echo "📡 [2/4] 取得 PR diff..."
PR_DIFF=$(gh pr diff "$PR_NUMBER" --repo "$REPO" 2>&1)
if [ $? -ne 0 ]; then
  echo "❌ 無法取得 diff: $PR_DIFF"
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi
DIFF_LINES=$(echo "$PR_DIFF" | wc -l | tr -d ' ')
echo "   ✓ ${DIFF_LINES} 行 diff $(step_time $STEP_START)"
echo ""

# Step 6: 組合 prompt 並寫入暫存檔
STEP_START=$SECONDS
echo "🔧 [3/4] 準備分析資料..."
PROMPT_TEMPLATE=$(cat "$PROMPT_FILE")
PROMPT_TMPFILE=$(mktemp)
cat > "$PROMPT_TMPFILE" <<EOF
${PROMPT_TEMPLATE}

## PR Metadata (JSON)
\`\`\`json
${PR_META}
\`\`\`

## PR Diff
\`\`\`diff
${PR_DIFF}
\`\`\`
EOF
echo "   ✓ 完成 $(step_time $STEP_START)"
echo ""

# Step 7: AI 分析（背景執行 + spinner）
echo "🤖 [4/4] AI 分析中..."
TMPFILE=$(mktemp)

run_ai "$ENGINE_CHOICE" "$PROMPT_TMPFILE" "$TMPFILE" &
spin $!
rm -f "$PROMPT_TMPFILE"

# 總耗時
TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
TOTAL_MIN=$(( TOTAL_ELAPSED / 60 ))
TOTAL_SEC=$(( TOTAL_ELAPSED % 60 ))

# 讀取 token 用量
USAGE_FILE="${TMPFILE}.usage"
INPUT_TOKENS=$(jq -r '.input_tokens // 0' "$USAGE_FILE" 2>/dev/null)
OUTPUT_TOKENS=$(jq -r '.output_tokens // 0' "$USAGE_FILE" 2>/dev/null)
COST_USD=$(jq -r '.cost_usd // 0' "$USAGE_FILE" 2>/dev/null)
INPUT_TOKENS=${INPUT_TOKENS:-0}
OUTPUT_TOKENS=${OUTPUT_TOKENS:-0}
COST_USD=${COST_USD:-0}
rm -f "$USAGE_FILE"

ENGINE_NAME="${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}"

if [ "$OUTPUT_CHOICE" = "2" ]; then
  less "$TMPFILE"
  # 也存一份供驗證使用
  {
    cat "$TMPFILE"
    printf "\n---\n"
    printf "Model: %s | Total: %02d:%02d | Tokens: %d in / %d out | Cost: \$%.4f\n" "$ENGINE_NAME" "$TOTAL_MIN" "$TOTAL_SEC" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"
    printf "<!-- verify-meta: repo=%s branch=%s -->\n" "$REPO" "$PR_HEAD_BRANCH"
  } > "$FILENAME"
  rm -f "$TMPFILE"
else
  {
    cat "$TMPFILE"
    printf "\n---\n"
    printf "Model: %s | Total: %02d:%02d | Tokens: %d in / %d out | Cost: \$%.4f\n" "$ENGINE_NAME" "$TOTAL_MIN" "$TOTAL_SEC" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"
    printf "<!-- verify-meta: repo=%s branch=%s -->\n" "$REPO" "$PR_HEAD_BRANCH"
  } > "$FILENAME"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  awk '/^#+ *彙整表/,0' "$TMPFILE"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "✅ 完整報告已儲存至 ${SCRIPT_DIR}/${FILENAME}\n"
  printf "⏱  總耗時 %02d:%02d\n" "$TOTAL_MIN" "$TOTAL_SEC"
  printf "📊 Tokens: %'d in / %'d out | 費用: \$%.4f\n" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"
  rm -f "$TMPFILE"
fi

# Step 8: 檢查 🔴 問題，詢問是否驗證
BUG_COUNT=$(grep '統計' "$FILENAME" 2>/dev/null | grep -oE '🔴[^/]*' | grep -oE '[0-9]+' | head -1)
BUG_COUNT=${BUG_COUNT:-0}
if [ "$BUG_COUNT" -gt 0 ]; then
  echo ""
  echo "🔍 發現 ${BUG_COUNT} 個 🔴 BUG 級問題"
  read -r -p "是否進行深度驗證？ [y/N]: " VERIFY
  VERIFY=${VERIFY:-N}
  if [[ "$VERIFY" =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/verify-bug.command" "$SCRIPT_DIR/$FILENAME"
    exit 0
  else
    echo "💡 稍後可執行: ./verify-bug.command ${FILENAME}"
  fi
else
  echo ""
  echo "✅ 沒有 🔴 BUG 級問題"
fi

echo ""
echo "按任意鍵關閉..."
read -n 1

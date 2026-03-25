#!/bin/bash

# Pattern Evolution Script
# Analyzes historical review/verify reports to suggest pattern improvements

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/lib/api-helper.sh"

PROMPT_FILE="$SCRIPT_DIR/prompts/evolve.md"
PATTERNS_DIR="$SCRIPT_DIR/patterns"
RESULTS_DIR="$SCRIPT_DIR/results"
API_CONFIG="$SCRIPT_DIR/.api-config"
TOTAL_START=$SECONDS

# Timer helper
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

# Strip ANSI
strip_ansi() {
  sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | sed $'s/\x1b\[[0-9;]*m//g'
}

echo ""
echo "🧬 Pattern Evolution"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Step 1: 掃描報告
STEP_START=$SECONDS
echo "📡 [1/3] 掃描歷史報告..."

REVIEW_FILES=$(ls "$RESULTS_DIR"/PR_*[0-9].md 2>/dev/null | grep -v '_verify')
VERIFY_FILES=$(ls "$RESULTS_DIR"/PR_*_verify.md 2>/dev/null)

REVIEW_COUNT=$(echo "$REVIEW_FILES" | grep -c '.' 2>/dev/null || echo 0)
VERIFY_COUNT=$(echo "$VERIFY_FILES" | grep -c '.' 2>/dev/null || echo 0)

if [ "$REVIEW_COUNT" -eq 0 ]; then
  echo "   ❌ results/ 中沒有找到任何報告"
  echo ""
  echo "按任意鍵關閉..."
  read -n 1
  exit 1
fi

echo "   ✓ ${REVIEW_COUNT} 份 review 報告, ${VERIFY_COUNT} 份驗證報告 $(step_time $STEP_START)"
echo ""

# 選擇 AI 引擎
ENGINE_LABELS=("" "Claude Opus" "opencode" "")
echo "🤖 選擇分析引擎（建議使用較強模型，需跨報告歸納分析）："
echo "  [1] Claude Opus（預設）"
echo "  [2] opencode"
echo "  [3] OpenAI 相容 API（Ollama / OpenRouter / 其他）"
echo ""
read -r -p "選擇 [1/2/3]（直接 Enter 為 1）: " ENGINE_CHOICE
ENGINE_CHOICE=${ENGINE_CHOICE:-1}

if [ "$ENGINE_CHOICE" = "3" ]; then
  echo ""
  prompt_api_settings "$API_CONFIG"
fi

case "$ENGINE_CHOICE" in
  3) echo "   → 使用: API (${API_MODEL} @ ${API_BASE})" ;;
  *) echo "   → 使用: ${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}" ;;
esac
echo ""

# Step 2: 組合 prompt
STEP_START=$SECONDS
echo "🔧 [2/3] 準備分析資料..."

# 收集所有 pattern 檔
PATTERNS_CONTENT=""
for PFILE in "$PATTERNS_DIR"/*.md; do
  if [ -f "$PFILE" ]; then
    PNAME=$(basename "$PFILE")
    PATTERNS_CONTENT="${PATTERNS_CONTENT}
### File: patterns/${PNAME}

$(cat "$PFILE")

---
"
  fi
done

# 收集所有報告（review + verify 配對）
REPORTS_CONTENT=""
for RFILE in $REVIEW_FILES; do
  RNAME=$(basename "$RFILE")
  REPORTS_CONTENT="${REPORTS_CONTENT}
### Review: ${RNAME}

$(cat "$RFILE")

---
"
  # 找對應的 verify 報告
  VFILE="${RFILE%.md}_verify.md"
  if [ -f "$VFILE" ]; then
    VNAME=$(basename "$VFILE")
    REPORTS_CONTENT="${REPORTS_CONTENT}
### Verify: ${VNAME}

$(cat "$VFILE")

---
"
  fi
done

# 組合最終 prompt
PROMPT_TEMPLATE=$(cat "$PROMPT_FILE")
PROMPT_TMPFILE=$(mktemp)
cat > "$PROMPT_TMPFILE" <<EOF
${PROMPT_TEMPLATE}

## Current Patterns

${PATTERNS_CONTENT}

## Historical Reports

${REPORTS_CONTENT}
EOF

PROMPT_SIZE=$(wc -c < "$PROMPT_TMPFILE" | tr -d ' ')
PROMPT_SIZE_KB=$((PROMPT_SIZE / 1024))
echo "   ✓ Prompt 大小: ${PROMPT_SIZE_KB}KB $(step_time $STEP_START)"
echo ""

# Step 3: AI 分析
echo "🤖 [3/3] AI 分析中..."

TMPFILE=$(mktemp)
RAW_FILE="${TMPFILE}.raw"
USAGE_FILE="${TMPFILE}.usage"

if [ "$ENGINE_CHOICE" = "2" ]; then
  PROMPT_CONTENT=$(cat "$PROMPT_TMPFILE")
  opencode run --format json "$PROMPT_CONTENT" > "$RAW_FILE" 2>/dev/null &
  spin $!
  jq -r 'select(.type=="text") | .part.text // empty' "$RAW_FILE" > "$TMPFILE"
  jq -r 'select(.type=="step_finish") | .part' "$RAW_FILE" | jq -s 'last | {input_tokens: .tokens.input, output_tokens: .tokens.output, cache_creation: .tokens.cache.write, cache_read: .tokens.cache.read, cost_usd: .cost}' > "$USAGE_FILE" 2>/dev/null
elif [ "$ENGINE_CHOICE" = "3" ]; then
  run_api "$API_BASE" "$API_KEY" "$API_MODEL" "$PROMPT_TMPFILE" "$TMPFILE" &
  spin $!
else
  echo "$( cat "$PROMPT_TMPFILE" )" | claude -p --model opus --output-format json > "$RAW_FILE" &
  spin $!
  jq -r '.result // empty' "$RAW_FILE" > "$TMPFILE"
  jq '{input_tokens: .usage.input_tokens, output_tokens: .usage.output_tokens, cache_creation: .usage.cache_creation_input_tokens, cache_read: .usage.cache_read_input_tokens, cost_usd: .total_cost_usd}' "$RAW_FILE" > "$USAGE_FILE" 2>/dev/null
fi
rm -f "$RAW_FILE" "$PROMPT_TMPFILE"

# 讀取 token 用量
USAGE_FILE="${TMPFILE}.usage"
INPUT_TOKENS=$(jq -r '.input_tokens // 0' "$USAGE_FILE" 2>/dev/null)
OUTPUT_TOKENS=$(jq -r '.output_tokens // 0' "$USAGE_FILE" 2>/dev/null)
COST_USD=$(jq -r '.cost_usd // 0' "$USAGE_FILE" 2>/dev/null)
INPUT_TOKENS=${INPUT_TOKENS:-0}
OUTPUT_TOKENS=${OUTPUT_TOKENS:-0}
COST_USD=${COST_USD:-0}
rm -f "$USAGE_FILE"

# 總耗時
TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
TOTAL_MIN=$(( TOTAL_ELAPSED / 60 ))
TOTAL_SEC=$(( TOTAL_ELAPSED % 60 ))

# 儲存結果
TIMESTAMP=$(date +%y%m%d%H%M%S)
OUTPUT_FILE="$RESULTS_DIR/evolve_${TIMESTAMP}.md"

{
  cat "$TMPFILE"
  printf "\n---\n"
  case "$ENGINE_CHOICE" in
    3) ENGINE_NAME="API (${API_MODEL})" ;;
    *) ENGINE_NAME="${ENGINE_LABELS[$ENGINE_CHOICE]:-$ENGINE_CHOICE}" ;;
  esac
  printf "Model: %s | Total: %02d:%02d | Tokens: %d in / %d out | Cost: \$%.4f\n" "$ENGINE_NAME" "$TOTAL_MIN" "$TOTAL_SEC" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"
  printf "Reports analyzed: %d review + %d verify\n" "$REVIEW_COUNT" "$VERIFY_COUNT"
} > "$OUTPUT_FILE"

# 輸出
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
cat "$TMPFILE"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "✅ 建議報告已儲存至 %s\n" "$OUTPUT_FILE"
printf "⏱  總耗時 %02d:%02d\n" "$TOTAL_MIN" "$TOTAL_SEC"
printf "📊 Tokens: %'d in / %'d out | 費用: \$%.4f\n" "$INPUT_TOKENS" "$OUTPUT_TOKENS" "$COST_USD"

rm -f "$TMPFILE"

echo ""
echo "💡 請人工審閱建議後，手動更新 patterns/ 下的檔案"
echo ""
echo "按任意鍵關閉..."
read -n 1

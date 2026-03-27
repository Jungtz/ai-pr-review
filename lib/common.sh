#!/bin/bash
# Shared utility functions for all scripts
# Usage: source "$SCRIPT_DIR/lib/common.sh"

# ── Timer ─────────────────────────────────────────────────

# Print elapsed seconds for a step
# Usage: step_time $STEP_START
step_time() {
  local start=$1
  local elapsed=$(( SECONDS - start ))
  echo "(${elapsed}s)"
}

# ── Spinner ───────────────────────────────────────────────

# Show a spinner while a background process runs
# Usage: some_command & spin $! "分析中"
spin() {
  local pid=$1
  local label=${2:-"處理中"}
  local chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  local i=0
  local start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    local elapsed=$(( SECONDS - start ))
    local min=$(( elapsed / 60 ))
    local sec=$(( elapsed % 60 ))
    printf "\r   ⏳ ${label} ${chars:i++%${#chars}:1} %02d:%02d " "$min" "$sec"
    sleep 0.1
  done
  local elapsed=$(( SECONDS - start ))
  printf "\r   ✓ 完成 (${elapsed}s)              \n"
}

# ── ANSI Stripping ────────────────────────────────────────

# Strip ANSI escape codes and control characters from stdin
strip_ansi() {
  sed $'s/\x1b\[[0-9;]*[a-zA-Z]//g' | sed $'s/\x1b\[[0-9;]*m//g' | sed $'s/\r//g; s/\x04//g; s/\x08//g'
}

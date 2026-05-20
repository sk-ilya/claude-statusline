#!/bin/bash

input=$(cat)
{ read -r cwd; read -r model; read -r effort; read -r ctx_pct; } \
    < <(echo "$input" | jq -r '.workspace.current_dir, (.model.display_name // ""), (.effort.level // ""), (.context_window.used_percentage // "")')
cd "$cwd" 2>/dev/null || cd "$HOME"
dir=$(basename "$cwd")

git_info=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git branch --show-current 2>/dev/null || git rev-parse --short HEAD 2>/dev/null)
    status=""
    git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null || status="*"
    git_info="  ${branch}${status}"
fi

meta=""
[ -n "$model" ] && meta="${model,,}"
if [ -n "$effort" ]; then
    if [ "$effort" = "max" ]; then
        meta="$meta ·  $effort"
    else
        meta="$meta · $effort"
    fi
fi
if [ -n "$ctx_pct" ]; then
    ctx_color="" reset=""
    pct=${ctx_pct%.*}
    if [ "$pct" -ge 95 ] 2>/dev/null; then ctx_color="\033[31m" reset="\033[0m"
    elif [ "$pct" -ge 80 ] 2>/dev/null; then ctx_color="\033[38;5;208m" reset="\033[0m"
    elif [ "$pct" -ge 60 ] 2>/dev/null; then ctx_color="\033[33m" reset="\033[0m"
    fi
    meta="$meta · ${ctx_color}${ctx_pct}%${reset}"
fi
[ -n "$meta" ] && meta=" [$meta]"

printf " %s%s%b" "$dir" "$git_info" "$meta"

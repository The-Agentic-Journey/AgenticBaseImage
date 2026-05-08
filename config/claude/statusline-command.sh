#!/usr/bin/env bash
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Shorten home directory to ~
home="$HOME"
short_cwd="${cwd/#$home/\~}"

# Get git branch, skip optional locks
git_branch=""
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
fi

# Build status line
parts="$short_cwd"

if [ -n "$git_branch" ]; then
  parts="$parts  $git_branch"
fi

if [ -n "$used" ]; then
  printf -v used_fmt "%.0f" "$used" 2>/dev/null || used_fmt="$used"
  parts="$parts  ctx:${used_fmt}%"
fi

if [ -n "$model" ]; then
  parts="$parts  $model"
fi

printf '%s' "$parts"

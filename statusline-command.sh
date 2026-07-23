#!/usr/bin/env bash

# A status line should degrade gracefully if an optional segment fails.
export LC_ALL=C
export GIT_OPTIONAL_LOCKS=0

ICON_FOLDER=$'\xef\x81\xbc'
ICON_BRANCH=$'\xee\x9c\xa5'
ICON_ANGLES_UP=$'\xef\x84\x82'

CTX_THRESHOLDS=(95 80 60)
CTX_COLORS=($'\033[31m' $'\033[38;5;208m' $'\033[33m')
RESET=$'\033[0m'

is_number() {
    [[ $1 =~ ^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$ ]]
}

format_cost() {
    local raw=$1 session_id=$2
    local formatted config_dir cost_dir state_dir month state_file
    local tmp monthly_cost cleanup_stamp

    formatted=$(printf '%.2f' "$raw") || return
    local label="\$${formatted}"

    [[ $session_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        printf '%s' "$label"
        return
    }

    if [[ -n ${CLAUDE_CONFIG_DIR:-} ]]; then
        config_dir=$CLAUDE_CONFIG_DIR
    elif [[ -n ${HOME:-} ]]; then
        config_dir=$HOME/.claude
    else
        printf '%s' "$label"
        return
    fi

    cost_dir=$config_dir/costs
    state_dir=$cost_dir/sessions
    umask 077
    mkdir -p -- "$state_dir" 2>/dev/null || {
        printf '%s' "$label"
        return
    }

    month=$(date +%Y-%m)
    state_file="$state_dir/${session_id}.state"

    # Per-session lock via mkdir (atomic on all POSIX, works on macOS unlike flock).
    local lock_dir="$state_file.lkdir"
    if ! mkdir -- "$lock_dir" 2>/dev/null; then
        rmdir -- "$lock_dir" 2>/dev/null
        mkdir -- "$lock_dir" 2>/dev/null || {
            printf '%s' "$label"
            return
        }
    fi
    trap 'rmdir -- "$lock_dir" 2>/dev/null' RETURN

    # A session spanning months carries its full lifetime cost; month_baseline
    # records the cost at the start of the current month so only the delta
    # counts toward it.
    local month_baseline=0
    local saved_month saved_baseline saved_raw
    if [[ -f $state_file ]] \
        && IFS=$'\t' read -r saved_month saved_baseline saved_raw <"$state_file" \
        && [[ $saved_month =~ ^[0-9]{4}-[0-9]{2}$ ]] \
        && is_number "$saved_baseline" \
        && is_number "$saved_raw"; then
        if [[ $saved_month == "$month" ]]; then
            month_baseline=$saved_baseline
        else
            # Month rolled over: previous raw becomes the new baseline
            month_baseline=$saved_raw
        fi
    fi

    # Atomic write: tmp + mv prevents concurrent readers from seeing partial data
    tmp=$(mktemp "$state_dir/.tmp.XXXXXX" 2>/dev/null) || {
        printf '%s' "$label"
        return
    }
    if printf '%s\t%s\t%s\n' "$month" "$month_baseline" "$raw" >"$tmp" \
        && mv -f -- "$tmp" "$state_file"; then
        :
    else
        rm -f -- "$tmp"
        printf '%s' "$label"
        return
    fi

    # Monthly total: sum (raw - baseline) across all session files for this month.
    # Clamp negative deltas to zero to handle corrupted state files.
    monthly_cost=$(awk -F'\t' -v month="$month" '
        $1 == month {
            delta = $3 - $2
            if (delta > 0) total += delta
        }
        END { printf "%.2f", total + 0 }
    ' "$state_dir/"*.state 2>/dev/null)

    if is_number "$monthly_cost" && [[ $formatted != "$monthly_cost" ]]; then
        label+=" (\$${monthly_cost} $(date +%b))"
    fi

    # Throttled cleanup: scan at most once per day
    cleanup_stamp=$cost_dir/.last-cleanup
    if [[ ! -e $cleanup_stamp ]] \
        || [[ -n $(find "$cleanup_stamp" -mtime +0 -print -quit 2>/dev/null) ]]; then
        find "$state_dir" -maxdepth 1 -type f -name '*.state' -mtime +62 \
            -delete 2>/dev/null
        # Remove stale lock dirs (orphaned by crashes)
        find "$state_dir" -maxdepth 1 -type d -name '*.lkdir' -mmin +1 \
            -exec rmdir {} + 2>/dev/null
        touch -- "$cleanup_stamp" 2>/dev/null || true
    fi

    printf '%s' "$label"
}

# --- main ---

input=$(cat)

{ IFS= read -r cwd; IFS= read -r model; IFS= read -r effort; IFS= read -r ctx_pct; IFS= read -r cost; IFS= read -r session_id; } \
    < <(printf '%s\n' "$input" | jq -r '
        def s: if type == "string" then . else "" end;
        ((.workspace.current_dir // .cwd // "") | s),
        ((.model.display_name // "") | s),
        ((.effort.level // "") | s),
        (if (.context_window.used_percentage | type) == "number"
         then (.context_window.used_percentage | tostring) else "" end),
        (if ((.cost.total_cost_usd | type) == "number" and .cost.total_cost_usd >= 0)
         then (.cost.total_cost_usd | tostring) else "" end),
        ((.session_id // "") | s)
    ' 2>/dev/null)

if ! cd -- "$cwd" 2>/dev/null; then
    cd -- "${HOME:-/}" 2>/dev/null || exit 0
fi
dir=${PWD##*/}
[[ -n $dir ]] || dir=/
# Prevent a crafted directory name from injecting terminal control sequences.
dir=$(printf '%s' "$dir" | tr -d '\000-\037\177')
[[ -n $dir ]] || dir='?'

git_info=
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git branch --show-current 2>/dev/null)
    [[ -n $branch ]] || branch=$(git rev-parse --short HEAD 2>/dev/null) || branch='?'
    dirty=
    [[ -n $(git status --porcelain=v1 --untracked-files=normal 2>/dev/null) ]] && dirty='*'
    git_info=" $ICON_BRANCH ${branch}${dirty}"
fi

parts=()
if [[ -n $model ]]; then
    parts+=("$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')")
fi

if [[ -n $effort ]]; then
    if [[ $effort == max ]]; then
        parts+=("$ICON_ANGLES_UP $effort")
    else
        parts+=("$effort")
    fi
fi

if [[ $ctx_pct =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    pct=${ctx_pct%%.*}
    color='' reset_seq=''
    for i in "${!CTX_THRESHOLDS[@]}"; do
        if ((pct >= CTX_THRESHOLDS[i])); then
            color=${CTX_COLORS[i]}
            reset_seq=$RESET
            break
        fi
    done
    parts+=("${color}${ctx_pct}%${reset_seq}")
fi

if is_number "$cost"; then
    parts+=("$(format_cost "$cost" "$session_id")")
fi

meta=
if ((${#parts[@]})); then
    meta=${parts[0]}
    for ((i = 1; i < ${#parts[@]}; i++)); do
        meta+=" · ${parts[i]}"
    done
    meta=" [$meta]"
fi

printf " $ICON_FOLDER %s%s%s" "$dir" "$git_info" "$meta"

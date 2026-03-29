#!/usr/bin/env bash

# Claude Code Enhanced Statusline v2.0
# Single-pass JSON parsing, DRY output, color-coded metrics

# Read JSON input from stdin
input=$(cat)

# Debug: uncomment to save input for troubleshooting
# echo "$input" > /tmp/statusline-debug.json

# ── Extract all values in a single jq call (bash 3.2 compatible) ─────────────
_jq_out=$(echo "$input" | jq -r '
    .workspace.current_dir // "",
    .model.display_name // "",
    .transcript_path // "",
    (.context_window.total_input_tokens // 0 | floor | tostring),
    (.context_window.total_output_tokens // 0 | floor | tostring),
    (.context_window.current_usage.cache_read_input_tokens // 0 | floor | tostring),
    (.context_window.current_usage.cache_creation_input_tokens // 0 | floor | tostring),
    (.context_window.used_percentage // 0 | floor | tostring),
    (.context_window.remaining_percentage // 0 | floor | tostring),
    (.context_window.context_window_size // 200000 | floor | tostring),
    (.cost.total_cost_usd // 0 | tostring),
    (.cost.total_duration_ms // 0 | floor | tostring)
')
_i=0
while IFS= read -r _line; do
    _v[_i]="$_line"
    _i=$((_i + 1))
done <<< "$_jq_out"
cwd="${_v[0]}"
model="${_v[1]}"
transcript_path="${_v[2]}"
total_input="${_v[3]}"
total_output="${_v[4]}"
cache_read="${_v[5]}"
cache_create="${_v[6]}"
context_used_pct="${_v[7]}"
context_remaining_pct="${_v[8]}"
context_limit="${_v[9]}"
total_cost_usd="${_v[10]}"
session_duration_ms="${_v[11]}"

# Shorten home directory
dir="${cwd/#$HOME/~}"

# ── ANSI color codes ────────────────────────────────────────────────────────
R="\033[0m"       # reset
GRAY="\033[90m"
WHITE="\033[37m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
MAGENTA="\033[35m"
CYAN="\033[36m"
BOLD="\033[1m"

# Bullet separator
B=" ${WHITE}•${R} "

# ── Transcript: message count, tool calls, elapsed time (single jq call) ───
message_count=0
tool_count=0
session_duration=""

if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    read -r message_count tool_count first_ts last_ts < <(
        jq -rs '
            [.[] | select(.type == "user" or .type == "assistant")] as $msgs |
            [.[] | select(.type == "tool_use" or .type == "tool_result")] as $tools |
            [
                ($msgs | length | tostring),
                (($tools | length / 2) | floor | tostring),
                ($msgs | first | .timestamp // ""),
                ($msgs | last | .timestamp // "")
            ] | join(" ")
        ' "$transcript_path" 2>/dev/null
    )

    if [ -n "$first_ts" ] && [ -n "$last_ts" ] && [ "$first_ts" != "$last_ts" ]; then
        # macOS date parsing
        first_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${first_ts%.*}" +%s 2>/dev/null)
        last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" +%s 2>/dev/null)

        if [ -n "$first_epoch" ] && [ -n "$last_epoch" ]; then
            dur=$((last_epoch - first_epoch))
            if [ "$dur" -ge 3600 ]; then
                session_duration="$((dur/3600))h $((dur%3600/60))m $((dur%60))s"
            elif [ "$dur" -ge 60 ]; then
                session_duration="$((dur/60))m $((dur%60))s"
            else
                session_duration="${dur}s"
            fi
        fi
    fi
fi

# ── Token metrics ───────────────────────────────────────────────────────────
tokens=""
cache_info=""
token_split=""
api_cost=""
max_cost=""
cost_color="$GRAY"
cost_rate=""
context_left=""
context_color="$GREEN"
context_bar=""

if [ "$total_input" -gt 0 ] || [ "$total_output" -gt 0 ]; then
    token_sum=$((total_input + cache_read + cache_create + total_output))

    # Format with K/M suffix
    if [ "$token_sum" -ge 1000000 ]; then
        tokens=$(echo "scale=1; $token_sum / 1000000" | bc)
        [[ "$tokens" == .* ]] && tokens="0$tokens"
        tokens="${tokens}M"
    elif [ "$token_sum" -ge 1000 ]; then
        tokens=$(echo "scale=1; $token_sum / 1000" | bc)
        [[ "$tokens" == .* ]] && tokens="0$tokens"
        tokens="${tokens}K"
    else
        tokens="${token_sum}"
    fi

    # Input vs output split (with K/M formatting)
    if [ "$total_input" -ge 1000000 ]; then
        in_fmt=$(echo "scale=1; $total_input / 1000000" | bc)
        [[ "$in_fmt" == .* ]] && in_fmt="0$in_fmt"
        in_fmt="${in_fmt}M"
    elif [ "$total_input" -ge 1000 ]; then
        in_fmt=$(echo "scale=1; $total_input / 1000" | bc)
        [[ "$in_fmt" == .* ]] && in_fmt="0$in_fmt"
        in_fmt="${in_fmt}K"
    else
        in_fmt="$total_input"
    fi
    if [ "$total_output" -ge 1000000 ]; then
        out_fmt=$(echo "scale=1; $total_output / 1000000" | bc)
        [[ "$out_fmt" == .* ]] && out_fmt="0$out_fmt"
        out_fmt="${out_fmt}M"
    elif [ "$total_output" -ge 1000 ]; then
        out_fmt=$(echo "scale=1; $total_output / 1000" | bc)
        [[ "$out_fmt" == .* ]] && out_fmt="0$out_fmt"
        out_fmt="${out_fmt}K"
    else
        out_fmt="$total_output"
    fi
    token_split="${in_fmt}in/${out_fmt}out"

    # Cache hit rate
    if [ "$token_sum" -gt 0 ]; then
        cache_hit_rate=$(echo "scale=0; ($cache_read * 100) / $token_sum" | bc)
        if [ "$cache_hit_rate" -gt 0 ]; then
            cache_info="${cache_hit_rate}% cached"
        fi
    fi

    # ── Cost metrics ────────────────────────────────────────────────────────
    if [ "$(echo "$total_cost_usd > 0" | bc)" -eq 1 ]; then
        api_cost=$(printf "\$%.2f" "$total_cost_usd")

        # Color-code cost: green < $1, yellow $1-5, red > $5
        if [ "$(echo "$total_cost_usd > 5" | bc)" -eq 1 ]; then
            cost_color="$RED"
        elif [ "$(echo "$total_cost_usd > 1" | bc)" -eq 1 ]; then
            cost_color="$YELLOW"
        else
            cost_color="$GREEN"
        fi

        # Max 20x subscription equivalent (API cost / 12)
        max_calc=$(echo "scale=4; $total_cost_usd / 12" | bc)
        [[ "$max_calc" == .* ]] && max_calc="0$max_calc"
        max_cost=$(printf "\$%.2f" "$max_calc")

        # Cost per hour burn rate
        if [ -n "$session_duration" ]; then
            # Get duration in seconds from the already-calculated values
            first_epoch_r=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${first_ts%.*}" +%s 2>/dev/null)
            last_epoch_r=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_ts%.*}" +%s 2>/dev/null)
            if [ -n "$first_epoch_r" ] && [ -n "$last_epoch_r" ]; then
                dur_s=$((last_epoch_r - first_epoch_r))
                if [ "$dur_s" -gt 60 ]; then
                    hourly=$(echo "scale=2; $total_cost_usd / $dur_s * 3600" | bc)
                    [[ "$hourly" == .* ]] && hourly="0$hourly"
                    cost_rate="\$${hourly}/h"
                fi
            fi
        fi
    fi

    # ── Context remaining with color + bar ──────────────────────────────────
    if [ "$context_limit" -gt 0 ]; then
        context_remaining=$((context_limit * context_remaining_pct / 100))

        if [ "$context_remaining" -ge 1000 ]; then
            context_fmt=$(echo "scale=0; $context_remaining / 1000" | bc)
            context_left="${context_fmt}K"
        else
            context_left="${context_remaining}"
        fi

        # Color-code: green > 50%, yellow 25-50%, red < 25%
        if [ "$context_remaining_pct" -lt 25 ]; then
            context_color="$RED"
        elif [ "$context_remaining_pct" -lt 50 ]; then
            context_color="$YELLOW"
        fi

        # Progress bar [████████░░] -- 10 chars wide
        filled=$((context_used_pct / 10))
        empty=$((10 - filled))
        bar=""
        for ((i=0; i<filled; i++)); do bar+="█"; done
        for ((i=0; i<empty; i++)); do bar+="░"; done
        context_bar="${bar} ${context_used_pct}%"
    fi
fi

# ── Git info (batched) ──────────────────────────────────────────────────────
git_header=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git -C "$cwd" -c core.useBuiltinFSMonitor=false branch --show-current 2>/dev/null)

    if [ -n "$branch" ]; then
        git_header=" on ${MAGENTA}${branch}${R}"

        # Upstream ahead/behind
        if git -C "$cwd" rev-parse --abbrev-ref @{u} > /dev/null 2>&1; then
            ahead=$(git -C "$cwd" rev-list --count @{u}..HEAD 2>/dev/null)
            behind=$(git -C "$cwd" rev-list --count HEAD..@{u} 2>/dev/null)
            sync=""
            [ "$ahead" -gt 0 ] && sync+="↑${ahead}"
            [ "$behind" -gt 0 ] && sync+="↓${behind}"
            [ -n "$sync" ] && git_header+="${CYAN}${sync}${R}"
        fi

        # Dirty / untracked status
        if ! git -C "$cwd" -c core.useBuiltinFSMonitor=false diff --quiet 2>/dev/null || \
           ! git -C "$cwd" -c core.useBuiltinFSMonitor=false diff --cached --quiet 2>/dev/null; then
            git_header+="${RED}!${R}"
        elif [ -n "$(git -C "$cwd" -c core.useBuiltinFSMonitor=false ls-files --others --exclude-standard 2>/dev/null | head -1)" ]; then
            git_header+="${GREEN}?${R}"
        fi
    fi
fi

# ── Line 2: Session (model, msgs, time, tokens) ───────────────────────────
line2="${GRAY}${model}${R}"

# Messages + tool calls
if [ "$message_count" -gt 0 ]; then
    msg_part="${message_count} msgs"
    if [ "$tool_count" -gt 0 ]; then
        msg_part+=" / ${tool_count} tools"
    fi
    line2+="${B}${GRAY}${msg_part}${R}"
fi

# Duration
if [ -n "$session_duration" ]; then
    line2+="${B}${GRAY}${session_duration}${R}"
fi

# Tokens + split + cache
if [ -n "$tokens" ]; then
    tok_part="${tokens}"
    if [ -n "$token_split" ]; then
        tok_part+=" (${token_split})"
    fi
    if [ -n "$cache_info" ]; then
        tok_part+=" ${cache_info}"
    fi
    line2+="${B}${GRAY}${tok_part}${R}"
fi

# ── Line 3: Cost + context ─────────────────────────────────────────────────
line3=""

if [ -n "$api_cost" ]; then
    line3="${cost_color}API ${api_cost}${R}"
    if [ -n "$max_cost" ]; then
        line3+=" ${GRAY}/ Max 20x ${max_cost}${R}"
    fi
    if [ -n "$cost_rate" ]; then
        line3+=" ${GRAY}(${cost_rate})${R}"
    fi
fi

if [ -n "$context_left" ]; then
    if [ -n "$line3" ]; then
        line3+="${B}"
    fi
    line3+="${context_color}${context_bar} ${context_left} left${R}"
fi

# ── Final output ────────────────────────────────────────────────────────────
out="${GREEN}${dir}${R}${git_header}"
out+="\n[${line2}]"
if [ -n "$line3" ]; then
    out+="\n[${line3}]"
fi
printf "%b" "$out"

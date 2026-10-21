#!/bin/bash
# Claude Code hook for dmucode's attention marker: an OSC 9 notification
# with a message, plus a bell (tmux records the bell from any window, the
# OSC 9 reaches the terminal only from the session's current window).
#
#   Notification  permission prompts, AskUserQuestion, MCP elicitations
#   Stop          a response that took longer than $MIN_SECONDS
#
# Claude Code's built-in notifications are off (preferredNotifChannel =
# notifications_disabled), which also silences the "Claude is waiting for
# your input" idle notification 60 seconds after every answer.
MIN_SECONDS=30

input=$(cat)
event=$(jq -r '.hook_event_name // ""' <<<"$input")

case "$event" in
Notification)
  message=$(jq -r '.message // "Claude needs your attention"' <<<"$input")
  ;;
Stop)
  # Still waiting for background work: the next Stop is the real end.
  [ "$(jq -r '.background_tasks // [] | length' <<<"$input")" = 0 ] || exit 0
  transcript=$(jq -r '.transcript_path // ""' <<<"$input")
  [ -r "$transcript" ] || exit 0
  # The last prompt typed by the user: not a tool result, and not a
  # background task's notification (turnOrigin "task_notification"),
  # which also arrives as a user message.
  started=$(jq -r 'select(.type == "user")
    | select((.turnOrigin // "human") == "human")
    | select((.message.content | type) == "string"
             or ([.message.content[]? | .type] | index("tool_result") | not))
    | .timestamp // empty' "$transcript" 2>/dev/null | tail -1)
  [ -n "$started" ] || exit 0
  start_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${started%%.*}" +%s 2>/dev/null) || exit 0
  seconds=$(( $(date +%s) - start_epoch ))
  [ "$seconds" -ge "$MIN_SECONDS" ] || exit 0
  if [ "$seconds" -ge 60 ]; then
    message="Done in $((seconds / 60)) min $((seconds % 60)) s"
  else
    message="Done in $seconds s"
  fi
  ;;
*) exit 0 ;;
esac

seq=$(printf '\033]9;%s\007\007' "$message")
jq -nc --arg seq "$seq" '{terminalSequence: $seq}'

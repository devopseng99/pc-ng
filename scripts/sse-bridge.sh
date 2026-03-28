#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# SSE Event Bridge — Redis pub/sub → HTTP Server-Sent Events
#
# Subscribes to Redis pipeline:events channel and serves events as SSE stream.
# Usage:
#   ./sse-bridge.sh [--port 8484]
#   curl -N http://localhost:8484/events   # SSE client
#   pc watch --stream                      # CLI wrapper
# ============================================================================

PORT="${1:-8484}"
EVENTS_CHANNEL="pipeline:events"
REDIS_PASS_FILE="/tmp/pc-autopilot/.redis-pass"
FIFO="/tmp/pc-autopilot/.sse-fifo"

_redis_pass() {
  if [[ -f "$REDIS_PASS_FILE" ]]; then
    cat "$REDIS_PASS_FILE"
  else
    local pass
    pass=$(kubectl get secret redis-credentials -n paperclip-v3 -o jsonpath='{.data.password}' | base64 -d)
    echo "$pass" > "$REDIS_PASS_FILE"
    chmod 600 "$REDIS_PASS_FILE"
    echo "$pass"
  fi
}

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

# Create named pipe for bridging Redis → HTTP
cleanup() {
  rm -f "$FIFO"
  kill 0 2>/dev/null || true
}
trap cleanup EXIT

rm -f "$FIFO"
mkfifo "$FIFO"

log "Starting SSE bridge on port $PORT (channel=$EVENTS_CHANNEL)"

# Background: subscribe to Redis and write to FIFO
(
  kubectl exec -n paperclip-v3 redis-pc-ng-master-0 -- \
    redis-cli -a "$(_redis_pass)" --no-auth-warning \
    SUBSCRIBE "$EVENTS_CHANNEL" 2>/dev/null | \
  while IFS= read -r line; do
    # Redis SUBSCRIBE output: "subscribe", channel, count, then "message", channel, payload
    # We want lines that look like JSON (start with {)
    if [[ "$line" == "{"* ]]; then
      echo "data: $line" > "$FIFO"
      echo "" > "$FIFO"
    fi
  done
) &

# Simple HTTP server using bash + socat (if available) or netcat
serve_sse() {
  local conn_fd="$1"
  # Send SSE headers
  printf "HTTP/1.1 200 OK\r\n" >&$conn_fd
  printf "Content-Type: text/event-stream\r\n" >&$conn_fd
  printf "Cache-Control: no-cache\r\n" >&$conn_fd
  printf "Connection: keep-alive\r\n" >&$conn_fd
  printf "Access-Control-Allow-Origin: *\r\n" >&$conn_fd
  printf "\r\n" >&$conn_fd

  # Stream events from FIFO
  while IFS= read -r line; do
    printf "%s\n" "$line" >&$conn_fd 2>/dev/null || break
  done < "$FIFO"
}

# Check if socat is available for proper connection handling
if command -v socat &>/dev/null; then
  log "Using socat for HTTP serving"
  socat TCP-LISTEN:${PORT},reuseaddr,fork EXEC:"bash -c 'serve_sse 1'"
else
  # Fallback: simple single-client mode via bash redirects
  log "socat not found — single-client mode (use 'pc watch --stream' or curl -N localhost:$PORT/events)"
  while true; do
    {
      # Read (and discard) the HTTP request
      read -r _ || true
      while IFS= read -r header; do
        [[ "$header" == $'\r' || -z "$header" ]] && break
      done

      # Send SSE response
      printf "HTTP/1.1 200 OK\r\n"
      printf "Content-Type: text/event-stream\r\n"
      printf "Cache-Control: no-cache\r\n"
      printf "Connection: keep-alive\r\n"
      printf "\r\n"

      # Stream from FIFO
      while IFS= read -r line; do
        printf "%s\n" "$line" 2>/dev/null || break
      done < "$FIFO"
    } < /dev/stdin | nc -l -p "$PORT" -q 0 2>/dev/null || {
      # nc variant without -q
      {
        printf "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n"
        while IFS= read -r line; do
          printf "%s\n" "$line" 2>/dev/null || break
        done < "$FIFO"
      } | nc -l "$PORT" 2>/dev/null || sleep 1
    }
  done
fi

#!/usr/bin/env bash
# Load generator for the Switchyard demo.
# Stands in for an AI agent: sends a mix of easy and hard prompts to Switchyard,
# using the auto route ("switchyard") and the per-model passthrough routes.
#
# Usage:  ./loadgen.sh [gateway_ip]        (default: read from terraform output)
#         CONCURRENCY=3 INTERVAL=2 ./loadgen.sh
# Stop:   Ctrl+C
# Needs:  curl, jq

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="${1:-$(terraform -chdir="$SCRIPT_DIR/../terraform" output -raw gateway_public_ip 2>/dev/null)}"
PORT="${PORT:-4000}"
CONCURRENCY="${CONCURRENCY:-3}"   # max requests in flight (CPU-only models are slow)
INTERVAL="${INTERVAL:-2}"         # seconds between new requests
MAX_TOKENS="${MAX_TOKENS:-256}"   # cap answer length so requests finish in reasonable time
TIMEOUT="${TIMEOUT:-180}"         # per-request timeout, seconds

if [ -z "$GATEWAY" ]; then
  echo "No gateway IP. Pass it as an argument: ./loadgen.sh <gateway_ip>" >&2
  exit 1
fi
URL="http://$GATEWAY:$PORT/v1/chat/completions"

EASY=(
  "Say hello in one short sentence."
  "What is 2 + 2?"
  "Name three colours."
  "What is the capital of France?"
  "Give me a one-word synonym for fast."
  "What does CPU stand for?"
)

HARD=(
  "Write a bash script that backs up /etc to a tarball, keeps the last 7 backups, and logs to syslog. Explain each line."
  "Compare Terraform and Ansible: when would you use each, and how do they work together? Give a concrete example."
  "Explain step by step how a Linux system boots, from BIOS/UEFI to a login prompt."
  "A web service has rising p95 latency but normal CPU. List likely causes and how you would investigate each."
  "Design a highly available architecture on AWS for a web app with a database. Justify each component."
)

# Route weights: the auto route most often, qwen least (it is the slowest).
ROUTES=(switchyard switchyard switchyard demo-model-llama demo-model-llama demo-model-nemotron demo-model-nemotron demo-model-qwen)

trap 'echo; echo "Stopping..."; kill $(jobs -p) 2>/dev/null; exit 0' INT TERM

send() {
  local route="$1" kind="$2" prompt="$3" body start resp code secs model ptok ctok
  body=$(jq -n --arg m "$route" --arg p "$prompt" --argjson mt "$MAX_TOKENS" \
    '{model:$m, max_tokens:$mt, messages:[{role:"user", content:$p}]}')
  start=$(date +%s)
  resp=$(curl -s -m "$TIMEOUT" -w '\n%{http_code}' -H 'Content-Type: application/json' -d "$body" "$URL")
  code=$(echo "$resp" | tail -n1)
  secs=$(( $(date +%s) - start ))
  model=$(echo "$resp" | sed '$d' | jq -r '.model // "-"' 2>/dev/null)
  ptok=$(echo "$resp" | sed '$d' | jq -r '.usage.prompt_tokens // "-"' 2>/dev/null)
  ctok=$(echo "$resp" | sed '$d' | jq -r '.usage.completion_tokens // "-"' 2>/dev/null)
  printf '%s  %-20s %-4s -> %-14s http=%s  %3ss  tokens in/out=%s/%s\n' \
    "$(date +%H:%M:%S)" "$route" "$kind" "${model:--}" "$code" "$secs" "$ptok" "$ctok"
}

echo "Sending load to $URL  (concurrency=$CONCURRENCY, every ${INTERVAL}s, max_tokens=$MAX_TOKENS). Ctrl+C to stop."
while true; do
  # wait until a slot is free
  while [ "$(jobs -rp | wc -l)" -ge "$CONCURRENCY" ]; do sleep 1; done

  route=${ROUTES[$((RANDOM % ${#ROUTES[@]}))]}
  if [ $((RANDOM % 10)) -lt 7 ]; then          # 70% easy, 30% hard
    kind=easy; prompt=${EASY[$((RANDOM % ${#EASY[@]}))]}
  else
    kind=hard; prompt=${HARD[$((RANDOM % ${#HARD[@]}))]}
  fi

  send "$route" "$kind" "$prompt" &
  sleep "$INTERVAL"
done

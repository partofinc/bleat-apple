#!/bin/bash
# Polls the demo's own server on localhost so its access log keeps moving.
paths=(/ /health.json /index.html /missing)
while true; do
    p=${paths[RANDOM % ${#paths[@]}]}
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:3000$p")
    printf '%s  GET %-12s %s\n' "$(date +%T)" "$p" "$code"
    sleep $((2 + RANDOM % 4))
done

#!/usr/bin/env bash
# Wait for a RESTART to complete, not merely for something to be healthy.
#
# *** A HEALTH CHECK CANNOT TELL "the OLD instance is still serving" FROM "the
# *** NEW one is ready". *** Three times tonight I waited on a probe -- first
# /v1/models, then a real completion -- concluded the restart was done, and
# acted against an engine that was either about to be taken down or had not
# come back. The only sound readiness test across a restart compares IDENTITY
# (the container's start time) and THEN health.
set -u
API=http://127.0.0.1:8888
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
WAS="${1:-}"
started(){ docker inspect -f '{{.State.StartedAt}}' "$C" 2>/dev/null; }
engine(){ curl -s -o /dev/null -w '%{http_code}' -m 25 -X POST "$API/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"claude-opus-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' 2>/dev/null; }

[ -n "$WAS" ] || { echo "usage: kvwait.sh <previous StartedAt>"; exit 2; }
echo "  waiting for a NEW container (was $WAS) and then a real completion"
for i in $(seq 1 90); do
  now=$(started)
  if [ -n "$now" ] && [ "$now" != "$WAS" ]; then
    code=$(engine)
    if [ "$code" = "200" ]; then
      echo "  ready: started=$now  engine=200  after $((i*10))s"
      exit 0
    fi
  fi
  sleep 10
done
echo "  TIMED OUT: started=$(started) engine=$(engine)"
exit 1

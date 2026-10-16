# on the head: sample used memory vs load progress until the container stops or health
C=dspark031-vllm-dspark031-1
while :; do
  st=$(docker inspect -f "{{.State.Status}}" $C 2>/dev/null); [ "$st" = running ] || { echo "stopped: $st oom=$(docker inspect -f '{{.State.OOMKilled}}' $C)"; break; }
  curl -fsS --max-time 2 http://127.0.0.1:18888/health >/dev/null 2>&1 && { echo HEALTHY; break; }
  used=$(free -m | awk '/Mem:/{print $3}'); cache=$(free -m | awk '/Mem:/{print $6}')
  shard=$(docker logs $C 2>&1 | tr '\r' '\n' | grep -oE "eager\):\s+[0-9]+% Completed \| [0-9]+/48" | tail -1 | grep -oE "[0-9]+/48")
  last=$(docker logs $C 2>&1 | tr '\r' '\n' | grep -vE "^\s*$" | tail -1 | cut -c1-110)
  echo "$(date -u +%H:%M:%S) used=${used}M cache=${cache}M shard=${shard:-none} | $last"
  sleep 3
done

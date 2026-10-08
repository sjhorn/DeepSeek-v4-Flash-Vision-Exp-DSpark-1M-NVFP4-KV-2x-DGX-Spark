#!/bin/bash
# kvdiag.sh -- run a KV-tier experiment and KEEP THE EVIDENCE.
#
# *** WHY THIS EXISTS. *** Two engine crashes on 2026-10-08 were investigated
# with `docker logs` AFTER the fact, and both times the traceback was destroyed
# by a restart -- once by the test script's own later stage, once by a recovery
# step in the same script that was collecting the evidence. A deduped fragment
# was all that survived either.
#
# THE FIXES, and they are all about ordering:
#
#   1. STREAM the log, do not query it. `docker logs -f` into a file from
#      BEFORE the experiment starts means the evidence survives the container
#      being removed, which `docker logs` after the fact does not.
#   2. NEVER RESTORE IN THE SAME RUN. On failure this captures and STOPS,
#      leaving the engine exactly as it died. Recovery is a separate, explicit
#      command, run after somebody has looked.
#   3. DISTINGUISH DEAD FROM HUNG. A dead engine core leaves its traceback in
#      the log; a hung worker leaves nothing, and needs `kill -USR1` for the
#      Python stacks (armed by kvmgr, no ptrace needed). Sending SIGUSR1 to a
#      corpse is pointless, and reading the log for a hang gives nothing, so
#      the handler has to tell them apart.
#   4. BRING OUR OWN TRAFFIC. Do not infer anything from whoever else happens
#      to be using the box; they may or may not be there.
#
# USAGE
#   ./kvdiag.sh start              begin collection (streams log + memory)
#   ./kvdiag.sh arm                turn the disk store path ON, hot, both ranks
#   ./kvdiag.sh disarm             turn it OFF, hot, both ranks
#   ./kvdiag.sh probe [TOKENS]     one request of our own, timed
#   ./kvdiag.sh soak [N] [TOKENS]  N probes, stopping the moment it breaks
#   ./kvdiag.sh capture [why]      snapshot everything NOW
#   ./kvdiag.sh status             where are we
#   ./kvdiag.sh stop               end collection (does NOT restart anything)
#   ./kvdiag.sh recover            the ONLY thing that restarts. Explicit.

set -u
C=deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1
API=http://127.0.0.1:8888
D=~/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark
EV=~/kvdiag
RUN="$EV/current"

api()  { curl -s -o /dev/null -w '%{http_code}' -m 10 "$API/v1/models" 2>/dev/null; }
mem()  { python3 -c "
import re
m=dict(re.findall(r'(\w+):\s+(\d+)', open('/proc/meminfo').read()))
print('mem %.2fGB swap %.2fGB cached %.2fGB' % (int(m['MemAvailable'])/1048576,
      int(m['SwapFree'])/1048576, int(m['Cached'])/1048576))"; }
knob() { curl -s -m 30 -X POST "$API/kv/knob" -H 'Content-Type: application/json' \
           -d "{\"name\":\"$1\",\"value\":$2}"; }

cmd_start() {
  mkdir -p "$RUN"
  echo "$(date -u +%Y%m%dT%H%M%SZ)" > "$RUN/started"
  # *** THE STREAM IS THE WHOLE POINT. --since 0 gets the backlog too, and -f
  # keeps writing, so removing the container cannot take the log with it.
  if ! pgrep -f "docker logs -f .*$C" >/dev/null 2>&1; then
    nohup docker logs -f --since 0 "$C" > "$RUN/engine.log" 2>&1 &
    echo "  log stream started -> $RUN/engine.log"
  else
    echo "  log stream already running"
  fi
  if ! pgrep -f "kvdiag-memsampler" >/dev/null 2>&1; then
    nohup bash -c "exec -a kvdiag-memsampler bash -c 'while true; do echo \"\$(date -u +%H:%M:%SZ) \$(python3 -c \"
import re
m=dict(re.findall(r\\\"(\w+):\s+(\d+)\\\", open(\\\"/proc/meminfo\\\").read()))
print(\\\"mem %.2f swap %.2f\\\" % (int(m[\\\"MemAvailable\\\"])/1048576, int(m[\\\"SwapFree\\\"])/1048576))
\")\" >> $RUN/mem.log; sleep 15; done'" >/dev/null 2>&1 &
    echo "  memory sampler started -> $RUN/mem.log"
  fi
  echo "  api=$(api)  $(mem)"
}

cmd_capture() {
  local why="${1:-manual}"
  local dir="$EV/capture-$(date -u +%Y%m%dT%H%M%SZ)-$why"
  mkdir -p "$dir"
  echo "  capturing to $dir  (reason: $why)"
  # the streamed log FIRST, because it is the thing that keeps getting lost
  [ -f "$RUN/engine.log" ] && cp "$RUN/engine.log" "$dir/engine-streamed.log"
  [ -f "$RUN/mem.log" ] && cp "$RUN/mem.log" "$dir/mem.log"
  # and the container's own view, which may already be gone -- belt and braces
  docker logs --tail 4000 "$C" > "$dir/engine-docker.log" 2>&1
  docker inspect "$C" > "$dir/inspect.json" 2>&1
  docker ps -a > "$dir/ps.txt" 2>&1
  { echo "api=$(api)"; mem; } > "$dir/state.txt" 2>&1
  curl -s -m 10 "$API/kv" > "$dir/kv.json" 2>&1
  curl -s -m 10 "$API/metrics" > "$dir/metrics.txt" 2>&1
  cp /var/tmp/vllm-kv-flags/flags.json "$dir/flags.json" 2>/dev/null
  journalctl --since "40 min ago" --no-pager > "$dir/journal.txt" 2>&1
  # *** AN EMPTY dmesg.txt IS "WE COULD NOT LOOK", NOT "NO KERNEL MESSAGES". ***
  # dmesg needs root here and there is no non-interactive sudo, so the obvious
  # form writes a 0-line file -- and a 0-line file reads exactly like a clean
  # kernel log. That cost a round on 2026-10-08: a worker died with no Python
  # traceback, the empty file looked like "not an OOM", and the only thing that
  # actually ruled OOM out was the memory sampler. Say which it is.
  # *** THE OOM WITNESS THAT NEEDS NO ROOT. *** dmesg is unreadable here (no
  # sudo on the host; no CAP_SYSLOG and no /dev/kmsg in the container, both
  # checked 2026-10-08), so the question "was it OOM-killed?" had no answer at
  # all when VllmWorker-0 died silently. The cgroup answers it: memory.events
  # `oom_kill` counts processes in this cgroup killed by ANY OOM killer,
  # global or cgroup-limit, and it is world-readable on both the host and
  # inside the container. `docker inspect` adds OOMKilled/ExitCode/RestartCount.
  #
  # The caveat is stated because it bit us: these counters reset when the
  # container's cgroup is recreated, which a restart does -- so they answer
  # "since this boot", and a crash that already auto-restarted is past
  # answering. That is what makes CAPTURING THEM CONTINUOUSLY the point, and
  # why mounting /dev/kmsg or adding cap_add: [SYSLOG] in the compose file is
  # still the real fix, to ride the next restart.
  {
    echo "== docker inspect =="
    docker inspect --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} RestartCount={{.RestartCount}} Status={{.State.Status}}' "$C" 2>&1
    echo "== cgroup memory.events (host view) =="
    cid=$(docker inspect -f '{{.Id}}' "$C" 2>/dev/null)
    cat "/sys/fs/cgroup/system.slice/docker-$cid.scope/memory.events" 2>&1
    echo "== cgroup memory.current / max =="
    cat "/sys/fs/cgroup/system.slice/docker-$cid.scope/memory.current" 2>&1
    cat "/sys/fs/cgroup/system.slice/docker-$cid.scope/memory.max" 2>&1
    echo "== NOTE =="
    echo "oom_kill > 0 means a process in this container WAS OOM-killed."
    echo "oom_kill = 0 means it was not -- SINCE THIS CONTAINER STARTED."
  } > "$dir/oom.txt" 2>&1

  if dmesg > "$dir/dmesg.txt" 2>/dev/null && [ -s "$dir/dmesg.txt" ]; then
    tail -200 "$dir/dmesg.txt" > "$dir/dmesg.tmp" && mv "$dir/dmesg.tmp" "$dir/dmesg.txt"
  else
    printf 'UNAVAILABLE: dmesg needs root and there is no non-interactive sudo on this box.\n%s\n' \
      'This is an ABSENCE, not a clean kernel log -- use mem.log to reason about OOM.' \
      > "$dir/dmesg.txt"
  fi

  # *** DEAD OR HUNG? They need different evidence and this is the one call
  # that decides. A dead core leaves a traceback; a hung worker leaves
  # nothing and needs its Python stacks.
  local alive; alive=$(docker inspect -f '{{.State.Running}}' "$C" 2>/dev/null)
  local st; st=$(api)
  echo "  container running=$alive  api=$st" | tee -a "$dir/state.txt"
  if [ "$alive" = "true" ] && [ "$st" != "200" ]; then
    echo "  => container UP but API not answering: treating as HUNG, dumping stacks"
    for p in $(docker exec "$C" sh -c 'for d in /proc/[0-9]*; do c=$(tr "\0" " " < $d/cmdline 2>/dev/null); case "$c" in *VLLM*|*EngineCore*|*vllm*) echo ${d#/proc/};; esac; done' 2>/dev/null | head -6); do
      echo "    kill -USR1 $p"
      docker exec "$C" kill -USR1 "$p" 2>/dev/null
    done
    sleep 6
    cp "$RUN/engine.log" "$dir/engine-streamed-after-usr1.log" 2>/dev/null
    docker exec "$C" sh -c 'for t in /proc/1/task/*; do cat $t/wchan 2>/dev/null; echo; done' \
      2>/dev/null | sort | uniq -c | sort -rn > "$dir/wchans.txt"
  else
    echo "  => treating as DEAD (or healthy); the traceback should be in the streamed log"
  fi
  grep -nE "ERROR|CRITICAL|Traceback" "$dir/engine-streamed.log" 2>/dev/null | tail -40 > "$dir/errors.txt"
  echo "  captured: $(ls "$dir" | tr '\n' ' ')"
  echo "  *** NOT RESTARTING. Look first, then: ./kvdiag.sh recover ***"
  echo "$dir"
}

cmd_probe() {
  local tok="${1:-8000}"
  local nonce="kvdiag-$(date +%s%N)"
  python3 - "$tok" "$nonce" <<'PY'
import json, sys
t, n = int(sys.argv[1]), sys.argv[2]
unit = (f" {n} alpha bravo charlie delta echo foxtrot golf hotel india juliet "
        "kilo lima mike november oscar papa quebec romeo sierra tango.")
need = int(t * 3.27)
text = (unit * (need // len(unit) + 1))[:need]
json.dump({"model":"claude-opus-5","max_tokens":8,"temperature":0,"stream":False,
           "messages":[{"role":"user","content":text}]}, open("/tmp/kvdiag-req.json","w"))
PY
  local t0 t1
  t0=$(date +%s%N)
  curl -s -m 2400 -X POST "$API/v1/chat/completions" -H 'Content-Type: application/json' \
    --data-binary @/tmp/kvdiag-req.json > /tmp/kvdiag-resp.json 2>&1
  t1=$(date +%s%N)
  python3 -c "
import json
try:
  d=json.load(open('/tmp/kvdiag-resp.json')); u=d['usage']
  c=(u.get('prompt_tokens_details') or {}).get('cached_tokens'); pt=u.get('prompt_tokens') or 0
  print('  probe ~$tok: wall=%.1fs tokens=%s cached=%s%s' % (($t1-$t0)/1e9, f'{pt:,}', c,
        '  (%.1f%%)' % (100*c/pt) if c and pt else ''))
except Exception as e:
  print('  probe ~$tok: FAILED after %.1fs -- %s' % (($t1-$t0)/1e9, str(e)[:60])); raise SystemExit(1)"
}

cmd_soak() {
  local n="${1:-5}" tok="${2:-8000}"
  for i in $(seq 1 "$n"); do
    echo "  --- probe $i/$n  $(mem) ---"
    if ! cmd_probe "$tok"; then
      echo "  *** PROBE FAILED -- capturing, NOT restarting ***"
      cmd_capture "probe-failed"
      return 1
    fi
    if [ "$(api)" != "200" ]; then
      echo "  *** ENGINE UNHEALTHY after probe $i -- capturing, NOT restarting ***"
      cmd_capture "engine-unhealthy"
      return 1
    fi
  done
  echo "  soak completed clean: $n probe(s) at ~$tok tokens"
}

case "${1:-status}" in
  start)   cmd_start ;;
  arm)     echo "  arming the disk store path (hot, both ranks)"
           knob disk_store_paused false | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('ranks') or []
print('   paused ->', [x.get('now') for x in r])"
           ;;
  disarm)  echo "  disarming (hot, both ranks)"
           knob disk_store_paused true | python3 -c "
import json,sys
d=json.load(sys.stdin); r=d.get('ranks') or []
print('   paused ->', [x.get('now') for x in r])"
           ;;
  probe)   cmd_probe "${2:-8000}" ;;
  soak)    cmd_soak "${2:-5}" "${3:-8000}" ;;
  capture) cmd_capture "${2:-manual}" ;;
  status)  echo "  api=$(api)  $(mem)"
           echo "  collection: $([ -f "$RUN/started" ] && cat "$RUN/started" || echo 'not started')"
           echo "  log stream: $(pgrep -cf "docker logs -f .*$C") proc(s), $(wc -l < "$RUN/engine.log" 2>/dev/null || echo 0) lines"
           echo "  captures:   $(ls -d $EV/capture-* 2>/dev/null | wc -l)"
           curl -s -m 10 "$API/kv" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
print('  tier:', {k:v for k,v in d['policy'].items() if 'disk' in k})" 2>/dev/null || echo "  tier: /kv unreachable"
           ;;
  stop)    pkill -f "docker logs -f .*$C" 2>/dev/null
           pkill -f kvdiag-memsampler 2>/dev/null
           echo "  collection stopped. Nothing was restarted." ;;
  recover) echo "  *** THE ONLY COMMAND THAT RESTARTS. ***"
           cmd_capture "pre-recover" >/dev/null
           cd "$D" || exit 1
           python3 -c "
import json;p='/var/tmp/vllm-kv-flags/flags.json'
d=json.load(open(p)); d['disk_store_paused']=1; d['disk_restore']=0
json.dump(d,open(p,'w'),indent=1); print('  file made safe:', {k:d[k] for k in ('disk_store_paused','disk_restore')})"
           docker compose -f docker-compose.dspark.yml --env-file .env.dspark down >/dev/null 2>&1
           ssh -o BatchMode=yes spark-da08 "cd $D && docker compose -f docker-compose.dspark.yml --env-file .env.dspark down" >/dev/null 2>&1
           ./start-deepseek-v4-flash-dspark.sh > /tmp/kvdiag-start.log 2>&1
           for i in $(seq 1 150); do [ "$(api)" = "200" ] && break; sleep 10; done
           echo "  api=$(api)" ;;
  *)       sed -n '1,40p' "$0" ;;
esac

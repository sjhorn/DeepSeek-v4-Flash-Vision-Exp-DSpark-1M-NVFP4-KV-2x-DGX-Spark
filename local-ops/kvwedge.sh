#!/usr/bin/env bash
# kvwedge.sh -- capture EVERYTHING about a live engine wedge, on both nodes, before anything restarts it.
#
#   local-ops/kvwedge.sh capture [why]     # from the HEAD; writes ~/kvdiag/wedge-<UTC>/ on BOTH nodes
#
# CLASS: READ-ONLY on the engine, with ONE caveat: the gdb step attaches to the
# vLLM worker and stops it for the seconds a backtrace takes, then detaches. On a
# wedged process that costs nothing; on a healthy one it is a stall of a few
# seconds. Nothing is killed, restarted, cancelled or changed. Safe to run by hand.
#
# WHY. 2026-10-14 14:36 CEST: both GPUs stopped on one group-0 load copy with no Xid,
# and it took ~25 hand-typed commands to learn what this records in one, while the
# wedge lasted (NCCL ends it at its 600s collective timeout + 60s, ~11 min, and the
# supervisor restarts both nodes -- after which the evidence is gone). Every step
# below is one of those commands, kept with the trap it hit:
#
#   - nvidia-smi: SM utilisation + power. The head read 96% at 11 W (a resident
#     spinning collective), the worker 0% (utilisation counts SMs, not the copy
#     engine). The asymmetry was the clue.
#   - per-thread state + kernel wait channel: which threads spin (R) and where.
#   - gdb native backtraces: needs `docker exec --privileged` -- the container has
#     no CAP_SYS_PTRACE, so a plain exec says "ptrace: Operation not permitted".
#   - smaps per mapping: needs `docker exec -i` -- WITHOUT -i a heredoc program is
#     silently discarded and exits 0, which looks like "nothing to report".
#   - the kvmgr ledger's OPEN entries (local-ops/kvledger.py): the copy the GPU
#     was handed and never finished.
#   - engine log since 15 min ago, kernel log, meminfo, PSI.
#
# Each node writes its own directory; an unreadable source says UNREADABLE in its
# file rather than leaving it empty (an empty kernel log reads as a clean one).
set -u
REPO=${DSPARK_REPO:-$HOME/DeepSeek-v4-Flash-0731-DSpark-1M-NVFP4-KV-2x-DGX-Spark}
NAME=${ENGINE_CONTAINER:-deepseek-v4-flash-0731-dspark-1m-nvfp4-kv-2x-dgx-spark-vllm-dspark-1}
TAG=dspark-vllm-$NAME

case "${1:-}" in
  capture) ;;
  *) echo "usage: $0 capture [why]" >&2; exit 2 ;;
esac
WHY=${2:-manual}
[ "$(hostname -s)" = spark-45ea ] || { echo "refusing: run on the head (spark-45ea), it drives both nodes" >&2; exit 1; }
set -a; . "$REPO/.env.dspark"; set +a
TS=$(date -u +%Y%m%dT%H%M%SZ)
D=kvdiag/wedge-$TS

# The per-node capture, run locally and on the worker via `ssh ... bash -s`.
read -r -d '' NODE <<'NODE_EOF'
set -u
D=$HOME/$1; NAME=$2; TAG=$3; WHY=$4; REPO=$5
mkdir -p "$D"; cd "$D"
echo "$(hostname -s) $(date -u +%FT%TZ) why: $WHY" > README
nvidia-smi --query-gpu=utilization.gpu,utilization.memory,clocks.sm,power.draw,temperature.gpu,pstate,clocks_event_reasons.active --format=csv > gpu.csv 2>&1 || echo UNREADABLE >> gpu.csv
nvidia-smi -q > gpu-q.txt 2>&1 || echo UNREADABLE >> gpu-q.txt
journalctl -k --no-pager -o short-precise --since=-30min > kernel.txt 2>&1 || echo "UNREADABLE: journalctl -k failed" >> kernel.txt
journalctl -a -t "$TAG" --since=-15min --no-pager -o short-precise > engine.log 2>&1 || echo UNREADABLE >> engine.log
cat /proc/meminfo > meminfo.txt; cat /proc/pressure/memory > psi.txt 2>&1
cp ~/kvoffload/diag/ledger-r*.jsonl . 2>/dev/null || echo "UNREADABLE: no ledger file" > ledger.MISSING
for f in ledger-r*.jsonl; do [ -e "$f" ] && python3 "$REPO/local-ops/kvledger.py" "$f" > "${f%.jsonl}.report.txt" 2>&1; done
docker exec --privileged -i "$NAME" bash -s > worker-threads.txt 2>&1 <<'IN'
p=$(for d in /proc/[0-9]*; do tr "\0" " " < $d/cmdline 2>/dev/null | grep -q "^VLLM::Worker_TP" && basename $d && break; done)
[ -n "$p" ] || { echo "UNREADABLE: no VLLM::Worker_TP process in the container"; exit 0; }
echo "worker pid (container ns) $p"
echo "== thread state / wchan / comm (count)"
for t in /proc/$p/task/*; do printf "%s %s %s\n" "$(awk '{print $3}' $t/stat)" "$(cat $t/wchan 2>/dev/null)" "$(cat $t/comm)"; done | sort | uniq -c | sort -rn
echo "RUNNING TIDS: $(for t in /proc/$p/task/*; do [ "$(awk '{print $3}' $t/stat)" = R ] && basename $t; done | tr '\n' ' ')"
echo "== smaps: swap by mapping kind"
python3 - "$p" <<'PY'
import re,sys,collections
cur=None; maps=[]
for ln in open("/proc/%s/smaps"%sys.argv[1]):
    p=ln.split()
    if re.match(r"^[0-9a-f]+-[0-9a-f]+$",p[0]):
        a,b=p[0].split("-"); cur={"size":(int(b,16)-int(a,16))//1024,"name":(p[5] if len(p)>5 else "[anon]"),"swap":0,"rss":0}; maps.append(cur)
    elif cur is not None and p[0] in ("Swap:","Rss:"):
        cur[p[0][:-1].lower()]=int(p[1])
g=collections.defaultdict(lambda:[0,0,0,0])
for m in maps:
    k=m["name"] if m["name"].startswith("/dev/") else ("[heap]" if m["name"]=="[heap]" else ("[anon]" if m["name"].startswith("[") else "file"))
    g[k][0]+=1; g[k][1]+=m["size"]; g[k][2]+=m["swap"]; g[k][3]+=m["rss"]
for k,v in sorted(g.items(), key=lambda kv:-kv[1][2]):
    print("  %-28s n=%-5d size %9.1f MB  swap %8.1f MB  rss %8.1f MB"%(k[:28],v[0],v[1]/1024,v[2]/1024,v[3]/1024))
PY
echo "== gdb native backtraces (process stopped briefly, then detached)"
timeout 170 gdb -p $p -batch -nx -ex "set pagination off" -ex "info threads" -ex "thread apply all bt 16" 2>&1
IN
echo "$(hostname -s): $(du -sh "$D" | cut -f1) in $D"
NODE_EOF

echo "kvwedge: capturing to ~/$D on both nodes (why: $WHY)"
bash -c "$NODE" _ "$D" "$NAME" "$TAG" "$WHY" "$REPO" &
ssh -o BatchMode=yes "$WORKER_HOST" bash -s -- "$D" "$NAME" "$TAG" "'$WHY'" "$REPO" <<<"$NODE" &
wait
echo "kvwedge: done -- ~/$D on spark-45ea and spark-da08"

#!/usr/bin/env python3
"""kv-mech-tests.py — offline tests for MNT-8 (free-queue ordering) and MNT-9
(static-head pinning), run against the REAL vLLM classes, no GPU and no restart.

WHY offline-in-the-container.  Both mechanisms are ordering and refcount logic;
they are wrong in ways a smoke test cannot see (a pin that double-references
leaks a block forever; a prepend that mis-links the free list corrupts the pool).
The engine's own classes are needed for that to mean anything, so this stages the
patched files in the container and exercises them there -- nothing is imported
into the running engine, and the running engine is not touched.

    HOST=spark-45ea bash local-ops/kv-mech-tests.sh     # wrapper, stages + runs
    # or, if the files are already at /tmp/kvtest in the container:
    docker exec <container> python3 /tmp/kvtest/kv-mech-tests.py

Every assertion is a claim docs/local/CACHE-TEST.md makes about the mechanisms. If one
fails, the write-up is wrong, not just the code.
"""
from collections import OrderedDict
import importlib.util, json, os, sys, types

def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m

U = load('/tmp/kvtest/patch8-kv_cache_utils.py', 'kvu_patched')
KVCacheBlock = U.KVCacheBlock
Q = U.FreeKVCacheBlockQueue

# --- test 1: prepend_n puts blocks at the head, append_n at the tail ---
blocks = [KVCacheBlock(block_id=i) for i in range(6)]
q = Q(blocks)
taken = [q.popleft() for _ in range(6)]
assert [b.block_id for b in taken] == [0,1,2,3,4,5], taken
q.append_n([blocks[0], blocks[1]])          # "cached" — back
q.prepend_n([blocks[4], blocks[5]])         # "scratch" — front
order = [q.popleft().block_id for _ in range(4)]
assert order == [4,5,0,1], order
assert q.num_free_blocks == 0, q.num_free_blocks
print("PASS 1 prepend_n ordering:", order)

# --- test 2: prepend_n into an empty queue, and empty input ---
q2 = Q([KVCacheBlock(block_id=i) for i in range(2)])
b = [q2.popleft() for _ in range(2)]
q2.prepend_n([])
assert q2.num_free_blocks == 0
q2.prepend_n(b)
assert [q2.popleft().block_id for _ in range(2)] == [0,1]
print("PASS 2 prepend_n empty/refill")

# --- test 3: block_pool.free_blocks(prepend=) routes correctly ---
sys.modules['vllm.v1.core.kv_cache_utils'] = U   # so block_pool sees prepend_n
BP = load('/tmp/kvtest/patch7-block_pool-dedupe.py', 'bp_patched')
pool = BP.BlockPool(num_gpu_blocks=8, enable_caching=True, hash_block_size=16)
got = pool.get_new_blocks(7)                # drain the pool, so the queue is
ids = [b.block_id for b in got]             # exactly what we free back
pool.free_blocks(got[:2])                   # "cached" -> append
pool.free_blocks(got[2:4], prepend=True)    # "scratch" -> prepend
nxt = [b.block_id for b in pool.get_new_blocks(4)]
assert nxt[:2] == ids[2:4], (nxt, ids)      # prepended come out first
assert nxt[2:] == ids[:2], (nxt, ids)       # appended come out last
print("PASS 3 free_blocks(prepend=) ->", nxt, "from", ids)

# --- test 4: flags file, env override, and fallbacks ---
os.environ['VLLM_KV_FLAGS_FILE'] = '/tmp/kvtest/flags.json'
M = load('/tmp/kvtest/patch6-single_type_kv_cache_manager.py', 'stkcm_patched')
assert M._flag('free_queue_prepend_uncached', False) is False, "missing file must be OFF"
with open('/tmp/kvtest/flags.json','w') as fh:
    json.dump({"free_queue_prepend_uncached": 1, "head_pin_fraction": 0.07}, fh)
M._flags_checked_at = -1e9
assert M._flag('free_queue_prepend_uncached', False) is True
assert abs(M._flag('head_pin_fraction', 0.05) - 0.07) < 1e-9
assert M._flag('pin_static_head', False) is False
os.environ['VLLM_FREE_QUEUE_PREPEND_UNCACHED'] = '0'
assert M._flag('free_queue_prepend_uncached', False) is False, "env must win"
del os.environ['VLLM_FREE_QUEUE_PREPEND_UNCACHED']
with open('/tmp/kvtest/flags.json','w') as fh:
    fh.write('{ this is not json')
M._flags_checked_at = -1e9
assert M._flag('free_queue_prepend_uncached', False) is False, "bad JSON must be OFF"
print("PASS 4 flags: default off, file on, env wins, bad JSON off")
print("boundary token id:", M._HEAD_BOUNDARY_TOKEN_ID, "scan limit:", M._HEAD_SCAN_LIMIT)

# ---------------------------------------------------------------- MNT-9
S = M.SingleTypeKVCacheManager
os.environ['VLLM_KV_FLAGS_FILE'] = '/tmp/kvtest/flags2.json'
json.dump({"pin_static_head": 1, "free_queue_prepend_uncached": 1,
           "head_pin_fraction": 0.5}, open('/tmp/kvtest/flags2.json', 'w'))
M._FLAGS_PATH = '/tmp/kvtest/flags2.json'
M._flags_checked_at = -1e9
BLOCK, ALIGN = 16, 256

class Bare(S):
    """Real methods, no __init__ — we set exactly the attributes they touch."""
    def get_num_common_prefix_blocks(self, running_request_id): return 0
    @classmethod
    def find_longest_cache_hit(cls, **kw): return ()
    def remove_skipped_blocks(self, request_id, num_computed_tokens): pass
    def get_num_skipped_tokens(self, num_computed_tokens): return 0

def mkstub(pool, blocks, rid, window=None):
    st = object.__new__(Bare)
    st.enable_caching = True; st.block_pool = pool; st.block_size = BLOCK
    st.cache_alignment_tokens = ALIGN; st.kv_cache_group_id = 0
    st.req_to_blocks = {rid: blocks}; st._head_pins = OrderedDict()
    st._pinned_head_block_ids = set(); st._head_boundary = {}
    st._head_pin_logged = True
    st._head_pin_incomplete_logged = True
    if window is not None:
        st.sliding_window = window
    return st

def mkreq(rid, head_at, hlen=4096):
    ids = [7] * hlen
    ids[head_at] = M._HEAD_BOUNDARY_TOKEN_ID
    return types.SimpleNamespace(request_id=rid, prompt_token_ids=ids,
                                 num_prompt_tokens=hlen)

pool = BP.BlockPool(num_gpu_blocks=512, enable_caching=True, hash_block_size=BLOCK)
def fresh(n, tag, uncached=()):
    bl = pool.get_new_blocks(n)
    for i, b in enumerate(bl):
        if i not in uncached:
            b.block_hash = (tag, i)  # pretend it got cached
    return bl

# B = floor((600-64)/256)*256 = 512 tokens = 32 blocks of 16
blocks_a = fresh(40, 'headA')
st = mkstub(pool, blocks_a, 'r1')
assert S._static_head_boundary(st, mkreq('r1', 600)) == 512
before = [b.ref_cnt for b in blocks_a]
S._maybe_pin_static_head(st, mkreq('r1', 600), 40)
after = [b.ref_cnt for b in blocks_a]
assert all(a == b + 1 for a, b in zip(after[:32], before[:32])), after[:34]
assert after[32:] == before[32:], "nothing past B may be pinned"
assert len(st._pinned_head_block_ids) == 32
print("PASS 5 full-attention pins exactly [0,B):", len(st._pinned_head_block_ids), "blocks")

# idempotent: a second request on the same head must not double-reference
S._maybe_pin_static_head(st, mkreq('r1', 600), 40)
assert [b.ref_cnt for b in blocks_a] == after, "double-touch"
key = blocks_a[0].block_hash
assert st._head_pins[key]["hits"] == 1, st._head_pins[key]
print("PASS 6 re-pin is a hit, not a second reference; hits =", st._head_pins[key]["hits"])

# An uncached block anywhere inside [0,B) makes the run incomplete, and an
# incomplete run cannot serve a hit -- so nothing is pinned (see PASS 15).
blocks_c = fresh(40, 'headC', uncached={5})
st_c = mkstub(pool, blocks_c, 'r9')
S._maybe_pin_static_head(st_c, mkreq('r9', 600), 40)
assert blocks_c[5].ref_cnt == 1 and len(st_c._pinned_head_block_ids) == 0
print("PASS 7 one uncached block inside the head => the head is NOT pinned")

# prefill that has NOT crossed B yet pins nothing
blocks_d = fresh(40, 'headD'); st_d = mkstub(pool, blocks_d, 'r8')
S._maybe_pin_static_head(st_d, mkreq('r8', 600), 31)
assert not st_d._pinned_head_block_ids
print("PASS 8 no pin before prefill crosses B")

# LRU trim: cap to 32 blocks, then pin a SECOND head -> the first is released
st._max_head_pin_blocks = lambda: 32   # room for exactly one head
blocks_b = fresh(40, 'headB')
st.req_to_blocks['r2'] = blocks_b
st._head_boundary.clear()
S._maybe_pin_static_head(st, mkreq('r2', 600), 40)
assert all(b.ref_cnt == 1 for b in blocks_a[:32]), [b.ref_cnt for b in blocks_a[:3]]
assert all(b.ref_cnt == 2 for b in blocks_b[:32]), [b.ref_cnt for b in blocks_b[:3]]
assert len(st._head_pins) == 1 and list(st._head_pins)[0] == blocks_b[0].block_hash
print("PASS 9 LRU trim released the least-recently-reused head, kept the new one")

# SWA group pins only the contiguous run ending at B: cdiv(127,16)+1 = 9 blocks
blocks_s = fresh(40, 'headS')
st_s = mkstub(pool, blocks_s, 'r3', window=128)
S._maybe_pin_static_head(st_s, mkreq('r3', 600), 40)
pinned = sorted(i for i, b in enumerate(blocks_s) if b.block_id in st_s._pinned_head_block_ids)
assert pinned == list(range(23, 32)), pinned
print("PASS 10 SWA pins only the 9-block tail ending at B:", pinned)

# common-prefix accounting discounts MNT-9's own reference
assert S._head_pin_ref(st_s, blocks_s[25]) == 1 and S._head_pin_ref(st_s, blocks_s[0]) == 0
print("PASS 11 _head_pin_ref discounts the pin reference")

# flag off => no pinning at all
json.dump({"pin_static_head": 0}, open('/tmp/kvtest/flags2.json','w'))
M._flags_checked_at = -1e9
blocks_e = fresh(40, 'headE'); st_e = mkstub(pool, blocks_e, 'r4')
S._maybe_pin_static_head(st_e, mkreq('r4', 600), 40)
assert not st_e._pinned_head_block_ids
print("PASS 12 flag off => inert")

# short heads are skipped (B would be 256 < 512 minimum)
json.dump({"pin_static_head": 1}, open('/tmp/kvtest/flags2.json','w'))
M._flags_checked_at = -1e9
st_f = mkstub(pool, fresh(40, 'headF'), 'r5')
assert S._static_head_boundary(st_f, mkreq('r5', 300)) == 0
assert S._static_head_boundary(mkstub(pool, [], 'r6'), mkreq('r6', 70)) == 0
print("PASS 13 heads below the 512-token floor are not pinned")

# ------------------------------------------------- MNT-6b / MNT-6c / MNT-9 fix
# Recycle gates: env overrides the file; the file decides otherwise.
# NOTE: this runs inside the live container, whose env really does set
# VLLM_SWA_RECYCLE_SKIPPED_BLOCKS=1 -- drop it first, or the override under test
# is the thing masking the test.
_saved_env = os.environ.pop('VLLM_SWA_RECYCLE_SKIPPED_BLOCKS', None)
json.dump({"swa_recycle": 0, "swa_recycle_cached": 0}, open('/tmp/kvtest/flags2.json', 'w'))
M._flags_checked_at = -1e9
assert M._recycle_enabled() is False
assert M._recycle_cached_pages() is False
os.environ['VLLM_SWA_RECYCLE_SKIPPED_BLOCKS'] = '1'
assert M._recycle_enabled() is True, "env must override the file for MNT-6b"
del os.environ['VLLM_SWA_RECYCLE_SKIPPED_BLOCKS']
json.dump({}, open('/tmp/kvtest/flags2.json', 'w'))
M._flags_checked_at = -1e9
assert M._recycle_enabled() is True and M._recycle_cached_pages() is True, "defaults = today"
if _saved_env is not None:
    os.environ['VLLM_SWA_RECYCLE_SKIPPED_BLOCKS'] = _saved_env
print("PASS 14 MNT-6b/6c gates: default on, file off, env overrides")

# MNT-9 must REFUSE an incomplete run rather than pin an unusable subset -- the
# defect that made arm C a confident null (3 of 33 blocks on KV group 3).
json.dump({"pin_static_head": 1, "head_pin_fraction": 0.5}, open('/tmp/kvtest/flags2.json', 'w'))
M._flags_checked_at = -1e9
blocks_g = fresh(40, 'headG', uncached={25})          # one hole inside the SWA run
st_g = mkstub(pool, blocks_g, 'r20', window=128)
st_g._head_pin_logged = False; st_g._head_pin_incomplete_logged = False
S._maybe_pin_static_head(st_g, mkreq('r20', 600), 40)
assert not st_g._pinned_head_block_ids, "an incomplete run must not be pinned"
assert st_g._head_pin_incomplete_logged, "and it must say so, loudly"
print("PASS 15 MNT-9 refuses an incomplete run and logs it")

# head_pin_partial=1 restores the old behaviour, for diagnosis only
json.dump({"pin_static_head": 1, "head_pin_fraction": 0.5, "head_pin_partial": 1},
          open('/tmp/kvtest/flags2.json', 'w'))
M._flags_checked_at = -1e9
blocks_h = fresh(40, 'headH', uncached={25})
st_h = mkstub(pool, blocks_h, 'r21', window=128)
st_h._head_pin_logged = True; st_h._head_pin_incomplete_logged = True
S._maybe_pin_static_head(st_h, mkreq('r21', 600), 40)
assert len(st_h._pinned_head_block_ids) == 8, len(st_h._pinned_head_block_ids)
print("PASS 16 head_pin_partial=1 pins the partial run anyway (diagnosis escape hatch)")

print("")
print("ALL PASS - 16 checks")

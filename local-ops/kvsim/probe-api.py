import inspect
from vllm.v1.kv_cache_interface import (KVCacheConfig, KVCacheGroupSpec,
                                        MLAAttentionSpec, SlidingWindowSpec, KVCacheTensor)
from vllm.v1.core.kv_cache_coordinator import get_kv_cache_coordinator
from vllm.v1.core.block_pool import BlockPool
print("get_kv_cache_coordinator:", inspect.signature(get_kv_cache_coordinator))
print("BlockPool:", inspect.signature(BlockPool.__init__))
import vllm.v1.core.kv_cache_utils as u
for n in ("BlockHash","get_request_block_hasher","init_none_hash","hash_block_tokens"):
    o=getattr(u,n,None)
    print(n, inspect.signature(o) if callable(o) else o)
from vllm.v1.request import Request
print("Request:", inspect.signature(Request.__init__))
from vllm.v1.core.kv_cache_manager import KVCacheManager
print("KVCacheManager:", inspect.signature(KVCacheManager.__init__))

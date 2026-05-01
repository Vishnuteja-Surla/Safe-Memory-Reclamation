# Safe Memory Reclamation in OCaml 5

**CS6868 Research Mini-Project** — Concurrent Programming, IIT Madras

**[Presentation Video Link](https://youtu.be/7KfrJmyW3RI)**

## Overview

This project implements and evaluates two memory reclamation schemes for
lock-free data structures in OCaml 5:

1. **Hazard Pointers (HP)** — M. M. Michael, IEEE TPDS 2004
2. **Epoch-Based Reclamation (EBR)** — K. Fraser, PhD thesis 2004

Both schemes address the **ABA problem** that arises when recycling nodes
in lock-free pools.

## Building

```bash
eval $(opam env)
dune build
```

## Running Tests

```bash
# Unit tests
dune exec test/test_lockfree_pool.exe     # Lock-free pool (Treiber stack)
dune exec test/test_hazard_pointer.exe    # Hazard pointer library
dune exec test/test_hp_pool.exe           # HP-protected pool
dune exec test/test_ebr.exe              # EBR library
dune exec test/test_ebr_pool.exe         # EBR-protected pool
dune exec test/test_ms_queue_ebr.exe     # Michael-Scott queue + EBR

# ABA demonstration
dune exec test/test_aba_demo.exe         # Orchestrated ABA bug trigger

# ABA stress tests
dune exec test/stress_aba.exe            # Option-boxed (shows 0 errors)
dune exec test/stress_aba_direct.exe     # Direct-pointer (shows 100K+ errors)

# Throughput benchmark
dune exec test/benchmark_pools.exe -- --ops 100000 --runs 3 --max-threads 8

# Formal Verification (QCheck-STM, QCheck-Lin, dscheck)
dune exec test/qcheck_stm_hp_pool.exe
dune exec test/qcheck_stm_ebr_pool.exe
dune exec test/qcheck_stm_ms_queue_ebr.exe
dune exec test/qcheck_lin_ms_queue_ebr.exe
dune exec test/dscheck_pool.exe
dune exec test/dscheck_ms_queue.exe
```

## Project Structure

```
lib/
  lockfree_pool.ml     — Lock-free Treiber stack pool (ABA-vulnerable)
  hazard_pointer.ml    — Hazard Pointer library (fixed-size global array)
  hp_pool.ml           — HP-protected pool (load-publish-verify)
  ebr.ml               — Epoch-Based Reclamation (3-epoch rotation)
  ebr_pool.ml          — EBR-protected pool
  ms_queue_ebr.ml      — Michael-Scott queue with EBR node recycling

test/
  test_aba_demo.ml     — Deterministic ABA bug demonstration
  stress_aba.ml        — ABA stress test (option-boxed, 8 domains)
  stress_aba_direct.ml — ABA stress test (direct pointers, 8 domains)
  benchmark_pools.ml   — Throughput comparison (5 variants × 2-8 threads)
  test_*.ml            — Unit tests for each module
  qcheck_stm_*.ml      — Sequential state-machine correctness
  qcheck_lin_*.ml      — Linearizability verification
  dscheck_*.ml         — Exhaustive interleaving model checking
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| HP: fixed-size global array (not linked list) | Avoids cross-domain DLS access |
| EBR: `active_count: int` (not bool) | Supports re-entrant enter/exit |
| EBR: read epoch first, then set active | Correct ordering per Fraser |
| EBR: per-domain limbo arrays | Zero-contention thread-local retire |
| Pool: pointer-based nodes (not indices) | HP can protect via physical equality |
| MS queue: GC fallback on pool exhaustion | Prevents deadlock |
| EBR free: no enter/exit wrapping | Caller has finished using the node |
| ABA demo / stress: direct pointers | OCaml's option boxing accidentally prevents ABA |

## Verification Guarantee

All 15 test suites pass with **zero errors**.
- **Unit Tests:** 24 deterministic tests
- **QCheck-STM:** 2,100 random sequential transitions
- **QCheck-Lin:** 300 concurrent linearizability reps
- **dscheck:** 8 exhaustive model-checking suites
- **TSAN:** ThreadSanitizer race detection confirms 0 data races (except in intentional unprotected tests)
- **ABA Stress:** Direct-pointer stress test triggers 100K+ ABA errors on raw pool; HP/EBR report 0.

## Benchmark Findings

1. **EBR scales positively:** Throughput increases from 607K ops/s (2T) to 1,128K ops/s (8T) because `enter`/`exit` serializes domains just enough to reduce CAS contention.
2. **HP degrades:** Throughput drops from 470K (2T) to 232K (8T) due to its $O(R \times N \times K)$ global scan. EBR is $\sim 4.9\times$ faster at 8 threads.
3. **GC dominates throughput:** OCaml 5's minor-heap bump allocator achieves 43–63M ops/s. Explicit memory pools are only justified for deterministic latency or bounded memory.

## Team

- **Vishnu** — HP library, lock-free pool, ABA demo, HP pool, stress tests
- **Ramya** — EBR library, EBR pool, MS queue + EBR, QCheck-Lin

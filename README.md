# Safe Memory Reclamation in OCaml 5

**CS6868 Research Mini-Project** — Concurrent Programming, IIT Madras

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

# ABA stress test (unprotected vs HP vs EBR)
dune exec test/stress_aba.exe

# Throughput benchmark
dune exec test/benchmark_pools.exe -- --ops 50000 --runs 3 --max-threads 8

# Linearizability test (QCheck-Lin)
dune exec test/qcheck_lin_ms_queue_ebr.exe
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
  stress_aba.ml        — ABA stress test (8 domains × 50K ops)
  benchmark_pools.ml   — Throughput comparison (5 variants × 2-8 threads)
  test_*.ml            — Unit tests for each module
  qcheck_lin_*.ml      — QCheck-Lin linearizability tests
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| HP: fixed-size global array (not linked list) | Avoids cross-domain DLS access |
| EBR: `active_count: int` (not bool) | Supports re-entrant enter/exit |
| EBR: read epoch first, then set active | Correct ordering per Fraser |
| Pool: pointer-based nodes (not indices) | HP can protect via physical equality |
| MS queue: GC fallback on pool exhaustion | Prevents deadlock |
| EBR free: no enter/exit wrapping | Caller has finished using the node |
| ABA demo: sentinel nodes (not option) | OCaml's option boxing prevents ABA |

## Team

- **Vishnu** — HP library, lock-free pool, ABA demo, HP pool, stress tests
- **Ramya** — EBR library, EBR pool, MS queue + EBR, QCheck-Lin

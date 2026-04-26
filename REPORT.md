# Safe Memory Reclamation for Lock-Free Data Structures in OCaml 5

**CS6868 Concurrent Programming — Research Mini-Project Report**

**Authors:** Vishnu Teja Surla, Ramya (Team)
**Date:** April 2026
**Platform:** OCaml 5.4.0 (with `ocaml-option-tsan`)

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Background](#2-background)
3. [The ABA Problem](#3-the-aba-problem)
4. [Architecture and Design Decisions](#4-architecture-and-design-decisions)
5. [Implementation Details](#5-implementation-details)
6. [Correctness Verification](#6-correctness-verification)
7. [Performance Evaluation](#7-performance-evaluation)
8. [Bugs Found and Fixed](#8-bugs-found-and-fixed)
9. [Lessons Learned](#9-lessons-learned)
10. [Conclusion](#10-conclusion)
11. [Appendix: File Listing](#11-appendix-file-listing)

---

## 1. Introduction

Lock-free data structures offer superior scalability over lock-based alternatives by allowing concurrent threads to make progress without blocking. However, they introduce a fundamental challenge: **safe memory reclamation**. When a thread removes a node from a shared data structure, it cannot immediately free or recycle that node because other threads may still hold references to it.

This project implements two industry-standard memory reclamation schemes for OCaml 5's multicore runtime:

1. **Hazard Pointers (HP)** — M. M. Michael, IEEE TPDS, 2004
2. **Epoch-Based Reclamation (EBR)** — K. Fraser, PhD Thesis, Cambridge, 2004

We integrate both into a lock-free node pool (Treiber stack) and additionally build a **Michael-Scott Queue** with EBR-managed node recycling. We verify correctness using QCheck-STM/Lin, ThreadSanitizer (TSAN), and custom stress tests, and benchmark throughput across 2–8 concurrent domains.

### Project Structure (2,425 lines total)

| Component | Files | Lines |
|-----------|-------|-------|
| Lock-free pool | `lockfree_pool.ml/.mli` | ~150 |
| Hazard Pointers | `hazard_pointer.ml/.mli`, `hp_pool.ml/.mli` | ~240 |
| Epoch-Based Reclamation | `ebr.ml/.mli`, `ebr_pool.ml/.mli` | ~200 |
| Michael-Scott Queue | `ms_queue_ebr.ml/.mli` | ~130 |
| Tests & Benchmarks | 13 test files | ~1,700 |

---

## 2. Background

### 2.1 OCaml 5 Multicore Model

OCaml 5 introduces **domains** (OS-level threads with parallel execution) and a shared-memory model. The `Atomic` module provides atomic read/write/CAS operations, and the `[@atomic]` annotation on mutable record fields enables fine-grained atomic access via `Atomic.Loc` (the `[%atomic.loc]` PPX).

Key property: OCaml's GC provides automatic memory management, but for **node recycling in pools** (avoiding GC overhead), we need explicit reclamation — and that's where the ABA problem strikes.

### 2.2 Hazard Pointers

Hazard Pointers allow each thread to announce which nodes it is currently accessing by publishing pointers in globally visible **HP slots**. Before a retired node can be freed, the reclaiming thread scans all HP slots across all domains. If any slot contains a reference to the node, the node is kept alive.

**Protocol:**
1. **Protect:** Write the pointer to your HP slot.
2. **Verify:** Re-read the source to confirm the pointer hasn't changed (load-publish-verify).
3. **Retire:** When removing a node, add it to a per-domain retired list.
4. **Scan:** When the retired list exceeds a threshold, scan all HP slots and reclaim unprotected nodes.

### 2.3 Epoch-Based Reclamation

EBR divides time into **epochs**. Each domain announces the epoch it observed when entering a critical section. The global epoch advances when all active domains have caught up. Nodes retired during epoch `e` become safe to free once the epoch reaches `e+2` (the "3-epoch rotation" scheme).

**Protocol:**
1. **Enter:** Read global epoch, publish it as local epoch, increment active counter.
2. **Exit:** Decrement active counter.
3. **Retire:** Add node to the current epoch's limbo bucket.
4. **Advance:** If all active domains have `local_epoch ≥ global_epoch`, CAS the global epoch forward.
5. **Free:** On next `enter`, free own limbo bucket for epoch `e-2`.

---

## 3. The ABA Problem

### 3.1 What Is ABA?

The ABA problem occurs in CAS-based algorithms when:
1. Thread T1 reads value `A` from a shared location.
2. Thread T2 changes the location from `A → B → A` (pops A, pops B, pushes A back).
3. T1's CAS succeeds (it sees `A` again), but the data structure has changed underneath.

In a Treiber stack pool, this means T1 could splice in a node `B` that T2 already owns — causing **double allocation** (the same node given to two threads simultaneously).

### 3.2 Why OCaml's `option` Type Prevents Some ABA

During implementation, we discovered an important OCaml-specific subtlety: `Atomic.compare_and_set` on `option` types (e.g., `Some node`) uses **structural equality** on the `Some` wrapper. Since each `Some` allocation is a fresh box, even if the same node is pushed back, the CAS sees a *different* `Some` and fails.

**Design decision:** To create a reproducible ABA demo, we switched from `option`-wrapped atomics to **direct node pointer atomics** with a sentinel node. This forces physical equality comparison on the node pointer itself, enabling ABA.

### 3.3 ABA Demonstration (`test_aba_demo.ml`)

Our orchestrated demo uses barriers to control thread interleaving:

```
Initial: top → A(1) → B(2) → C(3) → sentinel

T1: reads top=A, next=B, then suspends
T2: pops A, pops B (owns B), pushes A back
    Stack is now: top → A → C
    Physical pointer: top == node_a (same address!)
T1: CAS(top, A, B) succeeds — ABA BUG!
    top now points to B, but T2 already owns B!
```

**Result:** Node B is simultaneously in the stack and owned by T2 — a double-use corruption.

### 3.4 ABA Stress Test (`stress_aba.ml`)

We stress-tested ABA with 8 domains performing 50,000 random alloc/free cycles on a tiny 8-node pool:

| Pool Variant | ABA Errors | Time |
|--------------|:----------:|------|
| **Unprotected** | **4,562** | 0.32s |
| **HP Pool** | **0** ✓ | 0.10s |
| **EBR Pool** | **0** ✓ | 0.42s |

The unprotected pool exhibits thousands of ABA errors. Both HP and EBR eliminate them completely.

---

## 4. Architecture and Design Decisions

### 4.1 Global HP Registry: Fixed-Size Array vs. Linked List

**Decision:** Use a pre-allocated fixed-size array of HP slots, not a lock-free linked list.

**Rationale:** OCaml 5's `Domain.DLS` (Domain-Local Storage) is scoped per domain. A lock-free linked list of per-domain HP records would require cross-domain DLS access, which is not supported. A global array indexed by domain ID avoids this entirely. Each domain gets a contiguous slice: `slots[id * hp_per_domain .. (id+1) * hp_per_domain - 1]`.

**Trade-off:** Maximum domain count must be specified at creation time. We accept this limitation since the alternative (dynamic sizing with lock-free resizing) adds significant complexity without practical benefit.

### 4.2 EBR Active Counter: `int` vs `bool`

**Decision:** Use `active_count : int Atomic.t` instead of a boolean `is_active` flag.

**Rationale:** The `enter`/`exit` pattern must be **re-entrant**. If a library function internally calls `enter`/`exit`, and the caller also wraps in `enter`/`exit`, a boolean would prematurely mark the domain as inactive on the inner `exit`. An integer counter correctly handles nesting — only the outermost `exit` (decrementing to 0) marks the domain as inactive.

### 4.3 EBR `enter` Ordering

**Decision:** Read epoch first, then set local_epoch, then increment active_count.

**Rationale (per Fraser's thesis):** If we incremented `active_count` before reading the epoch, a concurrent advancer could see us as "active with stale epoch" and refuse to advance. By reading first and publishing, we ensure the advancer sees our up-to-date epoch.

### 4.4 Pool Node Identity: Physical Equality

**Decision:** Use physical equality (`==`) for all reclamation checks (HP scanning, EBR comparisons).

**Rationale:** OCaml's structural equality (`=`) would compare values stored in nodes, not node identity. For reclamation, we need to know "is this the *same node object*" — not "does this node contain the same value." Physical equality correctly identifies node identity.

### 4.5 EBR Free: No `enter`/`exit` Wrapping

**Decision:** `Ebr_pool.free` calls `retire` directly without wrapping in `enter`/`exit`.

**Rationale:** When a thread calls `free(node)`, it has **finished using the node**. Wrapping in `enter`/`exit` would be wasteful and semantically wrong — the caller doesn't need protection during `free` because it's relinquishing the node, not accessing it.

### 4.6 MS Queue: Internal Free List vs. Lockfree_pool

**Decision:** The Michael-Scott Queue manages its own internal lock-free free list instead of using `Lockfree_pool`.

**Rationale:** The queue's node type (`{ value; next }`) differs from the pool's node type (`Lockfree_pool.node`). Wrapping one inside the other would add indirection and type complexity. A simple internal free list (lock-free stack of retired nodes) is cleaner and avoids the type mismatch.

### 4.7 MS Queue: GC Fallback

**Decision:** When the internal free list is empty, allocate a fresh node via the GC instead of blocking.

**Rationale:** If `enq` waited for `deq` to retire nodes, we'd risk deadlock in producer-heavy workloads. GC-allocated nodes are safe (the GC handles their lifetime) and can later be recycled into the free list when retired.

### 4.8 Concrete Types in `.mli`

**Decision:** Export the concrete `node` and `t` type definitions in `lockfree_pool.mli` (not abstract).

**Rationale:** `Hp_pool` and `Ebr_pool` need to access the pool's internal fields (`top`, `next`) using `[%atomic.loc]` for CAS operations. Abstract types would hide these fields. While this breaks encapsulation, it's necessary for the protected pool wrappers to function.

### 4.9 Domain Registration Race Fix

**Decision:** In the DLS initializer, roll back `num_domains` on failure and cap scan ranges.

**Rationale (bug found during QCheck-Lin testing):** The original code used `fetch_and_add` followed by a bounds check. If the check failed, `num_domains` was already incremented. A concurrent `collect_protected` (HP) or `try_advance_epoch` (EBR) could read this inflated count and access out-of-bounds array slots. Fix: `fetch_and_add(-1)` on failure, plus `min(num_domains, max_domains)` in scan loops.

---

## 5. Implementation Details

### 5.1 Lock-Free Pool (`lockfree_pool.ml`) — 98 lines

A **Treiber stack** free list with exponential backoff:

```ocaml
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]
}

type 'a t = {
  mutable top : 'a node option; [@atomic]
  cap : int;
}
```

- `alloc`: CAS-pops from `top`, stores value. Returns `None` if empty.
- `free`: CAS-pushes node back to `top`.
- `alloc_fresh`: GC-allocated fallback (no pool involvement).
- Exponential backoff on CAS failure (1μs → 128μs).

### 5.2 Hazard Pointer Library (`hazard_pointer.ml`) — 118 lines

- **Slots:** `'a option Atomic.t array` of size `max_domains × hp_per_domain`.
- **Per-domain record:** `{ domain_id; base_idx; retired; retired_count }` via DLS.
- **`protect t slot value`:** Publishes value in `slots[base_idx + slot]`.
- **`scan t`:** Collects all protected pointers, iterates retired list, reclaims unprotected nodes via their cleanup callbacks. Uses physical equality (`==`).
- **Threshold batching:** `scan` only triggers when `retired_count ≥ retire_threshold`.

### 5.3 HP-Protected Pool (`hp_pool.ml`) — 84 lines

Wraps `Lockfree_pool` with hazard pointer protection:

```
alloc:
  1. Read top (load)
  2. Publish top in HP slot 0 (publish)
  3. Re-read top and verify with == (verify)
  4. If changed, retry from step 1
  5. CAS top to next
  6. Release HP slot

free:
  1. Retire node with cleanup = push_to_pool
  2. scan triggers reclamation when threshold reached
```

### 5.4 EBR Library (`ebr.ml`) — 119 lines

- **Records:** Pre-allocated array of `max_domains` domain records.
- **3 limbo buckets per domain:** `limbo : retired_node list ref array` (size 3).
- **`enter`:** Read epoch, set local_epoch, increment active_count, free old limbo bucket.
- **`exit`:** Decrement active_count.
- **`retire`:** Add to `limbo[epoch mod 3]`, try to advance epoch.
- **`try_advance_epoch`:** CAS global_epoch if all active domains have caught up.

Limbo bucket mapping: epoch `e-2 ≡ (e+1) mod 3`.

### 5.5 EBR-Protected Pool (`ebr_pool.ml`) — 56 lines

- `alloc`: Wrapped in `enter`/`exit`. CAS-pops from pool.
- `free`: Calls `retire` with cleanup = push_to_pool. No `enter`/`exit`.

### 5.6 Michael-Scott Queue + EBR (`ms_queue_ebr.ml`) — 107 lines

Classic two-pointer lazy queue (head/tail) with EBR node recycling:

```ocaml
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]
}

type 'a t = {
  mutable head : 'a node; [@atomic]
  mutable tail : 'a node; [@atomic]
  mutable free_list : 'a node option; [@atomic]
  ebr : 'a node Ebr.t;
}
```

- **`enq`:** Allocate from free list (or GC), CAS append at tail. Help advance lagging tail.
- **`try_deq`:** CAS swing head forward. Retire old sentinel via EBR (recycled after epoch advances).
- Both wrapped in `Ebr.enter`/`Ebr.exit`.

---

## 6. Correctness Verification

### 6.1 Unit Tests (7 test suites)

| Suite | Tests | What It Verifies |
|-------|:-----:|-----------------|
| `test_lockfree_pool` | 6 | Sequential ops, fill/drain, concurrent (4D), stress (8D×50K) |
| `test_aba_demo` | 1 | Deterministic ABA trigger with sentinel nodes |
| `test_hazard_pointer` | 4 | Protect/release/retire, threshold, multi-slot, multi-domain |
| `test_hp_pool` | 3 | Sequential, GC fallback, concurrent (4D×5K) |
| `test_ebr` | 4 | Basic, re-entrancy (depth 2–3), epoch advancement, multi-domain |
| `test_ebr_pool` | 2 | Sequential, concurrent (4D×5K) |
| `test_ms_queue_ebr` | 4 | Sequential FIFO, interleaved, fill/drain (1000), concurrent (4P+4C) |

**All 24 tests pass.**

### 6.2 QCheck-STM (State Machine Testing)

We use QCheck-STM to verify sequential correctness against a mathematical model:

| Test | Model | Cases | Result |
|------|-------|:-----:|:------:|
| `qcheck_stm_hp_pool` | Bounded counter (immediate free) | 1,000 | ✅ |
| `qcheck_stm_ebr_pool` | Bounded counter (deferred free + limbo) | 1,000 | ✅ |
| `qcheck_stm_ms_queue_ebr` | List-based FIFO (seq + parallel) | 1,000 + 100 | ✅ |

**Key insight for EBR pool STM:** The model must account for **deferred reclamation**. When a node is freed, it goes to limbo — not immediately back to the free list. The postcondition for `alloc` must accept non-deterministic results when the pool is "nominally empty" but limbo nodes may have been reclaimed.

### 6.3 QCheck-Lin (Concurrent Linearizability)

| Test | Framework | Cases | Result |
|------|-----------|:-----:|:------:|
| `qcheck_lin_ms_queue_ebr` | Lin_domain | 5 × 300 reps | ✅ |

**Why Lin only for the queue, STM for pools:** Pool operations (`alloc`/`free`) have inherent state dependencies (you can't `free` without prior `alloc`), which don't compose well with Lin's independent-operation model. STM with explicit state tracking is the correct tool for pools. The queue's `enq`/`deq` are independent and suitable for Lin.

**Domain exhaustion challenge:** Lin_domain spawns fresh OCaml domains per repetition (~300 per test). Each domain permanently consumes an EBR slot via DLS initialization. We solved this with a shared queue instance and `max_domains:8192`.

### 6.4 ThreadSanitizer (TSAN)

All concurrent tests were run under OCaml 5.4.0's TSAN-instrumented runtime:

| Test | TSAN Races |
|------|:----------:|
| `test_hazard_pointer` | **0** |
| `test_hp_pool` | **0** |
| `test_ebr` | **0** |
| `test_ebr_pool` | **0** |
| `test_ms_queue_ebr` | **0** |
| `stress_aba` | **0** |

**Zero data races detected.** The `[@atomic]` field annotations and `Atomic.t` operations are correctly instrumented, confirming all shared memory accesses are properly synchronized.

### 6.5 ABA Stress Test

8 domains × 50,000 random alloc/free operations on an 8-node pool. Ownership tracked via atomic array to detect double-allocation:

| Variant | ABA Errors | Time |
|---------|:----------:|:----:|
| Unprotected | 4,562 | 0.32s |
| HP Pool | 0 | 0.10s |
| EBR Pool | 0 | 0.42s |

---

## 7. Performance Evaluation

### 7.1 Benchmark Setup

- **Machine:** OCaml 5.4.0 on Linux (TSAN switch)
- **Workload:** Each domain performs 50,000 alloc/free cycles on a 1024-node pool
- **Variants:** Raw (unsafe), HP, EBR, Mutex, GC-only
- **Measurement:** 3 runs averaged, throughput in Kops/s

### 7.2 Results

| Threads | Raw(Kops) | HP(Kops) | EBR(Kops) | Mutex(Kops) | GC(Kops) |
|:-------:|:---------:|:--------:|:---------:|:-----------:|:--------:|
| 2 | 653 | 263 | 272 | 188 | 9,156 |
| 3 | 275 | 156 | 242 | 132 | 11,749 |
| 4 | 348 | 141 | 284 | 120 | 11,861 |
| 5 | 279 | 136 | 392 | 92 | 10,276 |
| 6 | 221 | 110 | 316 | 65 | 4,968 |
| 7 | 190 | 83 | 320 | 69 | 8,307 |
| 8 | 193 | 83 | 289 | 34 | 3,507 |

### 7.3 Analysis

**GC baseline dominates:** OCaml's GC makes `ref v` allocations extremely fast (~ns). Since there's zero contention (each alloc creates a fresh heap object), GC throughput is 10–50× higher than pool-based approaches. This is an important OCaml-specific finding: *GC pressure may be preferable to pool contention* for many workloads.

**EBR scales better than HP:** At 5–7 threads, EBR achieves 320–392 Kops/s vs HP's 83–136 Kops/s. This is because:
- HP's `scan` must read **all** HP slots across all domains (global scan), creating cache contention.
- EBR's `enter`/`exit` only touches the domain's own record. Epoch advancement is an infrequent CAS.
- EBR's limbo freeing is amortized — domains free their own old limbo on `enter`.

**Mutex collapses at scale:** Mutex throughput drops from 188K (2 threads) to 34K (8 threads) — a **5.5× degradation**. This is the classic lock contention cliff.

**Raw pool (unsafe):** Fastest lock-free option but produces thousands of ABA errors. Not usable in production.

**HP overhead is constant per operation:** Each `alloc` requires load-publish-verify (3 atomic ops) plus potential scan. The per-operation cost is higher than EBR's amortized `enter`/`exit`.

---

## 8. Bugs Found and Fixed

### 8.1 Domain Registration Race (Critical)

**Symptom:** `Invalid_argument("index out of bounds")` during QCheck-Lin testing.

**Root cause:** In the DLS initializer:
```ocaml
let id = Atomic.fetch_and_add num_domains 1 in
if id >= max_domains then failwith "too many domains"
```

The `fetch_and_add` increments `num_domains` *before* the check. If the check fails, `num_domains` is already inflated. A concurrent `collect_protected` (HP) or `try_advance_epoch` (EBR) reads `num_domains`, computes `n = num_domains * hp_per_domain`, and accesses `slots[n-1]` — which is out of bounds.

**Fix:**
```ocaml
let id = Atomic.fetch_and_add num_domains 1 in
if id >= max_domains then begin
  ignore (Atomic.fetch_and_add num_domains (-1));  (* rollback *)
  failwith "too many domains"
end
```
Plus capping scan ranges: `min (Atomic.get num_domains) max_domains`.

### 8.2 OCaml `option` Boxing Prevents ABA

**Symptom:** ABA demo couldn't trigger ABA when using `option`-wrapped atomics.

**Root cause:** OCaml allocates a fresh `Some` box for each `Some node`. CAS compares the `Some` wrapper (physical address), not the node inside. Even if the same node is pushed back, the new `Some node` has a different address → CAS fails → no ABA.

**Fix:** Switched to direct node pointer atomics with a sentinel node, ensuring physical pointer comparison on the node itself.

---

## 9. Lessons Learned

1. **OCaml's GC is remarkably fast.** For workloads where node lifetime is short, GC allocation outperforms pooling by an order of magnitude. Pools are only worthwhile when node recycling reduces GC pressure in long-running systems.

2. **Cross-domain DLS access is impossible.** This is the key constraint that shaped our HP architecture. The lecture's linked-list registry pattern doesn't work because scanning requires reading other domains' DLS entries. A global array with domain-ID indexing is the correct solution.

3. **EBR's deferred reclamation complicates testing.** QCheck-STM models must account for the gap between "freed by the application" and "actually returned to the pool." Postconditions must be relaxed for non-deterministic reclamation timing.

4. **Lin_domain is expensive.** Each Lin test case spawns fresh OCaml domains (300 reps × 2 domains per test = 600 domain creations per test). Combined with permanent DLS slot consumption, this limits practical test counts. STM is more efficient for state-dependent operations.

5. **`fetch_and_add` before bounds check is a TOCTOU race.** Even in a DLS initializer (which runs at most once per domain), the increment is visible to concurrent readers immediately. Always plan for rollback.

6. **Physical equality is essential for reclamation.** Structural equality would cause false matches (different nodes with the same value), leading to premature reclamation of protected nodes.

---

## 10. Conclusion

We implemented Hazard Pointers and Epoch-Based Reclamation for OCaml 5's multicore runtime, integrated them into a lock-free Treiber stack pool and a Michael-Scott Queue, and verified correctness using four complementary techniques:

- **Custom unit tests** (24 tests across 7 suites)
- **QCheck-STM** (2,100 sequential + 100 parallel state machine tests)
- **QCheck-Lin** (5 × 300 concurrent linearizability checks)
- **ThreadSanitizer** (0 data races across 6 concurrent test suites)

Key findings:
- **ABA is real and reproducible** in OCaml 5 lock-free pools (4,562 errors in stress test).
- **Both HP and EBR eliminate ABA completely** (0 errors under identical workloads).
- **EBR scales better** (up to 392 Kops/s at 5 threads vs HP's 136 Kops/s) due to amortized enter/exit costs.
- **OCaml's GC dominates** for short-lived allocations — pools are justified primarily for deterministic latency, not throughput.

---

## 11. Appendix: File Listing

### Library (`lib/`) — 13 files

| File | Lines | Description |
|------|:-----:|-------------|
| `lockfree_pool.ml` | 98 | Treiber stack pool, exponential backoff |
| `lockfree_pool.mli` | 55 | Pool interface (concrete types exported) |
| `hazard_pointer.ml` | 118 | HP library: protect, release, retire, scan |
| `hazard_pointer.mli` | 48 | HP interface |
| `hp_pool.ml` | 84 | HP-protected pool (load-publish-verify) |
| `hp_pool.mli` | 30 | HP pool interface |
| `ebr.ml` | 119 | EBR: 3-epoch rotation, re-entrant |
| `ebr.mli` | 37 | EBR interface |
| `ebr_pool.ml` | 56 | EBR-protected pool |
| `ebr_pool.mli` | 16 | EBR pool interface |
| `ms_queue_ebr.ml` | 107 | Michael-Scott queue + EBR recycling |
| `ms_queue_ebr.mli` | 20 | MS queue interface |
| `dune` | 22 | Build configuration |

### Tests (`test/`) — 13 files

| File | Lines | Description |
|------|:-----:|-------------|
| `test_lockfree_pool.ml` | 217 | Pool unit tests (6 tests, 8D stress) |
| `test_aba_demo.ml` | 130 | Deterministic ABA demonstration |
| `test_hazard_pointer.ml` | 148 | HP unit tests (4 tests, multi-domain) |
| `test_hp_pool.ml` | 119 | HP pool tests (3 tests) |
| `test_ebr.ml` | 107 | EBR unit tests (4 tests, re-entrancy) |
| `test_ebr_pool.ml` | 70 | EBR pool tests (2 tests) |
| `test_ms_queue_ebr.ml` | 120 | MS queue tests (4 tests, 4P+4C) |
| `stress_aba.ml` | 145 | ABA stress: 8D×50K, 3 variants |
| `benchmark_pools.ml` | 158 | Throughput: 5 variants × 2–8 threads |
| `qcheck_stm_hp_pool.ml` | 100 | STM: HP pool sequential |
| `qcheck_stm_ebr_pool.ml` | 100 | STM: EBR pool sequential (deferred model) |
| `qcheck_stm_ms_queue_ebr.ml` | 72 | STM: MS queue sequential + parallel |
| `qcheck_lin_ms_queue_ebr.ml` | 45 | Lin: MS queue concurrent linearizability |

---

*Report generated from test run on April 26, 2026. All results reproducible with `dune build && dune exec test/<name>.exe`.*

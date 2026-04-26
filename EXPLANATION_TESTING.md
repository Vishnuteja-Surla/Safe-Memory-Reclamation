# Testing & Verification — Detailed Explanation

This document explains every test file, what it verifies, how it works, and the reasoning behind each verification technique.

---

## Table of Contents

1. [Testing Strategy Overview](#1-testing-strategy)
2. [Unit Tests: Lock-Free Pool](#2-test-lockfree-pool)
3. [ABA Bug Demonstration](#3-test-aba-demo)
4. [Unit Tests: Hazard Pointers](#4-test-hazard-pointer)
5. [Unit Tests: HP Pool](#5-test-hp-pool)
6. [Unit Tests: EBR](#6-test-ebr)
7. [Unit Tests: EBR Pool](#7-test-ebr-pool)
8. [Unit Tests: MS Queue](#8-test-ms-queue)
9. [ABA Stress Test](#9-stress-aba)
10. [QCheck-STM: State Machine Testing](#10-qcheck-stm)
11. [QCheck-Lin: Linearizability Testing](#11-qcheck-lin)
12. [TSAN: ThreadSanitizer](#12-tsan)
13. [Benchmarking](#13-benchmarking)
14. [How to Run Everything](#14-how-to-run)

---

## 1. Testing Strategy Overview {#1-testing-strategy}

We use **four complementary verification techniques**, each catching different classes of bugs:

| Technique | What It Catches | How |
|-----------|----------------|-----|
| **Unit tests** | Logic errors, edge cases, basic concurrency | Hand-written scenarios |
| **QCheck-STM** | Sequential specification violations | Random command sequences vs. model |
| **QCheck-Lin** | Non-linearizable concurrent executions | Random parallel interleavings |
| **TSAN** | Data races (unsynchronized memory access) | Compiler instrumentation |

Plus:
- **ABA stress test** — domain-specific: detects double-allocation from ABA
- **Benchmarks** — measures performance overhead of each reclamation scheme

---

## 2. Unit Tests: Lock-Free Pool (`test_lockfree_pool.ml`) {#2-test-lockfree-pool}

**6 tests covering sequential correctness, edge cases, and concurrent stress.**

### Test 1: Sequential Operations
```ocaml
let pool = Lockfree_pool.create ~capacity:4 in
let n1 = Lockfree_pool.alloc pool 10 in  (* Should succeed *)
let n2 = Lockfree_pool.alloc pool 20 in
...assert values, free, re-alloc...
```
Verifies basic alloc/free cycle works correctly in single-threaded mode.

### Test 2: Single Alloc/Free Cycles
Tests that after freeing a node and re-allocating, the same physical node is reused (since it's a stack — LIFO order).

### Test 3: Fill and Drain
Allocates ALL nodes (exhausting the pool), verifies that the next alloc returns `None`, then frees everything and verifies all nodes are recoverable.

### Test 4: GC Fallback (`alloc_fresh`)
Tests that `alloc_fresh` creates a node outside the pool. This node has valid `value` and `next` fields but wasn't pre-allocated.

### Test 5: Concurrent Operations (4 domains)
```ocaml
let pool = Lockfree_pool.create ~capacity:100 in
let domains = Array.init 4 (fun id ->
  Domain.spawn (fun () ->
    for _ = 1 to 1000 do
      match Lockfree_pool.alloc pool id with
      | Some n -> Lockfree_pool.free pool n
      | None -> ()
    done
  ))
```
Verifies that concurrent alloc/free doesn't crash and all 100 nodes are recovered afterward.

### Test 6: Stress Test (8 domains × 50,000 ops)
High-contention test: 8 domains, 50,000 random alloc/free operations, only 16 nodes. This maximizes CAS contention and exercises the backoff logic. Verifies all 16 nodes are recovered.

**Note:** This test does NOT check for ABA — that's what `stress_aba.ml` does.

---

## 3. ABA Bug Demonstration (`test_aba_demo.ml`) {#3-test-aba-demo}

**A deterministic, orchestrated demonstration of the ABA bug.**

### Why Deterministic?

ABA is a race condition — it happens non-deterministically. For a convincing demo, we need to **force** the exact interleaving that triggers it. We use barriers (atomic counters) to synchronize two threads:

```ocaml
let barrier1 = Atomic.make 0 in
let barrier2 = Atomic.make 0 in

(* T1: read, then wait for T2 *)
let t1 = Domain.spawn (fun () ->
  let old_top = Atomic.get top in      (* Read A *)
  let next = Atomic.get old_top.next in (* Read B *)
  Atomic.set barrier1 1;               (* Signal: "I've read" *)
  wait_for barrier2 1;                 (* Wait for T2 to finish *)
  Atomic.compare_and_set top old_top next  (* CAS — will ABA! *)
)

(* T2: wait for T1's read, then manipulate stack *)
let t2 = Domain.spawn (fun () ->
  wait_for barrier1 1;                 (* Wait for T1's read *)
  (* Pop A, Pop B, Push A back *)
  ...
  Atomic.set barrier2 1;              (* Signal: "ABA ready" *)
)
```

### The Sentinel Trick

As explained in `EXPLANATION_DESIGN.md`, we use a sentinel node instead of `option` to enable physical pointer comparison:

```ocaml
type node = { id : int; next : node Atomic.t }  (* No 'option' wrapper *)

let sentinel : node =
  let s = { id = 0; next = Atomic.make (Obj.magic ()) } in
  Atomic.set s.next s;  (* Self-referencing sentinel *)
  s
```

The `Obj.magic ()` is needed because OCaml doesn't allow truly recursive value construction — we create the node first with a dummy `next`, then patch it to point to itself.

### What the Output Shows

```
Initial: top → A(1) → B(2) → C(3) → sentinel
[T1] Read top=A(1), next=B(2)
[T2] Popped A(1). Stack: top → B → C
[T2] Popped B(2). Stack: top → C. T2 OWNS B(2).
[T2] Pushed A(1) back. Stack: top → A → C
[T1] CAS(top, A, B) = true — ABA BUG TRIGGERED!
[T1] top is now B(2), but T2 already owns B!

*** ABA BUG CONFIRMED ***
```

---

## 4. Unit Tests: Hazard Pointers (`test_hazard_pointer.ml`) {#4-test-hazard-pointer}

**4 tests covering the full HP lifecycle.**

### Test 1: Basic Protect/Release/Retire
```ocaml
(* Retire without protection → should be reclaimed *)
let reclaimed = ref false in
Hazard_pointer.retire hp node_a (fun _ -> reclaimed := true);
Hazard_pointer.scan hp;
assert (!reclaimed = true);

(* Protect then retire → should NOT be reclaimed *)
Hazard_pointer.protect hp 0 node_b;
Hazard_pointer.retire hp node_b (fun _ -> reclaimed_b := true);
Hazard_pointer.scan hp;
assert (!reclaimed_b = false);

(* Release then scan → NOW should be reclaimed *)
Hazard_pointer.release hp 0;
Hazard_pointer.scan hp;
assert (!reclaimed_b = true);
```

### Test 2: Threshold-Based Batching
Verifies that `scan` only triggers when `retired_count >= retire_threshold`. Retires 4 nodes with threshold=5 → no scan. Retire 5th → scan runs and reclaims all 5.

### Test 3: Multiple HP Slots
Tests that a domain can protect multiple nodes simultaneously (one per slot). Releasing one slot only reclaims that specific node.

### Test 4: Multi-Domain Protection
The critical concurrent test:
```ocaml
(* Domain 1 protects node *)
let d1 = Domain.spawn (fun () ->
  Hazard_pointer.protect hp 0 shared_node;
  Atomic.set ready 1;
  wait_for done_flag 1;
  Hazard_pointer.release hp 0;
)

(* Domain 0 retires same node, scans *)
wait_for ready 1;
Hazard_pointer.retire hp shared_node cleanup;
Hazard_pointer.scan hp;
(* Node must NOT be reclaimed — D1 is protecting it! *)
assert (!reclaimed = false);
```

---

## 5. Unit Tests: HP Pool (`test_hp_pool.ml`) {#5-test-hp-pool}

### Test 1: Sequential Correctness
Alloc nodes, verify values, free, re-alloc — single-threaded.

### Test 2: GC Fallback
When pool is exhausted, `alloc_fresh` creates nodes outside the pool. Tests that these nodes work correctly.

### Test 3: Concurrent (4 domains × 5,000 ops)
4 domains concurrently alloc/free on a 64-node pool. Verifies no crashes and counts recovered nodes.

---

## 6. Unit Tests: EBR (`test_ebr.ml`) {#6-test-ebr}

### Test 1: Basic Enter/Exit/Retire
Single-domain lifecycle test. Enter critical section, retire a node, exit, verify behavior.

### Test 2: Re-Entrancy
Tests nested enter/exit at depth 2 and 3:
```ocaml
Ebr.enter ebr;       (* active_count = 1 *)
Ebr.enter ebr;       (* active_count = 2 *)
Ebr.enter ebr;       (* active_count = 3 *)
Ebr.exit ebr;        (* active_count = 2 — still active *)
Ebr.exit ebr;        (* active_count = 1 — still active *)
Ebr.exit ebr;        (* active_count = 0 — now inactive *)
```

### Test 3: Epoch Advancement
Verifies that entering and exiting critical sections actually advances the epoch, and that old limbo buckets get freed:
```ocaml
Ebr.enter ebr; Ebr.retire ebr n1 cleanup; Ebr.exit ebr;
Ebr.enter ebr; Ebr.exit ebr;  (* Advance epoch *)
Ebr.enter ebr; Ebr.exit ebr;  (* Advance again — n1's bucket freed *)
assert (!reclaimed_1 = true);
```

### Test 4: Multi-Domain Protection
Domain 1 enters critical section, domain 0 retires a node — the node must NOT be freed until domain 1 exits.

---

## 7. Unit Tests: EBR Pool (`test_ebr_pool.ml`) {#7-test-ebr-pool}

### Test 1: Sequential
Basic alloc/free cycle, value verification.

### Test 2: Concurrent (4 domains × 5,000 ops)
Same pattern as HP pool concurrent test.

---

## 8. Unit Tests: MS Queue (`test_ms_queue_ebr.ml`) {#8-test-ms-queue}

### Test 1: Sequential FIFO
```ocaml
Ms_queue_ebr.enq q 1;
Ms_queue_ebr.enq q 2;
Ms_queue_ebr.enq q 3;
assert (Ms_queue_ebr.try_deq q = Some 1);  (* FIFO order *)
assert (Ms_queue_ebr.try_deq q = Some 2);
assert (Ms_queue_ebr.try_deq q = Some 3);
assert (Ms_queue_ebr.try_deq q = None);    (* Empty *)
```

### Test 2: Interleaved Enq/Deq
Alternates enqueue and dequeue to test FIFO ordering under mixed operations.

### Test 3: Fill and Drain (1,000 items)
Enqueues 1,000 items, then dequeues all — verifies count and FIFO order.

### Test 4: Concurrent (4 producers + 4 consumers)
4 producer domains each enqueue 1,000 items. 4 consumer domains dequeue concurrently. Verifies all 4,000 items are seen exactly once using a Hashtbl:
```ocaml
(* Each consumer collects items *)
let seen = Hashtbl.create 100 in
(* After joining all domains, verify: *)
assert (Hashtbl.length seen = 4000);
```

---

## 9. ABA Stress Test (`stress_aba.ml`) {#9-stress-aba}

### How It Detects ABA

The key insight: ABA causes **double allocation** — two threads get the same node. We detect this with an atomic ownership array:

```ocaml
let ownership = Array.init pool_size (fun _ -> Atomic.make (-1)) in

(* On alloc: atomically claim ownership *)
let prev = Atomic.exchange ownership.(slot_idx) id in
if prev >= 0 then  (* Another thread already owns this! *)
  Atomic.incr errors

(* On free: release ownership *)
Atomic.set ownership.(slot_idx) (-1)
```

`Atomic.exchange` atomically reads-and-sets. If the previous owner is not -1 (meaning someone else already owns it), that's an ABA corruption.

### Why 8 Nodes?

A small pool (8 nodes) with many threads (8 domains) maximizes contention and ABA probability. With 50,000 ops per domain, the pool is constantly churning — alloc, use, free, repeat. The unprotected pool consistently shows ~4,500 ABA errors.

---

## 10. QCheck-STM: State Machine Testing {#10-qcheck-stm}

### What Is QCheck-STM?

QCheck-STM generates **random command sequences** and checks that the real data structure's behavior matches a simple mathematical model. It tests **sequential correctness**: "does the implementation agree with the specification?"

### HP Pool STM (`qcheck_stm_hp_pool.ml`)

**Model:** A bounded counter tracking available nodes.

```ocaml
type state = {
  free_count : int;        (* Nodes available *)
  allocated : int list;    (* Values of held nodes, stack order *)
}

let next_state c s = match c with
  | Alloc v ->
    if s.free_count > 0 then
      { free_count = s.free_count - 1; allocated = v :: s.allocated }
    else s
  | Free ->
    match s.allocated with
    | [] -> s
    | _ :: rest -> { free_count = s.free_count + 1; allocated = rest }
```

**Postcondition:** `alloc` succeeds iff `free_count > 0`. `get` returns the most recently allocated value.

### EBR Pool STM (`qcheck_stm_ebr_pool.ml`)

**The deferred reclamation challenge:** When a node is freed via EBR, it goes to **limbo** — not immediately back to the pool. The model must account for this:

```ocaml
type state = {
  free_count : int;
  in_limbo : int;        (* Freed but not yet reclaimed *)
  allocated : int list;
}

let next_state c s = match c with
  | Free ->
    { s with in_limbo = s.in_limbo + 1; allocated = rest }
    (* NOT: free_count + 1 ! *)
```

The postcondition for `alloc` is relaxed: when `free_count = 0`, alloc MIGHT still succeed (if limbo nodes were reclaimed) or fail (if they weren't). We accept both outcomes:

```ocaml
let postcond c s res = match c, res with
  | Alloc _, Res ((Bool, _), result) ->
    if s.free_count > 0 then result = true
    else true  (* Accept either — non-deterministic reclamation *)
```

### MS Queue STM (`qcheck_stm_ms_queue_ebr.ml`)

**Model:** A list-based FIFO queue.

```ocaml
type state = { contents : int list }  (* head = front *)

let next_state c s = match c with
  | Enq i -> { contents = s.contents @ [i] }  (* Append to back *)
  | Try_deq ->
    match s.contents with
    | [] -> s
    | _ :: rest -> { contents = rest }          (* Remove from front *)
```

This also runs **parallel** tests via `STM_domain`, which spawns 2 domains running commands concurrently against the model.

---

## 11. QCheck-Lin: Linearizability Testing {#11-qcheck-lin}

### What Is Linearizability?

A concurrent execution is **linearizable** if it's equivalent to some sequential execution where each operation takes effect atomically at some point between its invocation and response.

### How Lin_domain Works

For each test case, Lin generates a command sequence and runs it concurrently on 2 domains. It then checks if the observed results are consistent with ANY valid sequential ordering. If not, the test fails with a counterexample.

### MS Queue Lin (`qcheck_lin_ms_queue_ebr.ml`)

```ocaml
module MSQSig = struct
  type t = int MSQ.t
  let init () = ...; shared_q
  open Lin
  let api = [
    val_ "enq"     enq_wrap (t @-> nat_small @-> returning unit);
    val_ "try_deq" deq_wrap (t @-> returning (option int));
  ]
end

module MSQ_lin = Lin_domain.Make(MSQSig)
```

The `api` describes the operations and their types. Lin generates random `enq`/`deq` sequences, runs them on 2 domains simultaneously, and verifies linearizability.

### Why Only for the Queue?

Pool operations (`alloc`/`free`) are **stateful** — `free` requires a previously-allocated node. Lin generates random independent commands without tracking state dependencies. The `held_key` DLS workaround doesn't compose across domains because each domain has its own held-node list.

The MS Queue's operations are **independent**: `enq(x)` doesn't depend on prior state, and `try_deq()` returns a value determined by the queue state. Perfect for Lin.

---

## 12. TSAN: ThreadSanitizer {#12-tsan}

### What TSAN Detects

ThreadSanitizer instruments every memory access at compile time. It detects **data races**: two concurrent accesses to the same memory location where at least one is a write and they're not synchronized by atomics or locks.

### How We Use It

OCaml 5.4.0 with `ocaml-option-tsan` compiles all code with TSAN instrumentation. Simply running our tests under this switch checks for races:

```bash
# Already on 5.4.0+tsan switch
dune exec test/test_hazard_pointer.exe 2>/tmp/tsan.log
grep -c "ThreadSanitizer" /tmp/tsan.log
# → 0 (no races!)
```

TSAN reports races to stderr. If any are found, the exit code is 66 (not 0). We check both.

### What Our Results Mean

**Zero races across all 6 concurrent test suites.** This confirms:
- All shared fields are properly marked `[@atomic]`
- All accesses go through `Atomic.t` or `[%atomic.loc]`
- No plain mutable field is accessed from multiple domains
- The `retired` and `retired_count` fields in HP records are safe because they're only accessed by their owning domain (per-domain retired lists)

### Limitation

TSAN only detects races that **actually execute** during the test. It's not a formal proof — it might miss races on code paths not exercised. That's why we combine it with stress tests and QCheck.

---

## 13. Benchmarking (`benchmark_pools.ml`) {#13-benchmarking}

### What We Measure

**Throughput**: alloc+free cycles per second across 5 pool variants and 2–8 threads.

### The 5 Variants

1. **Raw**: Unprotected `Lockfree_pool` (ABA-vulnerable but fastest)
2. **HP**: `Hp_pool` with hazard pointer protection
3. **EBR**: `Ebr_pool` with epoch-based reclamation
4. **Mutex**: `Lockfree_pool` wrapped with a `Mutex` lock (baseline)
5. **GC**: `alloc_fresh` / GC collection (no pool at all)

### Methodology

```ocaml
let run_benchmark ~variant ~num_threads ~ops_per_thread ~pool_size =
  (* Each domain: loop ops_per_thread times, alloc then free *)
  let t0 = Unix.gettimeofday () in
  let domains = Array.init num_threads (fun id ->
    Domain.spawn (fun () ->
      for _ = 1 to ops_per_thread do
        let node = alloc ... in
        free node
      done
    ))
  in
  Array.iter Domain.join domains;
  let elapsed = Unix.gettimeofday () -. t0 in
  let total_ops = num_threads * ops_per_thread in
  float_of_int total_ops /. elapsed  (* ops/sec *)
```

3 runs averaged. 50,000 ops per thread. 1024-node pool.

---

## 14. How to Run Everything {#14-how-to-run}

### Prerequisites
```bash
opam switch 5.4.0+tsan   # or any OCaml 5.x switch
opam install qcheck-stm qcheck-lin
```

### Build
```bash
dune build
```

### Run All Unit Tests
```bash
for t in test_lockfree_pool test_aba_demo test_hazard_pointer \
         test_hp_pool test_ebr test_ebr_pool test_ms_queue_ebr; do
  dune exec test/$t.exe
done
```

### Run ABA Stress Test
```bash
dune exec test/stress_aba.exe
```

### Run QCheck Tests
```bash
dune exec test/qcheck_stm_hp_pool.exe
dune exec test/qcheck_stm_ebr_pool.exe
dune exec test/qcheck_stm_ms_queue_ebr.exe
dune exec test/qcheck_lin_ms_queue_ebr.exe
```

### Run TSAN Checks
```bash
# Must be on 5.4.0+tsan switch
for t in test_hazard_pointer test_hp_pool test_ebr test_ebr_pool \
         test_ms_queue_ebr stress_aba; do
  TSAN_OPTIONS="halt_on_error=0" dune exec test/$t.exe 2>/tmp/tsan.log
  echo "$t: $(grep -c ThreadSanitizer /tmp/tsan.log) races"
done
```

### Run Benchmarks
```bash
dune exec test/benchmark_pools.exe
```

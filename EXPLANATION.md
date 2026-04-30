# Safe Memory Reclamation — Complete Project Explanation

## Table of Contents
1. [Goals and Research Question](#1-the-problem)
2. [Lock-Free Pool: The Treiber Stack](#2-lock-free-pool)
3. [The ABA Problem](#3-the-aba-problem)
4. [Hazard Pointers: Per-Access Protection](#4-hazard-pointers)
5. [HP-Protected Pool](#5-hp-protected-pool)
6. [Epoch-Based Reclamation: Time-Based Protection](#6-epoch-based-reclamation)
7. [EBR-Protected Pool](#7-ebr-protected-pool)
8. [Michael-Scott Queue with EBR](#8-michael-scott-queue-with-ebr)
9. [Verification and Testing](#9-verification-and-testing)
10. [Evaluation](#10-benchmarking)
11. [Post-Audit Improvements](#11-post-audit-improvements)
12. [Reflection on the Use of LLMs](#12-llm-reflection)
13. [Conclusions](#13-conclusions)
14. [Contributions](#14-contributions)
15. [References](#15-references)

---

## 1. Goals and Research Question {#1-the-problem}

### What Was Implemented

This project implements two safe memory reclamation schemes — **Hazard Pointers** (HP) and **Epoch-Based Reclamation** (EBR) — as libraries in OCaml 5, and applies them to lock-free data structures (Treiber stack pool and Michael-Scott queue) to eliminate the ABA problem.

### Why It's Interesting

OCaml 5 introduced shared-memory parallelism via domains, but its garbage collector can mask the ABA problem in many cases (due to `option` boxing creating fresh heap addresses). This creates a false sense of safety. When nodes are explicitly recycled for performance (e.g., in a pre-allocated pool), ABA resurfaces. Understanding and preventing ABA is essential for writing correct lock-free code.

### Connection to Course Topics

This project directly applies concepts from CS6868 Concurrent Programming:
- **Lock-freedom** (Lectures 07–08): Treiber stacks and Michael-Scott queues using CAS
- **The ABA problem** (Lecture 07): Demonstrated and resolved
- **Linearizability** (Lecture 05): Verified via QCheck-Lin
- **Memory models** (Lecture 09): Atomic ordering, happens-before relationships
- **Verification** (Lectures 10–11): Property-based testing, model checking

### Research Question

> **What is the throughput cost of hazard pointer scanning vs. epoch-based reclamation for protecting a lock-free pool, and how does each scheme's latency profile differ (HP has bounded garbage, EBR can delay reclamation under stalled threads)?**

### The Core Challenge

In concurrent programming, lock-free data structures use **Compare-And-Swap (CAS)** instead of locks. CAS atomically checks if a memory location contains an expected value and, only if so, replaces it with a new value. This guarantees that at least one thread always makes progress (lock-freedom).

However, CAS introduces a critical problem: **when can you safely reuse a node** that's been removed from a data structure?

Consider a Treiber stack (a lock-free stack):
```
Thread A reads top → Node X, and reads X.next → Node Y
Thread A wants to CAS(top, X, Y)  — i.e., pop X

But between reading and CAS-ing, Thread B could:
  1. Pop X
  2. Pop Y
  3. Reuse X for something else
  4. Push X back

Now Thread A's CAS sees top == X (same pointer!) and succeeds,
but Y is no longer valid — it was already popped by B!
```

This is the **ABA problem**. The solution: don't allow nodes to be reused until it's safe. That's what **Hazard Pointers** and **Epoch-Based Reclamation** do.

### OCaml 5 Specifics

OCaml 5 introduced **domains** — OS-level parallel threads sharing memory. Key features we use:

- `Atomic.t` — atomic reference cells for CAS operations
- `[@atomic]` annotation on mutable record fields — enables `[%atomic.loc field]` for fine-grained CAS on struct fields
- `Domain.DLS` — Domain-Local Storage (like thread-local storage)
- `Domain.spawn` / `Domain.join` — create and wait for parallel domains

---

## 2. Lock-Free Pool: The Treiber Stack {#2-lock-free-pool}

### Concept

A **node pool** pre-allocates a fixed number of nodes and manages them as a free list. Instead of calling the garbage collector for every allocation, we recycle nodes:

```
Free list (Treiber stack):     top → N1 → N2 → N3 → None

alloc: pop from top             top → N2 → N3 → None  (return N1)
free:  push back to top         top → N1 → N2 → N3 → None
```

This is a classic Treiber stack — a lock-free stack where push/pop use CAS on the `top` pointer.

### Implementation: `lockfree_pool.ml`

**Data types** (lines 18–27):
```ocaml
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]  (* atomic for CAS *)
}

type 'a t = {
  mutable top : 'a node option; [@atomic]   (* head of free list *)
  cap : int;
}
```

The `[@atomic]` annotation is critical. It tells OCaml 5 to make these fields atomically accessible. Without it, `[%atomic.loc t.top]` wouldn't compile, and we couldn't use CAS on these fields.

**Creation** (lines 48–59):
```ocaml
let create ~capacity =
  let head = ref None in
  for _ = 1 to capacity do
    let node = { value = Obj.magic (); next = !head } in
    head := Some node
  done;
  { top = !head; cap = capacity }
```

We chain `capacity` nodes together. `Obj.magic ()` is used as a placeholder value — it will be overwritten on first `alloc`. This avoids requiring a default value at creation time.

**Alloc — CAS pop** (lines 64–80):
```ocaml
let alloc t v =
  let backoff = Backoff.create () in
  let rec loop () =
    let old_top = AL.get [%atomic.loc t.top] in    (* 1. Read top *)
    match old_top with
    | None -> None                                  (* Pool empty *)
    | Some node ->
      let next = AL.get [%atomic.loc node.next] in  (* 2. Read next *)
      if AL.compare_and_set [%atomic.loc t.top] old_top next then begin
        node.value <- v;                            (* 3. CAS succeeded *)
        Some node
      end else begin
        Backoff.once backoff;                       (* 4. CAS failed, retry *)
        loop ()
      end
  in loop ()
```

Step by step:
1. Read the current `top` atomically
2. Read `top.next` — this is what `top` will become after popping
3. CAS: if `top` is still `old_top`, set it to `next`. If CAS succeeds, we've popped the node
4. If CAS fails (another thread modified `top`), back off and retry

**Exponential backoff** (lines 30–42) reduces contention. On each CAS failure, we spin for a random delay that doubles each time (1→2→4→...→128 iterations of `Domain.cpu_relax()`).

**Free — CAS push** (lines 84–95): The reverse operation. Set `node.next = top`, then CAS `top` from old value to `Some node`.

**Why this is vulnerable to ABA:** Between steps 1 and 3 in `alloc`, another thread can pop the same node, use it, and push it back. The CAS in step 3 sees the same pointer and succeeds, but `next` (read in step 2) may no longer be valid.

---

## 3. The ABA Problem {#3-the-aba-problem}

### Concept

ABA occurs when:
1. Thread T1 reads pointer P = A
2. Thread T2 changes P: A → B → A (A leaves and returns)
3. T1's CAS(P, A, ...) succeeds incorrectly — A is the same address, but the world changed

In our pool, this means a node can be given to two threads simultaneously (**double allocation**).

### OCaml Subtlety: `option` Type Boxing

We discovered that OCaml's `option` type **naturally prevents some ABA** in a subtle way. When `top` is `'a node option Atomic.t`, each `Some node` creates a fresh heap allocation. Even if the same `node` is pushed back, the new `Some node` wrapper is at a different address. CAS compares the `Some` wrapper addresses, not the node inside — so it detects the change.

To demonstrate ABA, we had to bypass this. We use **direct node pointers** with a **sentinel node** instead of `None`:

### Implementation: `test_aba_demo.ml`

```ocaml
type node = {
  id : int;
  next : node Atomic.t;   (* Direct pointer, not 'option' *)
}

let sentinel : node =     (* Bottom of stack — replaces None *)
  let s = { id = 0; next = Atomic.make (Obj.magic ()) } in
  Atomic.set s.next s; s

let top = Atomic.make node_a  (* Direct node ref, not Some node_a *)
```

With direct pointers, CAS compares the node address itself. The sentinel replaces `None` as the stack bottom marker. Now ABA is possible because the same physical node pointer can reappear.

**The orchestrated demo** uses barriers to control interleaving:
```
T1: reads top = node_a, next = node_b, PAUSES at barrier
T2: pops A, pops B (now owns B), pushes A back
    Stack: top → A → C (same physical node_a!)
T1: resumes, CAS(top, node_a, node_b) → succeeds!
    top now points to B, but T2 already owns B!
```

**Result**: Node B is simultaneously in the stack AND owned by T2 — corruption!

### Stress Test: `stress_aba.ml`

The stress test runs 8 domains doing 50,000 random alloc/free cycles on an 8-node pool. It tracks ownership with an atomic array:

```ocaml
let ownership = Array.init pool_size (fun _ -> Atomic.make (-1)) in

(* On alloc: *)
let prev = Atomic.exchange ownership.(slot_idx) id in
if prev >= 0 then  (* Someone else owns this slot! ABA! *)
  Atomic.incr errors

(* On free: *)
Atomic.set ownership.(slot_idx) (-1)
```

If two threads get the same slot simultaneously, `Atomic.exchange` reveals it. Results: ~4,500 errors for unprotected pool, 0 for HP and EBR.

---

## 4. Hazard Pointers: Per-Access Protection {#4-hazard-pointers}

### Concept

Hazard Pointers (M. Michael, 2004) let each thread **announce** which nodes it's currently accessing by writing them into globally visible "HP slots." Before freeing a retired node, you scan all HP slots — if any thread has a hazard pointer to that node, you must defer freeing it.

**Protocol:**
1. **Protect**: Write node address to your HP slot (globally visible)
2. **Verify**: Re-read the source pointer — if it changed, the node might have been freed between your read and your protect. Release and retry.
3. **Retire**: When removing a node, add it to your retired list with a cleanup callback
4. **Scan**: When retired list exceeds a threshold, scan ALL HP slots across ALL domains. Reclaim nodes that no one is protecting.

The **load-publish-verify** pattern (steps 1–2) is essential. Without the verify step, there's a race: you read the pointer, the node gets freed, then you publish a dangling pointer in your HP slot.

### Why a Global Array?

OCaml 5's Domain-Local Storage (DLS) is **per-domain only** — you cannot read another domain's DLS from your domain. But HP scanning requires reading ALL domains' HP slots.

We solved this with a **pre-allocated global array** of HP slots, indexed by domain ID:
```
Domain 0: slots[0], slots[1]         (2 HP slots per domain)
Domain 1: slots[2], slots[3]
Domain 2: slots[4], slots[5]
...
base_idx = domain_id × hp_per_domain
```

DLS only stores the domain's **index** into this global array — the actual slots are globally accessible.

### Implementation: `hazard_pointer.ml`

**Data types** (lines 14–35):
```ocaml
type 'a retired_node = {
  node : 'a;
  cleanup : 'a -> unit;  (* Called when safe to reclaim *)
}

type 'a domain_record = {
  domain_id : int;
  base_idx : int;                 (* Index into global slots array *)
  retired : 'a retired_node list ref;
  retired_count : int ref;
}

type 'a t = {
  slots : 'a option Atomic.t array;  (* Global HP slots — ALL domains *)
  hp_per_domain : int;
  max_domains : int;
  retire_threshold : int;
  num_domains : int Atomic.t;
  domain_key : 'a domain_record Domain.DLS.key;
}
```

Each domain gets a `domain_record` via DLS. The `retired` list holds nodes this domain has removed but can't free yet. The `cleanup` callback defines what "freeing" means (for pools: push back to free list).

**Domain registration** (lines 43–53):
```ocaml
let domain_key = Domain.DLS.new_key (fun () ->
  let id = Atomic.fetch_and_add num_domains 1 in
  if id >= max_domains then begin
    ignore (Atomic.fetch_and_add num_domains (-1));  (* rollback! *)
    failwith "too many domains"
  end;
  { domain_id = id; base_idx = id * max_hp_per_domain;
    retired = ref []; retired_count = ref 0 }
)
```

The `fetch_and_add` atomically claims a domain ID. The rollback (`-1`) was added to fix a race where `num_domains` would exceed `max_domains` temporarily — a concurrent scan would read the inflated count and access out-of-bounds slots.

**Protect and Release** (lines 66–77):
```ocaml
let protect t slot value =
  let r = get_record t in
  Atomic.set t.slots.(r.base_idx + slot) (Some value)

let release t slot =
  let r = get_record t in
  Atomic.set t.slots.(r.base_idx + slot) None
```

Writing to a globally visible atomic slot. Any domain can read this during scanning.

**Scan — the core safety mechanism** (lines 80–109):
```ocaml
let collect_protected t =
  let nd = min (Atomic.get t.num_domains) t.max_domains in
  let n = nd * t.hp_per_domain in
  let protected = ref [] in
  for i = 0 to n - 1 do
    match Atomic.get t.slots.(i) with
    | None -> ()
    | Some ptr -> protected := ptr :: !protected
  done;
  !protected

let scan t =
  let r = get_record t in
  let protected = collect_protected t in
  List.iter (fun rn ->
    if List.exists (fun p -> p == rn.node) protected then
      (* Still protected — keep *)
      ...
    else
      (* Not protected — safe to reclaim! *)
      rn.cleanup rn.node
  ) !(r.retired)
```

Key: `p == rn.node` uses **physical equality**. We check if the exact same object (same memory address) appears in any HP slot. Structural equality (`=`) would compare values and produce false positives.

**Retire** (lines 113–118):
```ocaml
let retire t node cleanup =
  let r = get_record t in
  r.retired := { node; cleanup } :: !(r.retired);
  r.retired_count := !(r.retired_count) + 1;
  if !(r.retired_count) >= t.retire_threshold then
    scan t
```

Nodes accumulate in the retired list. When it exceeds the threshold, `scan` runs and reclaims unprotected ones. This batching amortizes the cost of scanning.

---

## 5. HP-Protected Pool {#5-hp-protected-pool}

### Implementation: `hp_pool.ml`

This wraps `Lockfree_pool` with HP protection. The key is the **load-publish-verify** pattern in `alloc`:

```ocaml
let alloc t v =
  let rec loop () =
    let top = AL.get [%atomic.loc t.pool.top] in   (* 1. LOAD *)
    match top with
    | None -> None
    | Some node ->
      Hazard_pointer.protect t.hp 0 node;           (* 2. PUBLISH *)
      let top2 = AL.get [%atomic.loc t.pool.top] in (* 3. VERIFY *)
      if top2 != top then begin
        Hazard_pointer.release t.hp 0;              (* Changed! Retry *)
        loop ()
      end else begin
        let next = AL.get [%atomic.loc node.next] in
        if AL.compare_and_set [%atomic.loc t.pool.top] top next then begin
          Hazard_pointer.release t.hp 0;
          Lockfree_pool.set node v;
          Some node
        end else begin
          Hazard_pointer.release t.hp 0;
          loop ()
        end
      end
  in loop ()
```

**Why verify?** Between LOAD and PUBLISH, the node could be freed by another thread. If we didn't verify, we'd protect a node that's already been reclaimed — meaning our HP slot points to garbage. The verify step catches this: if `top` changed, we know the world moved on and our protection is stale.

**Free** calls `retire` with a cleanup that pushes back to the pool:
```ocaml
let free t node =
  Hazard_pointer.retire t.hp node (fun n -> push_to_pool t.pool n)
```

The node doesn't return to the pool immediately. It goes to the retired list. Only after a `scan` confirms no one is protecting it does `push_to_pool` run.

---

## 6. Epoch-Based Reclamation: Time-Based Protection {#6-epoch-based-reclamation}

### Concept

EBR (K. Fraser, 2004) divides time into **epochs**. Instead of tracking individual node accesses (like HP), EBR tracks **when** a thread entered a critical section. The global epoch advances when all active threads have caught up. Nodes retired 2 epochs ago are guaranteed safe because all active threads started after they were retired.

**Three-epoch rotation:**
```
Epoch 0: nodes retired here go to bucket 0
Epoch 1: nodes retired here go to bucket 1  
Epoch 2: nodes retired here go to bucket 2, bucket 0 is safe to free
Epoch 3: bucket 1 is safe to free
...
```

When epoch is `e`, bucket `(e+1) mod 3` (= epoch `e-2`) is safe. Why? All active domains entered at epoch `e-1` or later, so they can't hold references to nodes from epoch `e-2`.

**Key difference from HP:** EBR has lower per-operation overhead (just enter/exit) but higher worst-case memory: if one domain stalls in a critical section, *no* nodes from that epoch onward can be freed.

### Why `active_count : int` Instead of `bool`?

The `enter`/`exit` pattern must be **re-entrant**. Consider:
```ocaml
let deq q =
  Ebr.enter q.ebr;
  (* ... internally calls some function that also does enter/exit ... *)
  Ebr.exit q.ebr
```

If `active` were a boolean, the inner `exit` would set it to false, making the epoch advancer think this domain is inactive — while the outer function still holds references! An integer counter correctly handles nesting: only the outermost `exit` (count → 0) marks the domain as truly inactive.

### `enter` Ordering

The order of operations in `enter` matters critically:
```
CORRECT:   read epoch → set local_epoch → increment active_count
WRONG:     increment active_count → read epoch → set local_epoch
```

With the wrong order: we mark ourselves active but with a stale `local_epoch`. A concurrent advancer sees us active with `local_epoch < global_epoch` and refuses to advance — indefinitely blocking progress.

With the correct order: we publish our epoch before becoming visible as active. The advancer sees our up-to-date epoch.

### Implementation: `ebr.ml`

**Data types** (lines 22–35):
```ocaml
type 'a domain_record = {
  local_epoch : int Atomic.t;
  active_count : int Atomic.t;
  limbo : 'a retired_node list ref array;  (* 3 buckets *)
}

type 'a t = {
  global_epoch : int Atomic.t;
  records : 'a domain_record array;   (* Global! Not DLS! *)
  max_domains : int;
  num_domains : int Atomic.t;
  domain_key : int Domain.DLS.key;    (* DLS stores only the index *)
}
```

The `records` array is global (not DLS) so other domains can read `local_epoch` and `active_count` during epoch advancement. DLS only stores the domain's index into this array.

**Enter** (lines 96–103):
```ocaml
let enter t =
  let r = get_record t in
  let e = Atomic.get t.global_epoch in          (* 1. Read epoch *)
  Atomic.set r.local_epoch e;                   (* 2. Publish *)
  ignore (Atomic.fetch_and_add r.active_count 1); (* 3. Become active *)
  free_limbo_bucket r.limbo.((e + 1) mod 3)     (* 4. Free old bucket *)
```

Step 4 is an optimization: while entering, we free our own limbo bucket for epoch `e-2`. This is safe because the epoch has already advanced past `e-2`, so those nodes are guaranteed unreferenced.

**Try advance epoch** (lines 76–88):
```ocaml
let try_advance_epoch t =
  let e = Atomic.get t.global_epoch in
  let n = min (Atomic.get t.num_domains) t.max_domains in
  let all_caught_up = ref true in
  for i = 0 to n - 1 do
    let r = t.records.(i) in
    if Atomic.get r.active_count > 0 then begin    (* Only check active *)
      if Atomic.get r.local_epoch < e then
        all_caught_up := false                      (* Someone is behind *)
    end
  done;
  if !all_caught_up then
    ignore (Atomic.compare_and_set t.global_epoch e (e + 1))
```

We only advance if ALL active domains have `local_epoch >= global_epoch`. Inactive domains (count=0) are ignored — they'll catch up when they next call `enter`.

**Retire** (lines 114–118):
```ocaml
let retire t node cleanup =
  let r = get_record t in
  let e = Atomic.get t.global_epoch in
  r.limbo.(e mod 3) := { node; cleanup } :: !(r.limbo.(e mod 3));
  try_advance_epoch t
```

Add to the current epoch's limbo bucket, then try to advance. The bucket mapping `e mod 3` ensures 3-epoch rotation.

---

## 7. EBR-Protected Pool {#7-ebr-protected-pool}

### Implementation: `ebr_pool.ml`

```ocaml
let alloc t v =
  Ebr.enter t.ebr;                                    (* Enter critical section *)
  let rec loop () =
    let top = AL.get [%atomic.loc t.pool.top] in
    match top with
    | None -> Ebr.exit t.ebr; None
    | Some node ->
      let next = AL.get [%atomic.loc node.next] in
      if AL.compare_and_set [%atomic.loc t.pool.top] top next then begin
        Ebr.exit t.ebr;                               (* Exit critical section *)
        Lockfree_pool.set node v;
        Some node
      end else loop ()
  in loop ()

let free t node =
  Ebr.retire t.ebr node (fun n -> push_to_pool t.pool n)
  (* No enter/exit! Caller finished using node *)
```

**Why no `enter`/`exit` around `free`?** When calling `free(node)`, the caller is **relinquishing** the node — not reading from it. There's no pointer to protect. The `retire` call just adds the node to limbo; it'll be pushed back to the pool after the epoch advances.

---

## 8. Michael-Scott Queue with EBR {#8-michael-scott-queue-with-ebr}

### Concept

The Michael-Scott Queue (1996) is the classic lock-free FIFO queue. It uses two pointers: `head` (dequeue end) and `tail` (enqueue end), connected by a singly-linked list. A **sentinel node** separates head from actual data.

```
Empty:    head → [sentinel] ← tail
                     next = None

After enq(1):   head → [sentinel] → [1] ← tail

After enq(2):   head → [sentinel] → [1] → [2] ← tail

After deq():    head → [1] → [2] ← tail    (old sentinel retired)
                 ↑ new sentinel
```

**Key insight:** `deq` doesn't actually remove the head node — it swings `head` to the next node, which becomes the new sentinel. The old sentinel is no longer needed and can be retired via EBR.

### Internal Free List

Instead of using `Lockfree_pool`, the queue manages its own free list. This avoids type mismatch: queue nodes have `{ value; next }` while pool nodes have a different type. The free list is a simple lock-free stack:

```ocaml
type 'a t = {
  mutable head : 'a node; [@atomic]
  mutable tail : 'a node; [@atomic]
  mutable free_list : 'a node option; [@atomic]  (* Internal recycling *)
  ebr : 'a node Ebr.t;
}
```

**GC fallback:** If the free list is empty, `alloc_node` creates a fresh GC-allocated node. This prevents deadlock in producer-heavy workloads where all nodes are in the queue (none available for recycling).

### Implementation: `ms_queue_ebr.ml`

**Enqueue** (lines 68–90): Allocate node, CAS-append at tail, help advance lagging tail.

**Dequeue** (lines 93–122): CAS-swing head forward, retire old sentinel via EBR.

Both are wrapped in `Ebr.enter`/`Ebr.exit` to protect node access during the operation.

---

## 9. Verification and Testing {#9-verification-and-testing}

### Unit Tests (7 suites, 24 tests)

Each module has dedicated tests verifying sequential correctness, edge cases, and concurrent behavior. For example, `test_hazard_pointer.ml` tests:
- Single-domain protect/release/retire
- Threshold-based batching (scan triggers only after N retires)
- Multiple HP slots per domain
- Multi-domain protection (domain 1 protects, domain 2 retires — must NOT reclaim)

### QCheck-STM: State Machine Testing

QCheck-STM tests sequential correctness against a mathematical model. For the HP pool, the model is a simple bounded counter:
```
State: { free_count: int; allocated: int list }
alloc v: if free_count > 0 then decrement, add to allocated
free:    increment free_count, remove from allocated
```

For the **EBR pool**, the model must account for **deferred reclamation**:
```
State: { free_count: int; in_limbo: int; allocated: int list }
free: node goes to in_limbo (NOT immediately back to free_count!)
alloc: might succeed even when free_count=0 (if limbo was reclaimed)
```

### QCheck-Lin: Concurrent Linearizability

Tests that concurrent `enq`/`deq` operations on the MS Queue are linearizable — every concurrent execution is equivalent to some sequential ordering.

**Challenge:** Lin_domain spawns ~600 fresh domains per test (300 reps × 2 domains). Each permanently consumes an EBR slot. Solution: use `max_domains:8192` and limit test count.

### TSAN: ThreadSanitizer

OCaml 5.4.0's TSAN-instrumented runtime detects unsynchronized memory accesses. All 6 concurrent test suites report **0 data races**, confirming our `[@atomic]` annotations are correct.

---

## 10. Evaluation {#10-benchmarking}

### Experimental Setup

**Hardware:**
- CPU: 11th Gen Intel Core i5-11300H @ 3.10 GHz, 4 cores / 8 threads
- RAM: 7.6 GB (WSL2 allocation)
- OS: Linux 5.15.167.4-microsoft-standard-WSL2

**Software:**
- OCaml 5.4.0 with `ocaml-option-tsan` (for race detection)
- Build system: dune 3.x
- Libraries: `qcheck-stm`, `qcheck-lin`, `dscheck`

**Methodology:**
- Each benchmark runs 50,000 alloc+free operations per thread
- Pool size: 1,024 nodes (large enough to avoid exhaustion)
- Thread counts: 1, 2, 3, 4, 5, 6, 7, 8
- 3 runs per configuration, results averaged
- No explicit warm-up phase — the first run initializes DLS lazily, subsequent runs reuse it
- Throughput = total operations / wall-clock time (ops/sec)

### The 5 Variants

| Variant | Description | ABA-safe? |
|---------|-------------|:---------:|
| **Raw** | Unprotected `Lockfree_pool` — no reclamation | ❌ |
| **HP** | `Hp_pool` with load-publish-verify + global scan | ✅ |
| **EBR** | `Ebr_pool` with enter/exit critical sections | ✅ |
| **Mutex** | `Lockfree_pool` wrapped with `Mutex.lock`/`unlock` | ✅ |
| **GC** | `alloc_fresh` — fresh GC allocation each time | ✅ |

### Results (50K ops/thread × 3 runs)

| Threads | Raw | HP | EBR | Mutex | GC-only |
|:-------:|:---:|:--:|:---:|:-----:|:-------:|
| 2 | 653K | 263K | 272K | 188K | 9,156K |
| 4 | 348K | 141K | 284K | 120K | 11,861K |
| 8 | 193K | 83K | 289K | 34K | 3,507K |

### Discussion

**Finding 1: OCaml's GC dominates throughput.**
GC-only allocation achieves 9–12M ops/sec at 2–4 threads — an order of magnitude faster than any pool-based scheme. OCaml 5's minor heap allocator is extremely fast (essentially a pointer bump), and the GC handles deallocation concurrently. This suggests that explicit memory pools in OCaml are justified only in scenarios requiring deterministic latency or bounded memory, not raw throughput.

**Finding 2: EBR scales better than HP.**
EBR maintains ~280K ops/sec regardless of thread count (near-flat scaling), while HP drops from 263K→83K (3.2× degradation). This is because HP's `scan` reads ALL HP slots across ALL domains — O(domains × slots_per_domain) work per scan. EBR's `enter`/`exit` is O(1), with epoch advancement amortized across retires.

**Finding 3: Mutex collapses under contention.**
Mutex throughput drops from 188K (2T) to 34K (8T) — a 5.5× collapse. This is the classic lock convoy effect: as threads increase, each thread spends more time waiting for the lock, and the critical section becomes the bottleneck.

**Finding 4: Raw pool is fastest lock-free, but unsafe.**
The unprotected pool achieves the highest lock-free throughput (no HP/EBR overhead), but the stress test reveals ~4,500 ABA errors at 8 threads × 50K ops. Trading correctness for performance is never acceptable.

**Finding 5: EBR is the recommended safe scheme for OCaml 5.**
EBR provides the best balance: near-flat throughput scaling, low per-operation overhead, and strong ABA protection. HP is better suited for scenarios where individual node protection semantics are needed (e.g., traversing graphs where only specific nodes need protection).


---

## 11. Post-Audit Improvements (April 29–30)

After the initial implementation, a series of audits and reviews led to significant improvements across the codebase. This section documents all changes made after the original explanation files.

### 11.1 New API: `Hazard_pointer.retired_count`

**Problem:** The HP pool test had no way to verify that all retired nodes were reclaimed after freeing. Nodes could remain stuck in the retired list.

**Solution:** Added `retired_count : 'a t -> int` to `hazard_pointer.ml/mli` and `hp_pool.ml/mli`. This returns the number of nodes pending reclamation in the calling domain's retired list.

**Usage in `test_hp_pool.ml`:**
```ocaml
(* After freeing all nodes, drain the retired list *)
while Hp_pool.retired_count t > 0 do
  Hp_pool.scan t;
  Domain.cpu_relax ()
done
```

This changed recovery from 0/64 nodes to **64/64 nodes** — a complete fix.

### 11.2 New API: `Ebr.force_flush` and `Ebr_pool.force_flush`

**Problem:** EBR reclamation is asynchronous — nodes sit in limbo until the epoch advances. This made it impossible to write strict STM tests, since the model couldn't predict when nodes would be reclaimed.

**Solution:** Added `force_flush : 'a t -> unit` to `ebr.ml/mli` and `ebr_pool.ml/mli`. This performs 3 enter/retire/exit cycles to advance the epoch past all 3 limbo buckets, then one final enter/exit to trigger freeing:

```ocaml
let force_flush t =
  for _ = 1 to 3 do
    enter t;
    retire t (Obj.magic ()) (fun _ -> ());
    exit t
  done;
  enter t; exit t
```

**Constraint:** Only safe in single-domain scenarios (sequential tests). In multi-domain scenarios, other active domains would prevent epoch advancement.

### 11.3 EBR Pool STM Test: Strict Postconditions

**Problem (audit finding):** The original STM test had `true (* accept either true or false *)` in the `Alloc` postcondition when `free_count = 0`. This masked potential memory leaks — a broken EBR that never reclaimed would still pass. Similarly, `Get` only checked `v <> None` instead of the exact value, hiding data corruption.

**Fix:** Using `force_flush` after every `Free` in the STM `run` function makes reclamation synchronous. This eliminated the need for `in_limbo` in the model and restored strict postconditions:

```ocaml
(* BEFORE: weak *)
| Alloc _, Res ((Bool, _), result) ->
  if s.free_count > 0 then result = true
  else true  (* accept either — DANGEROUS *)

(* AFTER: strict *)
| Alloc _, Res ((Bool, _), result) ->
  result = (s.free_count > 0)  (* Must match exactly *)
| Get, Res ((Option Int, _), v) ->
  match s.allocated with
  | [] -> v = None
  | x :: _ -> v = Some x  (* Exact value check *)
```

### 11.4 MS Queue STM Test: DLS Guard

**Problem (audit finding):** `init_domain` was called in `run` for every command. While EBR's DLS already makes this idempotent within a domain, the test lacked clarity about this guarantee. Also, `max_domains:128` could be insufficient if `STM_domain` spawns many fresh domains.

**Fix:** Added an explicit DLS guard (`inited` key) and bumped `max_domains` to 512:

```ocaml
let inited = Domain.DLS.new_key (fun () -> false)
let ensure_init q =
  if not (Domain.DLS.get inited) then begin
    MSQ.init_domain q;
    Domain.DLS.set inited true
  end
```

Note: 4096 was tried first but caused timeouts — `try_advance_epoch` scans all pre-allocated records, and 4096 records added too much overhead.

### 11.5 EBR Test Assertions

**Problem:** `test_ebr.ml` had tests that printed "OK" without asserting correctness. Tests would pass even if EBR was broken.

**Fix:** Added concrete assertions:
- `test_basic`: asserts node 1 is NOT reclaimed initially, then IS reclaimed after epoch advances
- `test_epoch_advancement`: asserts nodes 10, 20 are in `!reclaimed` after epoch cycles, and `n >= 2`
- `test_multi_domain_protection`: asserts the node is NOT reclaimed while domain 1 holds a critical section

### 11.6 DSCheck Tests: New Files

**Added `dscheck_pool.ml`** (4 tests):
1. Concurrent push — no value loss
2. Concurrent pop — no duplicates
3. Push-pop-push — ABA scenario (safe due to GC freshness)
4. Pool ownership with node recycling — double-allocation detection

**Added `dscheck_ms_queue.ml`** (4 tests):
1. Concurrent enqueue — all items present
2. Concurrent dequeue — no duplicates
3. Mixed enq/deq — FIFO consistency
4. Helping mechanism — tail-lagging path coverage

### 11.7 DSCheck: GC-vs-Recycling Divergence

**Key insight documented in dscheck tests:** The dscheck tests use GC-allocated nodes (fresh `{ value; next }` per push/enqueue). OCaml's GC guarantees unique addresses, so ABA is structurally impossible. The real `Lockfree_pool` pre-allocates and recycles nodes — same physical address can reappear — making HP/EBR mandatory. dscheck proves the *algorithm* is linearizable; HP/EBR prove the *implementation* is ABA-safe.

### 11.8 FIFO Strictness in DSCheck MS Queue

**User improvement:** Tightened Test 3 assertion from `dequeued = 1 || dequeued = 2` to `dequeued = 1`, and Test 4 from `dequeued = 42 || dequeued = 99` to `dequeued = 42`. Since item 1 (or 42) was enqueued before the concurrent operations begin, FIFO ordering guarantees it must be dequeued first. dscheck confirms this across all interleavings.

---

## 12. Reflection on the Use of LLMs {#12-llm-reflection}

### Tools Used

This project used **Gemini (Antigravity)** as an AI coding assistant, operating in a pair-programming mode. The LLM had access to the full workspace, could read/write files, run terminal commands (with approval), and execute tests. It was used throughout the implementation, testing, and documentation phases.

### What Worked Well

The LLM excelled at **boilerplate generation and API scaffolding**. Creating `.mli` interface files, `dune` build configurations, and test harnesses was fast and accurate. It also performed well at **translating algorithmic descriptions into OCaml code** — given a description of Hazard Pointers from Michael's 2004 paper, it produced a working implementation with the correct global-array registry pattern on the first attempt. The iterative workflow — implement, test, observe failure, diagnose, fix — was highly productive.

### What Didn't Work

The LLM initially struggled with **OCaml 5-specific features** like `[@atomic]` field annotations and `[%atomic.loc]` PPX syntax. Early attempts used `Atomic.t` fields instead of `[@atomic]` mutable fields, which required significant rework. It also produced an EBR pool STM test with **overly permissive postconditions** (`true (* accept either *)`) that masked potential bugs — a flaw that was only caught during manual audit. The lesson: LLM-generated tests require the same scrutiny as LLM-generated implementations.

### What Was Surprising

The most surprising discovery was OCaml's **`option` boxing behavior** preventing ABA in GC-allocated stacks. The LLM initially generated ABA demonstrations using `'a node option Atomic.t`, which never triggered ABA because each `Some` wrapper is a fresh heap allocation. Understanding this required deep reasoning about OCaml's memory model — the LLM provided the diagnosis after multiple failed attempts, correctly identifying the root cause as address identity vs. structural equality in `compare_and_set`.

### What Was Difficult

The hardest challenges involved **interactions between multiple concurrent systems**: EBR epoch advancement, domain DLS lifecycle, and QCheck test framework's domain spawning strategy. The `QCheck-Lin` domain exhaustion bug (§13 in EXPLANATION_DESIGN.md) required understanding three interacting components: DLS key initialization semantics, `Lin_domain`'s internal domain spawning, and EBR's slot allocation. The `max_domains` sizing problem (128 → 4096 → 512) also required iterative experimentation to find the right balance between correctness headroom and scan performance.

### Overall Assessment

The LLM was an effective **accelerator** for this project, reducing implementation time by an estimated 60–70%. However, it was not a replacement for human understanding. Every audit-discovered flaw (weak postconditions, missing assertions, documentation gaps) was found through careful manual review, not by the LLM self-checking its own output. The most productive workflow was: **LLM generates, human audits, LLM fixes, human verifies**. The LLM's strongest contribution was in exploring the solution space quickly; the human's strongest contribution was in identifying when the solution was subtly wrong.

---

## 13. Conclusions {#13-conclusions}

### Answering the Research Question

> **What is the throughput cost of hazard pointer scanning vs. epoch-based reclamation for protecting a lock-free pool, and how does each scheme's latency profile differ?**

**Throughput cost.** HP imposes a 2.3–2.5× throughput penalty vs. the unprotected pool (653K→263K at 2T, 193K→83K at 8T). EBR imposes only a 1.5–2.4× penalty (653K→272K at 2T) and **scales flat** — maintaining ~280K ops/sec regardless of thread count. The throughput gap widens with more threads because HP's `scan` is O(domains × slots_per_domain) work per invocation, while EBR's `enter`/`exit` is O(1) with epoch advancement amortized.

**Latency profiles.** The two schemes have fundamentally different memory reclamation guarantees:

- **HP has bounded garbage.** At any given moment, at most `N × R` nodes are unreclaimed (N = domains, R = retire threshold). Once a domain calls `scan`, every unprotected node is immediately freed. This gives HP **deterministic worst-case memory** — garbage is bounded even if one domain stalls.

- **EBR can delay reclamation under stalled threads.** If one domain enters a critical section and stalls (e.g., preempted by the OS), the global epoch cannot advance. ALL retired nodes from ALL domains remain in limbo until the stalled domain exits. This gives EBR **unbounded worst-case memory** in pathological cases. Our `test_multi_domain_protection` in `test_ebr.ml` directly verifies this: domain 1 holds a critical section, domain 2 retires — the node stays in limbo until domain 1 exits.

**Recommendation.** For OCaml 5 workloads with predictable domain lifetimes (no long-running critical sections), EBR is the clear winner — 1.5× better throughput than HP with simpler API (`enter`/`exit` vs. load-publish-verify). For workloads where domains may stall unpredictably, HP provides stronger memory-boundedness guarantees at the cost of throughput.

### Limitations

1. **Fixed `max_domains`**: The global array requires pre-specifying the maximum number of domains. Dynamic expansion is not implemented.
2. **DSCheck gap**: dscheck tests the algorithm (GC-allocated nodes), not the exact production code (`[@atomic]` fields). The GC-vs-recycling divergence means ABA is not tested in dscheck.
3. **No formal proof**: Verification is empirical (testing + model checking), not a formal proof of linearizability. dscheck explores all interleavings for small configurations, but doesn't scale to large state spaces.
4. **`Obj.magic` usage**: Both `Lockfree_pool.create` and `Ebr.force_flush` use `Obj.magic ()` for placeholder values. This is safe in practice but technically breaks type safety.

### Future Work

1. **Dynamic array expansion**: Implement lock-free growth of the HP/EBR registry when `max_domains` is exceeded.
2. **HP-based MS Queue**: Implement `Ms_queue_hp` to compare HP vs EBR for queue workloads (expected: HP has higher per-operation cost but lower worst-case memory).
3. **Formal verification**: Use Iris (separation logic framework) to produce a machine-checked proof of the HP and EBR implementations.
4. **Benchmark latency**: Current benchmarks measure throughput. Tail latency (p99, p999) would reveal GC pause effects that motivate pool-based reclamation.
5. **Integration with real workloads**: Apply HP/EBR to a concurrent hash map or skip list to evaluate performance in more complex scenarios.

---

## 14. Contributions {#14-contributions}

| Team Member | Contribution | Percentage |
|-------------|-------------|:----------:|
| Vishnu Surla (CS25M050) | Full implementation of HP, Lockfree Pool, HP Pool | 30% |
| Ramya Sinigi (CS25M049) | Full implementation of EBR, EBR Pool, MS Queue EBR | 30% |
| Team (CS25M049 and CS25M050) | All testing (unit, QCheck-STM, QCheck-Lin, DSCheck, TSAN, stress). Benchmarking. Documentation. Code audits and fixes. | 40% |


---

## 15. References {#15-references}

1. M. M. Michael, "Hazard Pointers: Safe Memory Reclamation for Lock-Free Objects," *IEEE Transactions on Parallel and Distributed Systems*, vol. 15, no. 6, pp. 491–504, June 2004.

2. K. Fraser, "Practical Lock-Freedom," Ph.D. dissertation, University of Cambridge, 2004, Chapter 5 (Epoch-Based Reclamation).

3. M. Herlihy and N. Shavit, *The Art of Multiprocessor Programming*, 2nd ed., Morgan Kaufmann, 2020, Chapter 10, Section 10.6 (Memory Reclamation and the ABA Problem).

4. M. M. Michael and M. L. Scott, "Simple, Fast, and Practical Non-Blocking and Blocking Concurrent Queue Algorithms," *Proceedings of the 15th ACM Symposium on Principles of Distributed Computing (PODC)*, pp. 267–275, 1996.

5. R. K. Treiber, "Systems Programming: Coping with Parallelism," IBM Research Report RJ 5118, April 1986 (Treiber Stack).

6. OCaml 5 Multicore Documentation, https://v2.ocaml.org/manual/parallelism.html

7. `multicoretests` — QCheck-STM and QCheck-Lin frameworks for OCaml 5, https://github.com/ocaml-multicore/multicoretests

8. `dscheck` — Deterministic concurrency testing for OCaml, https://github.com/ocaml-multicore/dscheck

9. ThreadSanitizer (TSAN) for OCaml 5, https://github.com/ocaml/ocaml/pull/12114

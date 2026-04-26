# Design Decisions & Bugs — Detailed Explanation

This document explains every design decision made in this project, why alternatives were rejected, and the bugs we discovered and fixed during development.

---

## Table of Contents

1. [Pool Type Exposure: Concrete vs Abstract](#1-pool-type-exposure)
2. [HP Registry: Global Array vs Linked List](#2-hp-registry)
3. [EBR Record Storage: Global Array vs DLS](#3-ebr-record-storage)
4. [EBR Active Counter: int vs bool](#4-ebr-active-counter)
5. [EBR enter Ordering](#5-ebr-enter-ordering)
6. [EBR Pool free: No enter/exit](#6-ebr-pool-free)
7. [Physical vs Structural Equality](#7-physical-vs-structural-equality)
8. [MS Queue: Internal Free List vs Lockfree_pool](#8-ms-queue-free-list)
9. [MS Queue: GC Fallback](#9-ms-queue-gc-fallback)
10. [ABA Demo: Sentinel vs Option](#10-aba-demo-sentinel)
11. [Bug: Domain Registration Race](#11-bug-domain-registration)
12. [Bug: OCaml option Boxing](#12-bug-option-boxing)
13. [Bug: QCheck-Lin Domain Exhaustion](#13-bug-qcheck-lin)

---

## 1. Pool Type Exposure: Concrete vs Abstract {#1-pool-type-exposure}

### The Decision

In `lockfree_pool.mli`, we **export the concrete type definitions** instead of making them abstract:

```ocaml
(* What we did — concrete types visible *)
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]
}

type 'a t = {
  mutable top : 'a node option; [@atomic]
  cap : int;
}
```

### Why Not Abstract Types?

The normal OCaml practice is to hide implementation details:
```ocaml
(* What we'd normally do *)
type 'a node    (* abstract *)
type 'a t       (* abstract *)
```

But `Hp_pool` and `Ebr_pool` need to **directly CAS on the pool's internal fields**. For example, in `hp_pool.ml`:

```ocaml
let alloc t v =
  let top = AL.get [%atomic.loc t.pool.top] in        (* Access pool.top *)
  ...
  let next = AL.get [%atomic.loc node.next] in         (* Access node.next *)
  if AL.compare_and_set [%atomic.loc t.pool.top] ...   (* CAS on pool.top *)
```

The `[%atomic.loc t.pool.top]` syntax requires that `top` is a visible `[@atomic]` mutable field. If `t` were abstract, this wouldn't compile — you can't access fields of abstract types.

### Alternatives Considered

1. **Put HP/EBR logic inside lockfree_pool.ml**: Rejected because it would create a monolithic module mixing concerns. The pool should be a simple, generic free list.

2. **Use accessor functions returning `Atomic.Loc.t`**: OCaml 5's `Atomic.Loc` isn't easily returned from functions — `[%atomic.loc]` is a PPX that operates on field access syntax.

3. **Use functors**: Overly complex for this use case. The pool is a single implementation, not a family of implementations.

### Trade-off

We sacrifice encapsulation for composability. The concrete types let HP and EBR wrappers implement their own CAS-based logic around the pool's internals. The `.mli` includes a `WARNING` comment noting the ABA vulnerability.

---

## 2. HP Registry: Global Array vs Linked List {#2-hp-registry}

### The Problem

Hazard Pointer scanning requires reading HP slots from **ALL domains**, not just the current one. But OCaml 5's `Domain.DLS` only allows a domain to access its own local storage.

### What the Textbook Says

Michael's original paper uses a lock-free linked list of per-thread HP records. Each thread appends its record to the list on first use. During scanning, you traverse the list and read all records.

### Why That Doesn't Work in OCaml 5

If HP records are stored in DLS:
```ocaml
(* WRONG approach *)
type 'a t = {
  domain_key : 'a hp_record Domain.DLS.key;
}

let scan t =
  (* How do we read OTHER domains' DLS entries?? *)
  (* Domain.DLS.get only works for the CURRENT domain! *)
  ???
```

A lock-free linked list of DLS keys doesn't help — you still can't dereference another domain's DLS key.

### Our Solution

Pre-allocate a **global flat array** of HP slots, indexed by domain ID:

```ocaml
type 'a t = {
  slots : 'a option Atomic.t array;    (* GLOBAL — accessible by all *)
  ...
  domain_key : 'a domain_record Domain.DLS.key;
}
```

DLS only stores the domain's **record** (containing `domain_id` and `base_idx`). The actual slots array is a field of `t`, accessible from any domain:

```
slots:  [D0_slot0] [D0_slot1] [D1_slot0] [D1_slot1] [D2_slot0] [D2_slot1] ...
         ←— Domain 0 —→      ←— Domain 1 —→      ←— Domain 2 —→

base_idx for domain i = i × hp_per_domain
```

Scanning just iterates the array:
```ocaml
let collect_protected t =
  let n = (Atomic.get t.num_domains) * t.hp_per_domain in
  for i = 0 to n - 1 do
    match Atomic.get t.slots.(i) with
    | Some ptr -> (* protected! *)
    | None -> ()
  done
```

### Trade-off

Must specify `max_domains` at creation time. The array size is fixed. In practice this is fine — you know your thread count at startup.

---

## 3. EBR Record Storage: Global Array vs DLS {#3-ebr-record-storage}

### The Same Problem

Like HP, EBR needs to read other domains' `local_epoch` and `active_count` during `try_advance_epoch`.

### Our Solution

Same pattern as HP: global array of records, DLS stores only the index:

```ocaml
type 'a t = {
  records : 'a domain_record array;   (* GLOBAL *)
  domain_key : int Domain.DLS.key;    (* DLS stores index only *)
}

let get_record t =
  let id = Domain.DLS.get t.domain_key in
  t.records.(id)    (* Index into global array *)
```

The fields `local_epoch` and `active_count` within each record are `Atomic.t` values, so they're safe to read from any domain.

---

## 4. EBR Active Counter: int vs bool {#4-ebr-active-counter}

### The Problem

EBR needs to know if a domain is "active" (inside a critical section). A boolean `is_active` flag seems natural.

### Why `int`?

Consider nested enter/exit:
```ocaml
let transfer q1 q2 =
  Ebr.enter ebr;
  let x = deq q1 in   (* internally: enter, read, exit *)
  enq q2 x;            (* internally: enter, write, exit *)
  Ebr.exit ebr;
```

With a boolean:
```
enter (outer):  is_active = true     ← correct
enter (inner):  is_active = true     ← no change, OK
exit (inner):   is_active = false    ← WRONG! Outer is still active!
exit (outer):   is_active = false    ← too late, damage done
```

The inner `exit` sets `is_active = false`, making the epoch advancer think this domain is inactive. It could advance the epoch and free nodes that the outer critical section still references.

With an integer counter:
```
enter (outer):  active_count = 1     ← active
enter (inner):  active_count = 2     ← still active
exit (inner):   active_count = 1     ← still active (count > 0)
exit (outer):   active_count = 0     ← now truly inactive
```

Only the outermost `exit` brings the count to 0.

### Implementation

```ocaml
let enter t =
  let r = get_record t in
  ...
  ignore (Atomic.fetch_and_add r.active_count 1);

let exit t =
  let r = get_record t in
  ignore (Atomic.fetch_and_add r.active_count (-1))
```

In `try_advance_epoch`, we check `active_count > 0`:
```ocaml
if Atomic.get r.active_count > 0 then begin
  if Atomic.get r.local_epoch < e then
    all_caught_up := false
end
```

Domains with `active_count = 0` are ignored — they're not holding any references.

---

## 5. EBR `enter` Ordering {#5-ebr-enter-ordering}

### The Critical Question

In `enter`, we must: (a) read global epoch, (b) set local_epoch, (c) increment active_count. What order?

### Wrong Order: Active First

```ocaml
(* WRONG *)
let enter t =
  let r = get_record t in
  ignore (Atomic.fetch_and_add r.active_count 1);  (* 1. Become active *)
  let e = Atomic.get t.global_epoch in              (* 2. Read epoch *)
  Atomic.set r.local_epoch e;                       (* 3. Publish *)
```

**Race scenario:**
1. Domain D enters, increments active_count to 1
2. Before D reads global_epoch, the advancer runs
3. Advancer sees D is active with `local_epoch = 0` (stale default)
4. `local_epoch (0) < global_epoch (5)` → advancer thinks D is behind
5. Epoch NEVER advances because D appears perpetually behind
6. **Livelock!** No nodes ever get freed

### Correct Order: Epoch First

```ocaml
(* CORRECT — what we implement *)
let enter t =
  let r = get_record t in
  let e = Atomic.get t.global_epoch in              (* 1. Read epoch *)
  Atomic.set r.local_epoch e;                       (* 2. Publish *)
  ignore (Atomic.fetch_and_add r.active_count 1);   (* 3. Become active *)
```

Now when the advancer sees D as active, `local_epoch` is already up-to-date. The advancer correctly sees D has caught up and can advance the epoch.

---

## 6. EBR Pool `free`: No `enter`/`exit` {#6-ebr-pool-free}

### The Question

Should `Ebr_pool.free` wrap the retire call in `enter`/`exit`?

```ocaml
(* Option A: with enter/exit *)
let free t node =
  Ebr.enter t.ebr;
  Ebr.retire t.ebr node (fun n -> push_to_pool t.pool n);
  Ebr.exit t.ebr

(* Option B: without — what we chose *)
let free t node =
  Ebr.retire t.ebr node (fun n -> push_to_pool t.pool n)
```

### Why Option B?

When calling `free(node)`, the caller is **done using the node**. There's nothing to protect — the caller doesn't read the node's value or follow its next pointer. The `retire` call just adds the node to the limbo list (a simple list append) — no shared data structure traversal that needs protection.

Wrapping in `enter`/`exit` would be wasteful:
- Extra atomic operations (fetch_and_add on active_count)
- Delays epoch advancement (domain appears "active" longer)
- Semantically misleading (implies the domain is accessing shared state)

### When IS `enter`/`exit` Needed?

In `alloc`: we read `pool.top` and follow `node.next` pointers. These nodes could be concurrently retired. We need protection during this traversal:

```ocaml
let alloc t v =
  Ebr.enter t.ebr;            (* Protect node access *)
  let top = ... t.pool.top in
  let next = ... node.next in  (* node could be retired without protection! *)
  ...
  Ebr.exit t.ebr;
```

---

## 7. Physical vs Structural Equality {#7-physical-vs-structural-equality}

### The Problem

When HP scans for protected nodes, it compares retired nodes against the protected set. Which equality?

```ocaml
(* Physical equality: same object in memory? *)
List.exists (fun p -> p == rn.node) protected

(* Structural equality: same value? *)
List.exists (fun p -> p = rn.node) protected
```

### Why Physical (`==`)

Consider two nodes with the same value:
```
Node X at address 0x100, value = 42
Node Y at address 0x200, value = 42
```

With structural equality (`=`), `X = Y` is true. If domain D protects node X, and we retire node Y, scan would see `Y = X` → true → "Y is protected" → don't reclaim Y. **False positive!** Y should be reclaimable.

With physical equality (`==`), `X == Y` is false (different addresses). Correctly identified as different objects.

For reclamation, we need **identity** (is this the exact same object?), not **equivalence** (do they look the same?). Physical equality gives us identity.

---

## 8. MS Queue: Internal Free List vs `Lockfree_pool` {#8-ms-queue-free-list}

### The Problem

The queue needs node recycling. Should it use `Lockfree_pool`?

### Why Not

`Lockfree_pool` nodes have type:
```ocaml
type 'a node = { mutable value : 'a; mutable next : 'a node option; [@atomic] }
```

Queue nodes need:
```ocaml
type 'a node = { mutable value : 'a; mutable next : 'a node option; [@atomic] }
```

They look identical! But they're **different types** in OCaml's type system. `Lockfree_pool.node` and the queue's `node` are incompatible — OCaml uses nominal typing, not structural typing. You can't CAS a `Lockfree_pool.node` where a queue `node` is expected.

### Workarounds Considered

1. **Wrap queue nodes inside pool nodes**: Each pool node stores a queue node as its value. But then CAS on `queue_node.next` requires unwrapping through the pool node — adds indirection and complexity.

2. **Make Lockfree_pool generic over node type (functors)**: Over-engineered for this use case.

3. **Internal free list**: Simple lock-free stack within the queue. ~15 lines. Clean and self-contained.

We chose option 3.

---

## 9. MS Queue: GC Fallback {#9-ms-queue-gc-fallback}

### The Problem

When the internal free list is empty (all nodes are in the queue or in EBR limbo), what does `enq` do?

### Option A: Block Until Available

```ocaml
let alloc_node t v =
  let rec loop () =
    match pop_free_list t with
    | Some node -> node
    | None -> Domain.cpu_relax (); loop ()  (* spin-wait *)
  in loop ()
```

**Dangerous!** If all nodes are in the queue and no consumer is running, this spins forever. **Deadlock!**

### Option B: GC Fallback (What We Chose)

```ocaml
let alloc_node t v =
  match pop_free_list t with
  | Some node -> node.value <- v; node
  | None -> { value = v; next = None }  (* Fresh GC allocation *)
```

If the free list is empty, allocate a fresh node via OCaml's GC. This node can later be retired and recycled into the free list. The GC handles its lifetime until then.

**Trade-off:** Occasional GC pressure vs. guaranteed progress. Since OCaml's GC is very fast (as our benchmarks show), this is an excellent trade-off.

---

## 10. ABA Demo: Sentinel vs Option {#10-aba-demo-sentinel}

### The Discovery

Our first ABA demo attempt used `option`-wrapped atomics:
```ocaml
let top : node option Atomic.t = Atomic.make (Some node_a)
```

**ABA never triggered!** After investigation, we discovered why:

Each `Some node_a` is a **fresh heap allocation** in OCaml. Even though `node_a` is the same object, wrapping it in `Some` creates a new box:

```
First push:   Some(node_a) at address 0x100
After pop+push: Some(node_a) at address 0x200  ← DIFFERENT address!

CAS checks: 0x100 == 0x200 → false → ABA prevented!
```

OCaml's `option` boxing acts as an accidental version counter — each wrapping is like incrementing a version stamp.

### The Fix

Use **direct node pointers** with a sentinel node (avoiding `option`):

```ocaml
type node = { id : int; next : node Atomic.t }  (* No option! *)
let sentinel = { id = 0; next = ... }           (* Replaces None *)
let top = Atomic.make node_a                    (* Direct pointer *)
```

Now CAS compares the node address directly:
```
Push A:     top = node_a at 0x300
Pop A, push A: top = node_a at 0x300  ← SAME address!

CAS checks: 0x300 == 0x300 → true → ABA triggered!
```

### Implication

In normal OCaml code using `option`-wrapped atomics, ABA is **less likely** due to boxing. But it's not a guarantee — the GC could reuse the same address for a new `Some` allocation. For correctness, explicit HP or EBR protection is still required.

---

## 11. Bug: Domain Registration Race {#11-bug-domain-registration}

### How We Found It

QCheck-Lin tests crashed with `Invalid_argument("index out of bounds")` — an array access violation in `collect_protected`.

### Root Cause

The DLS initializer used `fetch_and_add` followed by a bounds check:

```ocaml
(* BUGGY version *)
let domain_key = Domain.DLS.new_key (fun () ->
  let id = Atomic.fetch_and_add num_domains 1 in  (* Increments FIRST *)
  if id >= max_domains then
    failwith "too many domains";  (* num_domains is already inflated! *)
  ...
)
```

The `fetch_and_add` atomically increments `num_domains` **before** checking if `id` is valid. If the check fails:
- `num_domains` is now `max_domains + 1` (inflated)
- The exception unwinds the stack
- But `num_domains` stays inflated!

Meanwhile, a concurrent `collect_protected` reads:
```ocaml
let n = Atomic.get t.num_domains * t.hp_per_domain in
(* n = (max_domains + 1) × 2 = array_length + 2 *)
for i = 0 to n - 1 do
  t.slots.(i)  (* INDEX OUT OF BOUNDS when i >= array_length! *)
```

### The Fix

Two-part fix:

```ocaml
(* 1. Rollback on failure *)
let id = Atomic.fetch_and_add num_domains 1 in
if id >= max_domains then begin
  ignore (Atomic.fetch_and_add num_domains (-1));  (* UNDO the increment *)
  failwith "too many domains"
end;

(* 2. Cap scan range *)
let collect_protected t =
  let nd = min (Atomic.get t.num_domains) t.max_domains in  (* CAPPED *)
  let n = nd * t.hp_per_domain in
```

The cap provides defense-in-depth: even if `num_domains` is momentarily inflated (between the increment and the rollback), the scan range never exceeds the array size.

---

## 12. Bug: OCaml `option` Boxing {#12-bug-option-boxing}

Described in section 10 above. This was a conceptual bug — our understanding of OCaml's `option` semantics was wrong. We thought CAS would compare the `node` inside `Some`, but it compares the `Some` wrapper's address.

**Lesson:** Always verify your assumptions about equality semantics, especially in a language with GC-managed heap allocation.

---

## 13. Bug: QCheck-Lin Domain Exhaustion {#13-bug-qcheck-lin}

### The Problem

QCheck-Lin tests with `count=50` would either crash with "too many domains" or time out.

### Root Cause

`Lin_domain.Make` spawns **2 fresh OCaml domains per test repetition**. By default, each test has **300 repetitions**. So 50 tests × 300 reps × 2 domains = **30,000 domain creations**.

Each domain calls `init_domain`, which does `fetch_and_add` on `num_domains` — permanently consuming an EBR/HP slot. With `max_domains:4096`, we hit the limit after only ~2,000 domain creations.

### Why Domains Can't Be Reused

OCaml 5's DLS is initialized lazily per domain. When a domain terminates and a new one is spawned, it gets a **fresh DLS** — the old domain's DLS is gone. So `init_domain` runs again, consuming another slot.

### Solutions Applied

1. **Shared instance**: Create the data structure once at module load time, not per test
2. **Large `max_domains`**: Use 8192 to accommodate thousands of domain spawns
3. **Reduced count**: Use `count:5` for Lin tests (still meaningful with 300 reps each)
4. **STM for pools**: Pools use QCheck-STM (no domain spawning) instead of Lin
5. **Lin only for queue**: The MS Queue's `enq`/`deq` are stateless — ideal for Lin

### Why STM Works Better for Pools

Pool operations are **stateful**: `free` requires a previously-allocated node. Lin generates random command sequences — it doesn't know about this dependency. The `held_key` DLS workaround breaks because each domain has its own held list, so domain A's `free` can't free domain B's nodes.

STM with explicit state tracking handles this naturally — the model tracks which nodes are allocated and generates valid command sequences.

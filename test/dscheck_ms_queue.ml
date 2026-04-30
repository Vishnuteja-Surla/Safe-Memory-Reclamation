(** DSCheck model checking for a Michael-Scott Queue.

    Re-implements a minimal MS Queue using TracedAtomic to let dscheck
    explore all interleavings systematically.

    {b Architecture of the real [Ms_queue_ebr] vs this test:}

    1. {b Node recycling.} The production queue maintains an internal
       Treiber stack ([free_list]) for node recycling. Dequeued nodes are
       retired via EBR; after epoch advancement, EBR calls [recycle_node]
       which pushes the physical memory block back onto [free_list].
       [enq] pops from [free_list] instead of calling the GC.
       This test uses fresh GC allocations per [enq], so the same
       GC-vs-recycling divergence as the pool tests applies — ABA
       cannot occur here because every node is a fresh address.

    2. {b Sentinel node.} Both versions use a sentinel (dummy) node.
       The queue never becomes truly empty — [head] always points to a
       sentinel. On dequeue, the sentinel advances: [head] swings to
       [first.next], which becomes the new sentinel. The old sentinel
       is retired via EBR in production, or GC'd here.

    3. {b Helping mechanism.} The lock-freedom guarantee comes from
       "helping." Enqueue is a two-step operation:
         (a) CAS [last.next = None → Some new_node]  — link the node
         (b) CAS [q.tail = last → new_node]          — advance the tail
       If Thread A completes (a) but stalls before (b), Thread B detects
       the lagging tail ([last.next <> None]) and finishes A's work by
       CAS-advancing [q.tail]. This ensures global progress — at least
       one thread always makes forward progress (lock-freedom).

    Tests:
    1. Concurrent enqueues — all items present, no loss
    2. Concurrent dequeues — no duplicate returns
    3. Mixed enqueue/dequeue — FIFO consistency + no item loss
    4. Helping mechanism — tail-lagging scenario verified *)

module Atomic = Dscheck.TracedAtomic

(** {2 Minimal Michael-Scott Queue using TracedAtomic}

    Faithfully implements the MS Queue algorithm:
    - Sentinel-based: head always points to a dummy node
    - Two-phase enqueue with helping
    - Dequeue swings head forward, old sentinel becomes garbage

    Uses GC allocation (not recycling), so ABA is structurally impossible. *)
module Queue = struct
  type 'a node = {
    value : 'a;
    next : 'a node option Atomic.t;
  }

  type 'a t = {
    head : 'a node Atomic.t;
    tail : 'a node Atomic.t;
  }

  (** Create with a sentinel node. The sentinel's [value] is unused
      ([Obj.magic]). Both [head] and [tail] point to it initially. *)
  let create () =
    let sentinel = { value = Obj.magic (); next = Atomic.make None } in
    { head = Atomic.make sentinel; tail = Atomic.make sentinel }

  (** Enqueue: two-phase CAS with helping.

      Phase 1: CAS [last.next = None → Some node] — links the new node.
      Phase 2: CAS [q.tail = last → node] — advances the tail pointer.

      If Phase 1 succeeds but the thread stalls, another thread will
      detect [last.next <> None] and help by advancing the tail.
      This is the "helping" mechanism that guarantees lock-freedom. *)
  let enq q x =
    (* Fresh GC allocation — new address every time, no ABA *)
    let node = { value = x; next = Atomic.make None } in
    let rec loop () =
      let last = Atomic.get q.tail in
      let next = Atomic.get last.next in
      (* Consistency check: is tail still what we read? *)
      if last == Atomic.get q.tail then
        match next with
        | None ->
          (* Tail is at the true end — try to link our node *)
          if Atomic.compare_and_set last.next None (Some node) then
            (* Phase 1 succeeded. Try Phase 2 (best-effort). *)
            ignore (Atomic.compare_and_set q.tail last node)
          else loop ()
        | Some next_node ->
          (* Tail is lagging! Another thread completed Phase 1 but
             not Phase 2. HELP by advancing the tail for them. *)
          ignore (Atomic.compare_and_set q.tail last next_node);
          loop ()
      else loop ()
    in loop ()

  (** Dequeue: swing head forward, return the value from head.next.

      The current sentinel ([first]) is replaced by [first.next] as
      the new sentinel. The dequeued value comes from [next_node.value].
      In production, the old sentinel is retired via EBR. *)
  let try_deq q =
    let rec loop () =
      let first = Atomic.get q.head in
      let last = Atomic.get q.tail in
      let next = Atomic.get first.next in
      (* Consistency check *)
      if first == Atomic.get q.head then
        match next with
        | None -> None  (* Queue is empty: sentinel.next = None *)
        | Some next_node ->
          if first == last then begin
            (* Head caught up to tail — tail might be lagging. Help. *)
            ignore (Atomic.compare_and_set q.tail last next_node);
            loop ()
          end else begin
            let value = next_node.value in
            (* Swing head forward: next_node becomes new sentinel *)
            if Atomic.compare_and_set q.head first next_node then
              Some value
            else loop ()
          end
      else loop ()
    in loop ()
end

(** Test 1: Two concurrent enqueues — both values present.

    dscheck explores all interleavings of the two-phase enqueue.
    This includes the case where Thread A links its node (Phase 1)
    but Thread B helps advance the tail before A does. *)
let test_concurrent_enq () =
  Atomic.trace (fun () ->
    let q = Queue.create () in
    Atomic.spawn (fun () -> Queue.enq q 1);
    Atomic.spawn (fun () -> Queue.enq q 2);
    Atomic.final (fun () ->
      let v1 = Queue.try_deq q in
      let v2 = Queue.try_deq q in
      let v3 = Queue.try_deq q in
      let vals = List.filter_map Fun.id [v1; v2] in
      assert (List.length vals = 2);
      assert (List.mem 1 vals);
      assert (List.mem 2 vals);
      assert (v3 = None)
    )
  )

(** Test 2: Two concurrent dequeues — no duplicates.

    With 2 items in the queue, both threads should get different items.
    dscheck verifies this across all possible CAS orderings. *)
let test_concurrent_deq () =
  Atomic.trace (fun () ->
    let q = Queue.create () in
    Queue.enq q 1;
    Queue.enq q 2;
    let r1 = Atomic.make 0 in
    let r2 = Atomic.make 0 in
    Atomic.spawn (fun () ->
      match Queue.try_deq q with
      | Some v -> Atomic.set r1 v
      | None -> Atomic.set r1 (-1)
    );
    Atomic.spawn (fun () ->
      match Queue.try_deq q with
      | Some v -> Atomic.set r2 v
      | None -> Atomic.set r2 (-1)
    );
    Atomic.final (fun () ->
      let v1 = Atomic.get r1 in
      let v2 = Atomic.get r2 in
      if v1 > 0 && v2 > 0 then
        assert (v1 <> v2)  (* No duplicate *)
    )
  )

(** Test 3: Enqueue and dequeue concurrently — FIFO + no loss.

    Pre-enqueue item 1. Concurrently: Thread A enqueues 2,
    Thread B dequeues. Possible outcomes:
    - B dequeues 1 (before A's enqueue is visible): queue has [2]
    - B dequeues 1 (after A's enqueue): queue has [2]
    - B dequeues 2 (after A's enqueue, 1 already dequeued): impossible
      because FIFO means 1 must come out first

    In all cases, total items (dequeued + remaining) = 2. *)
let test_enq_deq () =
  Atomic.trace (fun () ->
    let q = Queue.create () in
    Queue.enq q 1;
    let r1 = Atomic.make 0 in
    Atomic.spawn (fun () -> Queue.enq q 2);
    Atomic.spawn (fun () ->
      match Queue.try_deq q with
      | Some v -> Atomic.set r1 v
      | None -> Atomic.set r1 (-1)
    );
    Atomic.final (fun () ->
      let dequeued = Atomic.get r1 in
      (* If dequeued something, it must be 1 or 2 *)
      if dequeued > 0 then
        assert (dequeued = 1);
      (* Remaining in queue *)
      let remaining = ref [] in
      let rec drain () = match Queue.try_deq q with
        | Some v -> remaining := v :: !remaining; drain ()
        | None -> ()
      in drain ();
      (* Total items: dequeued + remaining = 2 *)
      let total = (if dequeued > 0 then 1 else 0) + List.length !remaining in
      assert (total = 2)
    )
  )

(** Test 4: Helping mechanism — concurrent enqueue + dequeue on
    a single-element queue tests the tail-lagging path.

    When the queue has exactly one real node and [head == tail],
    dequeue must help advance the tail before it can proceed.
    dscheck explores the interleaving where:
    1. Thread A begins [enq], completes Phase 1 (links node)
    2. Thread B calls [try_deq], sees [head == tail] but [next <> None]
    3. Thread B helps advance [tail], then retries the dequeue

    This tests the critical "helping" code path. *)
let test_helping () =
  Atomic.trace (fun () ->
    let q = Queue.create () in
    Queue.enq q 42;
    let r_enq = Atomic.make false in
    let r_deq = Atomic.make 0 in
    Atomic.spawn (fun () ->
      Queue.enq q 99;
      Atomic.set r_enq true
    );
    Atomic.spawn (fun () ->
      match Queue.try_deq q with
      | Some v -> Atomic.set r_deq v
      | None -> Atomic.set r_deq (-1)
    );
    Atomic.final (fun () ->
      let enqueued = Atomic.get r_enq in
      let dequeued = Atomic.get r_deq in
      assert enqueued;
      if dequeued > 0 then
        assert (dequeued = 42);
      (* Drain remaining and verify total *)
      let count = ref (if dequeued > 0 then 1 else 0) in
      let rec drain () = match Queue.try_deq q with
        | Some _ -> incr count; drain ()
        | None -> ()
      in drain ();
      assert (!count = 2)
    )
  )

let () =
  Printf.printf "=== DSCheck Tests: Michael-Scott Queue ===\n\n";

  Printf.printf "Test 1: concurrent enqueue... %!";
  test_concurrent_enq ();
  Printf.printf "PASS\n%!";

  Printf.printf "Test 2: concurrent dequeue... %!";
  test_concurrent_deq ();
  Printf.printf "PASS\n%!";

  Printf.printf "Test 3: concurrent enq+deq... %!";
  test_enq_deq ();
  Printf.printf "PASS\n%!";

  Printf.printf "Test 4: helping mechanism... %!";
  test_helping ();
  Printf.printf "PASS\n%!";

  Printf.printf "\nAll dscheck tests passed!\n"

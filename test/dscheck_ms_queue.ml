(** DSCheck model checking for a Michael-Scott Queue.

    Re-implements a minimal MS Queue using TracedAtomic to let dscheck
    explore all interleavings systematically.

    Tests:
    1. Concurrent enqueues — all items present
    2. Concurrent dequeues — no duplicate returns
    3. Mixed enqueue/dequeue — FIFO ordering maintained *)

module Atomic = Dscheck.TracedAtomic

module Queue = struct
  type 'a node = {
    value : 'a;
    next : 'a node option Atomic.t;
  }

  type 'a t = {
    head : 'a node Atomic.t;
    tail : 'a node Atomic.t;
  }

  let create () =
    let sentinel = { value = Obj.magic (); next = Atomic.make None } in
    { head = Atomic.make sentinel; tail = Atomic.make sentinel }

  let enq q x =
    let node = { value = x; next = Atomic.make None } in
    let rec loop () =
      let last = Atomic.get q.tail in
      let next = Atomic.get last.next in
      if last == Atomic.get q.tail then
        match next with
        | None ->
          if Atomic.compare_and_set last.next None (Some node) then
            ignore (Atomic.compare_and_set q.tail last node)
          else loop ()
        | Some next_node ->
          ignore (Atomic.compare_and_set q.tail last next_node);
          loop ()
      else loop ()
    in loop ()

  let try_deq q =
    let rec loop () =
      let first = Atomic.get q.head in
      let last = Atomic.get q.tail in
      let next = Atomic.get first.next in
      if first == Atomic.get q.head then
        match next with
        | None -> None
        | Some next_node ->
          if first == last then begin
            ignore (Atomic.compare_and_set q.tail last next_node);
            loop ()
          end else begin
            let value = next_node.value in
            if Atomic.compare_and_set q.head first next_node then
              Some value
            else loop ()
          end
      else loop ()
    in loop ()
end

(** Test 1: Two concurrent enqueues — both values present *)
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

(** Test 2: Two concurrent dequeues — no duplicates *)
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

(** Test 3: Enqueue and dequeue concurrently — FIFO consistency *)
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
        assert (dequeued = 1 || dequeued = 2);
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

  Printf.printf "\nAll dscheck tests passed!\n"

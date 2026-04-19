(** ABA Bug Demonstration.

    Demonstrates the ABA problem on a lock-free Treiber stack.

    Key insight: OCaml 5's [Atomic.compare_and_set] uses physical equality
    ([==]). When using [option] types, each [Some x] creates a new heap
    allocation, so CAS naturally detects changes (no ABA). However, when
    storing node references directly (e.g., using a sentinel for "empty"),
    ABA is still possible because the same physical pointer can reappear.

    This demo uses a sentinel node (instead of [None]) so the [top] atomic
    stores node references directly, making ABA observable.

    Scenario:
      Initial:  top → A → B → C → sentinel
      Thread 1: reads top=A, next=B, then PAUSES
      Thread 2: pops A, pops B, pushes A back  →  top → A → C → sentinel
      Thread 1: CAS(top, A, B) SUCCEEDS — but B was already popped!
      Result:   top → B → C → sentinel, but Thread 2 owns B  →  CORRUPTION *)

type node = {
  id : int;
  next : node Atomic.t;
}

(** Sentinel node — marks the bottom of the stack.
    Initialized with a dummy self-reference, then patched. *)
let sentinel : node =
  let s = { id = 0; next = Atomic.make (Obj.magic ()) } in
  Atomic.set s.next s;
  s

let _is_sentinel n = n == sentinel

let mk_node id next = { id; next = Atomic.make next }

(** Spin-wait until [barrier] reaches [value]. *)
let wait_for barrier value =
  while Atomic.get barrier <> value do
    Domain.cpu_relax ()
  done

(** Demonstrate the ABA bug. Returns [true] if triggered. *)
let demo_aba () =
  let barrier1 = Atomic.make 0 in
  let barrier2 = Atomic.make 0 in

  let node_c = mk_node 3 sentinel in
  let node_b = mk_node 2 node_c in
  let node_a = mk_node 1 node_b in
  let top = Atomic.make node_a in

  Printf.printf "Initial: top → A(1) → B(2) → C(3) → sentinel\n%!";

  let aba_detected = Atomic.make false in

  (* Thread 1: reads top=A, next=B, pauses, then CAS *)
  let t1 = Domain.spawn (fun () ->
    let old_top = Atomic.get top in  (* = node_a *)
    let next = Atomic.get old_top.next in  (* = node_b *)
    Printf.printf "[T1] Read top=A(%d), next=B(%d)\n%!" old_top.id next.id;

    Atomic.set barrier1 1;
    wait_for barrier2 1;

    (* CAS: expects top=node_a, wants to set top=node_b.
       After T2's push, top IS node_a (same physical pointer) → CAS succeeds *)
    let cas_ok = Atomic.compare_and_set top old_top next in
    if cas_ok then begin
      Printf.printf "[T1] CAS(top, A, B) = true — ABA BUG TRIGGERED!\n%!";
      Printf.printf "[T1] top is now B(%d), but T2 already owns B!\n%!" next.id;
      Atomic.set aba_detected true
    end else
      Printf.printf "[T1] CAS(top, A, B) = false — ABA prevented\n%!"
  ) in

  (* Thread 2: pop A, pop B, push A back *)
  let t2 = Domain.spawn (fun () ->
    wait_for barrier1 1;

    (* Pop A *)
    let a = Atomic.get top in
    let next_a = Atomic.get a.next in
    ignore (Atomic.compare_and_set top a next_a);
    Printf.printf "[T2] Popped A(%d). Stack: top → B → C\n%!" a.id;

    (* Pop B — T2 now OWNS B *)
    let b = Atomic.get top in
    let next_b = Atomic.get b.next in
    ignore (Atomic.compare_and_set top b next_b);
    Printf.printf "[T2] Popped B(%d). Stack: top → C. T2 OWNS B(%d).\n%!" b.id b.id;

    (* Push A back — ABA! Same physical node_a reappears at top *)
    let cur_top = Atomic.get top in
    Atomic.set a.next cur_top;
    ignore (Atomic.compare_and_set top cur_top a);
    Printf.printf "[T2] Pushed A(%d) back. Stack: top → A → C\n%!" a.id;
    Printf.printf "[T2] ABA ready: top == node_a (same physical pointer)\n%!";

    Atomic.set barrier2 1
  ) in

  Domain.join t1;
  Domain.join t2;
  Atomic.get aba_detected

let () =
  Printf.printf "=== ABA Bug Demonstration ===\n\n%!";

  let triggered = demo_aba () in

  if triggered then begin
    Printf.printf "\n*** ABA BUG CONFIRMED ***\n%!";
    Printf.printf "CAS succeeded because node_a is the same physical pointer,\n%!";
    Printf.printf "even though the stack structure changed underneath.\n%!";
    Printf.printf "Node B is in the stack AND owned by T2 — double use!\n%!";
    Printf.printf "\nHP prevents this: T1's hazard pointer on A blocks T2\n%!";
    Printf.printf "from recycling A, so A can't reappear at top.\n%!";
    Printf.printf "EBR prevents this: A stays in limbo until all domains\n%!";
    Printf.printf "have advanced past the retirement epoch.\n%!"
  end else
    Printf.printf "\n(ABA not triggered in this run — try again)\n%!"

(** ABA Stress Test — Direct Pointers (no option boxing).

    Unlike [stress_aba.ml] which uses [Lockfree_pool] (option-wrapped top),
    this test builds a Treiber stack with direct node pointers and a sentinel.
    Without the [Some] wrapper, CAS sees the SAME physical pointer when a
    node is popped and re-pushed, making ABA observable.

    Three variants:
    1. Unprotected — EXPECTED to show ABA errors.
    2. HP-protected — load-publish-verify prevents ABA.
    3. EBR-protected — epoch critical sections prevent ABA. *)

(* ------------------------------------------------------------------ *)
(* Direct-pointer Treiber stack node (shared by all three variants)    *)
(* ------------------------------------------------------------------ *)

type node = {
  id : int;                  (** Unique slot index *)
  mutable value : int;       (** Payload *)
  next : node Atomic.t;      (** Direct pointer, NO option *)
}

(** Sentinel: self-referencing node that marks bottom of stack. *)
let sentinel : node =
  let s = { id = -1; value = -1; next = Atomic.make (Obj.magic ()) } in
  Atomic.set s.next s; s

let is_sentinel n = (n == sentinel)

let mk_node id v = { id; value = v; next = Atomic.make sentinel }

(* ------------------------------------------------------------------ *)
(* 1. Unprotected direct-pointer stack                                *)
(* ------------------------------------------------------------------ *)

type stack = {
  top : node Atomic.t;
}

let create_stack () = { top = Atomic.make sentinel }

let push s node =
  let rec loop () =
    let old_top = Atomic.get s.top in
    Atomic.set node.next old_top;
    if Atomic.compare_and_set s.top old_top node then ()
    else (Domain.cpu_relax (); loop ())
  in loop ()

let pop s =
  let rec loop () =
    let old_top = Atomic.get s.top in
    if is_sentinel old_top then None
    else
      let next = Atomic.get old_top.next in
      if Atomic.compare_and_set s.top old_top next then Some old_top
      else (Domain.cpu_relax (); loop ())
  in loop ()

(* ------------------------------------------------------------------ *)
(* 2. HP-protected direct-pointer stack                               *)
(* ------------------------------------------------------------------ *)

let pop_hp s (hp : node Hazard_pointer.t) =
  let rec loop () =
    let old_top = Atomic.get s.top in         (* 1. LOAD *)
    if is_sentinel old_top then None
    else begin
      Hazard_pointer.protect hp 0 old_top;    (* 2. PUBLISH *)
      let top2 = Atomic.get s.top in          (* 3. VERIFY *)
      if top2 != old_top then begin
        Hazard_pointer.release hp 0;
        loop ()
      end else begin
        let next = Atomic.get old_top.next in
        if Atomic.compare_and_set s.top old_top next then begin
          Hazard_pointer.release hp 0;
          Some old_top
        end else begin
          Hazard_pointer.release hp 0;
          loop ()
        end
      end
    end
  in loop ()

let free_hp s hp node =
  Hazard_pointer.retire hp node (fun n -> push s n)

(* ------------------------------------------------------------------ *)
(* 3. EBR-protected direct-pointer stack                              *)
(* ------------------------------------------------------------------ *)

let pop_ebr s (ebr : node Ebr.t) =
  Ebr.enter ebr;
  let rec loop () =
    let old_top = Atomic.get s.top in
    if is_sentinel old_top then (Ebr.exit ebr; None)
    else begin
      let next = Atomic.get old_top.next in
      if Atomic.compare_and_set s.top old_top next then
        (Ebr.exit ebr; Some old_top)
      else loop ()
    end
  in loop ()

let free_ebr s ebr node =
  Ebr.retire ebr node (fun n -> push s n)

(* ------------------------------------------------------------------ *)
(* Generic stress test harness                                        *)
(* ------------------------------------------------------------------ *)

let stress_test ~name ~num_domains ~pool_size ~ops_per_domain
    ~alloc ~free ~init ~cleanup =
  Printf.printf "Stress testing %s: %d domains × %d ops, pool=%d\n%!"
    name num_domains ops_per_domain pool_size;

  let ownership = Array.init pool_size (fun _ -> Atomic.make (-1)) in
  let errors = Atomic.make 0 in

  let worker id =
    init id;
    let owned = ref [] in
    let rng = Random.State.make [| id; 42 |] in
    for _ = 1 to ops_per_domain do
      if Random.State.bool rng && List.length !owned < pool_size then begin
        match alloc id with
        | Some node ->
          let slot = node.id in
          let prev = Atomic.exchange ownership.(slot) id in
          if prev >= 0 then
            Atomic.incr errors;
          owned := node :: !owned
        | None -> ()
      end else begin
        match !owned with
        | [] -> ()
        | node :: rest ->
          ignore (Atomic.compare_and_set ownership.(node.id) id (-1));
          owned := rest;
          free node
      end
    done;
    List.iter (fun node ->
      Atomic.set ownership.(node.id) (-1);
      free node
    ) !owned;
    cleanup id
  in

  let t0 = Unix.gettimeofday () in
  let domains = Array.init num_domains (fun id ->
    Domain.spawn (fun () -> worker id)
  ) in
  Array.iter Domain.join domains;
  let elapsed = Unix.gettimeofday () -. t0 in

  let errs = Atomic.get errors in
  Printf.printf "  %s: %.3fs, errors=%d %s\n%!"
    name elapsed errs (if errs = 0 then "✓" else "✗ ABA DETECTED");
  errs

(* ------------------------------------------------------------------ *)
(* Test 1: Unprotected (should show ABA)                              *)
(* ------------------------------------------------------------------ *)

let test_unprotected pool_size =
  let s = create_stack () in
  let nodes = Array.init pool_size (fun i -> mk_node i 0) in
  Array.iter (fun n -> push s n) nodes;

  stress_test ~name:"Unprotected (direct ptr)"
    ~num_domains:8 ~pool_size ~ops_per_domain:50_000
    ~init:(fun _ -> ())
    ~alloc:(fun _id -> match pop s with Some n -> n.value <- 0; Some n | None -> None)
    ~free:(fun n -> push s n)
    ~cleanup:(fun _ -> ())

(* ------------------------------------------------------------------ *)
(* Test 2: HP-protected (should show zero)                            *)
(* ------------------------------------------------------------------ *)

let test_hp pool_size =
  let s = create_stack () in
  let hp = Hazard_pointer.create ~max_domains:16 ~max_hp_per_domain:2
      ~retire_threshold:64 in
  let nodes = Array.init pool_size (fun i -> mk_node i 0) in
  Array.iter (fun n -> push s n) nodes;

  stress_test ~name:"HP-protected (direct ptr)"
    ~num_domains:8 ~pool_size ~ops_per_domain:50_000
    ~init:(fun _ -> Hazard_pointer.init_domain hp)
    ~alloc:(fun _id ->
      match pop_hp s hp with Some n -> n.value <- 0; Some n | None -> None)
    ~free:(fun n -> free_hp s hp n)
    ~cleanup:(fun _ ->
      (* Drain retired list *)
      while Hazard_pointer.retired_count hp > 0 do
        Hazard_pointer.scan hp
      done)

(* ------------------------------------------------------------------ *)
(* Test 3: EBR-protected (should show zero)                           *)
(* ------------------------------------------------------------------ *)

let test_ebr pool_size =
  let s = create_stack () in
  let ebr = Ebr.create ~max_domains:16 in
  let nodes = Array.init pool_size (fun i -> mk_node i 0) in
  Array.iter (fun n -> push s n) nodes;

  stress_test ~name:"EBR-protected (direct ptr)"
    ~num_domains:8 ~pool_size ~ops_per_domain:50_000
    ~init:(fun _ -> Ebr.init_domain ebr)
    ~alloc:(fun _id ->
      match pop_ebr s ebr with Some n -> n.value <- 0; Some n | None -> None)
    ~free:(fun n -> free_ebr s ebr n)
    ~cleanup:(fun _ -> ())

(* ------------------------------------------------------------------ *)
(* Main                                                               *)
(* ------------------------------------------------------------------ *)

let () =
  let pool_size = 8 in
  Printf.printf "=== ABA Stress Test (Direct Pointers — No Option Boxing) ===\n\n%!";

  let e1 = test_unprotected pool_size in
  Printf.printf "\n%!";
  let e2 = test_hp pool_size in
  Printf.printf "\n%!";
  let e3 = test_ebr pool_size in

  Printf.printf "\n--- Summary ---\n%!";
  Printf.printf "Unprotected: %d ABA errors %s\n%!" e1
    (if e1 > 0 then "(expected — ABA confirmed)" else "(got lucky — try again)");
  Printf.printf "HP Pool:     %d ABA errors %s\n%!" e2
    (if e2 = 0 then "✓ (ABA prevented)" else "✗ BUG");
  Printf.printf "EBR Pool:    %d ABA errors %s\n%!" e3
    (if e3 = 0 then "✓ (ABA prevented)" else "✗ BUG")

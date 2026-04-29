(** ABA Stress Test.

    Rapid alloc/free cycles on a small pool with many domains.
    Tracks ownership with an atomic array to detect double-allocation
    (the hallmark of ABA corruption).

    Run against: unprotected pool (may fail), HP pool, EBR pool. *)

(** Test a pool-like alloc/free interface for ABA corruption. *)
let stress_test ~name ~num_domains ~pool_size ~ops_per_domain
    ~alloc ~free ~init =
  Printf.printf "Stress testing %s: %d domains × %d ops, pool=%d\n%!"
    name num_domains ops_per_domain pool_size;

  (* Track which "slots" are owned. Each slot = one pool node.
     We use the node's stored value as a slot index. *)
  let ownership = Array.init pool_size (fun _ -> Atomic.make (-1)) in
  let errors = Atomic.make 0 in

  let worker id =
    init ();
    let owned = ref [] in
    let rng = Random.State.make [| id; 137 |] in
    for _ = 1 to ops_per_domain do
      if Random.State.bool rng && List.length !owned < pool_size then begin
        match alloc id with
        | Some (node, slot_idx) ->
          let prev = Atomic.exchange ownership.(slot_idx) id in
          if prev >= 0 then begin
            Printf.printf "  ABA DETECTED: domain %d got slot %d, but domain %d owns it!\n%!"
              id slot_idx prev;
            Atomic.incr errors
          end;
          owned := (node, slot_idx) :: !owned
        | None -> ()
      end else begin
        match !owned with
        | [] -> ()
        | (node, slot_idx) :: rest ->
          let expected = id in
          let cas_ok = Atomic.compare_and_set ownership.(slot_idx) expected (-1) in
          if not cas_ok then
            Printf.printf "  ABA DETECTED: Domain %d tried to wipe slot %d, but someone else's name is on it!\n%!" id slot_idx;
          owned := rest;
          free node
      end
    done;
    (* Release remaining *)
    List.iter (fun (node, slot_idx) ->
      Atomic.set ownership.(slot_idx) (-1);
      free node
    ) !owned
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

(** Unprotected pool — expected to potentially show ABA. *)
let test_unprotected () =
  let pool_size = 8 in
  let pool = Lockfree_pool.create ~capacity:pool_size in
  (* Pre-alloc and tag each node with a slot index *)
  let slot_nodes = Array.init pool_size (fun _ ->
    match Lockfree_pool.alloc pool 0 with
    | Some n -> n
    | None -> failwith "init alloc failed"
  ) in
  (* Free them all back *)
  Array.iter (fun n -> Lockfree_pool.free pool n) slot_nodes;

  stress_test ~name:"Unprotected Pool"
    ~num_domains:8 ~pool_size ~ops_per_domain:50_000
    ~init:(fun () -> ())
    ~alloc:(fun _id ->
      match Lockfree_pool.alloc pool 0 with
      | Some n ->
        let rec find_idx i =
          if i >= pool_size then failwith "Alien node detected!"
          else if n == slot_nodes.(i) then i
          else find_idx (i + 1)
        in
        let idx = find_idx 0 in        
        Some (n, idx)
      | None -> None)
    ~free:(fun n -> Lockfree_pool.free pool n)

(** HP-protected pool — should show zero ABA errors. *)
let test_hp () =
  let pool_size = 8 in
  let hp = Hp_pool.create ~capacity:pool_size ~max_domains:10 () in
  
  (* Capture the exact physical references *)
  let slot_nodes = Array.init pool_size (fun _ ->
    match Hp_pool.alloc hp 0 with
    | Some n -> n
    | None -> failwith "init alloc failed"
  ) in
  Array.iter (fun n -> Hp_pool.free hp n) slot_nodes;

  stress_test ~name:"HP Pool"
    ~num_domains:8 ~pool_size ~ops_per_domain:50_000
    ~init:(fun () -> Hp_pool.init_domain hp)
    ~alloc:(fun _id ->
      match Hp_pool.alloc hp 0 with
      | Some n ->
        let rec find_idx i =
          if i >= pool_size then failwith "Alien node detected!"
          else if n == slot_nodes.(i) then i
          else find_idx (i + 1)
        in
        let idx = find_idx 0 in
        Some (n, idx)
      | None -> None)
    ~free:(fun n -> Hp_pool.free hp n)

(** EBR-protected pool — should show zero ABA errors. *)
let test_ebr () =
  let pool_size = 8 in
  let ebr = Ebr_pool.create ~capacity:pool_size ~max_domains:10 () in
  
  (* Capture the exact physical references *)
  let slot_nodes = Array.init pool_size (fun _ ->
    match Ebr_pool.alloc ebr 0 with
    | Some n -> n
    | None -> failwith "init alloc failed"
  ) in
  Array.iter (fun n -> Ebr_pool.free ebr n) slot_nodes;

  stress_test ~name:"EBR Pool"
    ~num_domains:8 ~pool_size ~ops_per_domain:50_000
    ~init:(fun () -> Ebr_pool.init_domain ebr)
    ~alloc:(fun _id ->
      match Ebr_pool.alloc ebr 0 with
      | Some n ->
        let rec find_idx i =
          if i >= pool_size then failwith "Alien node detected!"
          else if n == slot_nodes.(i) then i
          else find_idx (i + 1)
        in
        let idx = find_idx 0 in
        Some (n, idx)
      | None -> None)
    ~free:(fun n -> Ebr_pool.free ebr n)

let () =
  Printf.printf "=== ABA Stress Tests ===\n\n%!";
  let e1 = test_unprotected () in
  Printf.printf "\n%!";
  let e2 = test_hp () in
  Printf.printf "\n%!";
  let e3 = test_ebr () in
  Printf.printf "\n--- Summary ---\n%!";
  Printf.printf "Unprotected: %d ABA errors %s\n%!" e1
    (if e1 > 0 then "(expected — demonstrates the bug)" else "(got lucky)");
  Printf.printf "HP Pool:     %d ABA errors %s\n%!" e2
    (if e2 = 0 then "✓ (ABA prevented)" else "✗ BUG");
  Printf.printf "EBR Pool:    %d ABA errors %s\n%!" e3
    (if e3 = 0 then "✓ (ABA prevented)" else "✗ BUG")

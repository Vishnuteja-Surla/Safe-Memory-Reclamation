(** Tests for the Hazard Pointer library. *)

(** Simple reclamation tracking for tests. *)
let reclaimed : int list ref = ref []
let reclaim_callback (id : int) = reclaimed := id :: !reclaimed
let reset_reclaimed () = reclaimed := []

let test_single_domain_basic () =
  Printf.printf "Testing single-domain basic protect/release/retire...\n%!";
  let hp = Hazard_pointer.create ~max_domains:4 ~max_hp_per_domain:2
      ~retire_threshold:1 in
  Hazard_pointer.init_domain hp;

  (* Retire a node — should be reclaimed immediately (threshold=1, no HP) *)
  reset_reclaimed ();
  Hazard_pointer.retire hp 42 reclaim_callback;
  assert (List.mem 42 !reclaimed);
  Printf.printf "  Unprotected node reclaimed: OK\n%!";

  (* Protect a node, retire it — should NOT be reclaimed *)
  reset_reclaimed ();
  Hazard_pointer.protect hp 0 100;
  Hazard_pointer.retire hp 100 reclaim_callback;
  assert (not (List.mem 100 !reclaimed));
  Printf.printf "  Protected node NOT reclaimed: OK\n%!";

  (* Release the HP, then force scan — NOW it should be reclaimed *)
  Hazard_pointer.release hp 0;
  Hazard_pointer.scan hp;
  assert (List.mem 100 !reclaimed);
  Printf.printf "  Released node reclaimed after scan: OK\n%!";

  Printf.printf "Single-domain basic tests passed!\n%!"

let test_multi_domain_protection () =
  Printf.printf "Testing multi-domain HP protection...\n%!";
  let hp = Hazard_pointer.create ~max_domains:4 ~max_hp_per_domain:2
      ~retire_threshold:1 in

  (* Use a heap-allocated ref so physical equality works across domains *)
  let shared_node = ref 999 in

  let protection_held = Atomic.make false in
  let retire_done = Atomic.make false in
  let check_done = Atomic.make false in

  reset_reclaimed ();

  (* Domain 1: protect the node *)
  let d1 = Domain.spawn (fun () ->
    Hazard_pointer.init_domain hp;
    Hazard_pointer.protect hp 0 shared_node;
    Atomic.set protection_held true;

    (* Wait until domain 2 has tried to retire *)
    while not (Atomic.get retire_done) do Domain.cpu_relax () done;
    (* Wait until the check is done *)
    while not (Atomic.get check_done) do Domain.cpu_relax () done;

    Hazard_pointer.release hp 0
  ) in

  (* Domain 2: retire the same node — should NOT be reclaimed *)
  let d2 = Domain.spawn (fun () ->
    Hazard_pointer.init_domain hp;
    while not (Atomic.get protection_held) do Domain.cpu_relax () done;

    Hazard_pointer.retire hp shared_node
      (fun _node -> reclaimed := 0 :: !reclaimed);
    Atomic.set retire_done true
  ) in

  Domain.join d2;

  (* The node should NOT have been reclaimed — D1 still protects it *)
  assert (not (List.exists (fun x -> x = 0) !reclaimed));
  Printf.printf "  Node protected by D1, retired by D2: NOT reclaimed: OK\n%!";
  Atomic.set check_done true;

  Domain.join d1;

  (* After D1 releases, a scan should reclaim it *)
  Hazard_pointer.scan hp;
  Printf.printf "Multi-domain protection tests passed!\n%!"

let test_threshold_batching () =
  Printf.printf "Testing threshold-based batching...\n%!";
  let hp = Hazard_pointer.create ~max_domains:4 ~max_hp_per_domain:2
      ~retire_threshold:5 in
  Hazard_pointer.init_domain hp;

  reset_reclaimed ();

  (* Retire 4 nodes — below threshold, no scan *)
  for i = 1 to 4 do
    Hazard_pointer.retire hp i reclaim_callback
  done;
  assert (!reclaimed = []);
  Printf.printf "  4 retires (threshold=5): no reclamation: OK\n%!";

  (* 5th retire triggers scan — all should be reclaimed *)
  Hazard_pointer.retire hp 5 reclaim_callback;
  assert (List.length !reclaimed = 5);
  Printf.printf "  5th retire triggers scan: all reclaimed: OK\n%!";

  Printf.printf "Threshold batching tests passed!\n%!"

let test_multiple_hp_slots () =
  Printf.printf "Testing multiple HP slots per domain...\n%!";
  let hp = Hazard_pointer.create ~max_domains:4 ~max_hp_per_domain:3
      ~retire_threshold:1 in
  Hazard_pointer.init_domain hp;

  let a = ref 1 in
  let b = ref 2 in
  let c = ref 3 in

  (* Protect all three slots *)
  Hazard_pointer.protect hp 0 a;
  Hazard_pointer.protect hp 1 b;
  Hazard_pointer.protect hp 2 c;

  reset_reclaimed ();

  (* Retire all three — none should be reclaimed *)
  Hazard_pointer.retire hp a (fun _ -> reclaimed := 1 :: !reclaimed);
  Hazard_pointer.retire hp b (fun _ -> reclaimed := 2 :: !reclaimed);
  Hazard_pointer.retire hp c (fun _ -> reclaimed := 3 :: !reclaimed);
  assert (!reclaimed = []);
  Printf.printf "  3 nodes in 3 slots, all protected: OK\n%!";

  (* Release slot 1 (b), scan — only b should be reclaimed *)
  Hazard_pointer.release hp 1;
  Hazard_pointer.scan hp;
  assert (List.mem 2 !reclaimed);
  assert (not (List.mem 1 !reclaimed));
  assert (not (List.mem 3 !reclaimed));
  Printf.printf "  Released slot 1: only b reclaimed: OK\n%!";

  Printf.printf "Multiple HP slots tests passed!\n%!"

let () =
  Printf.printf "=== Hazard Pointer Tests ===\n\n%!";
  test_single_domain_basic ();
  test_threshold_batching ();
  test_multiple_hp_slots ();
  test_multi_domain_protection ();
  Printf.printf "\nAll HP tests passed!\n%!"

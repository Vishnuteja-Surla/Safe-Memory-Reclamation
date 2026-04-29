(** Tests for the EBR library. *)

let reclaimed : int list ref = ref []
let reclaim_cb (id : int) = reclaimed := id :: !reclaimed
let reset () = reclaimed := []

let test_basic () =
  Printf.printf "Testing EBR basic enter/exit/retire...\n%!";
  let ebr = Ebr.create ~max_domains:4 in
  Ebr.init_domain ebr;

  (* Retire node 1 — goes to limbo, not reclaimed yet *)
  reset ();
  Ebr.retire ebr 1 reclaim_cb;
  assert (not (List.mem 1 !reclaimed));

  (* Advance epochs by entering/exiting + retiring (to trigger advance) *)
  for _ = 1 to 5 do
    Ebr.enter ebr;
    Ebr.retire ebr 0 (fun _ -> ());
    Ebr.exit ebr
  done;

  (* After enough epoch advances, enter frees old limbo *)
  Ebr.enter ebr;
  Ebr.exit ebr;

  (* Node 1 should now be reclaimed *)
  assert (List.mem 1 !reclaimed);

  Printf.printf "  Basic EBR operations: OK\n%!";
  Printf.printf "Basic EBR tests passed!\n%!"

let test_reentrant () =
  Printf.printf "Testing EBR re-entrancy (nested enter/exit)...\n%!";
  let ebr = Ebr.create ~max_domains:4 in
  Ebr.init_domain ebr;

  (* Double nesting: inner exit must NOT deactivate *)
  Ebr.enter ebr;    (* active_count = 1 *)
  Ebr.enter ebr;    (* active_count = 2 *)

  (* Retire inside nested section *)
  reset ();
  Ebr.retire ebr 99 reclaim_cb;

  Ebr.exit ebr;     (* active_count = 1, still active *)

  (* Epoch should NOT advance past our entry — node 99 must be safe *)
  for _ = 1 to 3 do
    Ebr.retire ebr 0 (fun _ -> ());
  done;
  (* We're still active, so epoch can't fully advance past us *)

  Ebr.enter ebr;
  Ebr.exit ebr;
  assert (not (List.mem 99 !reclaimed));

  Ebr.exit ebr;     (* active_count = 0, now truly inactive *)

  Ebr.retire ebr 0 (fun _ -> ());
  Ebr.enter ebr;
  Ebr.exit ebr;
  assert (List.mem 99 !reclaimed);

  (* Triple nesting *)
  Ebr.enter ebr;    (* 1 *)
  Ebr.enter ebr;    (* 2 *)
  Ebr.enter ebr;    (* 3 *)
  Ebr.exit ebr;     (* 2 *)
  Ebr.exit ebr;     (* 1 *)
  Ebr.exit ebr;     (* 0 — should not crash *)

  Printf.printf "  Nested enter/exit (depth 2, 3): OK\n%!";
  Printf.printf "Re-entrancy tests passed!\n%!"

let test_epoch_advancement () =
  Printf.printf "Testing epoch advancement...\n%!";
  let ebr = Ebr.create ~max_domains:2 in
  Ebr.init_domain ebr;

  reset ();

  (* Retire nodes 10 and 20 *)
  Ebr.enter ebr;
  Ebr.retire ebr 10 reclaim_cb;
  Ebr.retire ebr 20 reclaim_cb;
  Ebr.retire ebr 30 reclaim_cb;
  Ebr.retire ebr 40 reclaim_cb;
  Ebr.exit ebr;

  (* Neither should be reclaimed yet *)
  assert (not (List.mem 10 !reclaimed));
  assert (not (List.mem 20 !reclaimed));
  assert (not (List.mem 30 !reclaimed));
  assert (not (List.mem 40 !reclaimed));

  (* Advance epochs: enter/retire/exit cycles push the epoch forward *)
  Ebr.enter ebr;
  Ebr.retire ebr 0 (fun _ -> ());
  Ebr.exit ebr;

  assert (not (List.mem 10 !reclaimed));
  assert (not (List.mem 20 !reclaimed));
  assert (not (List.mem 30 !reclaimed));
  assert (not (List.mem 40 !reclaimed));

  Ebr.enter ebr;
  assert (List.mem 10 !reclaimed);
  assert (not (List.mem 20 !reclaimed));
  assert (not (List.mem 30 !reclaimed));
  assert (not (List.mem 40 !reclaimed));

  Ebr.retire ebr 0 (fun _ -> ());
  Ebr.exit ebr;
  
  Ebr.enter ebr;
  assert (List.mem 20 !reclaimed);
  assert (List.mem 30 !reclaimed);
  assert (List.mem 40 !reclaimed);
  Ebr.exit ebr;

  let n = List.length !reclaimed in
  Printf.printf "  Epoch advancement: %d nodes reclaimed\n%!" n;
  Printf.printf "Epoch advancement tests passed!\n%!"

let test_multi_domain_protection () =
  Printf.printf "Testing EBR multi-domain protection...\n%!";
  let ebr = Ebr.create ~max_domains:4 in

  let shared = ref 42 in
  let was_reclaimed = Atomic.make false in

  let stall_done = Atomic.make false in
  let retire_done = Atomic.make false in

  (* Domain 1: enters critical section and STALLS — holds epoch back *)
  let d1 = Domain.spawn (fun () ->
    Ebr.init_domain ebr;
    Ebr.enter ebr;

    (* Wait for D2 to retire *)
    while not (Atomic.get retire_done) do Domain.cpu_relax () done;

    (* Still in critical section — epoch should not have advanced past us,
       so the retired node should still be in limbo (not reclaimed) *)
    let reclaimed_while_held = Atomic.get was_reclaimed in    
    Ebr.exit ebr;

    Ebr.enter ebr;
    Ebr.exit ebr;
    Atomic.set stall_done true;

    (* Assert: node was NOT reclaimed while D1 held critical section *)
    assert (not reclaimed_while_held);
  ) in

  (* Domain 2: retires the shared node and tries to advance *)
  let d2 = Domain.spawn (fun () ->
    Ebr.init_domain ebr;
    Ebr.enter ebr;
    Ebr.retire ebr shared (fun _ -> Atomic.set was_reclaimed true);
    Ebr.exit ebr;

    for _ = 1 to 5 do
      Ebr.enter ebr;
      Ebr.retire ebr (ref 0) (fun _ -> ());
      Ebr.exit ebr
    done;

    Atomic.set retire_done true;
    while not (Atomic.get stall_done) do Domain.cpu_relax () done;
    Ebr.retire ebr (ref 0) (fun _ -> ());
    Ebr.enter ebr;
    assert (Atomic.get was_reclaimed);
    Ebr.exit ebr;


  ) in

  Domain.join d1;
  Domain.join d2;
 
  Printf.printf "  Multi-domain protection: OK (reclaimed=%b)\n%!"
    (Atomic.get was_reclaimed);
  Printf.printf "Multi-domain protection tests passed!\n%!"

let () =
  Printf.printf "=== EBR Tests ===\n\n%!";
  test_basic ();
  test_reentrant ();
  test_epoch_advancement ();
  test_multi_domain_protection ();
  Printf.printf "\nAll EBR tests passed!\n%!"

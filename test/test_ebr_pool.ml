(** Tests for EBR-protected pool. *)

let test_sequential () =
  Printf.printf "Testing EBR pool sequential...\n%!";
  let t = Ebr_pool.create ~capacity:5 () in
  Ebr_pool.init_domain t;

  let nodes = Array.init 5 (fun i ->
    match Ebr_pool.alloc t i with
    | Some n -> n
    | None -> failwith (Printf.sprintf "alloc %d failed" i)
  ) in
  assert (Option.is_none (Ebr_pool.alloc t 99));

  for i = 0 to 4 do
    assert (Ebr_pool.get nodes.(i) = i)
  done;

  (* Free all — retired via EBR *)
  Array.iter (fun n -> Ebr_pool.free t n) nodes;

  (* Advance epochs to reclaim *)
  for _ = 1 to 5 do
    match Ebr_pool.alloc t 0 with
    | Some n -> Ebr_pool.free t n
    | None -> ()
  done;

  Printf.printf "EBR pool sequential tests passed!\n%!"

let test_concurrent () =
  Printf.printf "Testing EBR pool concurrent...\n%!";
  let num_domains = 4 in
  let pool_size = 64 in
  let ops = 5_000 in
  let t = Ebr_pool.create ~capacity:pool_size ~max_domains:(num_domains + 1) () in
  Ebr_pool.init_domain t;

  let worker id =
    Ebr_pool.init_domain t;
    let owned = ref [] in
    let rng = Random.State.make [| id; 42 |] in
    for _ = 1 to ops do
      if Random.State.bool rng then begin
        match Ebr_pool.alloc t id with
        | Some node -> owned := node :: !owned
        | None -> ()
      end else begin
        match !owned with
        | [] -> ()
        | node :: rest ->
          owned := rest;
          Ebr_pool.free t node
      end
    done;
    List.iter (fun n -> Ebr_pool.free t n) !owned
  in

  let t0 = Unix.gettimeofday () in
  let domains = Array.init num_domains (fun id ->
    Domain.spawn (fun () -> worker id)
  ) in
  Array.iter Domain.join domains;
  let elapsed = Unix.gettimeofday () -. t0 in

  Printf.printf "EBR pool concurrent: %d domains × %d ops in %.3fs\n%!"
    num_domains ops elapsed;
  Printf.printf "EBR pool concurrent tests passed!\n%!"

let () =
  Printf.printf "=== EBR Pool Tests ===\n\n%!";
  test_sequential ();
  test_concurrent ();
  Printf.printf "\nAll EBR pool tests passed!\n%!"

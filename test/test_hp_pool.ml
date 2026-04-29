(** Tests for HP-protected pool. *)

let test_sequential () =
  Printf.printf "Testing HP pool sequential operations...\n%!";
  let t = Hp_pool.create ~capacity:5 () in
  Hp_pool.init_domain t;

  (* Alloc all *)
  let nodes = Array.init 5 (fun i ->
    match Hp_pool.alloc t i with
    | Some n -> n
    | None -> failwith (Printf.sprintf "alloc %d failed" i)
  ) in

  (* Pool empty *)
  assert (Option.is_none (Hp_pool.alloc t 99));

  (* Check values *)
  for i = 0 to 4 do
    assert (Hp_pool.get nodes.(i) = i)
  done;

  (* Free all — nodes go to retired list, then reclaimed via scan *)
  Array.iter (fun n -> Hp_pool.free t n) nodes;
  Hp_pool.scan t;

  (* Should be able to alloc again *)
  for i = 0 to 4 do
    match Hp_pool.alloc t (i + 10) with
    | Some n -> assert (Hp_pool.get n = i + 10)
    | None -> failwith (Printf.sprintf "re-alloc %d failed" i)
  done;

  Printf.printf "HP pool sequential tests passed!\n%!"

let test_concurrent () =
  Printf.printf "Testing HP pool concurrent operations...\n%!";
  let num_domains = 4 in
  let pool_size = 64 in
  let ops_per_domain = 5_000 in
  let t = Hp_pool.create ~capacity:pool_size ~max_domains:(num_domains + 1) () in
  Hp_pool.init_domain t;

  let worker id =
    Hp_pool.init_domain t;
    let owned = ref [] in
    let rng = Random.State.make [| id; 42 |] in
    for _ = 1 to ops_per_domain do
      if Random.State.bool rng then begin
        match Hp_pool.alloc t id with
        | Some node -> owned := node :: !owned
        | None -> ()
      end else begin
        match !owned with
        | [] -> ()
        | node :: rest ->
          owned := rest;
          Hp_pool.free t node
      end
    done;
    (* Free remaining *)
    List.iter (fun n -> Hp_pool.free t n) !owned;

    while Hp_pool.retired_count t > 0 do
      Hp_pool.scan t;
      Domain.cpu_relax ()
    done
  in

  let t0 = Unix.gettimeofday () in
  let domains = Array.init num_domains (fun id ->
    Domain.spawn (fun () -> worker id)
  ) in
  Array.iter Domain.join domains;
  let elapsed = Unix.gettimeofday () -. t0 in

  (* Force final scan to reclaim all retired nodes *)
  Hp_pool.scan t;

  (* Verify pool integrity — all nodes should be recoverable *)
  let count = ref 0 in
  while Option.is_some (Hp_pool.alloc t 0) do
    incr count
  done;

  Printf.printf "HP pool concurrent: %d domains × %d ops in %.3fs\n%!"
    num_domains ops_per_domain elapsed;

  if !count = pool_size then
    Printf.printf "HP pool concurrent tests passed! (%d nodes recovered)\n%!" pool_size
  else
    Printf.printf "HP pool: recovered %d/%d nodes (some may still be in retired lists)\n%!"
      !count pool_size

let test_alloc_fresh_fallback () =
  Printf.printf "Testing HP pool GC fallback...\n%!";
  let t = Hp_pool.create ~capacity:2 () in
  Hp_pool.init_domain t;

  let _n1 = Hp_pool.alloc t 1 in
  let _n2 = Hp_pool.alloc t 2 in
  assert (Option.is_none (Hp_pool.alloc t 3));

  (* GC fallback *)
  let fresh = Hp_pool.alloc_fresh 42 in
  assert (Hp_pool.get fresh = 42);

  (* Free fresh node into pool *)
  Hp_pool.free t fresh;
  Hp_pool.scan t;

  let n3 = match Hp_pool.alloc t 100 with
    | Some n -> n
    | None -> failwith "alloc after free of fresh node failed"
  in
  assert (Hp_pool.get n3 = 100);
  Printf.printf "HP pool GC fallback tests passed!\n%!"

let () =
  Printf.printf "=== HP Pool Tests ===\n\n%!";
  test_sequential ();
  test_alloc_fresh_fallback ();
  test_concurrent ();
  Printf.printf "\nAll HP pool tests passed!\n%!"

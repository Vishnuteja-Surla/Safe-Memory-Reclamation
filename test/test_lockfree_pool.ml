(** Test suite for Lock-Free Pool *)

let test_sequential () =
  Printf.printf "Testing sequential operations...\n%!";
  let pool = Lockfree_pool.create ~capacity:5 in

  (* Alloc all nodes *)
  let nodes = Array.init 5 (fun i ->
    match Lockfree_pool.alloc pool i with
    | Some node -> node
    | None -> failwith (Printf.sprintf "alloc %d failed" i)
  ) in

  (* Pool should be empty *)
  assert (Option.is_none (Lockfree_pool.alloc pool 99));

  (* Check values *)
  for i = 0 to 4 do
    assert (Lockfree_pool.get nodes.(i) = i)
  done;

  (* Free all *)
  Array.iter (fun node -> Lockfree_pool.free pool node) nodes;

  (* Should be able to alloc again *)
  let nodes2 = Array.init 5 (fun i ->
    match Lockfree_pool.alloc pool (i + 10) with
    | Some node -> node
    | None -> failwith (Printf.sprintf "re-alloc %d failed" i)
  ) in

  (* Check values *)
  for i = 0 to 4 do
    assert (Lockfree_pool.get nodes2.(i) = i + 10)
  done;

  Printf.printf "Sequential tests passed!\n%!"

let test_single_alloc_free () =
  Printf.printf "Testing single alloc/free cycles...\n%!";
  let pool = Lockfree_pool.create ~capacity:1 in
  for i = 0 to 99 do
    let node = match Lockfree_pool.alloc pool i with
      | Some n -> n
      | None -> failwith (Printf.sprintf "alloc %d failed" i)
    in
    assert (Lockfree_pool.get node = i);
    assert (Option.is_none (Lockfree_pool.alloc pool 0));
    Lockfree_pool.free pool node
  done;
  Printf.printf "Single alloc/free tests passed!\n%!"

let test_fill_and_drain () =
  Printf.printf "Testing fill and drain...\n%!";
  let n = 1000 in
  let pool = Lockfree_pool.create ~capacity:n in

  (* Alloc all *)
  let nodes = Array.init n (fun i ->
    match Lockfree_pool.alloc pool i with
    | Some node -> node
    | None -> failwith (Printf.sprintf "alloc %d failed" i)
  ) in

  (* Pool empty *)
  assert (Option.is_none (Lockfree_pool.alloc pool 0));

  (* Free all *)
  Array.iter (fun node -> Lockfree_pool.free pool node) nodes;

  (* Alloc all again *)
  let nodes2 = Array.init n (fun i ->
    match Lockfree_pool.alloc pool (i + 1000) with
    | Some node -> node
    | None -> failwith (Printf.sprintf "re-alloc %d failed" i)
  ) in

  (* Verify values *)
  Array.iter (fun node ->
    let v = Lockfree_pool.get node in
    assert (v >= 1000 && v < 2000)
  ) nodes2;

  Printf.printf "Fill and drain tests passed!\n%!"

let test_alloc_fresh () =
  Printf.printf "Testing alloc_fresh (GC fallback)...\n%!";
  let pool = Lockfree_pool.create ~capacity:2 in

  (* Exhaust pool *)
  let _n1 = Lockfree_pool.alloc pool 1 in
  let _n2 = Lockfree_pool.alloc pool 2 in
  assert (Option.is_none (Lockfree_pool.alloc pool 3));

  (* GC fallback *)
  let fresh = Lockfree_pool.alloc_fresh 42 in
  assert (Lockfree_pool.get fresh = 42);

  (* Can free the fresh node into the pool *)
  Lockfree_pool.free pool fresh;

  (* Should be able to alloc again *)
  let n3 = match Lockfree_pool.alloc pool 100 with
    | Some n -> n
    | None -> failwith "alloc after free of fresh node failed"
  in
  assert (Lockfree_pool.get n3 = 100);

  Printf.printf "alloc_fresh tests passed!\n%!"

let test_concurrent () =
  Printf.printf "Testing concurrent operations...\n%!";
  let num_domains = 4 in
  let pool_size = 100 in
  let ops_per_domain = 10_000 in
  let pool = Lockfree_pool.create ~capacity:pool_size in

  let errors = Atomic.make 0 in

  let worker _id =
    let owned = ref [] in
    let rng = Random.State.make [| _id; 42 |] in
    for _ = 1 to ops_per_domain do
      if Random.State.bool rng then begin
        (* Try to alloc *)
        match Lockfree_pool.alloc pool 0 with
        | Some node -> owned := node :: !owned
        | None -> ()
      end else begin
        (* Try to free *)
        match !owned with
        | [] -> ()
        | node :: rest ->
          owned := rest;
          Lockfree_pool.free pool node
      end
    done;
    (* Free remaining *)
    List.iter (fun node -> Lockfree_pool.free pool node) !owned
  in

  let domains = Array.init num_domains (fun id ->
    Domain.spawn (fun () -> worker id)
  ) in
  Array.iter Domain.join domains;

  (* Verify: should be able to alloc exactly pool_size nodes *)
  let count = ref 0 in
  while Option.is_some (Lockfree_pool.alloc pool 0) do
    incr count
  done;

  if !count <> pool_size then begin
    Printf.printf "ERROR: expected %d nodes, got %d\n%!" pool_size !count;
    Atomic.incr errors
  end;

  if Atomic.get errors = 0 then
    Printf.printf "Concurrent tests passed! (recovered all %d nodes)\n%!" pool_size
  else
    Printf.printf "Concurrent tests FAILED!\n%!"

let test_concurrent_stress () =
  Printf.printf "Testing concurrent stress (high contention)...\n%!";
  let num_domains = 8 in
  let pool_size = 16 in
  let ops_per_domain = 50_000 in
  let pool = Lockfree_pool.create ~capacity:pool_size in

  let worker _id =
    let owned = ref [] in
    let rng = Random.State.make [| _id; 137 |] in
    for _ = 1 to ops_per_domain do
      if Random.State.bool rng then begin
        match Lockfree_pool.alloc pool _id with
        | Some node -> owned := node :: !owned
        | None -> ()
      end else begin
        match !owned with
        | [] -> ()
        | node :: rest ->
          owned := rest;
          Lockfree_pool.free pool node
      end
    done;
    List.iter (fun node -> Lockfree_pool.free pool node) !owned
  in

  let t0 = Unix.gettimeofday () in
  let domains = Array.init num_domains (fun id ->
    Domain.spawn (fun () -> worker id)
  ) in
  Array.iter Domain.join domains;
  let elapsed = Unix.gettimeofday () -. t0 in

  (* Verify pool integrity *)
  let count = ref 0 in
  while Option.is_some (Lockfree_pool.alloc pool 0) do
    incr count
  done;

  Printf.printf "Stress test: %d domains × %d ops in %.3fs\n%!"
    num_domains ops_per_domain elapsed;
  if !count = pool_size then
    Printf.printf "Stress test passed! (all %d nodes recovered)\n%!" pool_size
  else
    Printf.printf "Stress test FAILED: expected %d nodes, got %d\n%!" pool_size !count

let () =
  Printf.printf "=== Lock-Free Pool Tests ===\n\n%!";
  test_sequential ();
  test_single_alloc_free ();
  test_fill_and_drain ();
  test_alloc_fresh ();
  test_concurrent ();
  test_concurrent_stress ();
  Printf.printf "\nAll tests passed!\n%!"

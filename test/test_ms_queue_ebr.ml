(** Tests for the Michael-Scott Queue with EBR. *)

let test_sequential () =
  Printf.printf "Testing MS Queue EBR sequential...\n%!";
  let q = Ms_queue_ebr.create () in
  Ms_queue_ebr.init_domain q;

  (* Empty queue *)
  assert (Ms_queue_ebr.try_deq q = None);

  (* Enqueue and dequeue — FIFO order *)
  Ms_queue_ebr.enq q 1;
  Ms_queue_ebr.enq q 2;
  Ms_queue_ebr.enq q 3;
  assert (Ms_queue_ebr.try_deq q = Some 1);
  assert (Ms_queue_ebr.try_deq q = Some 2);
  assert (Ms_queue_ebr.try_deq q = Some 3);
  assert (Ms_queue_ebr.try_deq q = None);

  Printf.printf "Sequential tests passed!\n%!"

let test_interleaved () =
  Printf.printf "Testing MS Queue EBR interleaved...\n%!";
  let q = Ms_queue_ebr.create () in
  Ms_queue_ebr.init_domain q;

  Ms_queue_ebr.enq q 10;
  assert (Ms_queue_ebr.try_deq q = Some 10);
  Ms_queue_ebr.enq q 20;
  Ms_queue_ebr.enq q 30;
  assert (Ms_queue_ebr.try_deq q = Some 20);
  Ms_queue_ebr.enq q 40;
  assert (Ms_queue_ebr.try_deq q = Some 30);
  assert (Ms_queue_ebr.try_deq q = Some 40);
  assert (Ms_queue_ebr.try_deq q = None);

  Printf.printf "Interleaved tests passed!\n%!"

let test_fill_and_drain () =
  Printf.printf "Testing MS Queue EBR fill and drain...\n%!";
  let n = 1000 in
  let q = Ms_queue_ebr.create () in
  Ms_queue_ebr.init_domain q;

  for i = 0 to n - 1 do
    Ms_queue_ebr.enq q i
  done;
  for i = 0 to n - 1 do
    assert (Ms_queue_ebr.try_deq q = Some i)
  done;
  assert (Ms_queue_ebr.try_deq q = None);

  Printf.printf "Fill and drain tests passed!\n%!"

let test_concurrent () =
  Printf.printf "Testing MS Queue EBR concurrent...\n%!";
  let q = Ms_queue_ebr.create ~max_domains:10 () in
  Ms_queue_ebr.init_domain q;
  let num_producers = 4 in
  let num_consumers = 4 in
  let items_per_producer = 1000 in
  let total_items = num_producers * items_per_producer in

  let seen = Array.make total_items false in

  let producer id =
    Ms_queue_ebr.init_domain q;
    let start = id * items_per_producer in
    for i = start to start + items_per_producer - 1 do
      Ms_queue_ebr.enq q i
    done
  in

  let consumed = Atomic.make 0 in
  let consumer () =
    Ms_queue_ebr.init_domain q;
    while Atomic.get consumed < total_items do
      match Ms_queue_ebr.try_deq q with
      | Some v ->
        seen.(v) <- true;
        ignore (Atomic.fetch_and_add consumed 1)
      | None ->
        Domain.cpu_relax ()
    done
  in

  let t0 = Unix.gettimeofday () in
  let producers = Array.init num_producers (fun id ->
    Domain.spawn (fun () -> producer id)
  ) in
  let consumers = Array.init num_consumers (fun _ ->
    Domain.spawn (fun () -> consumer ())
  ) in
  Array.iter Domain.join producers;
  Array.iter Domain.join consumers;
  let elapsed = Unix.gettimeofday () -. t0 in

  (* Verify all items were seen *)
  let missing = ref 0 in
  for i = 0 to total_items - 1 do
    if not seen.(i) then incr missing
  done;

  Printf.printf "Concurrent: %d producers × %d consumers, %d items in %.3fs\n%!"
    num_producers num_consumers total_items elapsed;
  if !missing = 0 then
    Printf.printf "Concurrent tests passed! (all %d items seen)\n%!" total_items
  else
    Printf.printf "FAILED: %d items missing!\n%!" !missing

let () =
  Printf.printf "=== MS Queue with EBR Tests ===\n\n%!";
  test_sequential ();
  test_interleaved ();
  test_fill_and_drain ();
  test_concurrent ();
  Printf.printf "\nAll MS Queue EBR tests passed!\n%!"

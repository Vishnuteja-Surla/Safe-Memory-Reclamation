(** Throughput benchmark: HP Pool vs EBR Pool vs GC baseline vs Mutex Pool.

    Each domain performs [ops] alloc/free cycles. We measure total
    operations per second across 2–8 threads.

    Based on the benchmark pattern from Lecture 08's benchmark_queues.ml. *)

module type POOL_BENCH = sig
  type t
  type node
  val name : string
  val create : capacity:int -> max_domains:int -> t
  val init_domain : t -> unit
  val alloc : t -> int -> node option
  val free : t -> node -> unit
end

(** Unprotected lock-free pool (baseline, not ABA-safe). *)
module RawPool : POOL_BENCH = struct
  type t = int Lockfree_pool.t
  type node = int Lockfree_pool.node
  let name = "Raw(unsafe)"
  let create ~capacity ~max_domains:_ = Lockfree_pool.create ~capacity
  let init_domain _ = ()
  let alloc t v = Lockfree_pool.alloc t v
  let free t n = Lockfree_pool.free t n
end

(** HP-protected pool. *)
module HPPool : POOL_BENCH = struct
  type t = int Hp_pool.t
  type node = int Lockfree_pool.node
  let name = "HP Pool"
  let create ~capacity ~max_domains = Hp_pool.create ~capacity ~max_domains ()
  let init_domain = Hp_pool.init_domain
  let alloc t v = Hp_pool.alloc t v
  let free t n = Hp_pool.free t n
end

(** EBR-protected pool. *)
module EBRPool : POOL_BENCH = struct
  type t = int Ebr_pool.t
  type node = int Lockfree_pool.node
  let name = "EBR Pool"
  let create ~capacity ~max_domains = Ebr_pool.create ~capacity ~max_domains ()
  let init_domain = Ebr_pool.init_domain
  let alloc t v = Ebr_pool.alloc t v
  let free t n = Ebr_pool.free t n
end

(** Mutex-protected pool (baseline). *)
module MutexPool : POOL_BENCH = struct
  type t = { q : int Queue.t; m : Mutex.t }
  type node = int
  let name = "Mutex Pool"
  let create ~capacity ~max_domains:_ =
    let q = Queue.create () in
    for i = 0 to capacity - 1 do Queue.add i q done;
    { q; m = Mutex.create () }
  let init_domain _ = ()
  let alloc t _v =
    Mutex.lock t.m;
    let r = if Queue.is_empty t.q then None
            else Some (Queue.pop t.q) in
    Mutex.unlock t.m; r
  let free t n =
    Mutex.lock t.m;
    Queue.add n t.q;
    Mutex.unlock t.m
end

(** GC-allocated baseline (no pool — fresh allocation every time). *)
module GCPool : POOL_BENCH = struct
  type t = unit
  type node = int ref
  let name = "GC Alloc"
  let create ~capacity:_ ~max_domains:_ = ()
  let init_domain _ = ()
  let alloc _t v = Some (ref v)
  let free _t _n = ()  (* GC handles it *)
end

let benchmark (type t n) (module P : POOL_BENCH with type t = t and type node = n)
    num_threads ops_per_thread =
  let capacity = 1024 in
  let pool = P.create ~capacity ~max_domains:(num_threads + 1) in
  P.init_domain pool;

  let worker () =
    P.init_domain pool;
    let owned = ref [] in
    for i = 1 to ops_per_thread do
      if i mod 2 = 0 then begin
        match P.alloc pool i with
        | Some n -> owned := n :: !owned
        | None -> ()
      end else begin
        match !owned with
        | [] ->
          (match P.alloc pool i with
           | Some n -> owned := n :: !owned
           | None -> ())
        | n :: rest ->
          owned := rest;
          P.free pool n
      end
    done;
    List.iter (fun n -> P.free pool n) !owned
  in

  Gc.full_major ();
  let t0 = Unix.gettimeofday () in
  let domains = List.init num_threads (fun _ -> Domain.spawn worker) in
  List.iter Domain.join domains;
  let elapsed = Unix.gettimeofday () -. t0 in
  let total_ops = float_of_int (num_threads * ops_per_thread) in
  total_ops /. elapsed

let avg lst =
  let sum = List.fold_left (+.) 0.0 lst in
  sum /. float_of_int (List.length lst)

let () =
  let ops = ref 100_000 in
  let runs = ref 3 in
  let max_threads = ref 8 in

  let speclist = [
    ("--ops", Arg.Set_int ops, "Ops per thread (default: 100000)");
    ("--runs", Arg.Set_int runs, "Runs to average (default: 3)");
    ("--max-threads", Arg.Set_int max_threads, "Max threads (default: 8)");
  ] in
  Arg.parse speclist (fun _ -> ()) "Benchmark: Pool throughput comparison";

  Printf.printf "=== Pool Throughput Comparison ===\n\n%!";
  Printf.printf "Configuration: %d ops/thread × %d runs\n\n%!" !ops !runs;

  Printf.printf "%-8s %12s %12s %12s %12s %12s\n%!"
    "Threads" "Raw(Kops)" "HP(Kops)" "EBR(Kops)" "Mutex(Kops)" "GC(Kops)";
  Printf.printf "%s\n%!" (String.make 72 '-');

  for threads = 2 to !max_threads do
    Printf.printf "%-8d" threads;

    (* Raw pool *)
    let tp = avg (List.init !runs (fun _ ->
      benchmark (module RawPool) threads !ops)) in
    Printf.printf " %11.0fK" (tp /. 1000.0);

    (* HP pool *)
    let tp = avg (List.init !runs (fun _ ->
      benchmark (module HPPool) threads !ops)) in
    Printf.printf " %11.0fK" (tp /. 1000.0);

    (* EBR pool *)
    let tp = avg (List.init !runs (fun _ ->
      benchmark (module EBRPool) threads !ops)) in
    Printf.printf " %11.0fK" (tp /. 1000.0);

    (* Mutex pool *)
    let tp = avg (List.init !runs (fun _ ->
      benchmark (module MutexPool) threads !ops)) in
    Printf.printf " %11.0fK" (tp /. 1000.0);

    (* GC pool *)
    let tp = avg (List.init !runs (fun _ ->
      benchmark (module GCPool) threads !ops)) in
    Printf.printf " %11.0fK" (tp /. 1000.0);

    Printf.printf "\n%!"
  done;

  Printf.printf "\nThroughput in thousands of ops/sec (alloc + free cycles).\n%!"

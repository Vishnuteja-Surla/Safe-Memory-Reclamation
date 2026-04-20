(** QCheck-STM state machine test for the HP-protected pool.

    Model: a bounded counter tracking available nodes.
    - alloc: decrements counter (returns Some if >0, None if 0)
    - free: increments counter
    Verifies that the pool behaves like a bounded resource allocator. *)

open QCheck
open STM

module Spec = struct
  (** Commands: alloc a node with a value, or free a previously allocated node. *)
  type cmd =
    | Alloc of int
    | Free
    | Get

  let show_cmd = function
    | Alloc v -> "Alloc " ^ string_of_int v
    | Free -> "Free"
    | Get -> "Get"

  (** Model state: number of free nodes, and a stack of allocated values
      (most recently allocated on top). *)
  type state = {
    free_count : int;
    allocated : int list;  (** stack of values, most recent first *)
  }

  (** SUT wraps the HP pool and a list of currently held nodes. *)
  type sut = {
    pool : int Hp_pool.t;
    held : int Lockfree_pool.node list Atomic.t;
  }

  let arb_cmd s =
    let alloc_gen = Gen.map (fun v -> Alloc v) Gen.nat_small in
    let cmds =
      if s.allocated = [] then
        [(3, alloc_gen)]
      else
        [(3, alloc_gen); (2, Gen.return Free); (1, Gen.return Get)]
    in
    QCheck.make ~print:show_cmd (Gen.oneof_weighted cmds)

  let init_state = { free_count = 10; allocated = [] }

  let init_sut () =
    let pool = Hp_pool.create ~capacity:10 ~max_domains:128 () in
    Hp_pool.init_domain pool;
    { pool; held = Atomic.make [] }

  let cleanup _ = ()

  let next_state c s = match c with
    | Alloc v ->
      if s.free_count > 0 then
        { free_count = s.free_count - 1; allocated = v :: s.allocated }
      else s
    | Free ->
      (match s.allocated with
       | [] -> s
       | _ :: rest -> { free_count = s.free_count + 1; allocated = rest })
    | Get ->
      s  (* get doesn't change state *)

  let precond _ _ = true

  let run c sut =
    Hp_pool.init_domain sut.pool;
    match c with
    | Alloc v ->
      let result = match Hp_pool.alloc sut.pool v with
        | Some node ->
          Atomic.set sut.held (node :: Atomic.get sut.held);
          true
        | None -> false
      in
      Res (bool, result)
    | Free ->
      let held = Atomic.get sut.held in
      (match held with
       | [] -> Res (bool, false)
       | node :: rest ->
         Atomic.set sut.held rest;
         Hp_pool.free sut.pool node;
         Hp_pool.scan sut.pool;
         Res (bool, true))
    | Get ->
      let held = Atomic.get sut.held in
      (match held with
       | [] -> Res (option int, None)
       | node :: _ -> Res (option int, Some (Hp_pool.get node)))

  let postcond c (s : state) res = match c, res with
    | Alloc _, Res ((Bool, _), result) ->
      result = (s.free_count > 0)
    | Free, Res ((Bool, _), result) ->
      result = (s.allocated <> [])
    | Get, Res ((Option Int, _), v) ->
      (match s.allocated with
       | [] -> v = None
       | x :: _ -> v = Some x)
    | _, _ -> false
end

module HP_seq = STM_sequential.Make(Spec)

let () =
  QCheck_base_runner.run_tests_main [
    HP_seq.agree_test ~count:1000 ~name:"HP Pool STM sequential";
  ]

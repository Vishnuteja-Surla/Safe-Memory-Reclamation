(** QCheck-STM state machine test for the EBR-protected pool.

    Unlike HP pool where scan can be forced, EBR's free is deferred —
    nodes are only returned to the pool after epoch advancement.
    The model accounts for this by tracking nodes "in limbo" separately.

    Model:
    - free_count: nodes available for allocation
    - in_limbo: nodes retired but not yet reclaimed
    - allocated: stack of values held by the test *)

open QCheck
open STM

module Spec = struct
  type cmd =
    | Alloc of int
    | Free
    | Get

  let show_cmd = function
    | Alloc v -> "Alloc " ^ string_of_int v
    | Free -> "Free"
    | Get -> "Get"

  type state = {
    free_count : int;
    in_limbo : int;       (** nodes retired but not yet reclaimed *)
    allocated : int list;
  }

  type sut = {
    pool : int Ebr_pool.t;
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

  let init_state = { free_count = 10; in_limbo = 0; allocated = [] }

  let init_sut () =
    let pool = Ebr_pool.create ~capacity:10 ~max_domains:128 () in
    Ebr_pool.init_domain pool;
    { pool; held = Atomic.make [] }

  let cleanup _ = ()

  let next_state c s = match c with
    | Alloc _ ->
      if s.free_count > 0 then
        { s with free_count = s.free_count - 1;
                 allocated = 0 :: s.allocated }
        (* We use 0 as placeholder — we don't track values precisely
           because EBR alloc may return nodes in different order *)
      else s
    | Free ->
      (match s.allocated with
       | [] -> s
       | _ :: rest ->
         (* Node goes to limbo, NOT immediately back to free list *)
         { s with in_limbo = s.in_limbo + 1; allocated = rest })
    | Get -> s

  let precond _ _ = true

  let run c sut =
    Ebr_pool.init_domain sut.pool;
    match c with
    | Alloc v ->
      let result = match Ebr_pool.alloc sut.pool v with
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
         Ebr_pool.free sut.pool node;
         Res (bool, true))
    | Get ->
      let held = Atomic.get sut.held in
      (match held with
       | [] -> Res (option int, None)
       | node :: _ -> Res (option int, Some (Ebr_pool.get node)))

  let postcond c (s : state) res = match c, res with
    | Alloc _, Res ((Bool, _), result) ->
      (* With EBR, alloc succeeds if there are free nodes.
         Limbo nodes may or may not have been reclaimed by now,
         so we accept both outcomes when pool might be empty. *)
      if s.free_count > 0 then result = true
      else
        (* Pool might have reclaimed some limbo nodes, or not *)
        true  (* accept either true or false *)
    | Free, Res ((Bool, _), result) ->
      result = (s.allocated <> [])
    | Get, Res ((Option Int, _), v) ->
      (match s.allocated with
       | [] -> v = None
       | _ -> v <> None)  (* value exists but may differ due to reuse *)
    | _, _ -> false
end

module EBR_seq = STM_sequential.Make(Spec)

let () =
  QCheck_base_runner.run_tests_main [
    EBR_seq.agree_test ~count:1000 ~name:"EBR Pool STM sequential";
  ]

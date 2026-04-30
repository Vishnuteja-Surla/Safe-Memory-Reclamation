(** QCheck-STM state machine test for the EBR-protected pool.

    The key insight: by calling [Ebr_pool.force_flush] after every [Free],
    we make EBR reclamation synchronous. This lets us use the exact same
    strict model as the HP pool test — no "accept either" wildcards,
    no "value exists but may differ" approximations.

    Model:
    - free_count: nodes available for allocation
    - allocated: stack of (value) held by the test

    Every postcondition is STRICT: alloc must match free_count exactly,
    and Get must return the exact stored value. *)

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

  (** Strict model: no in_limbo — force_flush makes Free synchronous. *)
  type state = {
    free_count : int;
    allocated : int list;  (** stack of values held by the test *)
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

  let init_state = { free_count = 10; allocated = [] }

  let init_sut () =
    let pool = Ebr_pool.create ~capacity:10 ~max_domains:128 () in
    Ebr_pool.init_domain pool;
    { pool; held = Atomic.make [] }

  let cleanup _ = ()

  let next_state c s = match c with
    | Alloc v ->
      if s.free_count > 0 then
        { free_count = s.free_count - 1;
          allocated = v :: s.allocated }
      else s
    | Free ->
      (match s.allocated with
       | [] -> s
       | _ :: rest ->
         (* force_flush makes Free synchronous — node returns to pool *)
         { free_count = s.free_count + 1; allocated = rest })
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
         (* THE FIX: Force immediate reclamation! *)
         Ebr_pool.force_flush sut.pool;
         Res (bool, true))
    | Get ->
      let held = Atomic.get sut.held in
      (match held with
       | [] -> Res (option int, None)
       | node :: _ -> Res (option int, Some (Ebr_pool.get node)))

  let postcond c (s : state) res = match c, res with
    | Alloc _, Res ((Bool, _), result) ->
      (* STRICT: must succeed iff free nodes available *)
      result = (s.free_count > 0)
    | Free, Res ((Bool, _), result) ->
      result = (s.allocated <> [])
    | Get, Res ((Option Int, _), v) ->
      (* STRICT: must return the exact stored value *)
      (match s.allocated with
       | [] -> v = None
       | x :: _ -> v = Some x)
    | _, _ -> false
end

module EBR_seq = STM_sequential.Make(Spec)

let () =
  QCheck_base_runner.run_tests_main [
    EBR_seq.agree_test ~count:1000 ~name:"EBR Pool STM sequential";
  ]

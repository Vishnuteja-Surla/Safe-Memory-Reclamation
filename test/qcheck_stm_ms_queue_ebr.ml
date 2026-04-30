(** QCheck-STM state machine test for MS Queue with EBR.

    Uses QCheck-STM to verify the queue against a sequential specification
    (a simple list-based FIFO). Tests both sequential and concurrent modes.

    Based on the pattern from Lecture 08's qcheck_stm_lockfree_queue.ml.

    Note on init_domain idempotency:
    EBR's init_domain uses Domain.DLS internally, so calling it multiple
    times from the SAME domain only consumes one EBR slot. The DLS guard
    below is an extra safety layer for clarity, and max_domains is bumped
    to 4096 to accommodate the many fresh domains STM_domain may spawn. *)

open QCheck
open STM

module MSQ = Ms_queue_ebr

(* DLS guard: ensures init_domain is only called once per domain.
   Redundant with EBR's internal DLS, but makes the intent explicit. *)
let inited = Domain.DLS.new_key (fun () -> false)

let ensure_init q =
  if not (Domain.DLS.get inited) then begin
    MSQ.init_domain q;
    Domain.DLS.set inited true
  end

module Spec = struct
  type cmd =
    | Enq of int
    | Try_deq

  let show_cmd = function
    | Enq i -> "Enq " ^ string_of_int i
    | Try_deq -> "Try_deq"

  (** Model state: FIFO queue as a list (head = front). *)
  type state = { contents : int list }

  type sut = int MSQ.t

  let arb_cmd _s =
    let int_gen = Gen.nat_small in
    QCheck.make ~print:show_cmd
      (Gen.oneof [
        Gen.map (fun i -> Enq i) int_gen;
        Gen.return Try_deq;
      ])

  let init_state = { contents = [] }

  let init_sut () =
    let q = MSQ.create ~max_domains:512 () in
    ensure_init q;
    q

  let cleanup _ = ()

  let next_state c s = match c with
    | Enq i -> { contents = s.contents @ [i] }
    | Try_deq ->
      match s.contents with
      | [] -> s
      | _ :: rest -> { contents = rest }

  let precond _ _ = true

  let run c q =
    ensure_init q;
    match c with
    | Enq i -> Res (unit, MSQ.enq q i)
    | Try_deq -> Res (option int, MSQ.try_deq q)

  let postcond c (s : state) res = match c, res with
    | Enq _, Res ((Unit, _), ()) -> true
    | Try_deq, Res ((Option Int, _), v) ->
      (match s.contents with
       | [] -> v = None
       | x :: _ -> v = Some x)
    | _, _ -> false
end

module MSQ_seq = STM_sequential.Make(Spec)
module MSQ_dom = STM_domain.Make(Spec)

let () =
  QCheck_base_runner.run_tests_main [
    MSQ_seq.agree_test   ~count:1000 ~name:"MSQueueEBR STM sequential";
    MSQ_dom.agree_test_par ~count:100 ~name:"MSQueueEBR STM parallel";
  ]

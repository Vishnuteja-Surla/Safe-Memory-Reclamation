(** QCheck-Lin linearizability test for the MS Queue with EBR.

    Lin_domain spawns fresh domains per test repetition. Each domain
    calls init_domain, permanently consuming an EBR slot.
    With Lin's default 300 reps × 2 domains per test, even 10 tests
    need ~6000 slots. We pre-allocate accordingly.

    To keep scan overhead manageable, we limit max_domains and
    reduce repetitions via the environment. *)

module MSQ = Ms_queue_ebr

let max_d = 8192
let shared_q = MSQ.create ~max_domains:max_d ()

let inited = Domain.DLS.new_key (fun () ->
  MSQ.init_domain shared_q; true)
let ensure_init () = ignore (Domain.DLS.get inited)

module MSQSig = struct
  type t = int MSQ.t

  let init () =
    ensure_init ();
    while Option.is_some (MSQ.try_deq shared_q) do () done;
    shared_q

  let cleanup _ = ()

  open Lin

  let enq_wrap q x = ensure_init (); MSQ.enq q x
  let deq_wrap q = ensure_init (); MSQ.try_deq q

  let api =
    [ val_ "enq"     enq_wrap (t @-> nat_small @-> returning unit);
      val_ "try_deq" deq_wrap (t @-> returning (option int)); ]
end

module MSQ_lin = Lin_domain.Make(MSQSig)

let () =
  QCheck_base_runner.run_tests_main [
    MSQ_lin.lin_test ~count:5 ~name:"MSQueueEBR Lin parallel";
  ]

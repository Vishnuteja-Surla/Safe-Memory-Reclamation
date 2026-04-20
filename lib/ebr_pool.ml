(** EBR-protected lock-free pool.

    Wraps {!Lockfree_pool} with {!Ebr} epoch-based reclamation.
    - [alloc] is wrapped in [enter]/[exit] to protect the read of [top].
    - [free] calls [retire] directly — no [enter]/[exit] needed because
      the caller has finished using the node (audit correction #6). *)

type 'a t = {
  pool : 'a Lockfree_pool.t;
  ebr : 'a Lockfree_pool.node Ebr.t;
}

module AL = Atomic.Loc

let create ~capacity ?(max_domains = 16) () =
  let pool = Lockfree_pool.create ~capacity in
  let ebr = Ebr.create ~max_domains in
  { pool; ebr }

let init_domain t = Ebr.init_domain t.ebr

(** Internal: push a node back onto the pool's free list. *)
let push_to_pool pool node =
  let rec loop () =
    let old_top = AL.get [%atomic.loc pool.Lockfree_pool.top] in
    AL.set [%atomic.loc node.Lockfree_pool.next] old_top;
    if AL.compare_and_set [%atomic.loc pool.Lockfree_pool.top]
        old_top (Some node)
    then ()
    else loop ()
  in
  loop ()

(** [alloc t v] pops a node with EBR protection. *)
let alloc t v =
  Ebr.enter t.ebr;
  let rec loop () =
    let top = AL.get [%atomic.loc t.pool.top] in
    match top with
    | None -> Ebr.exit t.ebr; None
    | Some node ->
      let next = AL.get [%atomic.loc node.next] in
      if AL.compare_and_set [%atomic.loc t.pool.top] top next then begin
        Ebr.exit t.ebr;
        Lockfree_pool.set node v;
        Some node
      end else
        loop ()
  in
  loop ()

(** [free t node] retires the node. Pushed back to pool after epoch advances. *)
let free t node =
  Ebr.retire t.ebr node (fun n -> push_to_pool t.pool n)

let get = Lockfree_pool.get
let set = Lockfree_pool.set
let alloc_fresh = Lockfree_pool.alloc_fresh

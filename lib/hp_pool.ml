(** Hazard pointer-protected lock-free pool.

    Wraps {!Lockfree_pool} with {!Hazard_pointer} protection to prevent
    the ABA problem. Each [alloc] protects the top node via HP before
    reading its [next] pointer, ensuring that a concurrent [free] cannot
    recycle the node while it is being inspected.

    The load-publish-verify pattern is applied in [alloc]:
    1. Read [top]
    2. Publish it in HP slot 0
    3. Re-read [top] — if changed, release and retry
    4. Proceed with CAS *)

type 'a t = {
  pool : 'a Lockfree_pool.t;
  hp : 'a Lockfree_pool.node Hazard_pointer.t;
}

module AL = Atomic.Loc

(** [create ~capacity ~max_domains] creates an HP-protected pool. *)
let create ~capacity ?(max_domains = 16) () =
  let pool = Lockfree_pool.create ~capacity in
  let hp = Hazard_pointer.create
      ~max_domains
      ~max_hp_per_domain:2
      ~retire_threshold:(max_domains * 4) in
  { pool; hp }

(** [init_domain t] registers the current domain with the HP system.
    Must be called once per domain before [alloc]/[free]. *)
let init_domain t = Hazard_pointer.init_domain t.hp

(** [alloc t v] pops a node from the pool with HP protection.
    Returns [Some node] or [None] if empty. ABA-safe. *)
let alloc t v =
  let rec loop () =
    let top = AL.get [%atomic.loc t.pool.top] in
    match top with
    | None -> None
    | Some node ->
      (* Publish node in HP slot 0 *)
      Hazard_pointer.protect t.hp 0 node;
      (* Verify top hasn't changed *)
      let top2 = AL.get [%atomic.loc t.pool.top] in
      if top2 != top then begin
        Hazard_pointer.release t.hp 0;
        loop ()
      end else begin
        let next = AL.get [%atomic.loc node.next] in
        if AL.compare_and_set [%atomic.loc t.pool.top] top next then begin
          Hazard_pointer.release t.hp 0;
          Lockfree_pool.set node v;
          Some node
        end else begin
          Hazard_pointer.release t.hp 0;
          loop ()
        end
      end
  in
  loop ()

(** Internal: push a node back onto the pool's free list via CAS. *)
let push_to_pool pool node =
  let rec loop () =
    let old_top = AL.get [%atomic.loc pool.Lockfree_pool.top] in
    AL.set [%atomic.loc node.Lockfree_pool.next] old_top;
    if AL.compare_and_set [%atomic.loc pool.Lockfree_pool.top] old_top (Some node)
    then ()
    else loop ()
  in
  loop ()

(** [free t node] retires [node] via HP. The node is pushed back onto
    the free list only after no domain holds a hazard pointer to it. *)
let free t node =
  Hazard_pointer.retire t.hp node (fun n -> push_to_pool t.pool n)

(** [get node] returns the value in [node]. *)
let get = Lockfree_pool.get

(** [set node v] updates the value in [node]. *)
let set = Lockfree_pool.set

(** [alloc_fresh v] allocates a fresh node via GC (fallback). *)
let alloc_fresh = Lockfree_pool.alloc_fresh

(** [scan t] forces an immediate HP scan. *)
let scan t = Hazard_pointer.scan t.hp

(** [retired_count t] returns the calling domain's pending retired count. *)
let retired_count t = Hazard_pointer.retired_count t.hp

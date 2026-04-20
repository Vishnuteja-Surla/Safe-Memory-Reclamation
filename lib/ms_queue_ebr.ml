(** Michael-Scott lock-free queue with EBR node recycling.

    Based on "The Art of Multiprocessor Programming" by Herlihy and Shavit
    (Chapter 10, Figures 10.9–10.12), adapted with epoch-based reclamation.

    Instead of allocating a fresh node for every [enq], this version
    maintains an internal lock-free free list of queue nodes. Dequeued
    sentinel nodes are retired via EBR and pushed back to the free list
    once safe. If the free list is empty, a fresh node is allocated
    via the GC (never deadlocks — audit fix #7).

    Lock-freedom: a CAS fails only if another thread's CAS succeeded. *)

(** A node in the queue's linked list. *)
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]
}

(** The queue with EBR and an internal free list. *)
type 'a t = {
  mutable head : 'a node; [@atomic]
  mutable tail : 'a node; [@atomic]
  mutable free_list : 'a node option; [@atomic]  (** Lock-free stack of recyclable nodes *)
  ebr : 'a node Ebr.t;
}

module AL = Atomic.Loc

(** Allocate a queue node: pop from free list, or GC-allocate if empty. *)
let alloc_node t v =
  let rec loop () =
    let top = AL.get [%atomic.loc t.free_list] in
    match top with
    | None ->
      (* GC fallback — allocate fresh *)
      { value = v; next = None }
    | Some node ->
      let next = AL.get [%atomic.loc node.next] in
      if AL.compare_and_set [%atomic.loc t.free_list] top next then begin
        node.value <- v;
        AL.set [%atomic.loc node.next] None;
        node
      end else
        loop ()
  in
  loop ()

(** Return a node to the free list. *)
let recycle_node t node =
  let rec loop () =
    let top = AL.get [%atomic.loc t.free_list] in
    AL.set [%atomic.loc node.next] top;
    if AL.compare_and_set [%atomic.loc t.free_list] top (Some node) then ()
    else loop ()
  in
  loop ()

(** [create ()] makes a new empty queue. *)
let create ?(max_domains = 16) () =
  let sentinel = { value = Obj.magic (); next = None } in
  let ebr = Ebr.create ~max_domains in
  { head = sentinel; tail = sentinel; free_list = None; ebr }

let init_domain t = Ebr.init_domain t.ebr

(** [enq q x] appends [x] to the queue. Lock-free, never blocks. *)
let enq q x =
  Ebr.enter q.ebr;
  let node = alloc_node q x in
  let rec loop () =
    let last = AL.get [%atomic.loc q.tail] in
    let next = AL.get [%atomic.loc last.next] in
    if last == AL.get [%atomic.loc q.tail] then
      match next with
      | None ->
        if AL.compare_and_set [%atomic.loc last.next] None (Some node)
        then
          ignore (AL.compare_and_set [%atomic.loc q.tail] last node)
        else
          loop ()
      | Some next_node ->
        (* Tail is lagging — help advance it *)
        ignore (AL.compare_and_set [%atomic.loc q.tail] last next_node);
        loop ()
    else
      loop ()
  in
  loop ();
  Ebr.exit q.ebr

(** [try_deq q] removes and returns [Some v], or [None] if empty. *)
let try_deq q =
  Ebr.enter q.ebr;
  let rec loop () =
    let first = AL.get [%atomic.loc q.head] in
    let last  = AL.get [%atomic.loc q.tail] in
    let next  = AL.get [%atomic.loc first.next] in
    if first == AL.get [%atomic.loc q.head] then
      match next with
      | None ->
        Ebr.exit q.ebr;
        None
      | Some next_node ->
        if first == last then begin
          (* Tail lagging — help advance *)
          ignore (AL.compare_and_set [%atomic.loc q.tail] last next_node);
          loop ()
        end else begin
          let value = next_node.value in
          if AL.compare_and_set [%atomic.loc q.head] first next_node then begin
            (* Retire old sentinel — recycled after epoch advances *)
            Ebr.retire q.ebr first (fun n -> recycle_node q n);
            Ebr.exit q.ebr;
            Some value
          end else
            loop ()
        end
    else
      loop ()
  in
  loop ()

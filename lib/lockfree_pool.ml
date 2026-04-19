(** Lock-free pool (Treiber stack-based free list).

    Based on the Treiber stack from "The Art of Multiprocessor Programming"
    by Herlihy and Shavit (Chapter 11).

    The pool pre-allocates [capacity] nodes and manages them as a lock-free
    stack (free list). [alloc] pops a node via CAS on [top]; [free] pushes
    a node back via CAS on [top].

    Lock-freedom: a CAS fails only if another thread's CAS succeeded,
    guaranteeing global progress. Exponential backoff reduces contention.

    WARNING: Without external protection (HP or EBR), this pool is
    vulnerable to the ABA problem. See {!Hp_pool} and {!Ebr_pool}. *)

(** A node in the pool. Carries a user value and an atomic [next] pointer
    for the free-list chain. *)
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]
}

(** The pool type. [top] points to the head of the free list. *)
type 'a t = {
  mutable top : 'a node option; [@atomic]
  cap : int;
}

(** Exponential backoff helper to reduce contention on the [top] pointer. *)
module Backoff = struct
  type t = { max_delay : int; mutable limit : int }

  let create ?(min_delay = 1) ?(max_delay = 128) () =
    { max_delay; limit = min_delay }

  let once t =
    let delay = Random.int (t.limit + 1) in
    for _ = 1 to delay do
      Domain.cpu_relax ()
    done;
    t.limit <- min t.max_delay (t.limit * 2)
end

module AL = Atomic.Loc

(** [create ~capacity] pre-allocates [capacity] nodes and chains them
    into a free list (Treiber stack). *)
let create ~capacity =
  if capacity <= 0 then { top = None; cap = 0 }
  else begin
    (* Build the chain by pushing nodes one at a time.
       Each new node's [next] points to the previous top. *)
    let head = ref None in
    for _ = 1 to capacity do
      let node = { value = Obj.magic (); next = !head } in
      head := Some node
    done;
    { top = !head; cap = capacity }
  end

(** [alloc t v] pops a node from the free list, stores [v] in it,
    and returns [Some node]. Returns [None] if the pool is empty.
    Lock-free with exponential backoff. *)
let alloc t v =
  let backoff = Backoff.create () in
  let rec loop () =
    let old_top = AL.get [%atomic.loc t.top] in
    match old_top with
    | None -> None
    | Some node ->
      let next = AL.get [%atomic.loc node.next] in
      if AL.compare_and_set [%atomic.loc t.top] old_top next then begin
        node.value <- v;
        Some node
      end else begin
        Backoff.once backoff;
        loop ()
      end
  in
  loop ()

(** [free t node] pushes [node] back onto the free list.
    Lock-free with exponential backoff. *)
let free t node =
  let backoff = Backoff.create () in
  let rec loop () =
    let old_top = AL.get [%atomic.loc t.top] in
    AL.set [%atomic.loc node.next] old_top;
    if AL.compare_and_set [%atomic.loc t.top] old_top (Some node) then ()
    else begin
      Backoff.once backoff;
      loop ()
    end
  in
  loop ()

(** [alloc_fresh v] allocates a fresh node outside the pool via the GC.
    Used as a fallback when the pool is exhausted. *)
let alloc_fresh v =
  { value = v; next = None }

(** [get node] returns the value stored in [node]. *)
let get node = node.value

(** [set node v] updates the value stored in [node]. *)
let set node v = node.value <- v

(** [capacity t] returns the initial capacity of the pool. *)
let capacity t = t.cap

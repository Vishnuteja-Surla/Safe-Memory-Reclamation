(** Lock-free pool (Treiber stack-based free list).

    A pool of pre-allocated nodes managed as a lock-free stack.
    [alloc] pops a node from the free list and stores a value in it.
    [free] pushes a node back onto the free list.

    WARNING: This pool is vulnerable to the ABA problem without
    external protection (hazard pointers or epoch-based reclamation).
    Concurrent alloc/free sequences can corrupt the free list. Use
    {!Hp_pool} or {!Ebr_pool} for safe concurrent usage. *)

(** A node in the pool. Nodes are pre-allocated and recycled.
    Identified by physical equality ([==]).
    The [next] field is atomic for lock-free stack operations. *)
type 'a node = {
  mutable value : 'a;
  mutable next : 'a node option; [@atomic]
}

(** The pool type. [top] is the atomic head of the free list. *)
type 'a t = {
  mutable top : 'a node option; [@atomic]
  cap : int;
}

val create : capacity:int -> 'a t
(** [create ~capacity] creates a pool with [capacity] pre-allocated nodes.
    All nodes start on the free list. *)

val alloc : 'a t -> 'a -> 'a node option
(** [alloc t v] pops a node from the free list and stores [v] in it.
    Returns [Some node] on success, or [None] if the pool is empty.
    Lock-free with exponential backoff. *)

val free : 'a t -> 'a node -> unit
(** [free t node] pushes [node] back onto the free list.
    The caller must ensure [node] was previously allocated from [t].
    Lock-free with exponential backoff. *)

val alloc_fresh : 'a -> 'a node
(** [alloc_fresh v] allocates a fresh node outside the pool via the GC.
    Used as a fallback when the pool is exhausted (e.g., in the MS queue)
    to avoid deadlock. The node can later be [free]d into the pool. *)

val get : 'a node -> 'a
(** [get node] returns the value stored in [node]. *)

val set : 'a node -> 'a -> unit
(** [set node v] updates the value stored in [node]. *)

val capacity : 'a t -> int
(** [capacity t] returns the initial capacity of the pool. *)

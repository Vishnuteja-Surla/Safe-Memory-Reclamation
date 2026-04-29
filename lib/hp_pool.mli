(** Hazard pointer-protected lock-free pool.

    Wraps {!Lockfree_pool} with {!Hazard_pointer} protection to prevent
    the ABA problem during concurrent alloc/free operations. *)

type 'a t

val create : capacity:int -> ?max_domains:int -> unit -> 'a t
(** [create ~capacity ()] creates an HP-protected pool with [capacity] nodes.
    @param max_domains Maximum number of concurrent domains (default 16). *)

val init_domain : 'a t -> unit
(** Register the current domain. Must be called once per domain. *)

val alloc : 'a t -> 'a -> 'a Lockfree_pool.node option
(** [alloc t v] pops a node and stores [v]. ABA-safe via hazard pointers.
    Returns [None] if the pool is empty. *)

val free : 'a t -> 'a Lockfree_pool.node -> unit
(** [free t node] retires [node]. It is returned to the free list only
    after no domain holds a hazard pointer to it. *)

val get : 'a Lockfree_pool.node -> 'a
val set : 'a Lockfree_pool.node -> 'a -> unit

val alloc_fresh : 'a -> 'a Lockfree_pool.node
(** GC fallback: allocate a node outside the pool. *)

val scan : 'a t -> unit
(** Force an immediate HP scan and reclaim unprotected retired nodes. *)

val retired_count : 'a t -> int
(** Number of retired nodes pending reclamation in the calling domain. *)

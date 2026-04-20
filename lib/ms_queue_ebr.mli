(** Michael-Scott lock-free queue with EBR node recycling.

    Adapted from Lecture 08's lock-free queue. Instead of allocating
    a fresh node per enqueue, dequeued sentinels are retired via EBR
    and recycled through an internal free list. If the free list is
    empty, a fresh node is GC-allocated (never deadlocks). *)

type 'a t

val create : ?max_domains:int -> unit -> 'a t
(** [create ()] creates a new empty queue with EBR node recycling.
    @param max_domains Maximum concurrent domains (default 16). *)

val init_domain : 'a t -> unit
(** Register the current domain. *)

val enq : 'a t -> 'a -> unit
(** [enq q x] appends [x] to the queue. Lock-free, never blocks. *)

val try_deq : 'a t -> 'a option
(** [try_deq q] removes and returns the first element, or [None]. *)

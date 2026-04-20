(** EBR-protected lock-free pool.

    Wraps {!Lockfree_pool} with {!Ebr} protection to prevent the ABA
    problem. [alloc] is wrapped in [enter]/[exit]; [free] calls [retire]
    directly (no enter/exit — the caller has finished using the node). *)

type 'a t

val create : capacity:int -> ?max_domains:int -> unit -> 'a t
val init_domain : 'a t -> unit
val alloc : 'a t -> 'a -> 'a Lockfree_pool.node option
val free : 'a t -> 'a Lockfree_pool.node -> unit
val get : 'a Lockfree_pool.node -> 'a
val set : 'a Lockfree_pool.node -> 'a -> unit
val alloc_fresh : 'a -> 'a Lockfree_pool.node

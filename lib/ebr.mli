(** Epoch-Based Reclamation (EBR) library.

    Based on K. Fraser, "Practical Lock-Freedom," PhD thesis,
    University of Cambridge, 2004, Chapter 5.

    Architecture:
    - Global epoch counter (monotonically increasing).
    - Fixed-size global array of per-domain records, each containing
      [local_epoch], [active_count], and 3 limbo buckets.
    - [enter] is re-entrant: increments [active_count] (not a bool).
    - [exit] decrements [active_count].
    - [retire] adds nodes to the current epoch's limbo bucket.
    - Each domain frees its own limbo on [enter] (not the advancer).
    - Epoch advances when all active domains have [local_epoch >= global_epoch]. *)

type 'a t
(** An EBR instance. ['a] is the type of managed pointers. *)

val create : max_domains:int -> 'a t
(** [create ~max_domains] creates a new EBR instance. *)

val init_domain : 'a t -> unit
(** Register the current domain. Called automatically on first use. *)

val enter : 'a t -> unit
(** Enter a critical section. Re-entrant: nested [enter]/[exit] pairs
    are safe — only the outermost [exit] marks the domain as inactive.
    On entry, attempts to free old limbo nodes from epoch [e-2]. *)

val exit : 'a t -> unit
(** Exit the critical section. Decrements [active_count]. *)

val retire : 'a t -> 'a -> ('a -> unit) -> unit
(** [retire ebr node cleanup] adds [node] to the current epoch's limbo list.
    Attempts to advance the global epoch. Nodes are freed by their owning
    domain on the next [enter] after the epoch has advanced sufficiently. *)

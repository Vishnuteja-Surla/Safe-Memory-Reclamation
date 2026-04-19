(** Hazard Pointer library for safe memory reclamation.

    Based on M. M. Michael, "Hazard Pointers: Safe Memory Reclamation
    for Lock-Free Objects," IEEE TPDS, 2004.

    Architecture: a fixed-size global array of HP slots (pre-allocated at
    [create] time). Each domain is assigned a contiguous slice via
    [init_domain]. Scanning reads the entire array — no cross-domain
    DLS access needed.

    The caller MUST use the load-publish-verify pattern around [protect]:
    {[
      let value = Atomic.get source in
      HP.protect hp 0 value;
      if Atomic.get source == value then
        (* value is safely protected *)
      else
        (* retry *)
    ]} *)

type 'a t
(** A hazard pointer domain. ['a] is the type of protected pointers. *)

val create : max_domains:int -> max_hp_per_domain:int -> retire_threshold:int -> 'a t
(** [create ~max_domains ~max_hp_per_domain ~retire_threshold] allocates
    a global array of [max_domains * max_hp_per_domain] HP slots. *)

val init_domain : 'a t -> unit
(** Register the current domain. Called automatically on first use of
    [protect]/[release]/[retire], but explicit init avoids startup races. *)

val protect : 'a t -> int -> 'a -> unit
(** [protect hp slot value] publishes [value] in HP slot [slot].
    The caller must perform load-publish-verify externally. *)

val release : 'a t -> int -> unit
(** [release hp slot] clears HP slot [slot]. *)

val retire : 'a t -> 'a -> ('a -> unit) -> unit
(** [retire hp node cleanup] adds [node] to the per-domain retired list.
    When the list exceeds [retire_threshold], scans all HP slots and
    reclaims (calls [cleanup] on) nodes not protected by any domain.
    Physical equality ([==]) is used for pointer comparison. *)

val scan : 'a t -> unit
(** [scan hp] forces an immediate scan of all HP slots and reclaims
    unprotected retired nodes. Normally called automatically by [retire]. *)

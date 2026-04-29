(** Hazard Pointer library for safe memory reclamation.

    Based on M. M. Michael, "Hazard Pointers: Safe Memory Reclamation
    for Lock-Free Objects," IEEE TPDS, 2004.

    Key design:
    - Global fixed-size array of HP slots, pre-allocated at [create].
    - Each domain gets a contiguous slice assigned at [init_domain].
    - [retire] adds nodes to a per-domain retired list; when it exceeds
      the threshold, [scan] reads ALL slots and reclaims unprotected nodes.
    - Physical equality ([==]) is used for pointer comparison. *)

(** A retired node awaiting reclamation. *)
type 'a retired_node = {
  node : 'a;
  cleanup : 'a -> unit;
}

(** Per-domain hazard pointer record. *)
type 'a domain_record = {
  domain_id : int;
  base_idx : int;              (** Base index into global [slots] array *)
  retired : 'a retired_node list ref;
  retired_count : int ref;
}

(** The hazard pointer domain. *)
type 'a t = {
  slots : 'a option Atomic.t array;    (** Global HP slots *)
  hp_per_domain : int;
  max_domains : int;
  retire_threshold : int;
  num_domains : int Atomic.t;
  domain_key : 'a domain_record Domain.DLS.key;
}

(** [create ~max_domains ~max_hp_per_domain ~retire_threshold] allocates
    the global HP slot array and returns a new HP domain. *)
let create ~max_domains ~max_hp_per_domain ~retire_threshold =
  let total_slots = max_domains * max_hp_per_domain in
  let slots = Array.init total_slots (fun _ -> Atomic.make None) in
  let num_domains = Atomic.make 0 in
  let domain_key = Domain.DLS.new_key (fun () ->
    let id = Atomic.fetch_and_add num_domains 1 in
    if id >= max_domains then begin
      ignore (Atomic.fetch_and_add num_domains (-1));
      failwith "hazard_pointer: too many domains registered"
    end;
    { domain_id = id;
      base_idx = id * max_hp_per_domain;
      retired = ref [];
      retired_count = ref 0 }
  ) in
  { slots; hp_per_domain = max_hp_per_domain;
    max_domains; retire_threshold; num_domains; domain_key }

(** Get or create the per-domain record for the calling domain. *)
let get_record t = Domain.DLS.get t.domain_key

(** [init_domain t] eagerly registers the current domain. *)
let init_domain t = ignore (get_record t)

(** [protect t slot value] publishes [value] in the calling domain's
    HP slot [slot]. The caller must then re-read the source and verify
    with physical equality before proceeding. *)
let protect t slot value =
  let r = get_record t in
  if slot < 0 || slot >= t.hp_per_domain then
    invalid_arg "Hazard_pointer.protect: slot index out of bounds";
  Atomic.set t.slots.(r.base_idx + slot) (Some value)

(** [release t slot] clears the calling domain's HP slot [slot]. *)
let release t slot =
  let r = get_record t in
  if slot < 0 || slot >= t.hp_per_domain then
    invalid_arg "Hazard_pointer.release: slot index out of bounds";
  Atomic.set t.slots.(r.base_idx + slot) None

(** Collect all currently protected pointers from ALL domains. *)
let collect_protected t =
  let nd = min (Atomic.get t.num_domains) t.max_domains in
  let n = nd * t.hp_per_domain in
  let protected = ref [] in
  for i = 0 to n - 1 do
    match Atomic.get t.slots.(i) with
    | None -> ()
    | Some ptr -> protected := ptr :: !protected
  done;
  !protected

(** [scan t] scans all HP slots and reclaims retired nodes that are
    not protected by any domain. Each reclaimed node has its [cleanup]
    function called. *)
let scan t =
  let r = get_record t in
  let protected = collect_protected t in
  let new_retired = ref [] in
  let new_count = ref 0 in
  List.iter (fun (rn : 'a retired_node) ->
    if List.exists (fun p -> p == rn.node) protected then begin
      (* Still protected — keep in retired list *)
      new_retired := rn :: !new_retired;
      incr new_count
    end else
      (* Not protected — safe to reclaim *)
      rn.cleanup rn.node
  ) !(r.retired);
  r.retired := !new_retired;
  r.retired_count := !new_count

(** [retire t node cleanup] adds [node] to the per-domain retired list.
    If the list exceeds [retire_threshold], triggers a [scan]. *)
let retire t node cleanup =
  let r = get_record t in
  r.retired := { node; cleanup } :: !(r.retired);
  r.retired_count := !(r.retired_count) + 1;
  if !(r.retired_count) >= t.retire_threshold then
    scan t

(** [retired_count t] returns the calling domain's pending retired count. *)
let retired_count t =
  let r = get_record t in
  !(r.retired_count)

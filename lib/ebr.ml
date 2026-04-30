(** Epoch-Based Reclamation (EBR) library.

    Based on K. Fraser, "Practical Lock-Freedom," PhD thesis,
    University of Cambridge, 2004, Chapter 5.

    Three-epoch rotation scheme:
    - Nodes retired during epoch [e] go into limbo bucket [e mod 3].
    - Epoch advances from [e] to [e+1] when all active domains have
      [local_epoch >= e].
    - Bucket [(e+1) mod 3] (≡ [e-2 mod 3]) is safe to free because
      all active domains started their critical section at or after
      epoch [e-1], so they cannot hold references to nodes retired
      in epoch [e-2] or earlier. *)

(** A retired node awaiting reclamation. *)
type 'a retired_node = {
  node : 'a;
  cleanup : 'a -> unit;
}

(** Per-domain EBR record. All fields are globally visible (not DLS). *)
type 'a domain_record = {
  local_epoch : int Atomic.t;
  active_count : int Atomic.t;
  limbo : 'a retired_node list ref array;  (** 3 buckets, indexed by epoch mod 3 *)
}

(** The EBR instance. *)
type 'a t = {
  global_epoch : int Atomic.t;
  records : 'a domain_record array;
  max_domains : int;
  num_domains : int Atomic.t;
  domain_key : int Domain.DLS.key;  (** Stores the domain's index into [records] *)
}

(** Create a fresh domain record with empty limbo buckets. *)
let make_record () =
  { local_epoch = Atomic.make 0;
    active_count = Atomic.make 0;
    limbo = Array.init 3 (fun _ -> ref []) }

(** [create ~max_domains] allocates the global record array. *)
let create ~max_domains =
  let num_domains = Atomic.make 0 in
  let records = Array.init max_domains (fun _ -> make_record ()) in
  let domain_key = Domain.DLS.new_key (fun () ->
    let id = Atomic.fetch_and_add num_domains 1 in
    if id >= max_domains then begin
      ignore (Atomic.fetch_and_add num_domains (-1));
      failwith "ebr: too many domains registered"
    end;
    id
  ) in
  { global_epoch = Atomic.make 0;
    records; max_domains; num_domains; domain_key }

(** Get the calling domain's index. *)
let get_id t = Domain.DLS.get t.domain_key

(** Get the calling domain's record. *)
let get_record t =
  let id = get_id t in
  t.records.(id)

(** [init_domain t] eagerly registers the current domain. *)
let init_domain t = ignore (get_id t)

(** Free all nodes in a limbo bucket. Each node's cleanup is called. *)
let free_limbo_bucket (bucket : 'a retired_node list ref) =
  List.iter (fun rn -> rn.cleanup rn.node) !bucket;
  bucket := []

(** Try to advance the global epoch. Succeeds if all active domains
    have [local_epoch >= global_epoch]. *)
let try_advance_epoch t =
  let e = Atomic.get t.global_epoch in
  let n = min (Atomic.get t.num_domains) t.max_domains in
  let all_caught_up = ref true in
  let i = ref 0 in
  while !i < n && !all_caught_up do
    let r = t.records.(!i) in
    if Atomic.get r.active_count > 0 then begin
      if Atomic.get r.local_epoch < e then
        all_caught_up := false
    end;
    i := !i + 1
  done;
  if !all_caught_up then
    ignore (Atomic.compare_and_set t.global_epoch e (e + 1))

(** [enter t] enters a critical section.

    Ordering (corrected per audit):
    1. Read global epoch into local_epoch
    2. Increment active_count
    3. Try to free own old limbo bucket *)
let enter t =
  let r = get_record t in
  let e = Atomic.get t.global_epoch in
  Atomic.set r.local_epoch e;
  ignore (Atomic.fetch_and_add r.active_count 1);
  (* Free own limbo for epoch e-2 ≡ bucket (e+1) mod 3.
     Safe because epoch has advanced past e-2. *)
  free_limbo_bucket r.limbo.((e + 1) mod 3)

(** [exit t] exits the critical section. Decrements [active_count].
    Re-entrant: nested exit only decrements, doesn't deactivate
    until the outermost exit. *)
let exit t =
  let r = get_record t in
  ignore (Atomic.fetch_and_add r.active_count (-1))

(** [retire t node cleanup] adds [node] to the current epoch's limbo.
    Then attempts to advance the global epoch. *)
let retire t node cleanup =
  let r = get_record t in
  let e = Atomic.get t.global_epoch in
  r.limbo.(e mod 3) := { node; cleanup } :: !(r.limbo.(e mod 3));
  try_advance_epoch t

(** [force_flush t] advances the epoch enough to flush all limbo buckets.
    Only safe when the calling domain is the sole active domain. *)
let force_flush t =
  (* 3 cycles of enter/retire-dummy/exit to advance epoch by 3,
     covering all 3 limbo buckets *)
  for _ = 1 to 3 do
    enter t;
    retire t (Obj.magic ()) (fun _ -> ());
    exit t
  done;
  (* One final enter/exit to trigger freeing of the last bucket *)
  enter t;
  exit t

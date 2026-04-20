(* Unit_store — umbrella. Exposes the port signature and adapters.
 *
 * Callers that need to instantiate a functor parameterised by the port
 * use [module US : Unit_store.S = ...]. Production wires [Fs]; tests
 * (phase 2+) will wire [In_mem]. *)

module type S = Unit_store_intf.UNIT_STORE

(* Re-export the shared entry record so callers (Lifecycle, tests) can
   write [Unit_store.entry] without poking into the _intf submodule. *)
type entry = Unit_store_intf.entry = {
  main : string;
  dropin : string option;
}

module Fs = Fs
module In_mem = In_mem

(* Compile-time proof that each adapter satisfies [S]. Phase 3's
   [Lifecycle.Make (M) (US : S)] depends on this; surface any signature
   drift here, not at the functor application site. *)
module _ : S = Fs
module _ : S = In_mem

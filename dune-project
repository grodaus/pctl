(lang dune 3.0)
(name pctl)

(package
 (name pctl)
 (synopsis "declarative Nix spec -> systemd --user units")
 (depends
  (ocaml (>= 5.0))
  dune
  cmdliner
  eio
  eio_main
  caqti
  caqti-eio
  ctypes
  yojson
  ppx_deriving_yojson
  logs
  digestif
  alcotest
  qcheck-core
  qcheck-alcotest))

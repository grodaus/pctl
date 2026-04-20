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
  caqti-driver-sqlite3
  ctypes
  ctypes-foreign
  yojson
  ppx_deriving_yojson
  ppx_blob
  logs
  digestif
  re
  fpath
  alcotest
  qcheck-core
  qcheck-alcotest
  bisect_ppx))

/* Exports errno integers as OCaml primitives so the OCaml side can
 * match without hardcoding Linux ABI values. Each macro resolves
 * against the runtime system's <errno.h>. */

#define CAML_NAME_SPACE
#include <caml/mlvalues.h>
#include <errno.h>

CAMLprim value pctl_errno_ENOENT(value unit) {
  (void)unit;
  return Val_int(ENOENT);
}

CAMLprim value pctl_errno_ECONNREFUSED(value unit) {
  (void)unit;
  return Val_int(ECONNREFUSED);
}

CAMLprim value pctl_errno_ENOMEDIUM(value unit) {
  (void)unit;
#ifdef ENOMEDIUM
  return Val_int(ENOMEDIUM);
#else
  /* Non-Linux libc (e.g. musl without the Linux extension). -1 is
   * never a valid errno, so the hint branch simply won't match. */
  return Val_int(-1);
#endif
}

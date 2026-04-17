{pkgs}:
pkgs.runCommand "pctl-test-nu"
{
  nativeBuildInputs = [pkgs.nushell];
  src = ../../.;
} ''
  cp -r $src/pctl pctl
  cp -r $src/tests tests
  shopt -s nullglob
  fail=0
  for f in tests/nu/*_test.nu; do
    echo "::: running $f"
    if ! nu "$f"; then
      fail=1
    fi
  done
  if [ "$fail" != 0 ]; then
    echo "one or more nu tests failed"
    exit 1
  fi
  echo ok > $out
''

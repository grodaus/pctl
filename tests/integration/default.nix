{pkgs}:
pkgs.runCommand "pctl-integration-tests"
{
  nativeBuildInputs = [pkgs.nushell];
  src = ../../.;
} ''
  cp -r $src/pctl pctl
  cp -r $src/tests tests
  cp -r $src/templates templates 2>/dev/null || true

  export HOME=$TMPDIR/home
  mkdir -p "$HOME"

  shopt -s nullglob
  fail=0
  for f in tests/integration/*_test.nu; do
    echo "::: running $f"
    # fresh XDG_RUNTIME_DIR per test
    per_test_xdg=$(mktemp -d)
    if ! XDG_RUNTIME_DIR="$per_test_xdg" nu "$f"; then
      fail=1
    fi
  done
  if [ "$fail" != 0 ]; then
    echo "one or more integration tests failed"
    exit 1
  fi
  echo ok > $out
''

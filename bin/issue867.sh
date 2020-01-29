#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

die() { echo "fatal: $*" >&2; exit 1; }

if [[ ! -d "pex" ]]; then
  die "this script must be executed from the root directory of the repo"
fi

# a directory to hold test run data
TEMP=

setup_test_dir() {
  local ts
  ts=$(date -u '+%Y%m%d%H%M%S')
  TEMP="t/${ts}"
  mkdir -p "$TEMP"
}
setup_test_dir



echo "------------------------------------------" >&2
echo "Contents of /etc/pexrc" >&2
cat /etc/pexrc >&2
echo "/usr/bin/which python" >&2
/usr/bin/which python
echo "PATH" >&2
echo "------------------------------------------" >&2


ORIG_ETC_PEXRC=''
if [[ -f /etc/pexrc ]]; then
  ORIG_ETC_PEXRC="/etc/pexrc.$(date '+%Y%m%d%H%M%S')"
  sudo mv /etc/pexrc "$ORIG_ETC_PEXRC"
fi

cleanup() {
  [[ -n "${TEMP:-}" ]] && rm -rf "${TEMP}"
  if [[ -n "${ORIG_ETC_PEXRC}" && -f "${ORIG_ETC_PEXRC}" ]]; then
    sudo mv "${ORIG_ETC_PEXRC}" /etc/pexrc
  fi
}

trap cleanup EXIT

OUTPUT=""

TEST_NUM=1
bump_counter() {
  TEST_NUM=$((TEST_NUM + 1))
}

PEXDIR="$(pwd)"
PYTHON="${PEX_TEST_PYTHON:-python}"

[[ -n "${PYENV_VERSION}" ]] || die "PYENV_VERSION not set"

log() {
  printf ':log: %s\n' $* >&2
}

with_etc_pexrc() {
  sudo cp "${ORIG_ETC_PEXRC}" /etc/pexrc
}

with_no_etc_pexrc() {
  sudo rm -f /etc/pexrc
}

assert_output_ok() {
  if [[ "$OUTPUT" != "OK" ]]; then
    echo "FAIL! expected OK, got: $OUTPUT"
    exit 1
  fi
}

assert_output_not_ok() {
  if [[ "$OUTPUT" == "OK" ]]; then
    echo "FAIL! expected !OK, got: $OUTPUT"
    exit 1
  fi
}

report_output_ok() {
  if [[ "$OUTPUT" == "OK" ]]; then
    log "PASS"
  else
    log "FAIL"
  fi
}

OPTS_SPEC="\
test run options
--
reqs=torf       use requirements.txt or not (no-reqs)
venv=torf       use venv or not
pythonbin=py    which python to use
pexrc=torf      /etc/pexrc or not
quiet!          silence python output
"

make_and_run() {
  (
    set -euo pipefail
    local reqs venv python_bin
    reqs=f
    venv=f
    python_bin="$PYTHON"
    pexrc=f
    quiet=f

    eval "$(echo "$OPTS_SPEC" | git rev-parse --parseopt -- "$@" || echo exit $?)"

    while [ $# -gt 0 ]; do
      opt="$1"
      shift
      case "$opt" in
        --reqs) reqs="$1"; shift  ;;
        --venv) venv="$1"; shift ;;
        --pythonbin) python_bin="$1"; shift ;;
        --pexrc) pexrc="$1"; shift ;;
        --quiet) quiet=t ;;
      esac
    done

    log "reqs: ${reqs}, venv: ${venv}, python: ${python_bin}, /etc/pexrc: ${pexrc}"

    local t
    t="${TEMP}/${TEST_NUM}"
    mkdir -p "${t}"
    export PEX_ROOT="${t}/pexroot"
    mkdir -p "${PEX_ROOT}"

    export PEX_IGNORE_RCFILES=1

    cd "${t}"
    cat > "${t}/worked.py" <<EOS
import sys
def main():
  print("OK")
  sys.exit(0)

if __name__ == '__main__':
  main()
EOS

    if [[ "${venv}" == 't' ]]; then
      "$PYTHON" -m venv venv || die 'venv failed'
      . venv/bin/activate || die 'failed to create venv'

      # change the invoking python call to the virtualenv's python link
      python_bin=$(/usr/bin/which python)
    fi


    local args
    args=(
      "${python_bin}" -m pex
      -o "${t}/out.pex"
      -m worked
      -D "${t}"
      --disable-cache
    )

    if [[ "${reqs}" == 't' ]]; then
      cat > "${t}/requirements.txt" <<EOS
-i https://pypi.org/simple
more-itertools==8.1.0
EOS
      args+=(-r requirements.txt)
    fi

    if [[ "${pexrc}" == 't' ]]; then
      with_etc_pexrc
    else
      with_no_etc_pexrc
    fi

    log "exec: $(echo ${args[*]})"

    (
      if [[ "$quiet" == 't' ]]; then
        exec &>/dev/null
      fi
      PYTHONPATH="$PEXDIR" "${args[@]}"
    )

     [[ -f "${t}/out.pex" ]] && "${t}/out.pex"
  )
}



run() {
  log "test num: ${TEST_NUM}"
  with_no_etc_pexrc  # clear state to decide later
  OUTPUT="$(make_and_run "$@")" || true
  report_output_ok
  bump_counter
}

maj_min_python="python$(echo "${PYENV_VERSION}" |sed -E -e 's/(.*)\.[0-9]/\1/')"

for reqs in f t; do
  for pexrc in f t; do
    for python in python python3 "$maj_min_python"; do
      run --reqs=$reqs --venv=$venv --pythonbin=$python --pexrc=$pexrc --quiet
    done
  done
done

mv "${TEMP}" "test-run-$(date '+%Y%m%d%H%M%S')"


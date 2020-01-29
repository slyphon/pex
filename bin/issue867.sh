#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

die() { echo "fatal: $*" >&2; exit 1; }

if [[ ! -d "pex" ]]; then
  die "this script must be executed from the root directory of the repo"
fi

# a directory to hold test run data
TEMP="$(pwd)/t/$(date -u '+%Y%m%d%H%M%S')"

mkdir -p "$TEMP"
export TEMP

cat >&2 <<EOS
------------------------------------------

Contents of /etc/pexrc
$(cat /etc/pexrc)

/usr/bin/which python: $(/usr/bin/which python)

PATH: $PATH

------------------------------------------
EOS


ORIG_ETC_PEXRC=''
if [[ -f /etc/pexrc ]]; then
  ORIG_ETC_PEXRC="/etc/pexrc.$(date '+%Y%m%d%H%M%S')"
  sudo mv /etc/pexrc "$ORIG_ETC_PEXRC"
fi

cleanup() {
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

pyrealpath() {
  /usr/bin/python -c 'from __future__ import print_function; import os.path, sys; print("\n".join([os.path.realpath(p) for p in sys.argv[1:]]))' "$@"
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
rpath=torf      use realpath of python binary
"

make_and_run() {
  (
    set -euo pipefail

    local reqs venv python_bin pexrc quiet rpath
    reqs=f
    venv=f
    python_bin="$PYTHON"
    pexrc=f
    quiet=f
    rpath=f

    eval "$(echo "$OPTS_SPEC" | git rev-parse --parseopt -- "$@" || echo exit $?)"

    while [ $# -gt 0 ]; do
      opt="$1"
      shift
      case "$opt" in
        --reqs) reqs="$1"; shift  ;;
        --venv) venv="$1"; shift ;;
        --pythonbin) python_bin="$1"; shift ;;
        --pexrc) pexrc="$1"; shift ;;
        --rpath) rpath="$1"; shift ;;
        --) break ;;
        *) die "unrecognized option $opt" ;;
      esac
    done

    log "reqs: ${reqs}, realpath: ${rpath}, python: ${python_bin}, /etc/pexrc: ${pexrc}"

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


    if [[ "${rpath}" == "t" ]]; then
      python_bin="$(pyrealpath $(pyenv which "${python_bin}"))"
    fi

    local args
    args=(
      "${python_bin}" -m pex
      -v -v -v -v -v -v -v -v -v
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

    echo "PYTHONPATH=$PEXDIR ${args[@]}" > "${t}/command"

    PYTHONPATH="$PEXDIR" "${args[@]}" >"${t}/pex.out" 2>"${t}/pex.err"

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

main() {
  local reqs pexrc rpath python
  maj_min_python="python$(echo "${PYENV_VERSION}" |sed -E -e 's/(.*)\.[0-9]/\1/')"

  for reqs in f t; do
    for pexrc in f t; do
      for rpath in f t; do
        for python in python python3 "$maj_min_python"; do
          run --reqs="$reqs" --pythonbin="$python" --pexrc="$pexrc" --rpath="${rpath}"
        done
      done
    done
  done
}

main "$@"


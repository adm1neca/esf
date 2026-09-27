#!/usr/bin/env bash
# Runs an agent command and decides its outcome from checks, not from what the
# model says. In a workflow stage it writes the step result
# (MACHINIST_STEP_RESULT_PATH) itself: Machinist explains that contract only to
# Codex and Claude, and a local model cannot be relied on to write exact JSON.
# In a plain command run, a failed check becomes a non-zero exit status.
#
#   --require-output NAME  the stage must leave NAME in MACHINIST_OUTPUT_DIR
#   --require-commit       the stage must move HEAD in the repository
#
# Usage: opencode-step [--require-output NAME] [--require-commit] -- COMMAND...
set -uo pipefail

require_output=""
require_commit=false
while (($#)); do
  case $1 in
    --require-output) require_output=${2:?--require-output needs a file name}; shift 2 ;;
    --require-commit) require_commit=true; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
(($#)) || { echo "opencode-step: no command given" >&2; exit 2; }
[[ -z $require_output || $require_output =~ ^[A-Za-z0-9._-]+$ ]] \
  || { echo "opencode-step: invalid output file name" >&2; exit 2; }

# result OUTCOME SUMMARY: record the outcome. Summaries are fixed text plus
# validated values, so they need no JSON escaping.
result() {
  if [[ -n ${MACHINIST_STEP_RESULT_PATH:-} ]]; then
    printf '{"outcome":"%s","summary":"%s"}\n' "$1" "$2" >"$MACHINIST_STEP_RESULT_PATH"
  else
    printf 'opencode-step: %s: %s\n' "$1" "$2" >&2
  fi
}

# blocked SUMMARY: a workflow pauses on a blocked result; a plain run fails.
blocked() {
  result blocked "$1"
  [[ -n ${MACHINIST_STEP_RESULT_PATH:-} ]] && exit 0
  exit 3
}

head_before=$(git rev-parse -q --verify HEAD 2>/dev/null || true)

"$@"
status=$?
if ((status != 0)); then
  result failed "The agent exited with status $status. See the run log."
  exit "$status"
fi

if [[ -n $require_output && ! -s ${MACHINIST_OUTPUT_DIR:-}/$require_output ]]; then
  blocked "The agent finished without writing $require_output. Retry, or use a model that follows instructions more reliably."
fi

if $require_commit; then
  head_after=$(git rev-parse -q --verify HEAD 2>/dev/null || true)
  if [[ $head_after == "$head_before" ]]; then
    blocked "The agent finished without committing a change. See the run log for its explanation."
  fi
  branch=$(git symbolic-ref -q --short HEAD 2>/dev/null || echo "a detached HEAD")
  if [[ ! $branch =~ ^[A-Za-z0-9._/\ -]+$ ]]; then
    branch="a new branch"
  fi
  result complete "Committed ${head_after:0:12} on $branch. Review it before merging."
  exit 0
fi

if [[ -n $require_output ]]; then
  result complete "Wrote $require_output to the task files. Review it before approving the next stage."
else
  result complete "The agent finished. See the run log for its summary."
fi

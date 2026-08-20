#!/usr/bin/env bash
# Record and classify an investigation's framing before a scout is dispatched.
# A scout answers a question. When the captain stated that question, the scope is
# theirs. When they named only a subject - "investigate it", "audit X" - the
# question is firstmate's own invention, and dispatching it unconfirmed spends a
# whole investigation answering the wrong thing.
# Usage: fm-scout-framing.sh <task-id> --captain-words <text> --question <text>
#        fm-scout-framing.sh <task-id> --captain-words-file <path> --question-file <path>
#        fm-scout-framing.sh <task-id> --discovery
#        fm-scout-framing.sh <task-id> --verdict
# Records data/<task-id>/framing.md under the active firstmate home and prints the
# verdict. bin/fm-brief.sh reads that verdict and refuses --scope-given on a scout
# brief without it. .agents/skills/investigation-framing owns what to do with each.
#
# The classification is deliberately mechanical, and it runs on the captain's
# literal sentence rather than on firstmate's summary of it. Two independent tests
# must BOTH hold for the exemption:
#   1. The captain's own words state a question: they contain "?" or one of
#      whether, why, which, what, how, who, whom, whose. "if", "when" and "where"
#      are excluded on purpose - in a commission they are far more often temporal
#      or conditional ("before any conversion work starts", "where you can") than
#      interrogative, and a marker that grants an exemption wrongly is the only
#      expensive kind of mistake this script can make.
#   2. The question firstmate would send introduces no content word the captain
#      did not use. Function words, question words and the verbs of commissioning
#      an investigation are ignored; plural and tense variation is normalised.
# Either test failing yields "confirm-required". The script can therefore only ever
# DEMAND a confirmation; it never certifies a framing on thin evidence. That
# asymmetry is the point: an unnecessary confirmation costs the captain one line,
# and a wrongly framed investigation costs the whole investigation.
#
# Verdicts:
#   captain-framed    both tests hold; --scope-given is permitted on the scout brief.
#   confirm-required  the framing is firstmate's; confirm it with the captain, write
#                     data/<task-id>/requirement.md, and scaffold with --requirement.
#   discovery         declared, not classified: this scout's own deliverable IS the
#                     elicitation (requirement-elicitation's deep path). It permits
#                     --scope-given because it obligates the worker to run the
#                     discovery with the captain - it does not skip the framing.
#
# The record is append-only. Re-running adds a new block and leaves every earlier
# verdict in place, so a framing that was re-recorded until it passed is visible in
# the record rather than erased from it. The last verdict is the effective one.
#
# What this cannot check: firstmate could paraphrase the captain into --captain-words
# and pass a framing that is really its own. Nothing in a script can detect that.
# What the script does guarantee is that the paraphrase is written down verbatim,
# attributed to the captain, and kept - so the claim is falsifiable by anyone who
# reads the record beside what the captain actually said.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
else
  DATA="$FM_HOME/data"
fi

MODE=classify
CAPTAIN_WORDS=
CAPTAIN_SET=0
QUESTION=
QUESTION_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      captain-words) CAPTAIN_WORDS=$a; CAPTAIN_SET=1 ;;
      captain-words-file)
        [ -f "$a" ] || { echo "error: --captain-words-file names no readable file: $a" >&2; exit 1; }
        CAPTAIN_WORDS=$(cat -- "$a"); CAPTAIN_SET=1 ;;
      question) QUESTION=$a; QUESTION_SET=1 ;;
      question-file)
        [ -f "$a" ] || { echo "error: --question-file names no readable file: $a" >&2; exit 1; }
        QUESTION=$(cat -- "$a"); QUESTION_SET=1 ;;
      *) echo "error: internal parser state for --$want_value" >&2; exit 1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --captain-words) want_value=captain-words ;;
    --captain-words=*) CAPTAIN_WORDS=${a#--captain-words=}; CAPTAIN_SET=1 ;;
    --captain-words-file) want_value=captain-words-file ;;
    --question) want_value=question ;;
    --question=*) QUESTION=${a#--question=}; QUESTION_SET=1 ;;
    --question-file) want_value=question-file ;;
    --discovery) MODE=discovery ;;
    --verdict) MODE=verdict ;;
    --*) echo "error: unknown option: $a" >&2; exit 1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }

[ "${#POS[@]}" -eq 1 ] || {
  echo "error: exactly one <task-id> is required" >&2
  usage >&2
  exit 1
}
ID=${POS[0]}
RECORD="$DATA/$ID/framing.md"

# --verdict is the machine surface bin/fm-brief.sh reads. It prints the LAST
# recorded verdict token and nothing else, so the record's prose stays free to
# change without breaking the gate.
if [ "$MODE" = verdict ]; then
  [ "$CAPTAIN_SET" -eq 0 ] && [ "$QUESTION_SET" -eq 0 ] || {
    echo "error: --verdict reads the existing record and takes no other input" >&2
    exit 1
  }
  [ -f "$RECORD" ] || { echo "error: no framing recorded for $ID at $RECORD" >&2; exit 3; }
  last=$(grep '^Verdict: ' "$RECORD" | tail -n 1 | sed 's/^Verdict: //') || last=
  [ -n "$last" ] || { echo "error: $RECORD records no verdict" >&2; exit 3; }
  printf '%s\n' "$last"
  exit 0
fi

if [ "$MODE" = discovery ]; then
  [ "$CAPTAIN_SET" -eq 0 ] && [ "$QUESTION_SET" -eq 0 ] || {
    echo "error: --discovery is a declaration about this scout's deliverable, not a classification; drop --captain-words and --question" >&2
    exit 1
  }
else
  [ "$CAPTAIN_SET" -eq 1 ] || {
    echo "error: --captain-words (or --captain-words-file) is required: paste the captain's own request verbatim, because the classification runs on their words and not on your reading of them" >&2
    exit 1
  }
  [ "$QUESTION_SET" -eq 1 ] || {
    echo "error: --question (or --question-file) is required: write down the one question you would send the scout to answer, because that framing is the thing being checked" >&2
    exit 1
  }
  case "$CAPTAIN_WORDS" in
    *[![:space:]]*) ;;
    *) echo "error: --captain-words is empty; an empty quote is not a captain framing" >&2; exit 1 ;;
  esac
  case "$QUESTION" in
    *[![:space:]]*) ;;
    *) echo "error: --question is empty; if you cannot state the question, the framing is not settled" >&2; exit 1 ;;
  esac
fi

# Function words, question words, and the verbs of commissioning an investigation.
# Deliberately short: every word left OUT of this list can only make the novelty
# test stricter, which is the safe direction.
STOPWORDS='the and or but nor for yet so than then that this these those there here
with without within into onto from about across over under after before during while
when where why how what which who whom whose whether if
all any both each every few many more most much other another some such own same too very just now next also per via
not only still already again ever never
its their they them our your his her hers him she you are was were been being
has have had having will would shall should can could may might must does did done doing
need needs let make makes making get got
investigate investigation audit review examine explore check find look report tell show dig
determine assess understand confirm verify scout answer question inspect
please thanks work works'

# Normalised, deduplicated content words of one text file, one per line.
# The stoplist is tested against both the raw and the normalised form so it can be
# written in natural English rather than in the normaliser's output alphabet.
content_words() {
  LC_ALL=C awk -v stop="$STOPWORDS" '
    function norm(w,  n) {
      n = length(w)
      if (n > 4 && w ~ /ies$/) return substr(w, 1, n - 3) "y"
      if (n > 4 && w ~ /(sses|xes|zes|ches|shes)$/) return substr(w, 1, n - 2)
      if (n > 5 && w ~ /ing$/) return substr(w, 1, n - 3)
      if (n > 4 && w ~ /ed$/) return substr(w, 1, n - 2)
      if (n > 3 && w ~ /[^s]s$/) return substr(w, 1, n - 1)
      return w
    }
    BEGIN { m = split(stop, sw, /[ \n]+/); for (i = 1; i <= m; i++) if (sw[i] != "") stopw[sw[i]] = 1 }
    {
      for (i = 1; i <= NF; i++) {
        raw = tolower($i)
        gsub(/[^a-z0-9]/, "", raw)
        if (length(raw) < 3) continue
        t = norm(raw)
        if (raw in stopw || t in stopw) continue
        if (!(t in seen)) { seen[t] = 1; print t }
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

# Test A: do the captain's own words state a question at all?
captain_states_a_question() {
  case "$1" in *'?'*) return 0 ;; esac
  printf '%s\n' "$1" \
    | LC_ALL=C grep -Eiq '(^|[^[:alnum:]])(whether|why|which|what|how|who|whom|whose)([^[:alnum:]]|$)'
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

VERDICT=
REASONS=()
NOVEL=
MARKER=
if [ "$MODE" = discovery ]; then
  VERDICT=discovery
else
  TMPDIR_FRAMING=$(mktemp -d "${TMPDIR:-/tmp}/fm-scout-framing.XXXXXX")
  trap 'rm -rf "$TMPDIR_FRAMING"' EXIT
  printf '%s\n' "$CAPTAIN_WORDS" > "$TMPDIR_FRAMING/captain.txt"
  printf '%s\n' "$QUESTION" > "$TMPDIR_FRAMING/question.txt"
  content_words "$TMPDIR_FRAMING/captain.txt" > "$TMPDIR_FRAMING/captain.words"
  content_words "$TMPDIR_FRAMING/question.txt" > "$TMPDIR_FRAMING/question.words"
  NOVEL=$(LC_ALL=C comm -13 "$TMPDIR_FRAMING/captain.words" "$TMPDIR_FRAMING/question.words" | paste -sd, - | sed 's/,/, /g')

  if captain_states_a_question "$CAPTAIN_WORDS"; then
    MARKER=yes
    REASONS+=("The captain's own words state a question, so the subject of the investigation is not all they gave.")
  else
    MARKER=no
    REASONS+=("The captain's own words state no question: they name a subject and an activity, which leaves the question's boundary for firstmate to invent.")
  fi

  if [ -z "$NOVEL" ]; then
    REASONS+=("The question introduces no word the captain did not use, so it is their framing rather than a wider one.")
  else
    REASONS+=("The question introduces words the captain did not use: $NOVEL.")
  fi

  if [ "$MARKER" = yes ] && [ -z "$NOVEL" ]; then
    VERDICT=captain-framed
  else
    VERDICT=confirm-required
  fi
fi

mkdir -p "$DATA/$ID"
PRIOR=
if [ -f "$RECORD" ]; then
  PRIOR=$(grep '^Verdict: ' "$RECORD" | tail -n 1 | sed 's/^Verdict: //') || PRIOR=
else
  # shellcheck disable=SC2016 # Backticks are literal Markdown in the record, not a command substitution.
  printf '# Investigation framing - %s\n\nEvery framing recorded for this task, oldest first. The last verdict is the one\n`bin/fm-brief.sh` enforces; earlier blocks are kept so a re-recorded framing stays visible.\n' \
    "$ID" > "$RECORD"
fi

{
  printf '\n---\n\n'
  printf 'Verdict: %s\n' "$VERDICT"
  printf 'Recorded: %s\n' "$(now_iso)"
  if [ -n "$PRIOR" ]; then
    printf 'Supersedes: %s\n' "$PRIOR"
  fi
  printf '\n'
  if [ "$MODE" = discovery ]; then
    cat <<'BLOCK'
## What was declared

This scout's own deliverable is the elicitation itself: `requirement-elicitation`'s
deep path, where the worker runs Crucible's `discover` inside the project and writes
the requirement beside its report.

## What the declaration obligates

The generated brief must instruct the worker to run that discovery with the captain
and to write `requirement.md` into this task's own `data/<task-id>/` directory, never
into the project. This verdict permits `--scope-given` because it commits the task to
more elicitation, not less. Claiming it for an ordinary investigation buys nothing: it
produces a worker that interviews the captain.
BLOCK
  else
    printf '## The captain'"'"'s words, verbatim\n\n'
    printf '%s\n' "$CAPTAIN_WORDS" | sed 's/^/> /'
    printf '\n## The question this investigation would answer\n\n'
    printf '%s\n' "$QUESTION" | sed 's/^/> /'
    printf '\n## Why this verdict\n\n'
    for reason in "${REASONS[@]}"; do
      printf -- '- %s\n' "$reason"
    done
    printf '\n## What firstmate owes before dispatch\n\n'
    if [ "$VERDICT" = captain-framed ]; then
      cat <<'BLOCK'
Nothing further. The scout brief may be scaffolded with `--scope-given`. The verbatim
quote above is the evidence for that exemption, and it is checkable against what the
captain actually said.
BLOCK
    else
      cat <<'BLOCK'
Put the question above to the captain in their own terms - one or two lines in the
terminal, not an interview - and take their answer as the framing. Write the result to
this task's `requirement.md` and scaffold the scout with `--requirement`, not
`--scope-given`. If their answer shows the question is not yet knowable, escalate into
`requirement-elicitation`'s light or deep path instead of guessing again.
BLOCK
    fi
  fi
} >> "$RECORD"

printf 'verdict: %s\n' "$VERDICT"
printf 'recorded: %s\n' "$RECORD"
if [ "$MODE" != discovery ]; then
  for reason in "${REASONS[@]}"; do
    printf -- '- %s\n' "$reason"
  done
fi
case "$VERDICT" in
  confirm-required)
    printf 'next: confirm this framing with the captain, write %s/%s/requirement.md, and scaffold with --requirement\n' "$DATA" "$ID" ;;
  captain-framed|discovery)
    printf 'next: the scout brief may be scaffolded with --scope-given\n' ;;
esac

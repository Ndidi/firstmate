#!/usr/bin/env bash
# Behavior tests for bin/fm-scout-framing.sh and the scout framing gate it arms
# in bin/fm-brief.sh.
#
# These pin the acceptance fixtures the captain set on 2026-08-20 after two
# investigations came back answering questions they rejected. The two real
# requests are exercised verbatim, because the whole failure was that firstmate
# read those exact sentences as carrying their own scope. The three not-firing
# fixtures are exercised too: a rule that fires in front of a typo is a failure
# of this feature, not a cautious success, and only a test can hold that line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FRAMING="$ROOT/bin/fm-scout-framing.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-scout-framing)

# The captain's two real requests, verbatim. Both must come out as needing their
# framing confirmed: the first gives the subject but not the question's boundary,
# the second gives no question at all.
PIXELTALE_AUDIT='Audit every category for divergence from beanheads now, and report before deciding fixes'
PIXELTALE_SCOUT='Investigate it first as its own scout, before any conversion work starts'
# The question firstmate actually sent a worker to answer for the second one, and
# the framing the captain rejected outright when the answer came back.
INVENTED_QUESTION='How does a newly commissioned Figma component declare its colour slots?'

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

test_script_parses() {
  local out rc
  out=$(bash -n "$FRAMING" 2>&1); rc=$?
  expect_code 0 "$rc" "bash -n bin/fm-scout-framing.sh must parse cleanly (got: $out)"
  [ -z "$out" ] || fail "bash -n bin/fm-scout-framing.sh emitted unexpected output: $out"
  pass "fm-scout-framing.sh: bash -n succeeds"
}

test_help_states_the_contract() {
  local out
  out=$("$FRAMING" --help 2>&1)
  assert_contains "$out" "captain-framed" "help does not name the permitting verdict"
  assert_contains "$out" "confirm-required" "help does not name the refusing verdict"
  assert_contains "$out" "discovery" "help does not name the discovery declaration"
  assert_contains "$out" "append-only" "help does not state that the record is append-only"
  assert_contains "$out" "paraphrase" "help does not disclose the limit the check cannot cover"
  pass "fm-scout-framing.sh: --help states the verdicts, the record contract, and the known limit"
}

# THE ACCEPTANCE FIXTURES. All five are driven end to end through the real
# scripts, so "it classifies them correctly" is demonstrated rather than
# asserted. Firing means a scout brief cannot be scaffolded on firstmate's own
# word; not firing means the ordinary ship scaffold is untouched and costs
# nothing new.
test_acceptance_fixtures() {
  local home id label kind words question expect out status brief
  home=$(new_home fixtures)
  id=0
  while IFS='|' read -r label kind words question expect; do
    [ -n "$label" ] || continue
    id=$((id + 1))
    case "$kind" in
      scout)
        out=$(FM_HOME="$home" "$FRAMING" "fixture-$id" \
          --captain-words "$words" --question "$question" 2>&1)
        status=$?
        expect_code 0 "$status" "$label: recording the framing should succeed"
        assert_contains "$out" "verdict: $expect" \
          "$label: framing verdict is not $expect"
        FM_HOME="$home" "$BRIEF" "fixture-$id" some-proj --scout --scope-given >/dev/null 2>&1
        status=$?
        [ "$status" -ne 0 ] || fail "$label: a scout brief was scaffolded on firstmate's own framing"
        assert_absent "$home/data/fixture-$id/brief.md" \
          "$label: refused scaffold still wrote a brief"
        ;;
      ship)
        # No framing record exists for these, and none is owed: the gate must
        # not appear in front of ordinary implementation work.
        FM_HOME="$home" "$BRIEF" "fixture-$id" some-proj --mode local-only --scope-given >/dev/null 2>&1
        status=$?
        expect_code 0 "$status" "$label: an ordinary ship brief must still scaffold with --scope-given"
        brief="$home/data/fixture-$id/brief.md"
        assert_present "$brief" "$label: ship brief was not scaffolded"
        assert_absent "$home/data/fixture-$id/framing.md" \
          "$label: a ship task was made to record an investigation framing"
        assert_no_grep "# Requirement" "$brief" \
          "$label: ship brief grew a requirement section it has no document for"
        ;;
      *) fail "$label: unknown fixture kind $kind" ;;
    esac
  done <<ROWS
audit whose boundary the captain never set|scout|$PIXELTALE_AUDIT|Which categories diverge from beanheads, and how?|confirm-required
investigation whose question firstmate invented|scout|$PIXELTALE_SCOUT|$INVENTED_QUESTION|confirm-required
fix this typo|ship|||
version bump or rename|ship|||
bug fix carrying a reproduction|ship|||
settled follow-up inheriting finished context|ship|||
ROWS
  pass "fm-scout-framing: both real investigations need their framing confirmed and no ship task pays for it"
}

# The exemption exists and is reachable, otherwise the rule would just be an
# interview in front of everything. It is granted only when firstmate can state
# the scout's question in the captain's own words.
test_a_question_the_captain_asked_is_exempt() {
  local home out status brief
  home=$(new_home exempt)
  out=$(FM_HOME="$home" "$FRAMING" exempt-1 \
    --captain-words 'Find out whether the export pipeline strips the alpha channel.' \
    --question 'Does the export pipeline strip the alpha channel?' 2>&1)
  status=$?
  expect_code 0 "$status" "recording a captain-framed investigation should succeed"
  assert_contains "$out" "verdict: captain-framed" \
    "a question the captain actually asked was not treated as their framing"

  FM_HOME="$home" "$BRIEF" exempt-1 some-proj --scout --scope-given >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "a captain-framed scout must scaffold with --scope-given"
  brief="$home/data/exempt-1/brief.md"
  assert_present "$brief" "captain-framed scout brief was not scaffolded"
  assert_grep "SCOUT task" "$brief" "captain-framed scaffold did not produce a scout brief"

  # A diagnosis the captain framed themselves is exempt on the same terms, so
  # "why is X broken" never turns into an interview.
  out=$(FM_HOME="$home" "$FRAMING" exempt-2 \
    --captain-words 'Investigate why CI is red.' \
    --question 'Why is CI red?' 2>&1)
  assert_contains "$out" "verdict: captain-framed" \
    "a diagnosis question the captain stated was not treated as their framing"
  pass "fm-scout-framing: a question stated in the captain's own words needs no confirmation"
}

# The narrower half of the failure: the captain DID ask a question, and firstmate
# widened it on the way to the worker. Recognising only "no question at all"
# would miss the audit fixture, whose subject was given and whose boundary was not.
test_a_widened_question_loses_the_exemption() {
  local home out
  home=$(new_home widened)
  out=$(FM_HOME="$home" "$FRAMING" widened-1 \
    --captain-words 'Find out whether the export pipeline strips the alpha channel.' \
    --question 'Does the export pipeline strip the alpha channel, and should we pin the shellcheck version?' 2>&1)
  assert_contains "$out" "verdict: confirm-required" \
    "a question widened past the captain's words kept its exemption"
  assert_contains "$out" "words the captain did not use" \
    "the refusal did not say which half of the check failed"
  assert_contains "$out" "shellcheck" \
    "the refusal did not name the vocabulary firstmate introduced"
  pass "fm-scout-framing: a question widened beyond the captain's words loses the exemption"
}

# The record is the artifact that makes the judgement checkable after the fact,
# so it has to carry the captain's words verbatim, the question, and the reason.
test_the_record_carries_the_evidence() {
  local home record
  home=$(new_home record)
  FM_HOME="$home" "$FRAMING" record-1 \
    --captain-words "$PIXELTALE_SCOUT" --question "$INVENTED_QUESTION" >/dev/null 2>&1 \
    || fail "recording a framing should succeed"
  record="$home/data/record-1/framing.md"
  assert_present "$record" "no framing record was written"
  assert_grep "Verdict: confirm-required" "$record" "record does not carry a machine-readable verdict"
  assert_grep "$PIXELTALE_SCOUT" "$record" "record does not carry the captain's words verbatim"
  assert_grep "$INVENTED_QUESTION" "$record" "record does not carry the question that would have been sent"
  assert_grep "requirement.md" "$record" "record does not name what firstmate owes before dispatch"
  assert_grep "not an interview" "$record" \
    "record does not bound the confirmation to something cheap"
  pass "fm-scout-framing: the record carries the verbatim quote, the question, and the reason"
}

# Re-recording must not erase what came before: a framing that was re-run until
# it passed is exactly the abuse this design has to keep visible.
test_the_record_is_append_only() {
  local home record out
  home=$(new_home append)
  FM_HOME="$home" "$FRAMING" append-1 \
    --captain-words "$PIXELTALE_SCOUT" --question "$INVENTED_QUESTION" >/dev/null 2>&1 \
    || fail "first framing record should succeed"
  FM_HOME="$home" "$FRAMING" append-1 \
    --captain-words 'Find out whether the exporter drops slots.' \
    --question 'Does the exporter drop slots?' >/dev/null 2>&1 \
    || fail "re-recording a framing should succeed"
  record="$home/data/append-1/framing.md"
  assert_grep "Verdict: confirm-required" "$record" "the superseded verdict was erased"
  assert_grep "Verdict: captain-framed" "$record" "the new verdict was not recorded"
  assert_grep "Supersedes: confirm-required" "$record" \
    "the record does not show that an earlier verdict was replaced"
  assert_grep "$INVENTED_QUESTION" "$record" "the superseded framing's evidence was erased"
  out=$(FM_HOME="$home" "$FRAMING" append-1 --verdict 2>&1)
  assert_contains "$out" "captain-framed" "--verdict did not report the last recorded verdict"
  [ "$(printf '%s' "$out" | wc -l)" -eq 0 ] \
    || fail "--verdict printed more than the bare token"
  pass "fm-scout-framing: re-recording appends and the last verdict is the effective one"
}

# A discovery scout's own deliverable IS the elicitation, so it is declared
# rather than classified - and the declaration has to state what it obligates,
# because an exemption that buys silence would reopen the hole.
test_discovery_is_declared_and_obligating() {
  local home out status record
  home=$(new_home discovery)
  out=$(FM_HOME="$home" "$FRAMING" disc-1 --discovery 2>&1)
  status=$?
  expect_code 0 "$status" "declaring a discovery scout should succeed"
  assert_contains "$out" "verdict: discovery" "the discovery declaration was not recorded as such"
  record="$home/data/disc-1/framing.md"
  assert_grep "discover" "$record" "the discovery record does not name the elicitation the worker owes"
  assert_grep "never" "$record" "the discovery record does not keep the requirement out of the project"
  FM_HOME="$home" "$BRIEF" disc-1 some-proj --scout --scope-given >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "a declared discovery scout must scaffold with --scope-given"

  out=$(FM_HOME="$home" "$FRAMING" disc-2 --discovery --question 'Anything?' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--discovery mixed with a classification input should be refused"
  assert_contains "$out" "not a classification" "the refusal did not explain why the inputs conflict"
  pass "fm-scout-framing: --discovery is a declaration that obligates the worker to elicit"
}

# A confirmed framing reaches the worker as a requirement document, which is the
# path this whole feature exists to force. It must stay open with no framing
# record at all: the document IS the confirmed framing.
test_a_requirement_document_needs_no_framing_record() {
  local home req status brief
  home=$(new_home requirement)
  req="$home/requirement.md"
  printf '# Requirement\nThe captain confirmed this framing.\n' > "$req"
  FM_HOME="$home" "$BRIEF" req-scout some-proj --scout --requirement "$req" >/dev/null 2>&1
  status=$?
  expect_code 0 "$status" "a scout brief built from a requirement document must scaffold"
  brief="$home/data/req-scout/brief.md"
  assert_present "$brief" "scout brief with a requirement was not scaffolded"
  assert_grep "$req" "$brief" "scout brief did not link the requirement document"
  assert_absent "$home/data/req-scout/framing.md" \
    "a scout with a requirement document was made to record a framing as well"
  pass "fm-brief: a scout built from a requirement document needs no separate framing record"
}

# The gate has to fail closed. A check that quietly allows dispatch whenever its
# evidence is unreadable looks enforced while being optional, which is the exact
# shape of the failure this replaces.
test_the_gate_fails_closed() {
  local home status record bindir out
  home=$(new_home failclosed)

  # No record at all.
  out=$(FM_HOME="$home" "$BRIEF" fc-1 some-proj --scout --scope-given 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout with no framing record was scaffolded"
  assert_contains "$out" "fm-scout-framing.sh fc-1" \
    "the refusal did not hand back the command that records the framing"
  assert_contains "$out" "investigation-framing" \
    "the refusal did not name the skill that owns the rule"

  # A record that carries no verdict at all.
  mkdir -p "$home/data/fc-2"
  printf '# Investigation framing - fc-2\n\nnothing machine-readable here\n' > "$home/data/fc-2/framing.md"
  FM_HOME="$home" "$BRIEF" fc-2 some-proj --scout --scope-given >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "a framing record with no verdict was accepted"

  # A record whose last verdict is not one that permits dispatch.
  mkdir -p "$home/data/fc-3"
  record="$home/data/fc-3/framing.md"
  printf 'Verdict: captain-framed\nVerdict: confirm-required\n' > "$record"
  FM_HOME="$home" "$BRIEF" fc-3 some-proj --scout --scope-given >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an earlier permitting verdict overrode the current one"

  # The classifier itself missing must refuse rather than wave the brief through.
  bindir="$TMP_ROOT/bin-without-framing"
  mkdir -p "$bindir"
  cp "$ROOT"/bin/fm-brief.sh "$ROOT"/bin/fm-marker-lib.sh "$ROOT"/bin/fm-classify-lib.sh "$bindir/"
  mkdir -p "$home/data/fc-4"
  printf 'Verdict: captain-framed\n' > "$home/data/fc-4/framing.md"
  FM_HOME="$home" "$bindir/fm-brief.sh" fc-4 some-proj --scout --scope-given >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "a missing classifier let a scout scaffold on an unverified record"
  pass "fm-brief: the scout framing gate refuses on absent, unreadable, stale, or uncheckable evidence"
}

# The classification runs on the captain's literal sentence and on the question
# firstmate would send. Refusing to guess either of them is what keeps the check
# from sliding back into firstmate grading its own reading.
test_both_texts_are_required_and_never_guessed() {
  local home out status label args
  home=$(new_home usage)
  while IFS='|' read -r label args; do
    [ -n "$label" ] || continue
    # shellcheck disable=SC2086  # args is an intentional word-split arg list
    out=$(FM_HOME="$home" "$FRAMING" usage-task $args 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
  done <<ROWS
no inputs at all|
question without the captain's words|--question Anything?
captain's words without a question|--captain-words Investigate
value-less flag|--captain-words --question
unknown option|--captain-words Investigate --question Anything? --nope
ROWS

  # A blank value carries no quote and no question, so it must be refused rather
  # than recorded as evidence of either. The table above word-splits, so these
  # two cases can only be driven with real quoting.
  out=$(FM_HOME="$home" "$FRAMING" usage-blank-words --captain-words '   ' --question 'Does it?' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a blank captain quote should be refused"
  assert_contains "$out" "empty quote is not a captain framing"     "the blank-quote refusal did not explain itself"
  out=$(FM_HOME="$home" "$FRAMING" usage-blank-question --captain-words 'Investigate whether it works' --question '  ' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a blank question should be refused"
  assert_contains "$out" "the framing is not settled"     "the blank-question refusal did not explain itself"
  assert_absent "$home/data/usage-blank-words/framing.md"     "a refused framing still wrote a record"

  out=$(FM_HOME="$home" "$FRAMING" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing task id should be refused"
  out=$(FM_HOME="$home" "$FRAMING" a b --verdict 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "two task ids should be refused"
  out=$(FM_HOME="$home" "$FRAMING" never-recorded --verdict 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--verdict on an unrecorded task should be refused"
  assert_contains "$out" "no framing recorded" "--verdict did not explain the absent record"
  pass "fm-scout-framing: both texts are required and a missing record is never read as a pass"
}

# File-based input exists so a long or awkwardly quoted captain request is pasted
# rather than retyped - retyping is where a verbatim quote quietly becomes a
# paraphrase, which is the one failure the check cannot see.
test_texts_can_be_supplied_from_files() {
  local home wordsf questionf out status
  home=$(new_home files)
  wordsf="$home/words.txt"
  questionf="$home/question.txt"
  printf '%s\n' "$PIXELTALE_AUDIT" > "$wordsf"
  printf 'Which categories diverge from beanheads?\n' > "$questionf"
  out=$(FM_HOME="$home" "$FRAMING" files-1 \
    --captain-words-file "$wordsf" --question-file "$questionf" 2>&1)
  assert_contains "$out" "verdict: confirm-required" \
    "file-supplied texts classified differently from inline ones"
  assert_grep "$PIXELTALE_AUDIT" "$home/data/files-1/framing.md" \
    "file-supplied captain words did not reach the record verbatim"
  out=$(FM_HOME="$home" "$FRAMING" files-2 --captain-words-file "$home/absent.txt" --question q 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an absent captain-words file should be refused"
  assert_contains "$out" "names no readable file" "the refusal did not explain the missing file"
  pass "fm-scout-framing: the captain's words and the question can be supplied from files"
}

test_script_parses
test_help_states_the_contract
test_acceptance_fixtures
test_a_question_the_captain_asked_is_exempt
test_a_widened_question_loses_the_exemption
test_the_record_carries_the_evidence
test_the_record_is_append_only
test_discovery_is_declared_and_obligating
test_a_requirement_document_needs_no_framing_record
test_the_gate_fails_closed
test_both_texts_are_required_and_never_guessed
test_texts_can_be_supplied_from_files

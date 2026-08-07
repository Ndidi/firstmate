#!/usr/bin/env bash
# Behavior tests for the captain capture-receipt ledger (bin/fm-capture-receipt.sh).
#
# The contract under test is AGENTS.md section 9's receipt obligation: work the
# captain cannot name is work they will reasonably conclude was never captured.
# Every assertion drives the real executable over a temp home and reads its
# public output or its observable state transitions; none inspect source text.
#
#   1. The obligation is DERIVED from the backlog, not declared, so filing by any
#      route incurs it, and the first reconcile in a home owes nothing.
#   2. Parsing is exact: indented task bodies are not items, the tasks-axi and
#      manual item renderings both resolve, and a non-slug identity is refused
#      rather than sanitized into a path.
#   3. The turn-end guard blocks at most once per identity, ever, so it can nag
#      but never wedge.
#   4. Attestation validates every identity before clearing any, so a mistype
#      cannot retire the wrong debt.
#   5. An unwritable ledger allows the turn end rather than trapping the session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECEIPT="$ROOT/bin/fm-capture-receipt.sh"
TMP_ROOT=$(fm_test_tmproot fm-capture-receipt)

# A home is just state/ + data/; the ledger never needs a checkout of its own.
make_home() {  # <dir> [backlog-body] -> echoes dir
  local dir=$1
  mkdir -p "$dir/state" "$dir/data"
  printf '%s' "${2-}" > "$dir/data/backlog.md"
  printf '%s\n' "$dir"
}

receipt() {  # <home> <verb...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    bash "$RECEIPT" "$@"
}

# File an item the way any backlog write does. No mtime manipulation: the ledger
# deliberately has no mtime fast path to defeat, so a same-second append is a
# real case these tests exercise rather than paper over.
file_item() {  # <home> <line>
  printf '%s\n' "$2" >> "$1/data/backlog.md"
}

# Rewrite the backlog through an awk program. A failing program would empty the
# backlog and turn several assertions into false passes, so it fails loudly.
rewrite_backlog() {  # <home> <awk-program>
  local home=$1 program=$2
  awk "$program" "$home/data/backlog.md" > "$home/data/backlog.md.new" \
    || fail "test helper: awk program failed: $program"
  [ -s "$home/data/backlog.md.new" ] \
    || fail "test helper: awk program emptied the backlog: $program"
  mv -f "$home/data/backlog.md.new" "$home/data/backlog.md"
}

SEED_BACKLOG='# Backlog

## In flight
- [ ] apex-auth-ws-strand - Reconnect the websocket strand (repo: apex) (kind: ship) (since 2026-08-05)
  A body paragraph that belongs to the item above.
  - a bullet inside that body, which is prose and never an item

## Queued
- [ ] ci-no-pr-gate - Pull requests merge with no checks at all (repo: the-shop-shop)

## Done
- [x] deploy-routine-prompt-stale - Deploy prompt drifted from the repo copy (repo: the-shop-shop)
'

# --- 1. the obligation is derived, and adoption owes nothing ----------------

test_first_reconcile_adopts_without_owing() {
  local home out
  home=$(make_home "$TMP_ROOT/adopt" "$SEED_BACKLOG")
  out=$(receipt "$home" pending)
  [ -z "$out" ] || fail "first reconcile in a home must owe nothing, got:"$'\n'"$out"
  receipt "$home" active && fail "a freshly adopted home must not report an owed receipt"
  pass "adoption: the whole pre-existing backlog is taken as already known"
}

test_new_item_becomes_an_owed_receipt() {
  local home out
  home=$(make_home "$TMP_ROOT/new-item" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] apex-loading-copy - The shop front should say it is opening (repo: the-shop-shop) (kind: ship)'
  out=$(receipt "$home" pending)
  assert_contains "$out" 'owed: apex-loading-copy' "a newly filed item must be owed"
  # shellcheck disable=SC2016 # Backticks are literal expected output.
  assert_contains "$out" 'Filed as `apex-loading-copy` - The shop front should say it is opening.' \
    "pending must hand over the exact captain-facing sentence"
  assert_not_contains "$out" '(repo:' "the backend metadata rendering is not part of the captain's sentence"
  assert_not_contains "$out" 'owed: ci-no-pr-gate' "an already-adopted item must not be re-owed"
  receipt "$home" active || fail "active must report the owed receipt"
  pass "derivation: filing an item incurs the receipt with no registration step"
}

test_done_transition_is_not_a_new_receipt() {
  local home out
  home=$(make_home "$TMP_ROOT/done-move" "$SEED_BACKLOG")
  receipt "$home" reconcile
  # The same identity moving Queued -> Done is a state change, not new work.
  rewrite_backlog "$home" '{ sub(/^- \[ \] ci-no-pr-gate/, "- [x] ci-no-pr-gate"); print }'
  out=$(receipt "$home" pending)
  [ -z "$out" ] || fail "a checkbox transition must not owe a receipt, got:"$'\n'"$out"
  pass "derivation: completing an item is not filing a new one"
}

test_departed_item_stops_being_a_debt() {
  local home out
  home=$(make_home "$TMP_ROOT/departed" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] transient-item - Filed then withdrawn'
  out=$(receipt "$home" pending)
  assert_contains "$out" 'owed: transient-item' "precondition: the item must first be owed"
  rewrite_backlog "$home" '!/^- \[ \] transient-item/ { print }'
  out=$(receipt "$home" pending)
  [ -z "$out" ] || fail "an item that left the backlog must stop being a debt, got:"$'\n'"$out"
  pass "prune: work removed from the backlog carries no residual receipt"
}

# --- 2. parsing is exact ----------------------------------------------------

test_body_bullets_are_never_items() {
  local home out
  home=$(make_home "$TMP_ROOT/body" "$SEED_BACKLOG")
  out=$(receipt "$home" pending)
  # Adoption is silent, so prove the body bullet never became a tracked identity
  # by checking it is absent from the baseline the adoption just wrote.
  assert_no_grep 'a bullet inside that body' "$home/state/capture-receipts/baseline" \
    "an indented body bullet must never be parsed as a backlog item"
  assert_grep 'apex-auth-ws-strand' "$home/state/capture-receipts/baseline" \
    "the real in-flight item must be adopted"
  assert_grep 'deploy-routine-prompt-stale' "$home/state/capture-receipts/baseline" \
    "a Done item must be adopted so it can never be re-owed later"
  pass "parse: only column-0 item lines are items"
}

test_manual_backend_rendering_resolves() {
  local home out
  home=$(make_home "$TMP_ROOT/manual" "$SEED_BACKLOG")
  receipt "$home" reconcile
  # The manual backlog path writes items without a checkbox.
  file_item "$home" '- manual-filed-item - Written by hand rather than by the tool'
  out=$(receipt "$home" pending)
  assert_contains "$out" 'owed: manual-filed-item' \
    "an unchecked manual item line must resolve to an identity"
  pass "parse: the manual backend's unchecked rendering is an item too"
}

test_non_slug_identities_are_refused() {
  local home out
  home=$(make_home "$TMP_ROOT/slug" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] ../../escape - a traversal attempt'
  printf -- '- [ ] two words - a spaced identity\n' >> "$home/data/backlog.md"
  out=$(receipt "$home" pending)
  [ -z "$out" ] || fail "a non-slug identity must be refused, got:"$'\n'"$out"
  assert_absent "$TMP_ROOT/slug/state/capture-receipts/owed/../../escape" \
    "a traversal identity must never resolve to a path outside owed/"
  [ "$(find "$home/state/capture-receipts/owed" -type f | wc -l)" -eq 0 ] \
    || fail "no owed record may be created from a refused identity"
  pass "parse: an identity that is not a slug is skipped, never sanitized"
}

# --- 3. the guard nags but cannot wedge -------------------------------------

test_guard_blocks_once_per_identity() {
  local home out status
  home=$(make_home "$TMP_ROOT/guard-once" "$SEED_BACKLOG")
  receipt "$home" reconcile

  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 0 "$status" "guard with nothing owed"
  [ -z "$out" ] || fail "guard must be silent with nothing owed, got:"$'\n'"$out"

  file_item "$home" '- [ ] apex-loading-copy - The shop front should say it is opening'
  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 2 "$status" "guard with an unsurfaced receipt"
  assert_contains "$out" 'THE CAPTAIN HAS NOT BEEN TOLD WHAT THIS WAS FILED AS' \
    "the block must name the failure in the captain's terms"
  # shellcheck disable=SC2016 # Backticks are literal expected output.
  assert_contains "$out" 'Filed as `apex-loading-copy`' \
    "the block must hand over the sentence, not ask firstmate to compose one"
  assert_contains "$out" 'fm-capture-receipt.sh delivered apex-loading-copy' \
    "the block must carry the exact command that clears it"

  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 0 "$status" "second turn end for the same identity"
  [ -z "$out" ] || fail "the same identity must never block twice, got:"$'\n'"$out"

  receipt "$home" active || fail "an ignored block must leave the debt owed, not clear it"
  pass "guard: blocks once per identity, then leaves the debt to the session digest"
}

test_guard_blocks_each_identity_once() {
  local home out status
  home=$(make_home "$TMP_ROOT/guard-many" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] first-thing - The first thing'
  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 2 "$status" "first identity blocks"
  file_item "$home" '- [ ] second-thing - The second thing'
  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 2 "$status" "a later, separate filing blocks on its own"
  assert_contains "$out" 'second-thing' "the new identity must be named"
  assert_not_contains "$out" 'first-thing' \
    "an already-surfaced identity must not be repeated in a later block"
  pass "guard: a fresh filing still blocks, an already-surfaced one never repeats"
}

test_pending_marks_an_already_surfaced_receipt() {
  local home out
  home=$(make_home "$TMP_ROOT/surfaced" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] apex-loading-copy - The shop front should say it is opening'
  receipt "$home" guard >/dev/null 2>&1
  out=$(receipt "$home" pending)
  assert_contains "$out" 'already surfaced once at a turn end' \
    "the digest must distinguish a debt that has already had its one block"
  pass "pending: an already-surfaced debt is disclosed as such"
}

# --- 4. attestation is all-or-nothing ---------------------------------------

test_mistyped_identity_clears_nothing() {
  local home out status
  home=$(make_home "$TMP_ROOT/mistype" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] apex-loading-copy - The shop front should say it is opening'
  receipt "$home" pending >/dev/null

  out=$(receipt "$home" delivered apex-loading-copy apex-loading-copyy 2>&1); status=$?
  expect_code 1 "$status" "attesting a mix of real and mistyped identities"
  assert_contains "$out" 'no receipt is owed for apex-loading-copyy' \
    "the refusal must name the identity it could not find"
  receipt "$home" active \
    || fail "a refused attestation must clear nothing, including the valid identity"

  out=$(receipt "$home" delivered apex-loading-copy 2>&1); status=$?
  expect_code 0 "$status" "attesting the real identity"
  receipt "$home" active && fail "a correct attestation must clear the debt"
  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 0 "$status" "guard after a delivered receipt"
  pass "delivered: validates every identity before clearing any"
}

test_delivered_requires_an_identity() {
  local status
  local home
  home=$(make_home "$TMP_ROOT/no-arg" "$SEED_BACKLOG")
  receipt "$home" delivered >/dev/null 2>&1; status=$?
  expect_code 2 "$status" "delivered with no identity"
  pass "delivered: refuses a bare invocation rather than clearing everything"
}

# --- 5. failure direction ---------------------------------------------------

test_absent_backlog_is_inert() {
  local home out status
  home=$(mktemp -d "$TMP_ROOT/no-backlog.XXXX")
  mkdir -p "$home/state"
  out=$(receipt "$home" guard 2>&1); status=$?
  expect_code 0 "$status" "guard in a home with no backlog at all"
  [ -z "$out" ] || fail "a home with no backlog must be silent, got:"$'\n'"$out"
  assert_absent "$home/state/capture-receipts" \
    "a home with no backlog must not have a ledger created for it"
  pass "inert: a home with no backlog costs nothing and creates nothing"
}

test_unwritable_ledger_allows_the_turn_end() {
  local home out status
  if [ "$(id -u)" -eq 0 ]; then
    pass "fail direction: unwritable-ledger case skipped (root ignores mode bits)"
    return 0
  fi
  home=$(make_home "$TMP_ROOT/readonly" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] apex-loading-copy - The shop front should say it is opening'
  receipt "$home" reconcile
  assert_present "$home/state/capture-receipts/owed/apex-loading-copy" \
    "precondition: the receipt must exist before the ledger is frozen"
  chmod 500 "$home/state/capture-receipts" "$home/state/capture-receipts/owed"
  out=$(receipt "$home" guard 2>&1); status=$?
  chmod 700 "$home/state/capture-receipts" "$home/state/capture-receipts/owed"
  expect_code 0 "$status" "guard against a ledger it cannot mark"
  [ -z "$out" ] || fail "an unmarkable block must stay silent rather than repeat forever"
  pass "fail direction: a ledger that cannot record the block never traps the session"
}

test_first_reconcile_after_adoption_survives_a_restart() {
  local home out
  home=$(make_home "$TMP_ROOT/restart" "$SEED_BACKLOG")
  receipt "$home" reconcile
  file_item "$home" '- [ ] apex-loading-copy - The shop front should say it is opening'
  receipt "$home" guard >/dev/null 2>&1
  # A new session reads the same disk; the debt is durable, not conversational.
  out=$(receipt "$home" pending)
  assert_contains "$out" 'owed: apex-loading-copy' \
    "an unpaid receipt must survive the session that incurred it"
  pass "durability: an unpaid receipt outlives the turn and the session"
}

test_first_reconcile_adopts_without_owing
test_new_item_becomes_an_owed_receipt
test_done_transition_is_not_a_new_receipt
test_departed_item_stops_being_a_debt
test_body_bullets_are_never_items
test_manual_backend_rendering_resolves
test_non_slug_identities_are_refused
test_guard_blocks_once_per_identity
test_guard_blocks_each_identity_once
test_pending_marks_an_already_surfaced_receipt
test_mistyped_identity_clears_nothing
test_delivered_requires_an_identity
test_absent_backlog_is_inert
test_unwritable_ledger_allows_the_turn_end
test_first_reconcile_after_adoption_survives_a_restart

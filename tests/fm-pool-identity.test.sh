#!/usr/bin/env bash
# bin/fm-pool-lib.sh: one repository, one pool.
#
# Treehouse names a pool after the working tree it is invoked in, so acquiring
# from inside a linked worktree seeds a SECOND pool for a repository that already
# has one. That is how this fleet grew firstmate-8bf1b0 alongside
# firstmate-17fd7c: two pools, one object store. These cases pin the refusal that
# stops it recurring and the detection that finds the ones already on disk.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-pool-identity)

# shellcheck source=bin/fm-pool-lib.sh
. "$ROOT/bin/fm-pool-lib.sh"

test_a_primary_checkout_is_acquirable() {
  local repo="$TMP_ROOT/primary/repo"
  fm_git_init_commit "$repo"
  fm_pool_assert_acquirable "$repo" \
    || fail "a repository's own primary checkout must be acquirable"
  pass "a repository's own primary checkout is acquirable"
}

test_a_linked_worktree_is_refused_with_the_place_to_use_instead() {
  local repo="$TMP_ROOT/linked/repo" wt="$TMP_ROOT/linked/other" out rc
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet --detach "$wt"

  out=$(fm_pool_assert_acquirable "$wt" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "acquiring from a linked worktree must be refused: $out"
  assert_contains "$out" "linked worktree" "the refusal says what the directory actually is"
  assert_contains "$out" "SECOND pool" "the refusal says what would go wrong"
  assert_contains "$out" "$repo" "the refusal names the primary checkout to use instead"
  pass "acquiring from a linked worktree is refused, naming the primary checkout to use instead"
}

test_a_symlinked_spelling_of_the_primary_is_still_the_primary() {
  local repo="$TMP_ROOT/symlink/repo" link="$TMP_ROOT/symlink/by-another-name"
  fm_git_init_commit "$repo"
  ln -s "$repo" "$link"
  # One directory under two names is one repository. If path spelling alone
  # decided this, every symlinked project would seed its own duplicate pool.
  fm_pool_assert_acquirable "$link" \
    || fail "a symlinked spelling of the primary checkout must still be acquirable"
  pass "a symlinked spelling of the primary checkout is recognized as the same checkout"
}

test_a_non_repository_is_refused() {
  local plain="$TMP_ROOT/plain" out rc
  mkdir -p "$plain"
  out=$(fm_pool_assert_acquirable "$plain" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "a directory outside any repository must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the refusal says why no pool can be resolved"
  pass "a directory that is not inside a repository is refused rather than guessed"
}

test_a_pool_seeded_from_a_worktree_is_a_duplicate_of_the_primarys_pool() {
  local base="$TMP_ROOT/dup" repo seed out
  repo="$base/repo"
  fm_git_init_commit "$repo"
  # The shape that actually seeds a duplicate, built the way it really happens
  # rather than the way it is easy to build. A worker inside the linked worktree
  # `seed` acquires a copy, so treehouse names a pool after `seed` and the copy is
  # added THROUGH that worktree - two pool directories, one object store.
  seed="$base/seed"
  git -C "$repo" worktree add --quiet --detach "$seed"
  mkdir -p "$base/pool/repo-aaaaaa/1" "$base/pool/seed-bbbbbb/1"
  git -C "$repo" worktree add --quiet --detach "$base/pool/repo-aaaaaa/1/repo"
  git -C "$seed" worktree add --quiet --detach "$base/pool/seed-bbbbbb/1/repo"

  out=$(FM_POOL_ROOT="$base/pool" fm_pool_duplicate_dirs)
  assert_contains "$out" "repo-aaaaaa" "the duplicate report names the primary checkout's pool"
  assert_contains "$out" "seed-bbbbbb" "the duplicate report names the pool seeded from a worktree"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "one repository with two pools is one finding, not two: $out"
  pass "a pool seeded from a linked worktree is reported as a duplicate of the primary checkout's pool"
}

test_a_pool_stranded_by_a_case_rename_groups_with_the_repository_that_remains() {
  local base="$TMP_ROOT/case" upper lower out
  # crucible-f0ba32 beside Crucible-0f8676, reproduced: one checkout, renamed so
  # that only its letter case changed, leaving the pool it seeded pointing at a
  # path that no longer exists. Keying on git alone cannot see this at all,
  # because git cannot answer for a repository that is gone.
  upper="$base/Crucible"
  lower="$base/crucible"
  fm_git_init_commit "$upper"
  fm_git_init_commit "$lower"
  mkdir -p "$base/pool/Crucible-aaaaaa/1" "$base/pool/crucible-bbbbbb/1"
  git -C "$upper" worktree add --quiet --detach "$base/pool/Crucible-aaaaaa/1/Crucible"
  git -C "$lower" worktree add --quiet --detach "$base/pool/crucible-bbbbbb/1/crucible"
  rm -rf "$lower"

  out=$(FM_POOL_ROOT="$base/pool" fm_pool_inventory)
  assert_contains "$out" "crucible-bbbbbb" "a pool whose repository is gone still appears in the inventory"
  case "$out" in
    *"crucible-bbbbbb"$'\t'"stranded"*) : ;;
    *) fail "the stranded pool must be labelled stranded, not dropped or called present: $out" ;;
  esac

  out=$(FM_POOL_ROOT="$base/pool" fm_pool_duplicate_dirs)
  assert_contains "$out" "Crucible-aaaaaa" "the finding names the pool that still works"
  assert_contains "$out" "crucible-bbbbbb" "the finding names the pool the rename stranded"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the pair is one repository's two pools, so it is one finding: $out"
  pass "a pool stranded by a letter-case rename is grouped with the repository that remains"
}

test_two_live_repositories_differing_only_in_case_are_not_folded_together() {
  local base="$TMP_ROOT/case-live" out
  # The control for the fold above, and the reason it is allowed only against a
  # repository that is GONE. Where both spellings exist they are two repositories,
  # and calling them one would invent a duplicate that is not there.
  fm_git_init_commit "$base/alpha"
  fm_git_init_commit "$base/ALPHA"
  mkdir -p "$base/pool/alpha-aaaaaa/1" "$base/pool/ALPHA-bbbbbb/1"
  git -C "$base/alpha" worktree add --quiet --detach "$base/pool/alpha-aaaaaa/1/alpha"
  git -C "$base/ALPHA" worktree add --quiet --detach "$base/pool/ALPHA-bbbbbb/1/ALPHA"

  out=$(FM_POOL_ROOT="$base/pool" fm_pool_duplicate_dirs)
  [ -z "$out" ] || fail "two repositories that both exist are not one repository: $out"
  pass "two live repositories whose paths differ only in letter case are not folded together"
}

test_every_pool_on_disk_appears_in_the_inventory() {
  local base="$TMP_ROOT/account" repo out lines
  repo="$base/repo"
  fm_git_init_commit "$repo"
  fm_git_init_commit "$base/gone"
  mkdir -p "$base/pool/repo-aaaaaa/1" "$base/pool/gone-bbbbbb/1"
  git -C "$repo" worktree add --quiet --detach "$base/pool/repo-aaaaaa/1/repo"
  git -C "$base/gone" worktree add --quiet --detach "$base/pool/gone-bbbbbb/1/gone"
  rm -rf "$base/gone"

  # Nothing may drop out silently. A pool that was examined and left alone has to
  # be distinguishable from one that was never examined, and that starts here:
  # every pool on disk gets a row, whether or not git could answer for it.
  out=$(FM_POOL_ROOT="$base/pool" fm_pool_inventory)
  lines=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$lines" = 2 ] || fail "both pools should be accounted for, got $lines row(s): $out"
  assert_contains "$out" "repo-aaaaaa" "the live pool is accounted for"
  assert_contains "$out" "gone-bbbbbb" "the pool whose repository is gone is accounted for"
  case "$out" in
    *"gone-bbbbbb"$'\t'"stranded"*) : ;;
    *) fail "an orphan must say so rather than reading like any other pool: $out" ;;
  esac
  pass "every pool on disk is accounted for in the inventory, including one whose repository is gone"
}

test_separate_repositories_are_not_reported_as_duplicates() {
  local base="$TMP_ROOT/distinct" out
  fm_git_init_commit "$base/alpha"
  fm_git_init_commit "$base/beta"
  mkdir -p "$base/pool/alpha-aaaaaa/1" "$base/pool/beta-bbbbbb/1"
  git -C "$base/alpha" worktree add --quiet --detach "$base/pool/alpha-aaaaaa/1/alpha"
  git -C "$base/beta" worktree add --quiet --detach "$base/pool/beta-bbbbbb/1/beta"

  # The control: grouping must be by object store, not by "there are two pools".
  out=$(FM_POOL_ROOT="$base/pool" fm_pool_duplicate_dirs)
  [ -z "$out" ] || fail "two pools for two different repositories are not duplicates: $out"
  pass "pools backing different repositories are not reported as duplicates"
}

test_a_pool_whose_repository_is_gone_reads_as_an_orphan() {
  local base="$TMP_ROOT/orphan" repo state
  repo="$base/repo"
  fm_git_init_commit "$repo"
  mkdir -p "$base/pool/repo-cccccc/1"
  git -C "$repo" worktree add --quiet --detach "$base/pool/repo-cccccc/1/repo"

  state=$(FM_POOL_ROOT="$base/pool" fm_pool_backing_state "$base/pool/repo-cccccc")
  case "$state" in present*) ;; *) fail "a live pool should read as present, got '$state'" ;; esac

  # A checkout renamed or re-cloned under another name strands its old pool this
  # way - the fault behind crucible-f0ba32, which is an orphan rather than a
  # duplicate and needs a different remedy.
  rm -rf "$repo"
  state=$(FM_POOL_ROOT="$base/pool" fm_pool_backing_state "$base/pool/repo-cccccc")
  [ "$state" = orphan ] || fail "a pool whose repository is gone should read as an orphan, got '$state'"
  pass "a pool whose repository is gone reads as an orphan, distinct from a duplicate"
}

test_a_primary_checkout_is_acquirable
test_a_linked_worktree_is_refused_with_the_place_to_use_instead
test_a_symlinked_spelling_of_the_primary_is_still_the_primary
test_a_non_repository_is_refused
test_a_pool_seeded_from_a_worktree_is_a_duplicate_of_the_primarys_pool
test_a_pool_stranded_by_a_case_rename_groups_with_the_repository_that_remains
test_two_live_repositories_differing_only_in_case_are_not_folded_together
test_every_pool_on_disk_appears_in_the_inventory
test_separate_repositories_are_not_reported_as_duplicates
test_a_pool_whose_repository_is_gone_reads_as_an_orphan

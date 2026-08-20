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

test_two_pools_over_one_object_store_are_reported_as_duplicates() {
  local base="$TMP_ROOT/dup" repo out
  repo="$base/repo"
  fm_git_init_commit "$repo"
  # The exact shape found in the fleet: two pool directories, differing only in
  # the name treehouse derived, whose copies share one object store.
  mkdir -p "$base/pool/repo-aaaaaa/1" "$base/pool/repo-bbbbbb/1"
  git -C "$repo" worktree add --quiet --detach "$base/pool/repo-aaaaaa/1/repo"
  git -C "$repo" worktree add --quiet --detach "$base/pool/repo-bbbbbb/1/repo"

  out=$(FM_POOL_ROOT="$base/pool" fm_pool_duplicate_dirs)
  assert_contains "$out" "repo-aaaaaa" "the duplicate report names the first pool"
  assert_contains "$out" "repo-bbbbbb" "the duplicate report names the second pool"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || fail "one repository with two pools is one finding, not two: $out"
  pass "two pools sharing one object store are reported as duplicates for that repository"
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
test_two_pools_over_one_object_store_are_reported_as_duplicates
test_separate_repositories_are_not_reported_as_duplicates
test_a_pool_whose_repository_is_gone_reads_as_an_orphan

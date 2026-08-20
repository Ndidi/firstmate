#!/usr/bin/env bash
# bin/fm-pool-reap.sh: the reserve policy, and above all the refusals.
#
# The refusal cases are the important ones. A reaper that reclaims a copy too
# few is a wasted gigabyte; a reaper that reclaims a copy too many has destroyed
# work that existed nowhere else. Every rule in the script's header gets a case
# here that proves the copy is still on disk afterwards, and that the run said
# why in words an operator can act on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity

TMP_ROOT=$(fm_test_tmproot fm-pool-reap)

# --- fixtures ---------------------------------------------------------------

# A fake treehouse standing in for the real pool mechanics. It answers status
# from a fixture the case writes, and its `destroy` models the real bare
# destroy's own safety: it removes only a clean worktree whose HEAD is already in
# the default branch, and skips anything else. That keeps treehouse's own gate
# present in these tests as a second opinion, exactly as it is in production.
make_fake_treehouse() {  # <fakebin> <status-file>
  local fakebin=$1 status_file=$2
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  status)
    cat "$status_file"
    exit 0
    ;;
  destroy)
    target=\$2
    if [ -n "\$(git -C "\$target" status --porcelain 2>/dev/null)" ]; then
      echo "did not destroy \$target (dirty); re-run with --include-unlanded" >&2
      exit 1
    fi
    head=\$(git -C "\$target" rev-parse HEAD 2>/dev/null)
    def=\$(git -C "\$target" rev-parse --verify refs/heads/main 2>/dev/null \\
          || git -C "\$target" rev-parse --verify refs/heads/master 2>/dev/null)
    if [ -n "\$def" ] && ! git -C "\$target" merge-base --is-ancestor "\$head" "\$def" 2>/dev/null; then
      echo "did not destroy \$target (unmerged); re-run with --include-unlanded" >&2
      exit 1
    fi
    git -C "\$target" worktree remove --force "\$target" >/dev/null 2>&1
    rm -rf "\$target"
    echo "Destroyed 1 worktree in \$(dirname "\$(dirname "\$target")") and freed 1.0 MiB."
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# Build a project repo plus a pool of <n> copies laid out the way treehouse lays
# one out: <pool-root>/<project>-<hash>/<slot>/<project>.
make_pool() {  # <case-dir> <project> <n>
  local base=$1 project=$2 n=$3 repo pool i
  repo="$base/projects/$project"
  pool="$base/pool/$project-abc123"
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.origin.git"
  mkdir -p "$pool"
  for i in $(seq 1 "$n"); do
    mkdir -p "$pool/$i"
    git -C "$repo" worktree add --quiet --detach "$pool/$i/$project"
  done
  printf '%s\n' "$pool"
}

# Every copy reads available with nothing attached, unless the case says otherwise.
write_status() {  # <status-file> <copy>...
  local out=$1 copy first=1
  shift
  printf '[' > "$out"
  for copy in "$@"; do
    [ "$first" = 1 ] || printf ',' >> "$out"
    printf '{"name":"1","path":"%s","status":"available","lease_id":"","lease_holder":"","processes":[]}' "$copy" >> "$out"
    first=0
  done
  printf ']\n' >> "$out"
}

# Backdate a copy past the settling window. Inner files first, so touching them
# cannot bump the directory mtime afterwards.
age_copy() {  # <copy> <days>
  local copy=$1 days=$2 stamp gitdir
  stamp=$(date -d "-$days days" +%Y%m%d%H%M 2>/dev/null || date -v-"${days}"d +%Y%m%d%H%M)
  if gitdir=$(git -C "$copy" rev-parse --path-format=absolute --git-dir 2>/dev/null); then
    [ -e "$gitdir/index" ] && touch -t "$stamp" "$gitdir/index"
  fi
  touch -t "$stamp" "$copy/.git" 2>/dev/null || true
  touch -t "$stamp" "$copy"
}

# One self-contained case directory with its own pool root, home, and PATH.
new_case() {  # <name>
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/pool" "$dir/projects"
  fm_fakebin "$dir" >/dev/null
  make_fake_treehouse "$dir/fakebin" "$dir/status.json"
  printf '%s\n' "$dir"
}

# Copies still on disk. Counts worktree leaves, not the slot directories that
# may outlive them.
count_copies() {  # <pool>
  find "$1" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' '
}

run_reap() {  # <case-dir> [args...]
  local dir=$1
  shift
  PATH="$dir/fakebin:$PATH" \
  FM_POOL_ROOT="$dir/pool" \
  FM_HOME="$dir/home" \
  FM_DATA_OVERRIDE="$dir/home/data" \
  FM_CONFIG_OVERRIDE="$dir/home/config" \
    "$ROOT/bin/fm-pool-reap.sh" "$@" 2>&1
}

# --- policy -----------------------------------------------------------------

test_reduces_to_reserve_and_names_every_copy() {
  local dir pool out
  dir=$(new_case reserve); pool=$(make_pool "$dir" alpha 4)
  write_status "$dir/status.json" "$pool"/{1,2,3,4}/alpha
  local i; for i in 1 2 3 4; do age_copy "$pool/$i/alpha" "$((10 - i))"; done

  out=$(run_reap "$dir")

  local left; left=$(count_copies "$pool")
  [ "$left" = 1 ] || fail "reserve 1 should leave one copy, found $left: $out"
  assert_contains "$out" "3 reclaimed" "the summary counts what it removed"
  for i in 1 2 3; do
    assert_contains "$out" "$pool/$i/alpha" "the report names reclaimed copy $i"
  done
  # Oldest-idle first: copy 1 is the stalest, copy 4 the freshest, so 4 survives.
  [ -d "$pool/4/alpha" ] || fail "the freshest copy should be the one kept warm: $out"
  pass "an idle pool is reduced to the reserve, and the report names every copy reclaimed"
}

test_reserve_is_configurable_and_defaults_need_no_config() {
  local dir pool out
  dir=$(new_case reserve-flag); pool=$(make_pool "$dir" alpha 4)
  write_status "$dir/status.json" "$pool"/{1,2,3,4}/alpha
  local i; for i in 1 2 3 4; do age_copy "$pool/$i/alpha" 5; done

  out=$(run_reap "$dir" --reserve 3)
  local left; left=$(count_copies "$pool")
  [ "$left" = 3 ] || fail "--reserve 3 should leave three copies, found $left: $out"

  dir=$(new_case reserve-file); pool=$(make_pool "$dir" alpha 4)
  write_status "$dir/status.json" "$pool"/{1,2,3,4}/alpha
  for i in 1 2 3 4; do age_copy "$pool/$i/alpha" 5; done
  printf 'alpha = 2\n' > "$dir/home/config/pool-reserve"
  out=$(run_reap "$dir")
  left=$(count_copies "$pool")
  [ "$left" = 2 ] || fail "a per-project reserve of 2 should leave two copies, found $left: $out"
  pass "the built-in reserve needs no configuration, and an operator can override it per project or per run"
}

test_malformed_config_is_refused_not_silently_defaulted() {
  local dir pool out rc
  dir=$(new_case bad-config); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 5; done
  printf 'alpha = plenty\n' > "$dir/home/config/pool-reserve"

  out=$(run_reap "$dir"); rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed reserve must not be treated as a default: $out"
  assert_contains "$out" "whole number" "the error names what was wrong with the value"
  [ -d "$pool/1/alpha" ] || fail "nothing may be removed on a configuration error"
  pass "a malformed reserve is refused with its reason rather than silently replaced by a default"
}

test_recently_used_copies_wait_out_the_settling_window() {
  local dir pool out
  dir=$(new_case fresh); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  # All three are clean and merged, but none has been idle for a day.
  out=$(run_reap "$dir")
  local left; left=$(count_copies "$pool")
  [ "$left" = 3 ] || fail "copies inside the settling window must be left alone, found $left: $out"
  assert_contains "$out" "0 reclaimed" "a run that reclaims nothing says so"

  out=$(run_reap "$dir" --min-idle-hours 0)
  left=$(count_copies "$pool")
  [ "$left" = 1 ] || fail "--min-idle-hours 0 should let the sweep proceed, found $left: $out"
  pass "a copy used more recently than the idle window is kept, and the window is configurable"
}

# --- refusals ---------------------------------------------------------------

test_refuses_a_copy_with_uncommitted_changes() {
  local dir pool out
  dir=$(new_case dirty); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done
  printf 'work nobody has committed\n' > "$pool/1/alpha/README.md"
  age_copy "$pool/1/alpha" 9

  out=$(run_reap "$dir")

  [ -d "$pool/1/alpha" ] || fail "a copy with uncommitted changes must survive the sweep: $out"
  assert_contains "$out" "refused" "the run reports the refusal"
  assert_contains "$out" "$pool/1/alpha" "the refusal names the copy"
  assert_contains "$out" "uncommitted changes to tracked files" "the refusal states its reason precisely"
  pass "a copy with uncommitted changes is left untouched, with the reason stated"
}

test_settings_local_json_exception_is_honoured_exactly() {
  local dir pool out
  dir=$(new_case settings-sole); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  # The captain's standing authority of 2026-08-11: this one file, and only when
  # it is the sole uncommitted change.
  mkdir -p "$pool/1/alpha/.claude"
  printf '{}\n' > "$pool/1/alpha/.claude/settings.local.json"
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done

  out=$(run_reap "$dir" --reserve 0)
  [ ! -d "$pool/1/alpha" ] || fail "a lone settings.local.json must not block reclaim: $out"

  # And no wider: the same file alongside any other change still refuses.
  dir=$(new_case settings-plus); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  mkdir -p "$pool/1/alpha/.claude"
  printf '{}\n' > "$pool/1/alpha/.claude/settings.local.json"
  printf 'and a real edit\n' > "$pool/1/alpha/README.md"
  for i in 1 2; do age_copy "$pool/$i/alpha" 9; done

  out=$(run_reap "$dir" --reserve 0)
  [ -d "$pool/1/alpha" ] || fail "settings.local.json alongside another change must still refuse: $out"
  assert_contains "$out" "uncommitted changes to tracked files" "the wider case refuses for the ordinary reason"
  pass "the settings.local.json exception clears a sole change and nothing wider"
}

test_untracked_only_content_blocks_reclaim_and_is_reported_as_a_decision() {
  local dir pool out
  dir=$(new_case untracked); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha

  # The live case this rule was decided against: a copy whose only dirt is an
  # untracked scratch directory holding a whole third-party clone. No tracked
  # changes, no branch, no owner - and still not decidable as disposable, because
  # an untracked file is the least recoverable thing in a repository.
  mkdir -p "$pool/1/alpha/.scratch/vendored/.git"
  printf 'a third-party clone nobody claimed\n' > "$pool/1/alpha/.scratch/vendored/README.md"
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done

  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "untracked content must block reclaim: $out"
  [ -d "$pool/1/alpha/.scratch/vendored" ] || fail "the untracked content itself must be untouched: $out"
  assert_contains "$out" "untracked files nobody has claimed" "the refusal names this as its own class"
  assert_contains "$out" ".scratch" "the report names what is sitting there"
  assert_contains "$out" "never clear on their own" "the report says the copy will not free itself"
  assert_contains "$out" "needs your explicit word" "discarding it is stated to be the captain's call"
  pass "untracked-only content blocks reclaim and is surfaced as a costed decision, not a silent lockout"
}

test_refuses_an_unmerged_branch_even_when_it_is_pushed() {
  local dir pool out repo
  dir=$(new_case unmerged); pool=$(make_pool "$dir" alpha 3)
  repo="$dir/projects/alpha"
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha

  # A copy holding a branch whose commits are pushed to the remote but are NOT in
  # the default branch: the shape of an open, unmerged PR. Being on a remote is
  # what makes the task-teardown test pass this, which is why the reaper adds its
  # own merged-into-default gate on top.
  git -C "$pool/1/alpha" checkout -q -b fm/open-pr
  printf 'unlanded work\n' > "$pool/1/alpha/feature.txt"
  git -C "$pool/1/alpha" add feature.txt
  git -C "$pool/1/alpha" commit -qm 'work with an open PR'
  git -C "$pool/1/alpha" push -q origin fm/open-pr
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done

  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "a pushed but unmerged branch must survive the sweep: $out"
  assert_contains "$out" "not in the default branch" "the refusal explains that pushed is not landed"
  git -C "$repo" rev-parse --verify fm/open-pr >/dev/null 2>&1 \
    || fail "the branch itself must be untouched"
  pass "a copy holding an unmerged branch with an open PR is refused even though it is pushed"
}

test_accepts_work_whose_content_already_landed_by_squash_merge() {
  local dir pool out repo def
  dir=$(new_case squashed); pool=$(make_pool "$dir" alpha 2)
  repo="$dir/projects/alpha"
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  def=$(git -C "$repo" symbolic-ref --short HEAD)

  # The branch's own commits are nowhere in the default branch, but its content
  # is: the squash-merge-then-delete flow. That work HAS landed.
  git -C "$pool/1/alpha" checkout -q -b fm/squashed
  printf 'landed content\n' > "$pool/1/alpha/feature.txt"
  git -C "$pool/1/alpha" add feature.txt
  git -C "$pool/1/alpha" commit -qm 'branch commit'
  printf 'landed content\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" commit -qm 'squashed onto the default branch'
  git -C "$repo" push -q origin "$def"
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done

  out=$(run_reap "$dir" --reserve 0)

  # The reaper's own merged-into-default gate must NOT be what stops this: the
  # work landed, and refusing it would strand every squash-merged copy forever.
  assert_not_contains "$out" "not in the default branch" \
    "the reaper's own gate must recognize squash-merged content as landed"
  # Treehouse's gate judges the branch separately. If it declines, that is a
  # reported refusal and the copy stays - never something to retry with an
  # override - so either outcome is acceptable here, but only one explanation is.
  if [ -d "$pool/1/alpha" ]; then
    assert_contains "$out" "treehouse declined" \
      "a surviving squash-merged copy must be attributed to the pool's own refusal, not the reaper's"
  fi
  pass "a branch whose content already landed by squash merge is not refused by the reaper's own gate"
}

test_refuses_a_copy_a_live_task_is_recorded_against() {
  local dir pool out
  dir=$(new_case claimed); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done

  # Nothing is running in it and it is clean and merged - only firstmate's own
  # durable record says a task still owns it. A crashed worker looks exactly
  # like this, and its copy still holds the work.
  fm_write_meta "$dir/home/state/fm-live-task.meta" \
    "worktree=$pool/1/alpha" "project=$dir/projects/alpha" "kind=ship" "mode=no-mistakes"

  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "a copy a task is recorded against must survive the sweep: $out"
  assert_contains "$out" "fm-live-task" "the refusal names the task that still owns it"
  [ ! -d "$pool/2/alpha" ] || fail "unclaimed copies should still be reclaimed: $out"
  pass "a copy a live task is recorded against is refused even with no process running in it"
}

test_a_secondmate_homes_records_protect_a_copy_too() {
  local dir pool out
  dir=$(new_case secondmate); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done

  mkdir -p "$dir/second/state"
  fm_write_meta "$dir/second/state/fm-second-task.meta" \
    "worktree=$pool/1/alpha" "project=$dir/projects/alpha" "kind=ship" "mode=no-mistakes"
  printf -- '- fm-second - handles alpha (home: %s; scope: alpha; projects: alpha; added 2026-08-20)\n' \
    "$dir/second" > "$dir/home/data/secondmates.md"

  out=$(run_reap "$dir" --json)
  printf '%s' "$out" | jq -e --arg h "$dir/second" '.homes_scanned | index($h)' >/dev/null \
    || fail "the report must name every home whose records were read: $out"
  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "a copy claimed by a secondmate's records must survive: $out"
  assert_contains "$out" "fm-second-task" "the refusal names the secondmate's task"
  pass "a copy recorded against a task in a secondmate's own home is refused too"
}

test_an_unreadable_secondmate_route_stops_the_sweep() {
  local dir pool out rc
  dir=$(new_case bad-route); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done
  # A route that names a home but cannot be parsed. Skipping it would silently
  # drop whatever that home claims, so the sweep must stop instead.
  printf -- '- fm-second (home: %s but the rest of this route is malformed)\n' \
    "$dir/second" > "$dir/home/data/secondmates.md"

  out=$(run_reap "$dir" --reserve 0); rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable route must stop the sweep: $out"
  [ -d "$pool/1/alpha" ] || fail "nothing may be reclaimed while a home's claims are unknown: $out"
  [ -d "$pool/2/alpha" ] || fail "nothing may be reclaimed while a home's claims are unknown: $out"
  assert_contains "$out" "claims are unknown" "the refusal says why the sweep stopped"
  pass "a registered home whose route cannot be read stops the sweep instead of being treated as empty"
}

test_leaves_a_copy_in_use_alone() {
  local dir pool out
  dir=$(new_case in-use); pool=$(make_pool "$dir" alpha 3)
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done
  cat > "$dir/status.json" <<JSON
[{"name":"1","path":"$pool/1/alpha","status":"in-use","lease_id":"","lease_holder":"","processes":[{"pid":1,"name":"claude"}]},
 {"name":"2","path":"$pool/2/alpha","status":"available","lease_id":"lease-7","lease_holder":"fm-task","processes":[]},
 {"name":"3","path":"$pool/3/alpha","status":"available","lease_id":"","lease_holder":"","processes":[]}]
JSON

  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "a copy with a live process must be left alone: $out"
  [ -d "$pool/2/alpha" ] || fail "a leased copy must be left alone: $out"
  [ ! -d "$pool/3/alpha" ] || fail "the genuinely idle copy should be reclaimed: $out"
  pass "a copy with a running worker or a held lease is left alone"
}

test_refuses_every_copy_in_a_pool_whose_repository_is_gone() {
  local dir pool out
  dir=$(new_case orphan); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done
  rm -rf "$dir/projects/alpha"

  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "an orphan pool's copies must not be guessed empty: $out"
  [ -d "$pool/2/alpha" ] || fail "an orphan pool's copies must not be guessed empty: $out"
  assert_contains "$out" "backing repository is gone" "the refusal explains why nothing can be verified"
  pass "a pool whose repository is gone has every copy refused rather than guessed disposable"
}

test_refuses_when_the_pool_state_cannot_be_read() {
  local dir pool out
  dir=$(new_case unreadable); pool=$(make_pool "$dir" alpha 2)
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done
  printf 'not json at all\n' > "$dir/status.json"

  out=$(run_reap "$dir" --reserve 0)

  [ -d "$pool/1/alpha" ] || fail "an unreadable pool state must reclaim nothing: $out"
  assert_contains "$out" "could not be read" "the refusal says the state was unreadable"
  pass "a pool whose own state cannot be read has everything refused rather than swept"
}

test_never_asks_treehouse_to_override_its_own_safety() {
  local dir pool out log
  dir=$(new_case no-force); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done
  log="$dir/treehouse.args"
  # Record every argument the reaper hands treehouse, then delegate to the fake.
  mv "$dir/fakebin/treehouse" "$dir/fakebin/treehouse-real"
  cat > "$dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exec "$dir/fakebin/treehouse-real" "\$@"
SH
  chmod +x "$dir/fakebin/treehouse"

  out=$(run_reap "$dir" --reserve 0)
  [ -s "$log" ] || fail "the sweep should have called treehouse at all: $out"
  assert_no_grep '--include-unlanded' "$log" "never asks treehouse to remove unlanded work"
  assert_no_grep '--include-in-use' "$log" "never asks treehouse to remove a copy in use"
  assert_no_grep '--include-leased' "$log" "never asks treehouse to remove a leased copy"
  assert_no_grep '--force' "$log" "never forces treehouse past its own refusal"
  pass "no run ever hands treehouse a flag that overrides its own safety"
}

test_treehouse_refusal_is_reported_not_worked_around() {
  local dir pool out
  dir=$(new_case th-refusal); pool=$(make_pool "$dir" alpha 2)
  write_status "$dir/status.json" "$pool"/{1,2}/alpha
  local i; for i in 1 2; do age_copy "$pool/$i/alpha" 9; done
  # treehouse declines everything, standing in for its own gate disagreeing.
  cat > "$dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  status) cat "$dir/status.json"; exit 0 ;;
  destroy) echo "did not destroy \$2 (skipped)" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/treehouse"

  out=$(run_reap "$dir" --reserve 0)
  [ -d "$pool/1/alpha" ] || fail "a copy treehouse declined must stay on disk: $out"
  assert_contains "$out" "treehouse declined" "the report surfaces the pool's own refusal"
  pass "a refusal from treehouse itself is reported and accepted, never retried with an override"
}

test_dry_run_decides_without_removing_anything() {
  local dir pool out
  dir=$(new_case dry); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done

  out=$(run_reap "$dir" --dry-run)
  local left; left=$(count_copies "$pool")
  [ "$left" = 3 ] || fail "a preview must remove nothing, found $left copies: $out"
  assert_contains "$out" "would-reclaim" "the preview says what it would have removed"
  assert_contains "$out" "nothing was removed" "the preview says plainly that it changed nothing"
  pass "a preview run decides and reports without removing anything"
}

test_json_report_accounts_for_every_copy() {
  local dir pool out
  dir=$(new_case json); pool=$(make_pool "$dir" alpha 3)
  write_status "$dir/status.json" "$pool"/{1,2,3}/alpha
  local i; for i in 1 2 3; do age_copy "$pool/$i/alpha" 9; done
  printf 'uncommitted\n' > "$pool/1/alpha/README.md"
  age_copy "$pool/1/alpha" 9

  out=$(run_reap "$dir" --json)
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fail "the JSON report must parse: $out"
  local n; n=$(printf '%s' "$out" | jq '.copies | length')
  [ "$n" = 3 ] || fail "every copy must appear in the report, got $n: $out"
  printf '%s' "$out" | jq -e '.copies[] | select(.outcome == "refused") | .detail' >/dev/null \
    || fail "a refusal must carry its reason in the JSON report: $out"
  pass "the JSON report accounts for every copy, refusals included"
}

test_reduces_to_reserve_and_names_every_copy
test_reserve_is_configurable_and_defaults_need_no_config
test_malformed_config_is_refused_not_silently_defaulted
test_recently_used_copies_wait_out_the_settling_window
test_refuses_a_copy_with_uncommitted_changes
test_settings_local_json_exception_is_honoured_exactly
test_untracked_only_content_blocks_reclaim_and_is_reported_as_a_decision
test_refuses_an_unmerged_branch_even_when_it_is_pushed
test_accepts_work_whose_content_already_landed_by_squash_merge
test_refuses_a_copy_a_live_task_is_recorded_against
test_a_secondmate_homes_records_protect_a_copy_too
test_an_unreadable_secondmate_route_stops_the_sweep
test_leaves_a_copy_in_use_alone
test_refuses_every_copy_in_a_pool_whose_repository_is_gone
test_refuses_when_the_pool_state_cannot_be_read
test_never_asks_treehouse_to_override_its_own_safety
test_treehouse_refusal_is_reported_not_worked_around
test_dry_run_decides_without_removing_anything
test_json_report_accounts_for_every_copy

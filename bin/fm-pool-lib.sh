#!/usr/bin/env bash
# fm-pool-lib.sh - shared knowledge about the treehouse worktree pool: where the
# pools are, which copies they hold, which repository backs each one, and the one
# invariant that keeps a repository to a single pool.
#
# POOL IDENTITY, AND WHY DUPLICATES HAPPEN. Treehouse resolves which pool to use
# from `git rev-parse --show-toplevel` of the current working directory, and names
# the pool `<basename-of-that-toplevel>-<hash-of-that-toplevel>`. The consequence
# is not obvious and it is the whole reason this file exists: acquiring from
# INSIDE an existing worktree does not reuse that worktree's pool, it seeds a
# brand-new pool named after the worktree, even though the backing repository is
# the same one. Reproduced 2026-08-20 against treehouse v2.1.1:
#
#   $ cd /tmp/probe/repo      && treehouse get --lease   -> ~/.treehouse/repo-2e1bb4/1/repo
#   $ cd /tmp/probe/wt-alpha  && treehouse get --lease   -> ~/.treehouse/wt-alpha-a39b50/1/wt-alpha
#
# where wt-alpha is `git worktree add`-ed from repo and shares its object store.
# That is exactly how this fleet ended up with firstmate-8bf1b0 and
# firstmate-17fd7c: two pools, one repository, both resolving to the same
# /home/ndidi/Development/firstmate/.git. A repository whose checkout is renamed
# or re-cloned under a different name strands its old pool the same way, which is
# how Crucible-0f8676 and crucible-f0ba32 came to coexist.
#
# THE INVARIANT. A pool acquire is safe exactly when it runs in a repository's
# OWN PRIMARY CHECKOUT - the main worktree of its object store, the one whose
# top level is the parent of its common git directory. fm_pool_assert_acquirable
# is that check, and bin/fm-spawn.sh calls it before every `treehouse get`.
# Enforcing it is what stops duplicate pools recurring; fm_pool_duplicate_dirs
# reports the ones already on disk.
#
# Sourced, never executed. Requires git; the status reads additionally require
# treehouse and jq.

# The user-level treehouse root. FM_POOL_ROOT overrides it for tests and for an
# operator whose treehouse.toml configures a different root.
fm_pool_root() {
  printf '%s\n' "${FM_POOL_ROOT:-$HOME/.treehouse}"
}

# Physically-resolved path, or nothing when the path is not an existing directory.
# Every comparison in this file goes through it, so a symlinked spelling of one
# directory never reads as two.
fm_pool_realpath() {  # <path>
  local target=${1:-}
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( CDPATH='' cd -- "$target" 2>/dev/null && pwd -P )
}

# Every pool directory under the root, one per line, sorted. A pool directory is
# any immediate child holding at least one copy; the root also holds treehouse's
# own bookkeeping files, which are not pools.
fm_pool_dirs() {
  local root entry
  root=$(fm_pool_root)
  [ -d "$root" ] || return 0
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    [ -n "$(fm_pool_copies "$entry")" ] || continue
    printf '%s\n' "$entry"
  done
}

# Every worktree copy in one pool, one per line, sorted by slot name. Derived
# from the filesystem (<pool>/<slot>/<leaf>) rather than from treehouse's private
# state file, so a pool whose bookkeeping is missing or corrupt still enumerates
# and can still be reported rather than silently vanishing from the inventory.
fm_pool_copies() {  # <pool-dir>
  local pool=${1:-} slot copy
  [ -n "$pool" ] && [ -d "$pool" ] || return 0
  for slot in "$pool"/*; do
    [ -d "$slot" ] || continue
    for copy in "$slot"/*; do
      [ -d "$copy" ] || continue
      [ -e "$copy/.git" ] || continue
      printf '%s\n' "$copy"
    done
  done
}

# The absolute common git directory backing a checkout - the shared object store
# a repository and all of its worktrees agree on. Two copies with the same value
# here belong to the same repository however their paths are spelled.
fm_pool_common_dir() {  # <dir>
  local dir=${1:-} common
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  fm_pool_realpath "$common"
}

# The primary checkout of the repository backing <dir>: the main worktree, which
# is the parent of a non-bare common git directory. Empty for a bare repository,
# which has no working tree to acquire from.
fm_pool_primary_checkout() {  # <dir>
  local dir=${1:-} common parent
  common=$(fm_pool_common_dir "$dir") || return 1
  case "$common" in
    */.git) ;;
    *) return 1 ;;
  esac
  parent=${common%/.git}
  fm_pool_realpath "$parent"
}

# The refusal that keeps one repository to one pool. Returns 0 when <dir> is a
# repository's own primary checkout and so is safe to acquire a pool copy from;
# otherwise prints why and returns non-zero. Not a warning: acquiring anyway is
# what silently doubles a project's disk.
fm_pool_assert_acquirable() {  # <dir> [<label>]
  local dir=${1:-} label=${2:-pool acquire} top primary
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    echo "error: $label: '$dir' is not an existing directory" >&2
    return 1
  fi
  if ! top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    echo "error: $label: '$dir' is not inside a git repository, so treehouse cannot resolve a pool for it" >&2
    return 1
  fi
  top=$(fm_pool_realpath "$top") || {
    echo "error: $label: could not resolve the working tree containing '$dir'" >&2
    return 1
  }
  if ! primary=$(fm_pool_primary_checkout "$dir") || [ -z "$primary" ]; then
    echo "error: $label: could not resolve the primary checkout backing '$dir'; refusing rather than seeding a pool that may duplicate an existing one" >&2
    return 1
  fi
  if [ "$top" != "$primary" ]; then
    echo "error: $label: '$top' is a linked worktree of '$primary', not that repository's primary checkout." >&2
    echo "Treehouse names a pool after the working tree it is invoked in, so acquiring here would seed a SECOND pool for one repository and double its disk. Acquire from '$primary' instead." >&2
    return 1
  fi
  return 0
}

# Pool directories that back the SAME repository, i.e. duplicates. Prints one
# line per repository that owns more than one pool:
#   <common-git-dir><TAB><pool-dir>,<pool-dir>[,...]
# Grouping is by common git directory, so it identifies duplicates by object
# store rather than by path spelling. A repository whose checkout was renamed or
# re-cloned leaves an ORPHAN pool instead (fm_pool_backing_state below), which is
# a different fault with a different remedy.
fm_pool_duplicate_dirs() {
  local pool copy common
  {
    while IFS= read -r pool; do
      [ -n "$pool" ] || continue
      copy=$(fm_pool_copies "$pool" | head -1)
      [ -n "$copy" ] || continue
      common=$(fm_pool_common_dir "$copy") || continue
      printf '%s\t%s\n' "$common" "$pool"
    done < <(fm_pool_dirs)
  } | LC_ALL=C sort | awk -F'\t' '
    { if ($1 == key) { list = list "," $2; n++ } else { if (n > 1) print key "\t" list; key = $1; list = $2; n = 1 } }
    END { if (n > 1) print key "\t" list }
  '
}

# Whether a pool's backing repository is still present: prints "present <primary>"
# when its primary checkout resolves, "orphan" when the repository it was seeded
# from is gone, and "unknown" when it cannot be determined. An orphan pool holds
# copies whose object store no longer exists, so nothing in it can be validated
# against a branch - the reaper reports those and never guesses them safe.
fm_pool_backing_state() {  # <pool-dir>
  local pool=${1:-} copy primary
  copy=$(fm_pool_copies "$pool" | head -1)
  if [ -z "$copy" ]; then
    printf 'unknown\n'
    return 0
  fi
  if ! git -C "$copy" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'orphan\n'
    return 0
  fi
  if primary=$(fm_pool_primary_checkout "$copy") && [ -n "$primary" ]; then
    printf 'present %s\n' "$primary"
    return 0
  fi
  printf 'unknown\n'
}

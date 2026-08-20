# Per-worker memory cap verification

Repeatable evidence for the memory bound applied to every spawned worker.
Current behavior and the operator contract are owned by [`../configuration.md`](../configuration.md) ("Crew memory cap"), and the mechanism by the header of `bin/fm-crew-memory-cap.sh`; this page records evidence only.

Date: 2026-08-20.
Host: systemd 255 (255.4-1ubuntu8.17).
Shell: GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu).
Memory: 29 GiB RAM, 16 GiB swap.
Comparison base: `main` at `3334373`.

## Why the bound sets two properties, not one

`MemoryMax` alone is not a bound on a host with swap: the kernel reclaims the cgroup into swap instead of refusing the allocation.
This is not a theoretical concern - the process that took the host down on 2026-08-20 held 7.2 GiB in swap on top of its 24.6 GiB resident.
The same child, allocating 16 MiB blocks outside any managed heap, was run under a 256M cap with and without `MemorySwapMax=0`:

```console
$ systemd-run --user --scope -q -p MemoryMax=256M -- python3 hog.py peak 1024
$ cat peak
1024
$ systemd-run --user --scope -q -p MemoryMax=256M -p MemorySwapMax=0 -- python3 hog.py peak 1024
$ cat peak
240
```

Without `MemorySwapMax=0` the child ran four times past its limit and was never refused; with it, the child stopped at the limit.
`tests/fm-crew-memory-cap.test.sh` pins this by asserting the peak rather than an exit status, because a cgroup that refuses an allocation may either kill the process or fail its `malloc`, and which one happens is not deterministic.

## What supervision sees when the bound fires

When any process in the scope is killed, systemd tears down the whole scope, so the worker dies as a unit rather than leaving a surviving parent attached to a dead child.
`memory.oom.group` is `0`, so this is systemd's unit handling rather than a kernel group-kill:

```console
$ systemd-run --user --scope -q -p MemoryMax=256M -p MemorySwapMax=0 -- \
    bash -c 'python3 hog.py peak 65536; echo PARENT-CONTINUED'
$ echo $?
143
```

`PARENT-CONTINUED` is never reached and the scope exits 143 (SIGTERM).
The pane then holds nothing but its shell, which `fm_backend_agent_state` reports as `dead` - the same recovery-grade state any other stopped worker produces, handled by the existing `stuck-crewmate-recovery` path with no new supervision case.

## A bounded death does not litter the user manager

systemd keeps a failed transient unit rather than collecting it, so without `CollectMode=inactive-or-failed` every worker killed at its limit would leave a permanent failed scope in the user manager.
This is not theoretical either: 24 of them accumulated across one afternoon of building this, and on a host where the bound fires regularly they would grow for as long as the machine runs.

```console
$ systemd-run --user --scope -q --description='collectmode-off-probe' \
    -p MemoryMax=128M -p MemorySwapMax=0 -- python3 hog.py
$ systemctl --user list-units --type=scope --state=failed --no-legend | grep -c collectmode-off-probe
1
$ systemd-run --user --scope -q --description='collectmode-on-probe' \
    -p CollectMode=inactive-or-failed -p MemoryMax=128M -p MemorySwapMax=0 -- python3 hog.py
$ systemctl --user list-units --type=scope --state=failed --no-legend | grep -c collectmode-on-probe
0
```

The kill is still recorded in the journal, so the durable evidence is unaffected.
`cap_properties` in `bin/fm-crew-memory-cap.sh` is the single owner of the property set, and both the availability probe and the real launch go through it, so the probe can never validate a different scope shape than a worker actually receives.

## The wrapper is invisible to liveness

`systemd-run --user --scope` execs into the command rather than supervising it, so it adds no process to the pane's foreground process group and the liveness classifier's verdict is unchanged.
`tests/fm-crew-memory-cap.test.sh` asserts both halves against the real classifier in `bin/backends/tmux.sh`, driving real processes in a real tmux server isolated by `tests/tmux-test-safety.sh`, which proves the redirect before the suite runs: a bounded worker reads `alive`, no `systemd-run` appears in the pane's foreground process group, and a worker killed at its limit reads `dead`.

The transition is observed promptly rather than lingering on a stale `alive`: driving a recognised agent that sleeps three seconds and then over-allocates, the classifier reports `alive` while it sleeps and `dead` 3.0 seconds later, so the detection itself is immediate once the process is gone.
The known false-alive read tracked as `fm-tmux-liveness-false-alive` did not obstruct this path.

Transient scopes are created as siblings under `app.slice` rather than nested inside the caller's scope, so a secondmate's own crewmates each receive an independent limit and cannot be starved by their parent's.

## Every supported harness composes under the wrapper

The bound wraps the fully composed launch line, so it touches every harness rather than only the ones a given fleet happens to run.
Single-quote escaping is a total encoding, so no launch string can break the quoting; what needed checking per harness is that each template is valid POSIX shell once wrapped, since the inner command is now run by `/bin/sh -c` rather than by the pane's interactive shell.

Driving `bin/fm-spawn.sh` against a fake tmux for each adapter, and checking the two templates whose binaries must be installed to compose (`kimi`, `muse`) against filled-in placeholders:

| harness | bounded | wrapped line parses | inner command parses |
|---|---|---|---|
| `claude`, `codex`, `opencode`, `grok`, `pi`, `cursor` | yes | yes | yes |
| `kimi`, `muse` | yes | yes | yes |

Each inner command also round-trips back to the exact pre-wrap string, which is what `fm_launch_unwrap` in `tests/lib.sh` relies on so existing launch-line assertions keep testing the command a worker actually runs.

## Coverage

`tests/fm-crew-memory-cap.test.sh` (25 assertions) covers the derived default and its floor and ceiling across 4 GiB, 29 GiB, and 256 GiB hosts; the operator override and its refusals (malformed, multi-line, symlinked); the quoting contract of `wrap`, asserted by running the wrapped command rather than by matching its shape; open degradation on a host with no `systemd-run` and on a host whose `systemd-run` refuses, both returning the command unchanged with a reason and neither failing the caller; the spawn-path integration through the real `bin/fm-spawn.sh`; the real bound stopping a runaway child, with an unbounded control run of the same child proving the case is not vacuous; and the liveness assertions above.
The portable assertions run everywhere; the sections needing systemd, a user manager, and cgroup memory delegation self-skip with a stated reason rather than failing.

```console
$ bash tests/fm-crew-memory-cap.test.sh | tail -3
ok - the wrapper execs into the worker and adds no process to the pane
ok - a worker killed at its limit reads 'dead', which supervision recovers from
ok - fm-crew-memory-cap full coverage complete
```

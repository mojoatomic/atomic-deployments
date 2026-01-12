# atomic-deploy

Atomic symlink deployments that actually work on macOS.

## The Problem

Most "atomic" deployment scripts use this pattern:

```bash
ln -sfn releases/20260112 current
```

It's not atomic. Here's what actually happens:

```
symlink("releases/20260112", "current") = -1 EEXIST
unlink("current") = 0                    # ← current doesn't exist here
symlink("releases/20260112", "current") = 0
```

Under load, requests hit that gap and get `ENOENT`. Your "zero-downtime" deploy just caused downtime.

The Linux fix is well-known:

```bash
ln -s releases/20260112 .tmp/current.$$
mv -T .tmp/current.$$ current
```

The `mv -T` calls `rename(2)`, which atomically replaces the target.

**But this doesn't work on macOS.** BSD `mv` doesn't have `-T` and follows symlinks differently. The Capistrano and Deployer communities have known about this for years. Most just accept the race condition on Mac.

## The Solution

This script uses Python's `os.replace()` on BSD systems, which calls `rename(2)` directly:

```bash
# Linux
mv -T "$tmp_link" "current"

# macOS/BSD  
python3 -c "import os; os.replace('$tmp_link', 'current')"
```

One script. Works everywhere.

## Installation

```bash
curl -O https://raw.githubusercontent.com/mojoatomic/atomic-deploy/main/deploy.sh
chmod +x deploy.sh
```

## Usage

```bash
./deploy.sh <source_dir> <deployment_root>
```

**Example:**

```bash
./deploy.sh ./build /var/www/myapp
```

This will:

1. Create `/var/www/myapp/releases/20260112143052/` (timestamped)
2. Copy `./build/*` into the release directory
3. Atomically swap the `current` symlink to point to the new release

Your web server points at `/var/www/myapp/current`.

## Directory Structure

```
/var/www/myapp/
├── current -> releases/20260112143052
├── releases/
│   ├── 20260112143052/
│   ├── 20260111092341/
│   └── 20260110083022/
└── .tmp/
```

## Features

**Atomic symlink swap** — No race condition on Linux or macOS.

**Automatic rollback** — If interrupted (Ctrl+C, SIGTERM), rolls back to previous release.

**Directory-based locking** — Prevents concurrent deploys. Detects and cleans up stale locks from crashed processes.

**State machine cleanup** — Knows whether to rollback or just clean up temp files based on where in the process the interrupt occurred.

**Platform detection** — Detects GNU vs BSD coreutils automatically (not just `uname`).

**No runtime dependencies** — Just bash and python3 (ships with macOS and every Linux distro).

## What This Doesn't Do

- **Shared directories** — No Capistrano-style shared folder symlinking. That's a separate concern.
- **Remote deployment** — This runs locally. Wrap it in ssh/rsync for remote deploys.
- **Release cleanup** — Doesn't prune old releases. Add a cron job or post-deploy hook.
- **Service restarts** — You handle that (systemctl, pm2, etc.).

## Testing the Race Condition

Want to see the bug yourself? Here's a test harness:

```bash
#!/bin/bash
# test-race.sh - Demonstrates ln -sfn race condition

mkdir -p releases/v1 releases/v2
echo "v1" > releases/v1/version
echo "v2" > releases/v2/version
ln -s releases/v1 current

errors=0

# Reader loop - runs in background
(
  for i in {1..10000}; do
    cat current/version 2>/dev/null || echo "ENOENT"
  done
) > reads.log &

reader_pid=$!

# Writer loop - rapidly swaps symlink
for i in {1..1000}; do
  ln -sfn releases/v1 current
  ln -sfn releases/v2 current
done

wait $reader_pid

errors=$(grep -c ENOENT reads.log)
echo "Errors: $errors / 10000 reads"

rm -rf releases current reads.log
```

On a typical system you'll see 10-50 errors per run. With `atomic-deploy`, you get zero.

## FAQ

**Why not just use Capistrano/Deployer?**

Those require Ruby/PHP. This is a single bash script you can drop into any CI pipeline.

**Why not containers/Kubernetes?**

Not everyone is on k8s. VMs, bare metal, and edge devices still exist. Symlink swaps remain the simplest zero-downtime pattern for those environments.

**Python is a dependency.**

Yes, but python3 ships with macOS and virtually every Linux distro. It's as close to "always there" as bash. The alternative is a compiled binary, which creates distribution problems.

**What about `renameat2()` with `RENAME_EXCHANGE`?**

That's Linux 3.15+ with glibc 2.28+. It does a true atomic swap of two paths. Better, but not portable. The symlink + rename pattern works everywhere.

**Does this work on NFS?**

No. `rename(2)` atomicity guarantees don't hold on network filesystems. Local filesystems only.

## How It Works

1. **Acquire lock** — `mkdir .deploy.lock` (atomic on POSIX). Write PID for stale detection.

2. **Create release** — Copy source to timestamped directory under `releases/`.

3. **Validate** — Check release directory isn't empty.

4. **Swap symlink** — 
   - Create temp symlink: `ln -s releases/NEW .tmp/current.$$`
   - Atomic replace:
     - Linux: `mv -T .tmp/current.$$ current`
     - BSD: `python3 -c "import os; os.replace('.tmp/current.$$', 'current')"`

5. **Cleanup** — Release lock, clean temp files.

If interrupted between steps 3-4, the trap handler rolls back to the previous release.

## Platform Detection

The script detects GNU vs BSD by checking `mv --version`:

```bash
detect_platform() {
    if mv --version 2>/dev/null | grep -q 'GNU'; then
        printf 'linux'
    else
        printf 'bsd'
    fi
}
```

This is more reliable than `uname` for edge cases like GNU coreutils installed via Homebrew on Mac.

## License

MIT

## See Also

- [Atomic symlinks](https://temochka.com/blog/posts/2017/02/17/atomic-symlinks.html) — Deep dive on the problem
- [Things UNIX can do atomically](https://rcrowley.org/2010/01/06/things-unix-can-do-atomically.html) — The `mv -T` insight
- [Capistrano issue #346](https://github.com/capistrano/capistrano/issues/346) — Original bug report from 2013

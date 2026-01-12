# Contributing

Thanks for your interest in contributing.

## Before You Start

**Open an issue first.** Before writing code, let's discuss:
- Is this in scope?
- Is there already a solution?
- What's the best approach?

This saves everyone time.

## What's In Scope

- Bug fixes
- Platform compatibility improvements
- Documentation improvements
- Test coverage

## What's Out of Scope

This script intentionally does one thing well. These are separate concerns:

- Shared directory management (Capistrano-style)
- Remote deployment (use rsync/ssh wrapper)
- Release pruning (use cron)
- Service restarts (use your init system)
- Container/k8s deployment

## Pull Request Process

1. Fork the repo
2. Create a feature branch (`git checkout -b fix/descriptive-name`)
3. Make your changes
4. Test on both Linux and macOS if possible
5. Update README if behavior changes
6. Open PR against `main`

## Code Style

- ShellCheck clean (`shellcheck deploy.sh`)
- Use `local` for function variables
- Prefer `[[` over `[`
- Quote your variables
- Meaningful variable names over comments

## Testing

Run the race condition test:

```bash
./test-race.sh
```

Run ShellCheck:

```bash
shellcheck deploy.sh
```

## Commit Messages

```
Short summary (50 chars or less)

Longer explanation if needed. Wrap at 72 characters.
Explain what and why, not how.

Fixes #123
```

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

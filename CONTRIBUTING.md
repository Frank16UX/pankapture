# Contributing

Thanks for helping. Bug reports, ideas, and pull requests are all welcome.

## Issues

- **Bugs:** say what you did, what you expected, and what happened. Include your macOS version, the app version (Settings → Updates), and logs if you can (`make logs` while reproducing).
- **Ideas:** describe the problem you're trying to solve before the solution.
- **Security problems:** don't open an issue; see [SECURITY.md](SECURITY.md).

## Pull requests

1. Fork the repo and branch from `main`.
2. Set up: select Xcode (`sudo xcode-select -s /Applications/Xcode.app`), then `make cert` once and `make run`.
3. Make your change. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first for anything beyond a small fix, and keep to the rules in [CLAUDE.md](CLAUDE.md) (module boundaries, design tokens, theming, concurrency).
4. Run `make test` (not bare `swift test`).
5. Open a pull request that explains what changed and why. Screenshots or a short recording help for UI changes.

What to expect:

- `main` is protected. Every change lands through a pull request that the maintainer reviews and merges.
- CI runs on your pull request after the maintainer approves it to run. It tests and builds the app but has no access to signing keys and publishes nothing.
- Every merge to `main` ships a release to everyone with automatic updates on, so reviews are careful and changes to `.github/` or `scripts/` get extra scrutiny.
- Keep pull requests focused. One fix or feature each is easier to review and to revert.
- Don't name other apps in code, docs, or commits; describe features generically.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

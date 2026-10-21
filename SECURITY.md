# Security

Pankapture records your screen, microphone, and camera, and updates itself from this repository's releases, so security reports are taken seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through [GitHub's private vulnerability reporting](https://github.com/Frank16UX/pankapture/security/advisories/new) instead. Include what you found, how to reproduce it, and which version you're on (Settings → Updates).

You'll get a reply within a week. Once a fix ships, the advisory is published with credit to you unless you'd rather stay anonymous.

## Supported versions

Only the latest release gets fixes. The app checks for updates daily by default.

## What's in scope

- The app itself: capture, recording, history, URL commands (`pankapture://`), and the in-app updater.
- The release pipeline: `.github/workflows/`, `scripts/release.sh`, and `scripts/install.sh`.

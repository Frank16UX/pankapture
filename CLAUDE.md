# Pankapture — agent guide

Native macOS (Apple Silicon, macOS 15+) screenshot / annotation / screen-recording app. Swift 6, SwiftPM, no third-party dependencies.

Read first: `docs/PRD.md` (requirements with IDs), `docs/ARCHITECTURE.md` (decisions, modules, flows), `docs/DESIGN.md` (visual rules), `docs/ROADMAP.md` (current milestone).

## Commands

- `make build`: debug compile. `make test`: unit tests. `make run`: bundle + launch `build/Pankapture.app`.
- Always run `make test` (not bare `swift test`): with the Command Line Tools toolchain it adds the swift-testing plugin path that `swift test` otherwise intermittently misses.
- Logs: `make logs` (zsh shadows `log`; use `/usr/bin/log`).

## Rules

- **No product names of other apps in docs, code, or commits.** Describe features generically ("inline annotation", "quick-access thumbnail"), never by competitor or reference-app name.
- **Toolchain:** build with Xcode selected (`xcode-select -p` → `/Applications/Xcode.app/...`). SwiftUI/SwiftData macros (`@State`, `@Entry`, `@Model`, `#Preview`) need Xcode's plugins; the Command Line Tools alone can't build the app.
- **No SwiftPM resources** (`resources:` in Package.swift): `Bundle.module` doesn't resolve inside the hand-assembled `.app`. Draw assets in code or use SF Symbols.
- **Module boundaries** (ARCHITECTURE §3): the app target is a thin composition root; feature modules depend only on `AppCore`/`DesignSystem`/`Annotation`; `Annotation` stays pure. Add a module when its milestone starts, never as an empty placeholder.
- **Theming:** chrome uses semantic colors and materials only (`.primary`, `.secondary`, `Color.accentColor`, `.separator`, `pkSurface()`). No hex colors in chrome. Annotation colors and overlay dimming are content and don't follow the theme.
- **Tokens:** spacing, radii, metrics, and motion come from `PK.*` in `DesignSystem/Tokens.swift`.
- **Concurrency:** Swift 6 strict; UI and coordinators are `@MainActor`; capture/recording pipelines run on their own serial queues. `@unchecked Sendable` only for immutable CF wrappers, with a comment.
- **Coordinates:** name variables by space (AppKit global / Quartz global / capture-local) and convert at one boundary (ARCHITECTURE §5).
- **Preferences:** every UserDefaults key lives in `AppCore/Preferences.swift` (`PreferenceKey`).
- **Docs stay current:** when a requirement lands, tick it in `ROADMAP.md` and mark the milestone ✅ in the PRD table. Record new architectural decisions as ADRs in ARCHITECTURE §2.
- **Performance budgets** (PRD §6.1) are requirements. Hot paths get `os_signpost` intervals.

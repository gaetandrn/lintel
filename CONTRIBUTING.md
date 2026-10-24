# Contributing

Bug reports and pull requests are welcome. For a security issue, see [SECURITY.md](SECURITY.md).

## Build

Requirements: macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). Running the tests needs Xcode.

```sh
scripts/dev.sh      # build, install over your copy, relaunch (arguments go to the app)
scripts/test.sh     # unit tests
scripts/bundle.sh   # build Lintel.app only (--universal, --adhoc)
```

The first `scripts/dev.sh` run creates a signing certificate, **Lintel Local**, in a keychain of Lintel’s own (`~/Library/Application Support/Lintel`), so macOS keeps the Accessibility permission across rebuilds.

Try installer changes with `LINTEL_DRY_RUN=1 ./install.sh`: it prints the commands that would change the system instead of running them.

## Guidelines

- Keep it light: no animations; react to notifications, and poll only where macOS posts none (say why in a comment).
- Put platform-independent logic in `LintelCore` and cover it with tests.
- Comments explain *why*, not *what*.
- User-facing strings go in `Resources/en.lproj` and `Resources/fr.lproj`.
- Scripts must pass `shellcheck` (CI runs it) and work with macOS’s bash 3.2.

## Release

Write the release notes in an annotated tag and push it. GitHub Actions tests, builds a universal `Lintel.zip`, checks it and publishes the release with the tag’s notes, and attaches `install.sh`, `uninstall.sh` and `agent-hooks.py`. The install and uninstall commands download those copies, so changes on `main` reach users only with the next release.

```sh
git tag -a v0.2.0 -m "Lintel 0.2.0" -m "- What changed, in a line or two"
git push origin v0.2.0
```

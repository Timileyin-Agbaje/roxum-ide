# CLAUDE.md

## Commands

```bash
flutter pub get --enforce-lockfile
flutter analyze                      # must report no issues
flutter test                         # unit tests; SSH tests skip without the env vars below
ROXUM_TEST_SSH=ssh://user@host:port ROXUM_TEST_SSH_KEY=/path/to/key flutter test test/vm_run_ssh_test.dart
```

The APK cannot be built locally (arm64 dev machine, no `aapt2`). CI builds it: `.github/workflows/build-apk.yml`.

## What this is

A personal fork of Roxum IDE (Flutter, Android) for hand-coding JS, TS, React, HTML and CSS on a phone. Editing happens on the phone; Play can run the project on an Azure VM over SSH. The owner codes on a Samsung Z Fold 4 and an Itel S23 (4 GB RAM, 720×1612), has no computer, and installs the APK from GitHub Releases.

- `PLAN.md`: the current work. Do the work packages in order, one branch and PR each.
- `info.md`: what plan 1 (Run on Azure VM) built and why. Read it before touching VM code.

## Where things live

- `lib/ui/editor_page.dart`: editor screen, Play button, run commands.
- `lib/ui/widgets.dart` (about 13,800 lines): editor widgets, bottom toolbar, autosave.
- `lib/terminal/terminal.dart`: terminal sessions, extra keys, SSH sessions, stop.
- `lib/utils/vm_run.dart`: everything VM: run target, SFTP sync, run plans, preview tunnel.
- `lib/utils/functions.dart`: SSH connect, `startLspServer()` (language servers).
- `lib/utils/themes.dart`: app, editor and terminal themes.
- `packages/code_forge/` (after PLAN WP2): vendored editor library: highlighting, completion popup, LSP client.
- State uses `flutter_bloc` (BLoC/Cubit) in `lib/bloc/`.

## Things that will bite you

- **Upstream merges.** The owner pulls upstream with GitHub's "Sync fork". Hide unused features behind constants in `lib/utils/constants.dart` instead of deleting their code. Keep edits to upstream files small and local.
- **Don't reformat.** Upstream code is not `dart format`ted. Format only new files and the lines you change, never whole existing files.
- **Huge files.** `widgets.dart` and `editor_page.dart` are very large. Edit surgically; don't split or reorganize them.
- **Vendored `code_forge`.** Keep the first vendoring commit unchanged from 10.14.0. Put each of our changes in its own clear commit. Don't upgrade it.
- **Slow phone.** The Itel has 4 GB RAM. Nothing per keystroke may allocate much or block the UI thread: no full-document re-highlighting, no synchronous file or network I/O.
- **Signing.** Every build must use the existing keystore (repo secrets `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`), or updates won't install. Never change the package name `com.roxum`.
- **Public repo.** Never commit the VM's IP, usernames, keys, Azure credentials or tokens. Use `<vm-ip>` in docs. Never print secrets in logs or CI output.
- **Git LFS.** Native assets are LFS files. Don't add large binaries outside LFS.
- **Dynamic feature modules.** Only `node_feature` and `vscode_langservers_extracted_feature` exist; the app stages them from the APK, never from the Play Store.

## Writing code

- Make the smallest change that does the job. No speculative abstractions, options or "future-proofing".
- Match the surrounding code: naming, BLoC/Cubit patterns, widget structure.
- No new dependencies unless clearly needed; say why in the PR description.
- Comments explain why, not what. No commented-out code.
- Handle errors where users would see them (SSH, SFTP, LSP, Azure): show a short, plain message and keep the app usable.
- User-facing text is short and plain.

## Tests

Keep tests few and valuable.

- Write unit tests only for pure logic that is easy to get wrong: fuzzy matching and ranking, theme scope resolution, snippet parsing, sync decisions, shell quoting, output-block detection.
- About 3–8 focused tests per work package is plenty. Cover the main cases and the one or two edge cases that matter.
- No widget or golden tests, no tests for getters, constants or simple wiring, no mocks of large classes, no tests written just to add coverage.
- Don't rewrite or delete existing tests unless the behavior they check changed on purpose.
- UI and on-device behavior is checked by the owner using the acceptance tests in `PLAN.md`; list the exact steps in the PR.

## Git and pull requests

- Branch from `playstore-version` as `wp<n>-<short-name>`. Never push to `playstore-version` directly.
- Small, focused commits with clear messages. One PR per work package, into `playstore-version`.
- Before opening or updating a PR: `flutter analyze` is clean and `flutter test` passes.
- PR description: what changed and why, any deviation from `PLAN.md` with the reason, and "How to test on the phone" steps.
- **Greptile reviews every PR.** Read all its comments. Fix the valid ones in new commits on the same branch. If you disagree, reply on the comment with a one-line reason instead of changing the code. Don't resolve comments you didn't address.
- CI builds an APK for each PR. Don't merge; the owner merges after testing that APK.
- If the plan conflicts with the code, or a decision changes what the owner will see, stop and ask.

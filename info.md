# Session record: Roxum IDE fork, "Run on Azure VM"

This file records what was done in the working session of 6 October 2026 that implemented `PLAN.md`, so any person or agent picking up this fork can understand the current state without the conversation. Read `PLAN.md` first for the goals; this file covers what was built, how, why, and what is left.

**Status: done.** All work packages are implemented, built by CI, installed on both phones (Samsung Z Fold 4 and Itel S23), and the owner confirmed every acceptance test in `PLAN.md` passes, including stopping and restarting the VM.

## Contents

1. [Summary](#1-summary)
2. [Repository and branches](#2-repository-and-branches)
3. [Commits](#3-commits)
4. [Work packages in detail](#4-work-packages-in-detail)
5. [Decisions and deviations from the plan](#5-decisions-and-deviations-from-the-plan)
6. [Testing](#6-testing)
7. [CI, signing and releases](#7-ci-signing-and-releases)
8. [Installing, and the corrupted download problem](#8-installing-and-the-corrupted-download-problem)
9. [VM setup done by the owner](#9-vm-setup-done-by-the-owner)
10. [Known limitations and leftovers](#10-known-limitations-and-leftovers)
11. [How to continue working on this](#11-how-to-continue-working-on-this)

## 1. Summary

The fork's Play button can now run JavaScript, TypeScript and Vite/React projects on a Linux VM over SSH, while editing stays on the phone:

- Pick the VM in the menu next to Play (remembered per project).
- Play syncs the project to `~/roxum/<project folder>` on the VM over SFTP (changed files only), then runs it in an SSH terminal: `npm install` (only when needed) plus `npm run dev` for projects with a `dev` script, `npx --yes tsx` for `.ts`/`.tsx`, `node` for `.js`/`.mjs`/`.cjs`.
- A Vite dev server is previewed in the app's webview through an SSH tunnel; saves sync automatically so hot reload works.
- Stop sends Ctrl+C, then kills whatever is left of the run's process group on the VM.
- If the VM is off, Play shows "VM unreachable" with "Run on phone instead".

The app was also slimmed to the web toolchain (Node.js with TypeScript, VSCode HTML/CSS/JSON language servers). 18 language feature modules, local GGUF models (`llama_flutter_android`) and Copilot were removed or hidden. The universal APK is about 104 MB (the plan estimated 250 MB).

## 2. Repository and branches

| Item | Value |
| --- | --- |
| Fork | `Timileyin-Agbaje/roxum-ide` (fork of `heckmon/roxum-ide`, MIT) |
| Working branch | `playstore-version`, the fork's default branch. There is no `main` branch; everything is pushed straight to `playstore-version`. |
| Upstream remote | `upstream` → `heckmon/roxum-ide` |
| Base | Roxum 2.7.0 (`e6bd626`), plus the owner's `PLAN.md` upload (`c70cc55`) |

## 3. Commits

Each work package was committed separately, except WP3–WP6 (see section 5).

| Commit | What |
| --- | --- |
| `aa9fce9` | WP1: fix saved SSH key path, warn before regenerating keys |
| `e5759dc` | WP2: slim the app to JS/TS/React, HTML and CSS |
| `8393302` | WP8: GitHub Actions workflow building a signed universal APK |
| `3e74ed9` | WP3–WP6: run on a VM (run target, SFTP sync, VM commands, preview tunnel) |
| `f483e7f` | WP7: README section on installing, preparing the VM and running |
| `4cf5172` | Always upload just-saved files when syncing on save (bug fix found in review) |

## 4. Work packages in detail

### WP1: SSH key path bug (`lib/utils/functions.dart`, `lib/ui/settings.dart`)

- `SSHPrivateKey.fromJsonMap` always set the key to `$appDir/.termux/.ssh/id_ed25519` (the Termux key), so remote servers that use the app key `$appDir/.ssh/id_ed25519` failed after an app restart. It now reads the saved `termuxKeyLoc`; `null` means the app key (the fallback in `connect()` already handles it). Termux entries are saved with their real path, so they keep working.
- **Regenerate keys** now shows a confirmation dialog explaining that every server will reject the app until the new public key is added.

### WP2: slim the app

- **Gradle:** removed 18 modules from `dynamicFeatures` in `android/app/build.gradle.kts` and from `android/settings.gradle.kts`, and deleted their folders. Kept `node_feature` and `vscode_langservers_extracted_feature`.
- **Local models:** removed the `llama_flutter_android` dependency (`pubspec.yaml`/`pubspec.lock`), its `InferenceService` in `AndroidManifest.xml` and its ProGuard rules. `lib/utils/local_llama_stub.dart` mirrors the three symbols the app uses (`LlamaController`, `GpuInfo`, `ChatMessage`) and makes every call fail, so the hidden local-model code still compiles. The GGUF buttons and the `LocalLlama` provider are hidden behind `kLocalModelsEnabled = false` in `lib/utils/constants.dart`.
- **Copilot:** the sign-in button is hidden behind `kCopilotEnabled = false`. Its extension is no longer installable, and every Copilot start-up path already bails when `extensions/copilot-language-server` is missing, so the rest of the Copilot code is inert.
- **Downloads catalog:** `lib/utils/package_catalog.dart` filters both lists to `node` and `vscode-langservers-extracted` (`_keptPackages`). The entries themselves were left in place so upstream catalog changes merge cleanly.
- **Run commands (`lib/ui/editor_page.dart`, phone branch):** removed the C/C++, Java, Kotlin, Zig, Go and Rust recipes. The fallback now refuses languages whose run command is not bundled (`_bundledRunCommands = {'node', 'tsc', 'bash'}`) with "Running X files isn't supported in this build", instead of invoking a missing binary. The Termux branch was left unchanged because Termux brings its own toolchains.
- **Templates (`lib/utils/proj_temps.dart`):** removed the Dart and Rust project templates.
- **No Play Store downloads (`lib/ui/downloads.dart`):** if Play Core does not report a module as installed, the app stages it from the asset bundled in the APK; the Play `installModule` path was removed. Inspection of the built APK showed bundletool writes `com.android.dynamic.apk.fused.modules = base,node_feature,vscode_langservers_extracted_feature`, which Play Core reads, so modules normally report as installed anyway.
- Syntax highlighting for all languages was kept.

### WP3: choose where code runs

- The menu next to Play (previously Phone/Termux plus a greyed-out "Remote server, coming soon" placeholder) now lists **Phone**, Termux (when connected) and every saved SSH server, plus **Sync on save** and **Clean VM copy** when a VM is selected. The Play icon shows a cloud badge when a VM is selected.
- The choice is stored per project in SharedPreferences (`runTarget:<rootDir>`, `RunTargetStore` in `lib/utils/vm_run.dart`) and restored when the editor opens.
- Running on a VM connects first if needed (`ensureVmConnected`, which also treats a closed client as disconnected). SSH connects now time out after 15 s (`functions.dart`). On failure: "VM unreachable … Start it in the Azure app" with **Cancel** / **Run on phone instead**.

### WP4: SFTP sync (`VmProjectSync` in `lib/utils/vm_run.dart`)

- Mirrors the project to `~/roxum/<project folder name>` using `dartssh2` SFTP on the existing connection.
- Uploads files whose size or modified time differ from a manifest stored per server at `$appDir/vm-sync/<serverId>.json` (keyed by project path). If the remote folder has disappeared, everything is uploaded again.
- Skips `node_modules`, `.git`, `dist`, `build`, `.vite`, `.next`, `coverage` at any depth, and `*.log`. Refuses folders with more than 5000 syncable files.
- Syncs before every run. While a VM dev server runs, saves sync after a 300 ms debounce. Both save points (autosave in `lib/ui/widgets.dart`, manual save in `editor_page.dart`) call `VmSaveEvents.notifySaved(path)`; Dart cannot watch folders recursively on Android. Just-saved files are always uploaded, even if size and time look unchanged (fix in `4cf5172`).
- Never deletes remote files. **Clean VM copy** stops the run and deletes the project folder and its run script on the VM, after confirmation.
- Progress shows in a status line at the bottom of the editor (`VmSession.status`, `_buildVmStatusLine`).

### WP5: run commands on the VM (`VmRunPlan`, `prepareRunCommand`, `lib/terminal/terminal.dart`)

| What is run | Command |
| --- | --- |
| Project whose `package.json` has a `dev` script, Vite detected | `npm install` if `node_modules` is missing or the `sha1sum` stamp of `package.json` + lockfile in `node_modules/.roxum-deps` does not match, then `npm run dev -- --host 127.0.0.1 --port 5173 --strictPort` |
| Project with another `dev` script | same install step, then `npm run dev` (no preview tunnel) |
| `.ts`, `.tsx` | `npx --yes tsx <file>` |
| `.js`, `.mjs`, `.cjs` | `node <file>` |
| HTML, CSS, Markdown, anything else | unchanged: runs or previews on the phone |

- Each run uploads a script to `~/.roxum/run-<project>.sh` that writes its PID (which is its process-group ID under the interactive shell's job control) to `~/.roxum/run-<project>.pid`, removes it on exit, and prints a hint if Node.js is missing. The app types `cd <project folder> && bash ~/.roxum/run-<project>.sh` into an interactive SSH shell, so the shell stays usable afterwards (for example `hostname`).
- Before each run, the previous run of the same project is stopped, so port 5173 is free.
- **Stop:** `TerminalRuntime.stopProcess` now sends Ctrl+C to SSH sessions (OpenSSH ignores the old `SSHSignal.KILL` request) and, 3 s later, runs the stop command, which sends TERM and then KILL to the whole process group.
- SSH terminal sessions are now marked as running (the Stop button used to stay disabled for them), stay "running" until the remote shell ends, and deleting a session closes its shell.

### WP6: preview through an SSH tunnel (`VmPreviewTunnel`, `VmSession`)

- When the Vite server answers on the VM (checked by opening a forward channel, every second, for up to 5 minutes), a local `ServerSocket` on `127.0.0.1:5173` (or the next free port up to 5192) forwards each connection with `client.forwardLocal('127.0.0.1', 5173)`, and the built-in webview opens that address. HMR WebSockets go through the same tunnel.
- The toolbar's Vite preview button opens the tunnel URL when a VM is selected.
- Every 5 s the tunnel checks the remote port and closes when the dev server stops or SSH drops; it also closes when the editor closes.

### WP7: README

A "This fork: run on a VM" section in `README.md` covers installing the APK, the one-time Node.js/`tsx` setup on the VM, adding the app's SSH key in Azure, how Play/Stop/sync/clean behave, and the workflow's secrets. It uses `<vm-ip>` rather than the real address because the repository is public.

### WP8: CI build (`.github/workflows/build-apk.yml`)

Runs on manual dispatch and on pushes to `playstore-version` (Markdown-only changes and `LICENCE` are ignored). It checks out with Git LFS through a cache, sets up JDK 17 and Flutter 3.47.6 (Dart 3.13.5), runs `flutter pub get --enforce-lockfile`, writes `android/key.properties` from secrets, builds the app bundle with build number `1000 + run number`, converts it with bundletool 1.18.3 `--mode=universal` (signed with the same keystore), uploads the APK as an artifact and publishes a GitHub Release `build-<run number>`.

### WP9 and WP10

- **WP9 (signing key):** generated in this session instead of on the VM (see section 7).
- **WP10 (switch over):** done by the owner: uninstalled the Play Store version, installed build 3 on both phones, generated a new app key, added it in Azure, connected.

## 5. Decisions and deviations from the plan

- **Run target state:** the plan said to reuse `CurrentlySelectedTerminalCubit`, but that cubit only drives the terminal button. The app already had `SelectedRuntimeEnvironmentCubit` for the Play button's target, so the VM option was added there.
- **WP3–WP6 in one commit:** they share `lib/utils/vm_run.dart` and the same editor code paths; splitting them would have produced commits that do not build.
- **Hide rather than delete:** to keep upstream merges easy ("Sync fork"), removed features are hidden behind constants or filters, and their Dart code was left in place. Only the native modules and the `llama_flutter_android` dependency were actually removed.
- **Termux runs unchanged:** removed languages may still run through Termux, which has its own packages.
- **`--strictPort`** was added to the Vite command so a busy port fails visibly instead of Vite silently moving to 5174, where the tunnel would not find it.
- **Signing key generated on this machine:** the owner asked for the build to be done without manual steps. The key was created here with `keytool`; the owner ran the script that uploads the GitHub secrets.
- **Tests not committed:** upstream's `.gitignore` excludes `/test`, so the tests exist only in the local clone (section 6).

## 6. Testing

Android builds cannot run on the development machine (Termux/proot on arm64; Google ships `aapt2` only for x86_64 Linux), so the APK is only built in CI. Everything else was verified locally:

- `flutter analyze` reports no issues (Flutter 3.47.6 installed at `/root/flutter`).
- `test/vm_run_test.dart`, 9 unit tests: exclusion rules, shell quoting (including a round trip through `sh`), and the command chosen for each file and project type.
- `test/vm_run_ssh_test.dart`, 7 integration tests against a real OpenSSH server (a local `sshd` on `127.0.0.1:2222` with Node.js 22). They are skipped unless `ROXUM_TEST_SSH=ssh://user@host:port` and `ROXUM_TEST_SSH_KEY=/path/to/key` are set. They cover: changed-only uploads and exclusions; re-uploading after the remote copy is deleted; forced upload of just-saved files; never deleting remote files; running `.js` and `.ts` (via `npx tsx`); Ctrl+C ending a run with the shell still usable; the stop command killing a run that ignores SIGINT, including its child process; and a real Vite project (install once, preview through the tunnel, sync on save, tunnel closing on stop). The first six passed three runs in a row; the forced-upload test was added afterwards and passed with the full suite.
- An early flaky failure came from the test itself (`pgrep -f` matching the shell running the check, and `ps -g` selecting by session rather than process group); the tests now check the run's process group with `pgrep -g`.
- The built APK was inspected with `aapt` and `apksigner`: package `com.roxum`, minSdk 26, targetSdk 36, arm64-v8a only, v2+v3 signatures, `libnode.so` (123 MB), `node.zip` and `vscode-langservers-extracted.zip` present, fused-modules metadata as above.
- On-device acceptance tests were run by the owner on both phones; all passed.

## 7. CI, signing and releases

- **Keystore:** `/root/roxum-signing/roxum-release.jks` (PKCS12, alias `roxum`, RSA 2048, valid 10000 days, certificate `CN=Roxum IDE fork`). The random password is in `/root/roxum-signing/credentials.txt` on the development machine, never in the repository. `set-secrets.sh` in the same folder uploads the four secrets. The owner was asked to back the folder up off the phone. **Every build must use this keystore**, or updates will not install over the existing app.
- **Repository secrets:** `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.
- **Releases:** `build-1`, `build-2`, `build-3` (latest, from `4cf5172`), each with a ~104 MB `roxum-2.7.0-<n>.apk` (versionCode `1000 + n`). Builds took about 5–15 minutes; repeat builds are faster thanks to the LFS, Gradle and pub caches.

## 8. Installing, and the corrupted download problem

- The Play Store Roxum has to be uninstalled first (same package name, different signing key); that deletes its data, so projects were backed up first.
- **Problem:** build 3 failed to install on both phones with "You can't install the app on your device". The APK on GitHub was fine (it matched the release's SHA-256 digest and verified with `apksigner`). The copy the phone's browser downloaded had the right size but a ~45 MB run of zero bytes in the middle (roughly bytes 36–82 MB), so its signature check failed. The browser had reported the download as complete.
- **Fix:** a verified copy was written to `Download/roxum-2.7.0-3-verified.apk` on the phone running the session and sent to the other phone with Quick Share. Both installed. **If an APK ever refuses to install, check the download first**, for example by comparing `sha256sum` with the digest shown by `gh api repos/Timileyin-Agbaje/roxum-ide/releases/tags/<tag>`.

## 9. VM setup done by the owner

- Node.js LTS from NodeSource, plus `tsx` and `typescript` globally (README, "Prepare the VM").
- New app SSH key added in Azure (Reset password → Add SSH public key, user `azureuser`).
- `npm config set update-notifier false` and `npm config set fund false` on the VM to silence `npm notice` lines (stored in `~/.npmrc`, so no app change was needed).
- The VM's public IP is a Standard SKU address, which Azure always assigns statically; the stop/start test confirmed the app reconnects without changes. Connection details are in `PLAN.md`.

## 10. Known limitations and leftovers

- The sync never deletes or renames remote files: a file deleted or renamed on the phone leaves its old copy on the VM until **Clean VM copy**.
- Changes made on the VM are never copied back (one-way sync, as planned).
- Only Vite dev servers get a preview tunnel, always to VM port 5173.
- Removed features' Dart code (Copilot, local models, other runtimes' install helpers, unused `_PfdRuntimeConfig` entries in `downloads.dart`, unused `*_feature_title` strings in `res/values/strings.xml`) is still present but unreachable.
- Upstream behaviour left as is: restarting an SSH terminal session starts a local shell in its place (`_restartSession` in `terminal.dart`).
- The tests are not in the repository (gitignored); they can be force-added with `git add -f test/` if wanted.

## 11. How to continue working on this

1. Clone the fork and work on `playstore-version`. Pull upstream changes with GitHub's **Sync fork**; most fork changes live in `lib/utils/vm_run.dart`, `lib/utils/local_llama_stub.dart`, the Gradle files and small edits in `editor_page.dart`, `terminal.dart`, `settings.dart`, `downloads.dart`.
2. Before pushing, run `flutter analyze` and `flutter test` (with the SSH variables set for the integration tests, against any SSH server that has Node.js).
3. Push to `playstore-version`; CI builds and publishes a new Release. Download it on the phone, check it if it does not install (section 8), and install it over the existing app.

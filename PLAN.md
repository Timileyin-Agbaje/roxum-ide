# Roxum IDE fork: Run on Azure VM — Implementation Plan

Oct 6, 2026 · @Timi

## Goal

Build a personal fork of Roxum IDE whose Play button runs JS, TS and React code on my Azure VM instead of my phone, installed as a sideloaded APK. Editing stays on the phone; running, `npm install` and dev servers happen on the VM.

The fork keeps only what I use: **JavaScript, TypeScript, React (JSX/TSX), HTML and CSS**. Everything else (Python, Rust, Go, Java, Kotlin, C/C++, Dart, Zig, Ruby, Lua and their language servers) is removed, cutting about 1.3 GB from the build.

The implementer (Claude Opus 5.5) should make the smallest set of changes that achieves this, follow the app's existing code style (Flutter, BLoC/Cubit), and keep local (on-phone) running working as a fallback when no VM is selected.

## Current setup and findings

The VM works and accepts Roxum's SSH key, but Roxum's design keeps all code running on the phone. Findings come from reading the source at [github.com/heckmon/roxum-ide](https://github.com/heckmon/roxum-ide) (MIT license, last commit 20 Sep 2026).

**My environment**

| Item | Value |
| --- | --- |
| VM | Azure B2as_v2 (2 vCPU, 8 GB, burstable), Ubuntu 24.04, Spain Central |
| Access | `azureuser@158.158.38.65`, port 22, SSH key only |
| Phones | Samsung Z Fold 4 and Itel S23 (4 GB RAM), both arm64 |
| Budget | Azure for Students credit; VM is stopped when not in use |

**What the code does today**

- **Run button is local only.** In `lib/ui/editor_page.dart`, `.ts` runs `tsc` + `node` through `runCodeInTermux(...)` on the phone or Termux, never over SSH.
- **No remote files.** There is no SFTP code anywhere; projects live only on the phone, so a VM session cannot see them.
- **Remote terminal exists but is hidden.** In `lib/terminal/terminal.dart`, the small ▾ beside **+** opens a session on a connected SSH server. The **+** alone always opens a phone session.
- **SSH key bug.** `SSHPrivateKey.fromJsonMap` in `lib/utils/functions.dart` always sets the key path to `$appDir/.termux/.ssh/id_ed25519`, but `SshKeygen` writes it to `$appDir/.ssh/id_ed25519`. After an app restart, saved remotes fail with `PathNotFoundException`. Editing and re-saving works only because a fresh object has no path set.
- **Vite preview exists locally.** `editor_page.dart` starts Vite on the phone and opens it in the built-in webview; this can be reused for the VM through an SSH tunnel.
- **Package name is hard-coded.** `lib/utils/constants.dart` sets `appDir = "/data/data/com.roxum"`, plus 32 more literal paths, and the bundled binaries expect that path.
- **Bundled runtimes are huge.** 1.49 GB of Git LFS files; the parts I need are `node_feature` (149 MB), `vscode_langservers_extracted_feature` (15 MB) and `main` (40 MB).

## Key decisions

| Decision | Choice | Why |
| --- | --- | --- |
| Package name | Keep `com.roxum` | Changing it breaks 33 hard-coded paths and the bundled binaries. The Play Store version must be uninstalled first. |
| Distribution | Sideloaded APK only | No Play Store, so every runtime I keep must be packaged inside the APK. |
| Languages kept | JS, TS, JSX/TSX, HTML, CSS | Keep `node_feature` and `vscode_langservers_extracted_feature`; delete the other 18 feature modules. |
| Where code runs | VM when a VM is selected, phone otherwise | Local running stays as a fallback for when the VM is stopped. |
| File transfer | SFTP over the existing `dartssh2` connection | Already a dependency; no new server software or open ports. |
| React preview | SSH port forwarding | VM port 5173 appears on the phone as `127.0.0.1:5173`; no Azure firewall changes. |
| Builds | GitHub Actions on my fork | Free with GitHub Student Pack; a phone cannot run Flutter or Android build tools. |
| Signing | My own release keystore, stored as GitHub secrets | Every build must use the same key so updates install over the previous version. |

## Work packages

Build order: WP1 → WP2 → WP8 and WP9 (get an installable APK early) → WP3 to WP6 → WP7. Each package should land as its own commit.

### WP1. Fix the SSH key path bug

- In `SSHPrivateKey.fromJsonMap`, read `termuxKeyLoc` from the saved JSON (it is already written by `toJsonMap`) instead of always using `$appDir/.termux/.ssh/id_ed25519`. A null value must fall back to `SshKeygen.privateKeyFilelocation`.
- Before **Generate keys** overwrites an existing key, show a warning: replacing the key locks the app out of the VM until the new public key is added.

### WP2. Slim the app to web languages

- Remove 18 modules from `dynamicFeatures` in `android/app/build.gradle.kts` and from `android/settings.gradle.kts`, and delete their folders. Keep only `node_feature` and `vscode_langservers_extracted_feature`.
- Remove the AI features: local GGUF models (the `llama_flutter_android` dependency and its screens) and Copilot completion (`copilot_language_server_feature`). Keep the code that the rest of the app depends on compiling.
- Hide the removed runtimes and language servers in `lib/utils/package_catalog.dart` and the downloads screen, and remove their Run commands. Keep syntax highlighting for all languages.
- Confirm that in a universal APK, `SplitInstallService.isModuleInstalled("node_feature")` returns true. If it does not, treat a module as installed when its asset zip exists, and never start a Play Store download.

### WP3. Choose where code runs

- Add a **Run on: Phone / Azure VM** selector to the editor toolbar, reusing the existing `CurrentlySelectedTerminalCubit`. Remember the choice per project.
- If the VM is selected but not connected, connect automatically. On failure, show "VM unreachable — start it in the Azure app" with a **Run on phone instead** button.

### WP4. Sync the project to the VM over SFTP

1. Mirror the project to `~/roxum/<project folder name>/` on the VM.
2. Upload only changed files, comparing size and modified time against a manifest saved per server and project.
3. Skip `node_modules`, `.git`, `dist`, `build`, `.vite`, `.next`, `coverage` and `*.log`.
4. Sync before every run, and on every save while a VM dev server is running, so Vite hot reload sees edits. Sync on save is on by default, with a setting to turn it off.
5. Never delete remote files automatically. Add a manual **Clean VM copy** action.
6. Show sync progress in a status line.

### WP5. Run commands on the VM

Run in an SSH terminal session (existing `SetupTerminal` with `sshId` and `commandToExecuteInSSH`), always `cd` into the project's VM folder first.

| What is run | Command on the VM |
| --- | --- |
| Project with a `dev` script (React/Vite) | `npm install` if `node_modules` is missing or `package.json`/lockfile changed, then `npm run dev -- --host 127.0.0.1 --port 5173` |
| `.ts` or `.tsx` file | `npx --yes tsx <file>` |
| `.js`, `.mjs` or `.cjs` file | `node <file>` |
| `.html` or `.css` outside a Vite project | Unchanged: local preview on the phone |

The Stop button must end the process on the VM (Ctrl+C, then kill if needed).

### WP6. React preview through an SSH tunnel

- When a VM dev server starts, forward phone `127.0.0.1:5173` to VM `127.0.0.1:5173` with `dartssh2`'s `forwardLocal`. If 5173 is taken on the phone, use the next free port.
- Wait until the forwarded port answers (reuse the existing socket check), then open the existing webview at that address. Hot reload WebSockets pass through the same tunnel.
- Close the tunnel when the run stops or SSH disconnects.

### WP7. Prepare the VM (one-time, documented in the fork's README)

Install Node system-wide so it is on the PATH for SSH commands:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm i -g tsx typescript
```

Optional: a **Prepare VM** button that runs these when `node -v` fails.

### WP8. Build the APK with GitHub Actions

Add `.github/workflows/build-apk.yml`, triggered manually and on push to `playstore-version` (the fork's default branch; the plan is based on this branch, version 2.7.0):

1. Check out with Git LFS, caching LFS objects, the pub cache and Gradle.
2. Set up Java (17, or 21 if AGP 9.0.1 requires it) and Flutter stable at a version whose Dart satisfies `sdk: ^3.13.4`.
3. Write `android/key.properties` and the keystore from secrets.
4. Run `flutter build appbundle --release`.
5. Convert with bundletool `build-apks --mode=universal`, signed with the same keystore, and extract `universal.apk`.
6. Upload it as an artifact and attach it to a GitHub Release, so I can download it straight to my phone.

Expected APK size: about 250 MB.

### WP9. Create the signing key (one-time, done by me on the VM)

```bash
sudo apt-get install -y openjdk-17-jdk-headless
keytool -genkey -v -keystore roxum-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias roxum
base64 -w0 roxum-release.jks
```

Save as GitHub secrets: `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`. Back up the `.jks` file and passwords somewhere off the VM.

### WP10. Install and switch over (done by me)

- [ ] Back up my projects first: uninstalling the Play Store Roxum deletes its data.
- [ ] Uninstall the Play Store Roxum.
- [ ] Download the APK from the latest Release and install it (allow "install unknown apps").
- [ ] Generate a new key in the app and add it in Azure: **Reset password → Add SSH public key**, user `azureuser`.
- [ ] Add the remote `azureuser@158.158.38.65` and connect.

## Acceptance tests

The fork is done when every box below passes on my Itel S23 with the VM running.

- [ ] The APK installs, opens, and the GitHub Actions run finishes with no manual steps.
- [ ] The Azure VM remote still connects after force-closing and reopening the app (WP1 bug fixed).
- [ ] With **Run on: Azure VM**, pressing Play on a `.ts` file shows output from the VM; `hostname` in the same session prints `timi`.
- [ ] The 4-second benchmark file runs on the VM and reports its TOTAL time.
- [ ] A new Vite React project runs on the VM: `npm install` runs once, the preview opens in the app, and an edit appears in the preview within a few seconds of saving.
- [ ] A second run skips unchanged files and does not re-run `npm install`.
- [ ] With the VM stopped, Play shows the "VM unreachable" message and **Run on phone instead** works.
- [ ] TypeScript, HTML and CSS still show completions and errors (language servers work).
- [ ] No removed language appears in the downloads or Run menus.

## Scope, risks and open questions

**Out of scope for v1:** editing files directly on the VM, two-way sync (VM changes copied back to the phone), automatic remote deletes, multiple VMs, and the Play Store release.

**Risks**

| Risk | Mitigation |
| --- | --- |
| Git LFS download quota runs out (each uncached build pulls about 200 MB) | Cache LFS objects in Actions; build only when needed |
| Flutter or AGP version mismatch breaks the CI build | Pin versions in the workflow; implementer checks the first run's log |
| Upstream Roxum updates conflict with my changes | Keep changes in few files; use GitHub's **Sync fork** and fix conflicts as they come |
| Lost signing key | Back up the keystore; without it I must uninstall to update, losing app data |
| VM runs out of CPU credits during long `npm install` runs | Normal for B-series; runs finish, just slower |

**Decisions on the open questions**

- **AI features:** removed (see WP2).
- **Sync on save:** on by default while a dev server runs (see WP4).
- **VM project folder:** `~/roxum/<project name>`.

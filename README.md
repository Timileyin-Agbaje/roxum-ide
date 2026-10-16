<p align="left">
  <a href="./README.md">English</a> |
  <a href="./README-CN.md">简体中文</a> |
  <a href="./README-ES.md">Español</a>
</p>

# Roxum IDE

Roxum IDE is a mobile-first code editor and mini IDE for Android, built with Flutter.
It combines editing, terminal workflows, Git/GitHub tooling, AI assistance, runtime downloads, and deep customization in one app.

#### Roxum uses the powerful [code_forge](https://github.com/heckmon/code_forge) package as the editor engine.

## This fork: run on a VM

This fork's Play button can run JavaScript, TypeScript and React (Vite) projects on a Linux VM over SSH, while editing stays on the phone. It keeps only the web toolchain (Node.js with TypeScript, and the HTML/CSS/JSON language servers). Other runtimes, local GGUF models and Copilot are removed. It is installed as a sideloaded APK, not from the Play Store.

### Install

1. Back up your projects, then uninstall the Play Store version of Roxum (both use the package name `com.roxum`, and uninstalling deletes the app's data).
2. Download the APK from the latest [release](../../releases/latest) and install it (allow "install unknown apps" for your browser).

### Prepare the VM (one time)

Install Node.js system-wide so it is on the `PATH` for SSH commands, plus `tsx` for running TypeScript files:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
sudo npm i -g tsx typescript
node -v && tsx --version
```

### Connect

1. In Roxum, open **Settings → Remote host and Termux** and tap **Generate keys**. Copy the public key.
2. Add the public key to the VM. On Azure: **Reset password → Add SSH public key**, user `azureuser`.
3. Add a remote host with the URL `ssh://azureuser@<vm-ip>:22` and connect.

### Run

- Open a project and pick the VM in the menu next to the Play button (the choice is remembered per project). Pick **Phone** to run on the device again.
- **Play** syncs the project to `~/roxum/<project folder>` on the VM (only changed files; `node_modules`, `.git`, `dist`, `build`, `.vite`, `.next`, `coverage` and `*.log` are skipped), then:
  - a project with a `dev` script runs `npm install` when needed and `npm run dev` (Vite on `127.0.0.1:5173`), and the preview opens in the app through an SSH tunnel;
  - a `.ts`/`.tsx` file runs with `npx tsx`, a `.js`/`.mjs`/`.cjs` file with `node`;
  - HTML and CSS files still preview on the phone.
- **Stop** in the terminal sends Ctrl+C, then ends anything left of the run on the VM.
- While a Vite dev server runs, saved files sync automatically so hot reload sees them. Turn this off with **Sync on save** in the same menu.
- After `npm install` runs on the VM, the app copies the packages' type definitions (every `package.json` and `.d.ts` file) into the phone project's `node_modules`, so hovers and auto-imports on the phone know React and the other packages. A `node_modules` installed on the phone itself is left alone. The file tree hides `node_modules`.
- **Clean VM copy** in that menu deletes the project's folder on the VM. Nothing on the VM is deleted otherwise.
- If the VM is stopped, Play offers **Run on phone instead**.

### Build

`.github/workflows/build-apk.yml` builds a signed universal APK on every push to `playstore-version` (or manually) and publishes it as a GitHub Release. It needs four repository secrets: `KEYSTORE_BASE64` (the keystore, base64-encoded), `KEYSTORE_PASSWORD`, `KEY_ALIAS` and `KEY_PASSWORD`. Every build must use the same keystore, or the APK will not install over the previous one.

### Theme and font

The app, editor and terminal use Cursor Dark ("Cursor Dark Anysphere v0.0.3", colors by [Anysphere](https://cursor.com)). The theme file is the VS Code version from [nexmoe/cursor-themes-for-zed](https://github.com/nexmoe/cursor-themes-for-zed) (MIT), stored unchanged as `assets/themes/cursor-dark.json`; the app reads its colors at start-up. Code is set in [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) (SIL Open Font License 1.1, see `assets/fonts/JetBrainsMono-OFL.txt`).

<a href="https://play.google.com/store/apps/details?id=com.roxum">
  <img src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" height="60">
</a>

## Feature list:
- **Completely free and open source.**
- **Built-in Termux support for using Termux as a backend.**
- **Download or load local GGUF LLM models for offline chat and code completion.**
- **Offline compilers and extensions for popular languages.**
- **245 built-in themes and, an option for creating custom themes.**
- **Built-in terminal.**
- **Rust based editor backend using rope and sum tree data structures, similar to the zed editor.**
- **AI Code Completion.**
- **LSP support (suggesions, completions, error highlighting, hover info, etc).**
- **Git and Github intergration.**
- **SSH support for connecting with remote systems.**  
- **Intergrate with external AI providers for agentic editing.**

## What's new in 2.7.0:
  - FIX: [#50](https://github.com/heckmon/roxum-ide/issues/50)
  - FIX: [#49](https://github.com/heckmon/roxum-ide/issues/49)
  - FIX: Run button opens terminal.
  - FIX: Cargo TLS certificate error.
  - FEATURE: Added ZIG compiler.
  - FEATURE: Added ZLS LSP server.

---
### Gallery

 <table>
  <tr>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/home.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/ag.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/ag_diff.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/rt-roxum.jpg" width="100%"></td>
  </tr>
  <tr>
    <td><img src="https://lh3.googleusercontent.com/o8_GNH3SBQnbnrJWduWE9xbW-RF8NBO3iphBx1mEc_gVYbSkyAGZyy5zEcMTGupt_1oCQipOpZMwbjlhJgbjyEs" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/ext.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/diag.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/accnt.jpg" width="100%"></td>
  </tr>
  <tr>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/explorer.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/lsp.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/ai_cmpl.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/themes.jpg" width="100%"></td>
  </tr>
  <tr>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/git_diff.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/gguf.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/termenu.jpg" width="100%"></td>
    <td><img src="https://raw.githubusercontent.com/heckmon/android-arm64-shared-libraries/refs/heads/main/scrnshots/term.jpg" width="100%"></td>
  </tr>
  
</table> 

---
<br>

# If playstore isn't accessible in your country:
## Download the full apk from [releases](https://github.com/heckmon/roxum-ide/releases)

#### OR

## Build from source

This section is intended for users from countries like China where the Play Store isn't accessible. Otherwise, it is recommended to download the full-featured APK from the Play Store as mentioned above.<br>

Clone this repo, then:

Make sure that [git-lfs](https://git-lfs.com/) is installed in your system and accessible via the `path`. Don't skip this step; the compilers and interpreters are stored in the GitHub large file storage.
#### 1) Build the app as an `aab` bundle.

> [!NOTE]
> 
> To include all compilers, interpreters and extensions in the build, we build it as a standalone `aab` file, which is bigger compared to the APK downloaded from the Play Store. The Play Store build is smaller because these external dependencies are downloaded on demand when the user requests the particular compiler/interpreter/extension.

Make sure to install necessary Flutter and Android development tools before starting.

```bash
cd android && ./gradlew :app:bundleRelease
```
This will generate the output file in `build/app/outputs/bundle/release/app-release.aab`

#### 2) Creating APK from AAB
To install aab in your device, it needs to be converted to apk first. For that, download the latest bundletool from the official repo:
https://github.com/google/bundletool/releases

Then build the APK:
```bash
java -jar path/to/bundletool.jar build-apks --bundle=your_app/build/app/outputs/bundle/release/app-release.aab --output=output.apks --mode=universal
```
This will generate a file called output.apks in the current directory
#### 3) Then install the apks:
Make sure that you are connected to an emulator or physical device via `adb`.
```bash
java -jar /path/to/bundletool.jar install-apks --apks=output.apks
```
---

Special Thanks ♥️
- [@MaximoMachado](https://github.com/MaximoMachado) — helped fund the Play store release.

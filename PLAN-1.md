# Roxum IDE fork: Plan 2 — Cursor Dark, fast IntelliSense, cleaner UI, smoother VM

Oct 16, 2026 · owner: @Timi

The first plan (Run on Azure VM) is done. It is summarised in `info.md` and kept in git history. This plan replaces it. Read `CLAUDE.md` for how to work in this repo.

## Goal

Make the fork feel like a fast, minimal, Cursor-style editor for hand-written JS, TS, React, HTML and CSS on a 6.5" phone:

1. **Cursor Dark everywhere:** the app, the editor and the terminal use Cursor's own dark theme.
2. **Clear, consistent syntax colors:** every kind of name (function, parameter, property, type…) has its own color, and colors do not change after typing.
3. **A well-sized coding font:** JetBrains Mono at a size that is comfortable on 6.5".
4. **Fast, smart IntelliSense (no AI):** suggestions appear instantly, fuzzy matching, good ranking, auto-imports, parameter hints, React snippets.
5. **Easy terminal copying:** copy one command's output, or the whole session, in one tap.
6. **Less clutter:** fewer buttons, shorter paths, no unused screens.
7. **Smoother VM workflow:** start the VM from the app, mirror deletes and renames, any dev server port, auto-reconnect.

Make the smallest changes that achieve this, follow the existing style, and keep everything working on both phones: Samsung Z Fold 4 and Itel S23 (4 GB RAM, 720×1612 screen).

## Findings that shape this plan

These were checked in the code on Oct 16, 2026.

| Area | Finding |
| --- | --- |
| Editor library | `code_forge` 10.14.0 from pub.dev (MIT, by the Roxum author). Highlighting, completion popup and LSP client all live there. |
| Highlighting | Two layers: `re_highlight` 0.0.3 (regex, highlight.js port) colors text instantly, then LSP semantic tokens repaint words. `getSemanticMapping()` squeezes semantic types back into highlight.js theme keys and ignores modifiers (`declaration`, `readonly`, `defaultLibrary`). So functions, variables and parameters often share a color, and colors change a moment after typing. |
| Completion delay | `CodeForgeController._lspTypingDebounce = 300 ms` before asking the server. |
| Completion matching | Prefix only: `label.toLowerCase().startsWith(prefix)` in `code_area.dart`. `uEf` or `effect` do not find `useEffect`. |
| Completion features | The client sends `snippetSupport: false`. `additionalTextEdits` (auto-imports) is resolved but should be verified end to end. `signatureHelp` is supported. |
| TS server | `typescript-language-server` is started in `startLspServer()` (`lib/utils/functions.dart`) with empty `initializationOptions`. |
| Types | `npm install` runs on the VM, so `node_modules` usually exists only there. The TS server on the phone then cannot see React's or other packages' types. |
| Theme source | Cursor's real theme file, "Cursor Dark Anysphere v0.0.3", is available as VS Code JSON in [nexmoe/cursor-themes-for-zed](https://github.com/nexmoe/cursor-themes-for-zed) at `vscode-themes/cursor-dark-color-theme.json` (MIT repo, colors by Anysphere). It has 250 UI colors, 225 TextMate rules and 40 semantic rules. |
| Fonts | `assets/fonts/` has JetBrains Mono in Medium only, so bold is synthesized. |
| Terminal | `xterm` 4.0.0. Copy works only through text selection (`Clipboard.setData` in `terminal.dart`). Extra keys have no TAB. Sessions are in a mostly empty drawer. |
| CI | `build-apk.yml` builds only on push to `playstore-version` and manual dispatch. |

Key Cursor Dark colors, for reference only (always read the JSON, don't hard-code from this table):

| Use | Color |
| --- | --- |
| Editor background | `#181818` |
| Panels, sidebar, terminal, status bar | `#141414` |
| Text | `#E4E4E4EB` |
| Keywords | `#82D2CE` |
| Strings | `#E394DC` |
| Functions | `#EFB080` (bold at declaration) |
| Properties | `#AAA0FA` |
| Numbers | `#EBC88D` |

## Decisions

- **Theme from the JSON, not by hand.** Commit Cursor's theme file as `assets/themes/cursor-dark.json` and build the app, editor and terminal colors from it at start-up. Credit both the Zed port and Anysphere in the README.
- **Vendor `code_forge`.** Copy `code_forge` 10.14.0 into `packages/code_forge` and point `pubspec.yaml` at it with a path dependency. The first commit is the unchanged copy, so reviewers see only our real changes in later commits. Do not upgrade it to 11.x in this plan.
- **Keep ligatures on.** The owner likes `===` drawn as a ligature.
- **IntelliSense stays on the phone.** Running the TS server on the VM would add network delay to every keystroke. Instead, types are copied from the VM (WP5).
- **Hide, don't delete.** As in plan 1, hide unused UI with flags so "Sync fork" with upstream stays easy.
- **Branch and PR per work package.** Greptile reviews every PR. The owner merges after testing the PR's APK.

## Work packages

Build in this order. Each WP is one branch and one PR (`wp<n>-<short-name>`) into `playstore-version`.

### WP0: CI for pull requests

- Add a `pull_request` trigger (into `playstore-version`) to `build-apk.yml`. On PRs, run `flutter analyze` and `flutter test`, build the APK and upload it as an artifact. Do not create a Release for PRs. Keep releases on push to `playstore-version`.
- Remove `/test` from `.gitignore` and commit the existing tests from plan 1, so CI and Greptile see them.
- **Done when:** a PR shows analyze, test and build results, and its APK installs over the current app.

### WP1: Cursor Dark app theme and font

- Add `assets/themes/cursor-dark.json` (copied verbatim, with a comment-tolerant loader) and a small loader in `lib/utils/themes.dart` that maps VS Code UI colors to Flutter: `editor.background`, `sideBar.background`, `titleBar.activeBackground`, `tab.activeBackground`/`tab.inactiveBackground`, `statusBar.background`, `editorLineNumber.*`, `editor.selectionBackground`, `editorCursor.foreground`, `focusBorder`, `editorSuggestWidget.*`, `editorHoverWidget.*`, `terminal.*` and `terminal.ansi*`.
- Make Cursor Dark the default app theme and the default editor and terminal theme. Hide the light/dark toggle on the home screen; the app is always Cursor Dark.
- Add JetBrains Mono Regular and Bold (OFL, from the official JetBrains release) next to the existing Medium, as one font family with weights.
- Defaults: JetBrains Mono, 13 sp, line height about 1.4, ligatures on. On screens 600 dp or wider (Fold inner screen), default to 14 sp. Users' saved settings still win.
- Make the editor gutter slimmer (line numbers plus fold arrows currently take a large share of the 360 dp width) and add a **Soft wrap** toggle to the editor menu, off by default.
- **Done when:** every screen, dialog, popup and the terminal use Cursor Dark colors, and about 40 columns fit on the Itel at the default size.

### WP2: Syntax highlighting (in vendored `code_forge`)

- **Commit 1:** vendor `code_forge` 10.14.0 unchanged into `packages/code_forge` and switch `pubspec.yaml` to it.
- **Regex layer:** build the editor theme map (highlight.js keys) from the Cursor JSON by resolving each key to a TextMate scope, using VS Code's rule that the longest matching scope prefix wins:

  | highlight.js key | TextMate scope |
  | --- | --- |
  | `keyword` | `keyword` |
  | `built_in` | `support.function` |
  | `type` | `entity.name.type` |
  | `literal` | `constant.language` |
  | `number` | `constant.numeric` |
  | `string`, template strings | `string` |
  | `subst` | `meta.template.expression` |
  | `regexp` | `string.regexp` |
  | `title.function`, `title.function.invoke` | `entity.name.function` |
  | `title.class` | `entity.name.type.class` |
  | `attr` | `meta.object-literal.key` |
  | `property` | `variable.other.property` |
  | `params` | `variable.parameter` |
  | `comment` | `comment` |
  | `tag`, `name` (JSX/HTML tags) | `entity.name.tag` |
  | `attribute` | `entity.other.attribute-name` |
  | `variable.language` (`this`) | `variable.language` |
  | `operator` | `keyword.operator` |
  | `punctuation` | `punctuation` |

  If a key has no rule, use the editor foreground. Check the TSX, JSX, HTML and CSS grammars in `re_highlight` for other keys they emit and map those too.
- **Semantic layer:** replace the semantic-to-highlight.js mapping with direct colors. For each token, resolve `type.modifier` selectors from the JSON's `semanticTokenColors` (VS Code rules: most specific selector wins, `*.modifier` allowed). If none match, fall back to VS Code's standard semantic-to-TextMate scopes (for example `function` → `entity.name.function`, `property` → `variable.other.property`, `parameter` → `variable.parameter`, `variable.readonly` → `variable.other.constant`) and look those up in `tokenColors`. Support `fontStyle` (bold, italic).
- **No flicker:** while typing, keep the existing semantic colors on lines that did not change, and shift spans on the edited line by the inserted or deleted length instead of dropping them, until new tokens arrive.
- **Done when:** in the owner's MovieFinder `App.tsx`, functions (`handleSearch`, `useState`, `movieFinder`) are orange, parameters, properties, types and JSX tags each have their own Cursor color, and nothing changes color a moment after typing.

### WP3: IntelliSense speed

All in vendored `code_forge` unless noted.

- **Ask immediately:** on a trigger character (`.`, `"`, `'`, `/`, `<`, `@`) or the first character of a new identifier, request completions with no debounce. Keep the 200 ms document-sync debounce for other edits, but always flush pending changes before a completion request.
- **Filter locally:** while the same identifier keeps growing, re-filter and re-rank the current list on the phone without a new request. Request again only when the server marked the list `isIncomplete`, or a new identifier or trigger starts.
- **Resolve lazily:** call `completionItem/resolve` only for the highlighted item, and cancel stale requests.
- **Warm server:** start the TS server when a JS/TS project opens, not when the first file opens. In `startLspServer()`, pass `initializationOptions` for `ts`/`js`: `tsserver: {useSyntaxServer: 'auto'}`, and `maxTsServerMemory: 1024` only on devices with 4 GB RAM or less.
- **Timing readout:** a setting "Show completion timing" that shows the last request's time (ms) in the editor status line. Off by default.
- **Done when:** on the Itel with a warm server, local-identifier suggestions appear within about 100 ms of typing, and `obj.` member suggestions within about 300 ms, measured with the readout.

### WP4: IntelliSense quality

- **Fuzzy matching (VS Code style):** characters must appear in order; score bonuses for start of word, camelCase humps, consecutive characters, matching case, and a whole-prefix match. Match against `filterText` when the server sends it. `uEf`, `useEf` and `effect` must all find `useEffect`.
- **Ranking:** score first, then the server's `sortText` and `preselect`, plus a boost for items accepted recently (last 50 per language, kept across restarts).
- **Snippets:** set `snippetSupport: true` and implement LSP snippet tab stops (`$1`, `${1:name}`, `$0`) on top of `code_forge`'s existing `CustomCodeSnippet` cursor handling, so function calls and JSX attributes (`={}`) put the cursor in the right place. If tab stops prove too large a change, keep `snippetSupport: false` and say so in the PR.
- **Auto-imports:** make sure `additionalTextEdits` from resolved items are applied when an item is accepted (for example accepting `useEffect` adds it to the `react` import).
- **Parameter hints:** confirm signature help shows while typing arguments and highlights the current parameter. Fix if broken.
- **React snippets:** `rfc` (function component with export), `us` (`useState`), `ue` (`useEffect`), `map` (`.map` with `key`), shown in the same popup and ranked like other items.
- **JSX helpers:** typing `>` after an opening tag inserts the matching closing tag (not for void HTML tags). If the server supports `textDocument/linkedEditingRange`, editing an opening tag name renames the closing one.
- **Popup on a phone:** kind icon, label, grey detail text, at most about 6 visible rows, accepted with Tab or Enter.
- **Done when:** the fuzzy cases above work, accepting `useEffect` adds the import, `rfc` creates a component, and parameter hints show for `movieFinder(`.

### WP5: Types from the VM

- After `npm install` succeeds on the VM (the existing `.roxum-deps` stamp changes), the app builds a compressed archive on the VM of every `package.json` and `*.d.ts` under `node_modules` (skipping the `typescript` package), downloads it over SFTP, and extracts it into the phone project's `node_modules` with the existing `archive` package. Write a stamp file `node_modules/.roxum-types`.
- If the phone project already has a `node_modules` without that stamp (a real local install), do nothing.
- Restart or notify the TS server after extraction so it picks up the types.
- `node_modules` is already excluded from upload, so this does not loop. Hide `node_modules` in the file tree.
- **Done when:** in a fresh Vite React project run once on the VM, hovering `useState` on the phone shows React's types, and auto-import from a package works.

### WP6: Editor and home cleanup

- **Editor bottom toolbar:** one row instead of two. Keep Tab, undo, redo and the four arrows. Add a horizontally scrolling strip of symbols for hand coding: `{ } ( ) [ ] ; : " ' \` < > / = => ,`. Move zoom, code actions (lightbulb), highlight, page up/down and the fold/info buttons into a "⋯" overflow menu. Hide the AI (sparkle) button behind the existing AI flags.
- **Editor top bar:** one Play button with the run-target menu. Fold the separate preview button into the Play menu (or show it only while a preview is available).
- **Home screen:** hide the downloads and GitHub icons and the theme toggle. Make the "Start" and "Recent" headings smaller. In Recent, show paths relative to the app's storage folder (`Projects/MovieFinder`) instead of `/storage/emulated/0/Android/media/com.roxum/...`.
- **Done when:** the editor shows more code lines than before on the Itel, and the home screen has no unused buttons.

### WP7: Terminal

- **Sessions as tabs** across the top, like editor tabs, with + to add a session (with the phone/VM choice in its menu). Remove the drawer, or keep it only for long-press actions (restart, stop, delete).
- **Colors:** Cursor Dark terminal colors from WP1 (background `#141414`, not pure black).
- **Extra keys:** add TAB, `|`, `-`, `/` and `~`. Keep CTRL, ALT, ESC, HOME, END and the arrows. One or two compact rows.
- **Copy one command's output:** each time the app sends Enter, record the current buffer line. A command's output is the lines between that command line and the next prompt (the line where the next Enter is sent, or the current last line). Long-press inside an output shows **Copy output**. Also add **Copy last output** to the terminal menu.
- **Copy all:** copies the whole session buffer (scrollback included), trimmed of trailing blank lines.
- **Copy on select:** when a selection ends, copy it automatically and show a short "Copied" toast.
- Works the same for phone, Termux and VM sessions.
- **Done when:** after `npm run build` on the VM, one long-press copies its whole output, and Copy all copies the session.

### WP8: VM workflow

- **Start and stop the VM from the app (optional, see risks):**
  - Owner one-time setup in Azure Cloud Shell (browser): create a service principal with a custom role allowing only `Microsoft.Compute/virtualMachines/read`, `start/action` and `deallocate/action`, scoped to this one VM. Document the exact commands in the README.
  - The app stores tenant ID, client ID, secret, subscription ID, resource group and VM name in `flutter_secure_storage`, entered in Settings.
  - Uses Azure REST (OAuth client-credentials token, then `instanceView`, `start`, `deallocate`) with the existing `http` package.
  - The run-target menu shows the VM's power state. "VM unreachable" gets a **Start VM** button that starts it, waits for SSH, then runs. Add **Stop VM** (deallocate) to the menu.
  - Never log or commit credentials.
- **Mirror deletes and renames:** on each sync, delete on the VM any file the app previously uploaded (in the manifest) that no longer exists on the phone. Never touch files the app did not upload (`node_modules`, `dist`, VM-created files).
- **Any dev server port:** keep Vite on 5173 with `--strictPort`. For other `dev` scripts, detect the port from the first `http://localhost:<port>` or `http://127.0.0.1:<port>` line in the output and tunnel that.
- **Auto-reconnect:** if SSH drops during a run (network change), reconnect with backoff, re-open the tunnel, and show "Reconnecting…" in the status line. Don't restart the remote process.
- **Restarting an SSH terminal session** reconnects to the same server instead of starting a phone shell.
- **Done when:** the acceptance tests below pass.

## Acceptance tests (owner, on both phones)

1. The app, editor, popups and terminal are all Cursor Dark. Text is JetBrains Mono and comfortable to read; `===` still shows as a ligature.
2. In `App.tsx`, functions, parameters, properties, types, strings and JSX tags have distinct Cursor colors, and nothing changes color while typing.
3. Typing `uEf` suggests `useEffect`; accepting it adds the import. Suggestions feel instant (timing readout under about 100 ms for local names on the Itel).
4. `rfc` creates a component; typing `<div>` adds `</div>`; parameter hints show inside `movieFinder(`.
5. After the first VM run, hovering `useState` shows React's types on the phone.
6. The editor has a one-row toolbar with symbol keys, and no AI button. Home has no downloads, GitHub or theme buttons, and Recent shows short paths.
7. In a VM terminal, long-press copies one command's full output; Copy all copies the session; TAB completes a path.
8. Deleting a file on the phone and pressing Play removes it on the VM.
9. A non-Vite dev server (for example an Express app printing `http://localhost:3000`) opens in the preview.
10. Turning Wi-Fi off and on during a dev server run reconnects without restarting the server.
11. (If WP8 Start/Stop is done) With the VM stopped, Play → Start VM starts it and runs the project; Stop VM deallocates it.

## Out of scope

- AI features of any kind.
- Two-way sync (VM changes copied back), except type definitions in WP5.
- Running the TS server on the VM.
- Upgrading `code_forge` to 11.x, or Flutter.
- Light themes.

## Risks

- **Azure for Students may block service principals.** If creating one fails, skip Start/Stop and keep the current "Start it in the Azure app" message.
- **TS server memory on the Itel.** A 1 GB cap may be too low for large projects; if the server crashes, raise it or remove the cap.
- **Snippet tab stops** may be a large change inside `code_forge`; WP4 allows deferring them.
- **Vendored `code_forge`** makes upstream Roxum's `code_forge` upgrades manual. Keep our changes in small, clearly named commits so they can be re-applied.

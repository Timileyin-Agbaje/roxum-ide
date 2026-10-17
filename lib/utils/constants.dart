const appDir = "/data/data/com.roxum";
const binDir = "$appDir/bin";
const libDir = "$appDir/lib";
const downloadsDir = "/storage/emulated/0/Android/data/com.roxum/files/data/user/0/com.roxum/files";
const certDir = "/data/data/com.roxum/certs";
const runtimesDir = "/data/data/com.roxum/runtimes";
const projectDir = "/storage/emulated/0/Android/media/com.roxum/Projects";
const templateDir = "/storage/emulated/0/Android/media/com.roxum/Templates";
const filesDir = "/storage/emulated/0/Android/media/com.roxum/Files";
const tempDir = "$appDir/temps";
const extensionDir = "$appDir/extensions";
const homeDir = "$appDir/Home";

// Features this fork removes. The code stays so upstream merges stay simple; these hide it.
const kLocalModelsEnabled = false;
const kCopilotEnabled = false;
const kAppThemeToggleEnabled = false;
// One-row editor toolbar with symbol keys; the upstream two-row toolbar stays in the code.
const kCompactEditorToolbar = true;
// The home screen's downloads (runtimes) and GitHub buttons.
const kHomeExtraButtonsEnabled = false;

// Folders the file tree doesn't show. node_modules holds the types copied from the VM.
const kHiddenTreeFolders = {'node_modules', '.roxum-types-tmp'};

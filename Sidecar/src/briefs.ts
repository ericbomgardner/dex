/**
 * Told to every session, whatever model:
 * the host is what reads the mark, so the host is what asks for it.
 */
export const SCREEN_BRIEF = `# Driving the user's screen

This session runs inside Dex, a Mac app, and the user is often at the keyboard. Anything that moves the pointer, clicks, types, or brings a window forward (CGEvent to the HID tap, cliclick, System Events keystroke/click, AppleScript activate) takes the machine away from them.

Prefer routes that need neither the pointer nor focus: read state through the Accessibility tree, press a control with AXUIElementPerformAction(kAXPressAction), or post a CGEvent to the target's pid with CGEvent.postToPid rather than to the HID tap. Capture windows by id (screencapture -l) instead of activating them.

When only global input will do, prefix the command with DEX_DRIVES_SCREEN=1 (for example \`DEX_DRIVES_SCREEN=1 /tmp/drive click 100 200\`). Dex then either lets it through when the user is away or asks them first; the reply you get back says which. Never run one unmarked.`;

/**
 * Also told to every session. Reading inside another app's container makes
 * macOS ask the user whether Dex may see other apps' data, charged to the
 * host, and a home-wide sweep trips it without meaning to. An instruction
 * rather than a filter: a session whose task is that data still reads it.
 */
export const FOLDERS_BRIEF = `# Other apps' folders

Reading inside ~/Library/Containers or ~/Library/Group Containers makes macOS ask the user, by dialog, whether Dex may see other apps' data. Prune both from any search that sweeps the home folder or ~/Library (\`find ~ -path ~/Library/Containers -prune -o ...\`, \`grep --exclude-dir=Containers\`, or search narrower). Read them directly only when the task is about that app's data.`;

/**
 * Also told to every session. Once the conversation's images and documents are
 * over the CLI's cap it swaps the oldest for a placeholder before each request,
 * says so to nobody, and a model handed one has gone on to describe the file.
 */
export const MEDIA_BRIEF = `# Files that never reached you

A tool result that reads \`[media removed: request limit]\` held an image or document that was taken out of the request because the conversation's files were too large to send. You have not seen that file. Say so plainly and don't describe its contents; offer to read it as text or a few pages at a time instead.`;

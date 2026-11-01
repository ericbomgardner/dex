#!/bin/bash
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read from the Swift that looks for them, so the two can't name different apps.
identity() {
    sed -n "s/^ *public static let $1 = //p" \
        "$ROOT/Sources/DexCore/Support/BundleIdentity.swift" | sed 's/prefix + //; s/"//g'
}
CODE_ID="$(identity prefix)$(identity code)"
CODE_BUNDLE="$(identity codeBundle)"
if ! [[ "$CODE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ && "$CODE_BUNDLE" == *.app ]]; then
    echo "could not read the bundle id and name from BundleIdentity.swift: '$CODE_ID', '$CODE_BUNDLE'" >&2
    exit 1
fi

# macOS remembers a folder you granted, and the keychain which app may read an
# item, by the app's signature. A certificate outlives the builds, so both
# survive a rebuild; a build signed without one is a new app every time.
IDENTITY="${DEX_CODESIGN_IDENTITY:-}"
# Not -v: a self-signed certificate signs fine but isn't trusted, and -v leaves it out.
if ! security find-identity -p codesigning 2>/dev/null \
    | awk -v id="$IDENTITY" 'id != "" && (index($0, "\"" id "\"") || $2 == id) { found = 1 } END { exit !found }'; then
    echo "Dex needs a code signing certificate; a self-signed one is enough (Keychain Access → Certificate Assistant →" >&2
    echo "Create a Certificate, Identity Type \"Self Signed Root\", Certificate Type \"Code Signing\")." >&2
    echo "Then set DEX_CODESIGN_IDENTITY to the certificate's name." >&2
    exit 1
fi
# Listed isn't usable: an expired certificate, or a keychain locked over ssh,
# fails only at codesign, which would be after the build.
SIGN_TRIAL="$(mktemp -d)"
cp /usr/bin/true "$SIGN_TRIAL/trial"
if ! SIGN_OUTPUT="$(codesign --force --sign "$IDENTITY" "$SIGN_TRIAL/trial" 2>&1)"; then
    rm -rf "$SIGN_TRIAL"
    echo "could not sign with \"$IDENTITY\": $SIGN_OUTPUT" >&2
    exit 1
fi
rm -rf "$SIGN_TRIAL"

cd "$ROOT"
# The app's product alone: the probes are a product of their own, and a
# Rebuild has no use for them.
PRODUCTS=(DexCode)
for PRODUCT in "${PRODUCTS[@]}"; do
    swift build -c "$CONFIG" --product "$PRODUCT"
done
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# The sidecar host runs from the bundle, so its dependencies have to be in the
# bundle too — node_modules is not something the app can install at launch.
# Installed here rather than demanded of whoever pressed Rebuild.
#
# The SDK carries the `claude` binary every hosted session runs, so the CLI
# under the app is not the self-updating one you type — it is whatever the pin
# resolved to, and it sat ten versions behind for two weeks without a word.
# Moving it forward is asked for, never assumed: DEX_UPDATE_SDK=1
# installs the newest npm has, rewrites the pin to what was installed (the
# lockfile is what a fresh checkout builds from, and a repo shipping a version
# it doesn't name is the one failure this can't report), and re-runs every
# probe against it. That used to happen on every build, which put a
# ten-minute probe sweep behind a Rebuild button that said nothing about it.
# Without the flag the build installs what the lockfile already says — quick,
# and the same SDK as the build before it. DEX_PIN_SDK=1 is the
# stricter form of that, `npm ci`, for an offline or reproducible build.
SIDECAR="$ROOT/Sidecar"
SDK="@anthropic-ai/claude-agent-sdk"

# Searched, not taken off PATH: the app's Rebuild button runs this from a GUI
# process, which inherits the launchd PATH — /usr/bin:/bin and nothing else, no
# homebrew and no nvm. Read with `node` unfound, the version below came back
# empty and the check at the end called a perfectly good install broken. Same
# search HostLocation.node does, for the same reason. nvm last, newest first.
if ! command -v node >/dev/null 2>&1; then
    NVM_BIN="$(ls -d "$HOME/.nvm/versions/node"/*/bin 2>/dev/null | sort -V | tail -1)"
    if [ -n "$NVM_BIN" ]; then PATH="$NVM_BIN:$PATH"; fi
fi
NODE="$(command -v node 2>/dev/null || true)"
if [ -z "$NODE" ]; then
    for DIR in /opt/homebrew/bin /usr/local/bin /usr/bin; do
        if [ -x "$DIR/node" ]; then NODE="$DIR/node"; break; fi
    done
fi
if [ -z "$NODE" ]; then
    echo "node was not found on PATH, in nvm, /opt/homebrew/bin, /usr/local/bin or /usr/bin." >&2
    echo "The host runs on it, and this build reads the installed SDK with it." >&2
    exit 1
fi

sdk_version() {
    SDK_PACKAGE="$SIDECAR/node_modules/$SDK/package.json" \
        "$NODE" -p 'require(process.env.SDK_PACKAGE).version' 2>/dev/null || true
}

# What the sessions will actually run, which is the reading that matters and the
# one nothing else on the machine reports.
bundled_cli() {
    local binary="$SIDECAR/node_modules/$SDK-darwin-arm64/claude"
    [ -x "$binary" ] || return 0
    "$binary" --version 2>/dev/null | awk '{print $1}' || true
}

# One install at a time. npm has no protection against two of them sharing a
# node_modules, and two builds know nothing about each other: one run from a
# terminal and one from the app's own Rebuild button, say. Every build writes
# there. Held for the rest of the run rather than just the install, since
# copying a tree someone else is rewriting is the same bug one step later.
LOCK="$ROOT/.build/sidecar-install.lock"
mkdir -p "$ROOT/.build"

# Renaming the app leaves the old name's bundle sitting in .build, and a stale
# artifact is worse than a missing one. So nothing but this build's own output
# survives the start of it. A stale bundle something still runs from waits for
# a later build, since deleting it would take the ground out from under that
# app's host.
for stale in "$ROOT"/.build/*.app "$ROOT"/.build/*.zip; do
    [ -e "$stale" ] || continue
    case "${stale##*/}" in
        "$CODE_BUNDLE") ;;
        *)
            if pgrep -f "$stale/Contents/" >/dev/null 2>&1; then
                echo "Leaving $(basename "$stale") in place: something is still running from it"
            else
                echo "Clearing a previous build's $(basename "$stale")"; rm -rf "$stale"
            fi
            ;;
    esac
done
WAITED=0
until mkdir "$LOCK" 2>/dev/null; do
    if [ "$WAITED" -eq 0 ]; then
        echo "Waiting for another build's dependency install…"
    fi
    if [ "$WAITED" -gt 180 ]; then
        echo "another build has held $LOCK for three minutes." >&2
        echo "if nothing else is building, remove it: rmdir $LOCK" >&2
        exit 1
    fi
    WAITED=$((WAITED + 1))
    sleep 1
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if ! command -v npm >/dev/null 2>&1; then
    if [ ! -d "$SIDECAR/node_modules" ]; then
        echo "Sidecar needs npm to install its dependencies, and npm is not on PATH" >&2
        exit 1
    fi
    echo "warning: npm is not on PATH — building with the SDK already installed" >&2
elif [ -n "${DEX_PIN_SDK:-}" ]; then
    echo "Installing Sidecar dependencies from the lockfile…"
    (cd "$SIDECAR" && npm ci --silent) || {
        echo "Sidecar dependency install failed; try: (cd Sidecar && npm ci)" >&2
        exit 1
    }
elif [ -z "${DEX_UPDATE_SDK:-}" ]; then
    echo "Installing Sidecar dependencies as pinned…"
    if ! (cd "$SIDECAR" && npm install --silent); then
        echo "warning: could not install Sidecar dependencies — building with what is there" >&2
        if [ ! -d "$SIDECAR/node_modules" ]; then
            echo "Sidecar has no dependencies installed and npm could not install them" >&2
            exit 1
        fi
    fi
else
    BEFORE_SDK="$(sdk_version)"
    BEFORE_CLI="$(bundled_cli)"
    # Clean before the install or not ours to commit afterwards: an edit in
    # progress here would be swept into a commit nobody asked for.
    PIN_WAS_CLEAN=""
    if [ -z "$(git -C "$ROOT" status --porcelain \
        -- Sidecar/package.json Sidecar/package-lock.json 2>/dev/null)" ]; then
        PIN_WAS_CLEAN=yes
    fi

    echo "Updating the Sidecar SDK…"
    # Exact, not the caret `npm install` writes on its own: the pin is meant to
    # name the one version this ships, and a range says a build could differ
    # from the build beside it without the file changing.
    if ! (cd "$SIDECAR" && npm install --silent --save-exact "$SDK@latest"); then
        echo "warning: could not reach npm — building with the SDK already installed" >&2
        if [ ! -d "$SIDECAR/node_modules" ]; then
            echo "Sidecar has no dependencies installed and npm is unreachable" >&2
            exit 1
        fi
    fi

    AFTER_SDK="$(sdk_version)"
    if [ -n "$AFTER_SDK" ] && [ "$AFTER_SDK" != "$BEFORE_SDK" ]; then
        AFTER_CLI="$(bundled_cli)"
        echo "==> SDK ${BEFORE_SDK:-none} → $AFTER_SDK (Claude Code ${BEFORE_CLI:-none} → ${AFTER_CLI:-?})" >&2

        if [ -n "$PIN_WAS_CLEAN" ]; then
            echo "    the pin moved in Sidecar/package.json; commit it with your work" >&2
        else
            echo "    the pin moved in Sidecar/package.json, over an edit already there" >&2
        fi

        # The one moment the CLI our sessions run becomes a different one, and
        # so the one moment every reading in docs/claude-code is owed a re-check. This
        # used to be a line in the pin's commit message saying to run `smoke`,
        # which is one probe of seventeen and is read by nobody.
        #
        # Slow — real sessions, minutes — and that is the trade: it runs only
        # when the pin actually moved, which only happens when the update was
        # asked for. Never fatal: the app was asked for, is built, and is
        # about to be opened whatever the probes say.
        if [ "${SKIP_RECHECK:-}" = "1" ]; then
            echo "    SKIP_RECHECK=1 — probes not re-run; do it with Scripts/maintainer/recheck.sh" >&2
        else
            echo >&2
            "$ROOT/Scripts/maintainer/recheck.sh" >&2 || \
                echo "warning: a probe failed — a reading in docs/claude-code no longer holds" >&2
        fi
    fi
fi
# Asked of every route above, and asked of the tree rather than of the install
# that wrote it. An install used to run once, against nothing, so failing meant
# nothing was there and the directory check caught it. Now it runs against a
# working node_modules every build, and a network drop halfway through leaves
# the directory in place with the SDK part-written — which `cp -R` bundles as
# readily as a good one, reports as a build that worked, and hands you a session
# that cannot start.
if [ -z "$(sdk_version)" ] || [ -z "$(bundled_cli)" ]; then
    echo "Sidecar's SDK is not installed intact: no version, or no claude binary" >&2
    echo "under $SIDECAR/node_modules. Nothing has been bundled." >&2
    echo "fix with: (cd Sidecar && rm -rf node_modules && npm ci)" >&2
    exit 1
fi

# The node the host runs on ships inside the bundle, as a helper app with its
# own identifier (see HostLocation.bundledNode for why: a screen recording or
# accessibility grant belongs to the host, and a bundle under a certificate is
# the only identity of it that survives a rebuild). The official build is
# self-contained, where homebrew's is a stub over twenty of its own dylibs.
# Fetched once per version into a cache, and before the bundle is touched, so
# a download that fails leaves the running app alone. Unpacked beside its
# final name and moved in whole, so a tar cut off halfway can't leave a
# truncated binary the executable check would trust on every later build.
NODE_VERSION="${DEX_NODE_VERSION:-26.5.0}"
NODE_ARCH="$(uname -m)"
[ "$NODE_ARCH" = x86_64 ] && NODE_ARCH=x64
NODE_DIST="node-v$NODE_VERSION-darwin-$NODE_ARCH"
NODE_CACHE="${DEX_NODE_CACHE:-$HOME/.cache/dex/node}"
BUNDLED_NODE="$NODE_CACHE/$NODE_DIST/bin/node"
if [ ! -x "$BUNDLED_NODE" ]; then
    echo "==> fetching node v$NODE_VERSION for the host" >&2
    mkdir -p "$NODE_CACHE"
    (
        cd "$NODE_CACHE"
        curl -fsSLO "https://nodejs.org/dist/v$NODE_VERSION/$NODE_DIST.tar.gz"
        curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" \
            -o "SHASUMS256-v$NODE_VERSION.txt"
        grep " $NODE_DIST.tar.gz\$" "SHASUMS256-v$NODE_VERSION.txt" \
            | shasum -a 256 -c - >/dev/null
        rm -rf "$NODE_DIST.partial"
        mkdir "$NODE_DIST.partial"
        tar xzf "$NODE_DIST.tar.gz" -C "$NODE_DIST.partial" "$NODE_DIST/bin/node"
        mv "$NODE_DIST.partial/$NODE_DIST" "$NODE_DIST"
        rm -rf "$NODE_DIST.partial" "$NODE_DIST.tar.gz"
    )
fi

# The helper first: a bundle is sealed over its nested code, so the outer
# signature is only as good as the one already inside.
sign() {
    SIGN_OUTPUT="$(codesign --force --sign "$1" "$HELPER" 2>&1)" \
        && SIGN_OUTPUT="$(codesign --force --sign "$1" "$APP" 2>&1)"
}


bundle() {
# Last, so that "nothing has been bundled" above is true. This used to be the
# first thing the script did, which meant every way it could fail from here up
# took the running app's Resources with it — its node_modules and the claude
# binary among them. The app stayed open on a bundle with its insides gone:
# turns already running finished, since their processes were spawned before the
# delete, and the next session refused to start at all, the SDK answering that
# no native CLI could be found for darwin-arm64.
echo "==> bundling $APP" >&2
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

mkdir -p "$APP/Contents/Resources/Sidecar"
cp -c -R "$ROOT/Sidecar/src" "$ROOT/Sidecar/node_modules" "$ROOT/Sidecar/package.json" \
    "$APP/Contents/Resources/Sidecar/"
# TypeScript and its native compiler are for typecheck, not for the host the app runs.
(cd "$APP/Contents/Resources/Sidecar" && npm prune --omit=dev --no-audit --no-fund >/dev/null 2>&1) \
    || echo "warning: couldn't prune dev dependencies from the bundled Sidecar" >&2

cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
HELPER="$APP/Contents/Helpers/$HELPER_EXECUTABLE.app"
mkdir -p "$HELPER/Contents/MacOS" "$HELPER/Contents/Resources"
cp -c "$BUNDLED_NODE" "$HELPER/Contents/MacOS/$HELPER_EXECUTABLE"
cp "$ICON" "$HELPER/Contents/Resources/AppIcon.icns"
cat > "$HELPER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$HELPER_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$HELPER_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$HELPER_ID</string>
    <key>CFBundleExecutable</key>        <string>$HELPER_EXECUTABLE</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSUIElement</key>               <true/>
    <!-- The host is spawned disclaimed, so what a session reads is charged to
         the helper, and macOS reads the reason for the prompt off this plist,
         not the app's. -->
    <key>NSAppDataUsageDescription</key>
    <string>$HELPER_APP_DATA</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>$HELPER_FOLDERS</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>$HELPER_FOLDERS</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>$HELPER_FOLDERS</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$DISPLAY_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <!-- Launched into the menu bar, when it is. Not menu-bar only: syncWindowState
         moves it to .regular whenever it has a real window, so it takes a Dock
         icon and an app-switcher entry for as long as one is open. -->
    <key>LSUIElement</key>               <$MENU_BAR_ONLY/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>$BUNDLE_ID.session</string>
            <key>CFBundleURLSchemes</key>    <array><string>$SCHEME</string></array>
        </dict>
    </array>
    <key>NSDesktopFolderUsageDescription</key>
    <string>$APP_FOLDERS</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>$APP_FOLDERS</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>$APP_FOLDERS</string>
</dict>
</plist>
PLIST

# The only chance to record this: by the time it is asked, the checkout has moved.
COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
if [ -n "$COMMIT" ]; then
    /usr/libexec/PlistBuddy -c \
        "Add :DexBuildCommit string $COMMIT" "$APP/Contents/Info.plist"
    # The same commit again beside the sidecar, where the host can read it and
    # say it on the welcome. The app compares that against its own plist copy;
    # a running host stamped differently is one from before this build.
    printf '{"commit":"%s"}\n' "$COMMIT" > "$APP/Contents/Resources/Sidecar/build.json"
fi

if [ -n "$IDENTITY" ] && sign "$IDENTITY"; then
    :
else
    echo "could not sign with $IDENTITY: $SIGN_OUTPUT" >&2
    exit 1
fi

}

# What `bundle` names the app and its host.
BUILT=()
        APP="$ROOT/.build/$CODE_BUNDLE"
        BIN="$BIN_DIR/DexCode"
        EXECUTABLE=Dex
        DISPLAY_NAME="${CODE_BUNDLE%.app}"
        BUNDLE_ID="$CODE_ID"
        SCHEME=dex
        MENU_BAR_ONLY=true
        ICON="$ROOT/Icon/AppIcon.icns"
        APP_FOLDERS="Dex looks in the folders your sessions run in, and hands on the files you drop on one."
        HELPER_EXECUTABLE=DexHost
        HELPER_NAME="Dex Host"
        HELPER_ID="$BUNDLE_ID.host"
        HELPER_APP_DATA="Dex sessions run shell commands. A search across your home folder reads other apps' folders on the way."
        HELPER_FOLDERS="Dex sessions run shell commands in the folders you point them at, and search from there."
    bundle
    BUILT+=("$APP")

# Last: the app's Rebuild opens the line naming its own bundle.
printf '%s\n' "${BUILT[@]}"

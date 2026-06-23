#!/usr/bin/env bash
# Build a release zip of the plugin and update extensions.xml in place
# with the new version + SHA1.
#
# Reads the version from AudioMuseAI/install.xml so the zip filename and
# the extensions.xml entry stay in lock-step with the manifest.
#
# Usage:
#   scripts/build.sh                  # build only, leave extensions.xml alone
#   scripts/build.sh --update-manifest  # also rewrite extensions.xml

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/AudioMuseAI"
INSTALL_XML="$SRC/install.xml"
EXT_XML="$ROOT/extensions.xml"

UPDATE=0
[[ "${1:-}" == "--update-manifest" ]] && UPDATE=1

# Pull version from install.xml (single source of truth).
VERSION=$(grep -oP '(?<=<version>)[^<]+' "$INSTALL_XML")
if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not read <version> from $INSTALL_XML" >&2
    exit 1
fi

OUT="$ROOT/AudioMuseAI-v${VERSION}.zip"

# Drop any prior zip artefacts so an old version doesn't confuse the
# release dir.
find "$ROOT" -maxdepth 1 -name 'AudioMuseAI-v*.zip' -delete

# Build via python — `zip` isn't always installed on dev hosts.
python3 - "$SRC" "$OUT" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
base = os.path.basename(src)  # "AudioMuseAI"
parent = os.path.dirname(src)
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(src):
        # Strip dotfiles (`.DS_Store`, `.git`, editor temp files).
        dirs[:] = [d for d in dirs if not d.startswith('.')]
        for f in files:
            if f.startswith('.') or f == '.DS_Store':
                continue
            full = os.path.join(root, f)
            # Store paths relative to the parent so the archive contains
            # AudioMuseAI/... entries (Lyrion expects this layout).
            arc = os.path.relpath(full, parent)
            z.write(full, arc)
PY

SHA=$(sha1sum "$OUT" | awk '{print $1}')
SIZE=$(stat -c%s "$OUT")

printf 'built  %s\n' "$OUT"
printf '       %s bytes\n' "$SIZE"
printf '       sha1=%s\n' "$SHA"

if (( UPDATE )); then
    # Surgical replacements — keep the rest of extensions.xml intact.
    python3 - "$EXT_XML" "$VERSION" "$SHA" <<'PY'
import re, sys
path, ver, sha = sys.argv[1:]
text = open(path).read()
text = re.sub(r'(<plugin name="AudioMuseAI" version=")[^"]+(")',
              rf'\g<1>{ver}\g<2>', text)
# [^/]+ (not [^.]+) for the filename version — dotted versions like 0.3.1
# contain '.', so [^.]+ would stop at the first dot and the substitution
# would silently no-op, leaving a stale download URL.
text = re.sub(r'(releases/download/v)[^/]+(/AudioMuseAI-v)[^/]+(\.zip)',
              rf'\g<1>{ver}\g<2>{ver}\g<3>', text)
text = re.sub(r'(<sha>)[^<]+(</sha>)',
              rf'\g<1>{sha}\g<2>', text)
open(path, 'w').write(text)
PY
    printf 'updated %s\n' "$EXT_XML"
fi

echo
echo "Next steps:"
echo "  1. git add AudioMuseAI extensions.xml AudioMuseAI-v${VERSION}.zip"
echo "  2. git commit -m 'v${VERSION}: ...'"
echo "  3. git tag v${VERSION} && git push --tags"
echo "  4. gh release create v${VERSION} ${OUT##*/} \\"
echo "       --title 'v${VERSION}' --notes 'changelog goes here'"

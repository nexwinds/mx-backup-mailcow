#!/usr/bin/env bash
#
# build-release.sh - build a reproducible release archive and checksum manifest
#
# Development tool, not installed on servers. Produces:
#   dist/mx-backup-mailcow-<version>.tar.gz
#   dist/SHA256SUMS          (archive + installer checksums, published as assets)
#   dist/install.sh          (standalone bootstrap installer asset)
#
# The archive contains its own SHA256SUMS manifest, which the installer and the
# update script verify after extraction.
#
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_DIR="$REPO_ROOT"
OUT_DIR="$REPO_ROOT/dist"
VERSION_OVERRIDE=""
STAGE=""

usage() {
    cat <<'EOF'
Usage: build-release.sh [OPTIONS]

Options:
  --source DIR    Source tree (default: repository root)
  --out DIR       Output directory (default: dist/)
  --version VER   Override the version in VERSION (used for tests)
  -h, --help      Show this help
EOF
}

die() { printf 'build-release: %s\n' "$*" >&2; exit 1; }

cleanup() {
    [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf -- "$STAGE" 2>/dev/null || true
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE_DIR=${2:?}; shift ;;
        --out) OUT_DIR=${2:?}; shift ;;
        --version) VERSION_OVERRIDE=${2:?}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

[[ -d "$SOURCE_DIR" ]] || die "source directory not found: $SOURCE_DIR"

VERSION=""
if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION=$VERSION_OVERRIDE
elif [[ -r "$SOURCE_DIR/VERSION" ]]; then
    VERSION=$(<"$SOURCE_DIR/VERSION")
else
    die "VERSION file not found in $SOURCE_DIR"
fi
VERSION=${VERSION//[[:space:]]/}
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version: $VERSION"

for file in \
    install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh \
    README.md CHANGELOG.md LICENSE VERSION \
    systemd/mailcow-sync.service systemd/mailcow-sync.timer \
    config/config.example logrotate/mailcow-backup-mx; do
    [[ -f "$SOURCE_DIR/$file" ]] || die "missing required file: $file"
done

mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)
STAGE="$OUT_DIR/mx-backup-mailcow-$VERSION"

rm -rf -- "$STAGE"
install -d -m 0755 "$STAGE/bin" "$STAGE/systemd" "$STAGE/share/doc" "$STAGE/config" "$STAGE/logrotate"

for script in install.sh sync-mailcow.sh update.sh diagnose.sh update-scripts.sh; do
    install -m 0755 "$SOURCE_DIR/$script" "$STAGE/bin/$script"
done
install -m 0644 "$SOURCE_DIR/VERSION" "$STAGE/VERSION"
install -m 0644 "$SOURCE_DIR/systemd/mailcow-sync.service" "$STAGE/systemd/mailcow-sync.service"
install -m 0644 "$SOURCE_DIR/systemd/mailcow-sync.timer" "$STAGE/systemd/mailcow-sync.timer"
install -m 0644 "$SOURCE_DIR/README.md" "$STAGE/share/doc/README.md"
install -m 0644 "$SOURCE_DIR/CHANGELOG.md" "$STAGE/share/doc/CHANGELOG.md"
install -m 0644 "$SOURCE_DIR/LICENSE" "$STAGE/share/doc/LICENSE"
install -m 0644 "$SOURCE_DIR/config/config.example" "$STAGE/config/config.example"
install -m 0644 "$SOURCE_DIR/logrotate/mailcow-backup-mx" "$STAGE/logrotate/mailcow-backup-mx"
printf '%s\n' "$VERSION" >"$STAGE/VERSION"

# Inner manifest: every file except the manifest itself.
(
    cd "$STAGE"
    find . -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sed -E 's|^([0-9a-f]{64}) [ *]\./|\1  |' \
        >SHA256SUMS
)
chmod 0644 "$STAGE/SHA256SUMS"

ARCHIVE="mx-backup-mailcow-$VERSION.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "$OUT_DIR/$ARCHIVE" -C "$OUT_DIR" "mx-backup-mailcow-$VERSION" 2>/dev/null \
    || tar -czf "$OUT_DIR/$ARCHIVE" -C "$OUT_DIR" "mx-backup-mailcow-$VERSION"

# Standalone installer asset for the documented one-liner. A downloaded
# install.sh has no adjacent VERSION file, so embed the release version.
grep -q '^VERSION="0\.0\.0-dev"$' "$SOURCE_DIR/install.sh" \
    || die "install.sh no longer contains the version placeholder"
awk -v v="$VERSION" '
    /^VERSION="0\.0\.0-dev"$/ { print "VERSION=\"" v "\""; next }
    { print }
' "$SOURCE_DIR/install.sh" >"$OUT_DIR/install.sh"
chmod 0755 "$OUT_DIR/install.sh"
grep -q "^VERSION=\"$VERSION\"$" "$OUT_DIR/install.sh" \
    || die "failed to embed the release version in install.sh"

(
    cd "$OUT_DIR"
    {
        sha256sum "$ARCHIVE" | sed -E 's/^([0-9a-f]{64}) [ *]/\1  /'
        sha256sum install.sh | sed -E 's/^([0-9a-f]{64}) [ *]/\1  /'
    } >SHA256SUMS
)

rm -rf -- "$STAGE"
STAGE=""

printf 'release:  %s/%s\n' "$OUT_DIR" "$ARCHIVE"
printf 'manifest: %s/SHA256SUMS\n' "$OUT_DIR"
printf 'installer:%s/install.sh\n' "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"

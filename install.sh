#!/bin/sh
# Install the published, platform-specific Nuitka binary without Python or uv.
#
#   curl -fsSL <release-url>/install.sh | sh
#   ./install.sh [VERSION] [--prefix DIRECTORY] [--force]
#
# Verification is two-layered: a sha256 checksum catches transit corruption, and an
# openssl RSA signature over the binary is the actual trust control -- an attacker who
# can replace the binary can replace its checksum file too, but cannot forge a
# signature without the private key. There is no flag to skip the signature check.
set -eu

# ─────────────────────────────────────────────────────────────────────────────────
# MOCK / TBD -- where a release actually lives. None of this is final; every value
# below is a placeholder, overridable via env so the rest of the script can be
# written and exercised before the real hosting is decided. Once it is, update the
# defaults here -- this is the one place they live.
# ─────────────────────────────────────────────────────────────────────────────────
REPOSITORY="${CWPILOT_REPOSITORY:-YuraLitvinov/binstore}"                                  
BASE_URL="${CWPILOT_RELEASE_BASE_URL:-https://github.com/${REPOSITORY}/releases}"
PREFIX="${CWPILOT_INSTALL_PREFIX:-${HOME:-}/.local/bin}"
TIMEOUT_SECONDS="${CWPILOT_INSTALL_TIMEOUT:-60}"
VERSION="${CWPILOT_VERSION:-}"
FORCE=0

# The RSA public key releases are signed with, as PEM (SubjectPublicKeyInfo). Embedded
# literally -- not read from a sibling file -- because this script must work piped
# through `curl | sh`, where there is no checkout to read a file out of. This is the
# place to put your public key: paste the contents of signing.pub below, replacing this
# block, and keep signing.pub at the repo root in sync so the two never drift apart.
# Rotate by editing both at once.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAn4GrxtJher6IBoMoq7od
JbiZ5ACLJvEKabwjz+XJFGzIhQUgYy/B2TbX0KuiLRxHnMn7pbRBa68yAB7CL5C5
eZiZLV6VwG9yayhOxXVCOsb3kBliJITkXYZLiPJ3yMvwarFm9ZuYbvN+Pfjrhy6s
yfYgnoTdTYoORTw3OJO/HU0yZEkNSe5tJ1CRws6sXBEJ9ylb1NZfewDGxRAnxtvg
eooPhbtAzBgJ9YpqQi4VLMXPRrTymypm6oF6bS8c+L54VDk37Xr6sTzX/nlq0EMR
Bpy/KGtJZQgceyx5qe2DIu2tvso2V7tRKhtoLhzLwP5IfXvTTeICM3zIDZTkUrIZ
98Vj0yW9rjsmGLIc0j5PTE8iS2jmI2VeVwsNb2/8SO0SHhlJ1YRnm442l26+VtAh
6io7TUyzfQ7mmVAAYMTjd/uq8lswut1Gv/eQ5AH+VJ4QSYIEMFRL8TnUsQf3qVXj
TL2lPz1k7GZlGgZMkt8QT0Gm10WCVr6yH6YpdXOeVIydLavEOXxf74PaYeO1zWvZ
9O7pCTR7ETQhN+50Xwpq2hEe+67eOwlYJ7yl5FQPtNdZqk0wXQs6b8Qy2n09UbUH
g9q9iIgMMKoomDGuhy7r4y0Ua0lFFh9QpA8/9k3/90+6z05IfP97hZKyk7po/Y41
vOipVXWeyt0DjfsGpSmBi/MCAwEAAQ==
-----END PUBLIC KEY-----'

usage() {
    cat <<EOF
Usage: install.sh [VERSION] [--prefix DIRECTORY] [--force]

Installs cwpilot from the Clockwork-Pilot release assets.

VERSION is a positional release tag such as 0.0.1. It defaults to "latest" when
omitted (or CWPILOT_VERSION is unset), which pins to no particular release.

Re-running updates the stable link; --force re-downloads the requested version.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || { echo "error: --prefix needs a value" >&2; exit 2; }
            PREFIX="$2"; shift 2 ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) VERSION="$1"; shift ;;
    esac
done

# ── Platform: Linux/Darwin x x86_64/arm64 ───────────────────────────────────────
# system is uname -s VERBATIM -- Linux, Darwin -- matching the <platform> keys
# scripts/find-binary.sh's platform_tag() and binaries.lock use, so a
# manually-placed cache entry and an install.sh download agree on the same name.
# arch is still normalized: uname -m spells the same CPU family differently
# across tools (amd64 vs x86_64, aarch64 vs arm64), so that half can't be raw.
system="$(uname -s)"
case "$system" in
    Linux|Darwin) ;;
    *) echo "error: unsupported OS: $system" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "error: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

PLATFORM="${system}-${arch}"

# ── Version: "latest" unless a specific release is requested ────────────────────
if [ -z "$VERSION" ]; then
    VERSION=latest
fi

# GitHub release URLs: the "latest" alias lives under releases/latest/download/, while
# a specific release lives under releases/download/<tag>/ -- and this repo's tags are
# bare versions (0.0.1), not v-prefixed, so no "v" belongs in the URL.
#   https://github.com/YuraLitvinov/binstore/releases/latest/download/cwpilot-Linux-x86_64
#   https://github.com/YuraLitvinov/binstore/releases/download/0.0.1/cwpilot-Linux-x86_64
if [ "$VERSION" = latest ]; then
    RELEASE_URL="${BASE_URL}/latest/download"
else
    VERSION="${VERSION#v}"
    # VERSION becomes a directory name below. Reject path traversal rather than
    # allowing an option intended to select a release to escape the install cache.
    case "$VERSION" in
        ''|.|..|*/*) echo "error: invalid version: ${VERSION}" >&2; exit 2 ;;
    esac
    RELEASE_URL="${BASE_URL}/download/${VERSION}"
fi

# GitHub computes and stores a sha256 "digest" for every uploaded release asset --
# it's already in the release, so there's no need to also publish (and fetch) a
# separate *.sha256 sidecar file. The digest is only exposed through the REST API,
# not the plain releases/download/... URLs used above for the binary and signature.
if [ "$VERSION" = latest ]; then
    API_URL="https://api.github.com/repos/${REPOSITORY}/releases/latest"
else
    API_URL="https://api.github.com/repos/${REPOSITORY}/releases/tags/${VERSION}"
fi

ASSET="cwpilot-${PLATFORM}"
destination="${PREFIX}/cwpilot"
cache_dir="${PREFIX}/../cwpilot-versions/${VERSION}"
cached_binary="${cache_dir}/cwpilot"
tmpdir=""
cache_tmp=""
link_tmp=""
cleanup() {
    [ -z "$tmpdir" ] || rm -rf "$tmpdir"
    [ -z "$cache_tmp" ] || rm -f "$cache_tmp"
    [ -z "$link_tmp" ] || rm -f "$link_tmp"
}
trap cleanup EXIT INT TERM

mkdir -p "$PREFIX" "$cache_dir"

# A previous version rejected an existing destination with "already exists (use
# --force)". The cache is now keyed by version, so a cached release can be reused and
# the stable link below can always move to the requested version.
if [ "$FORCE" -ne 1 ] && [ -f "$cached_binary" ]; then
    chmod 0755 "$cached_binary"
else
    command -v curl >/dev/null 2>&1 || { echo "error: curl is required" >&2; exit 1; }
    if command -v sha256sum >/dev/null 2>&1; then
        SHA256=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        SHA256="shasum -a 256"
    else
        echo "error: sha256sum or shasum is required" >&2
        exit 1
    fi
    command -v openssl >/dev/null 2>&1 || {
        echo "error: openssl is required to verify release signatures" >&2
        exit 1
    }

    # Wraps curl with a message that names what failed to download and why, instead of
    # leaving the bare "curl: (22) The requested URL returned error: 404" to explain
    # itself -- that error alone doesn't say whether it was the binary, the signature,
    # or the release metadata that 404'd, or against which URL.
    fetch() {
        description="$1"; url="$2"; out="$3"; shift 3
        if ! curl --fail --silent --show-error --location --max-time "$TIMEOUT_SECONDS" \
                "$@" "$url" -o "$out"; then
            echo "error: failed to download ${description} from ${url}" >&2
            exit 1
        fi
    }

    # The release JSON GitHub's API returns is pretty-printed one field per line, so a
    # small state machine tracking the most recently seen "name" is enough to pull out
    # the matching asset's digest -- no JSON parser needed, which matters since this
    # script has to run with nothing but curl, openssl and POSIX awk on whatever box
    # it's piped into.
    extract_digest() {
        json_file="$1"; want="$2"
        awk -v want="$want" '
            /"name":/ {
                line = $0
                sub(/^[^"]*"name": *"/, "", line)
                sub(/".*$/, "", line)
                name = line
            }
            /"digest": *"sha256:/ {
                if (name == want) {
                    line = $0
                    sub(/^[^"]*"digest": *"sha256:/, "", line)
                    sub(/".*$/, "", line)
                    print line
                    exit
                }
            }
        ' "$json_file"
    }

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cwpilot-install.XXXXXX")"
    binary="${tmpdir}/${ASSET}"
    signature="${tmpdir}/${ASSET}.sig"
    metadata="${tmpdir}/release.json"
    pubkey_file="${tmpdir}/signing.pub"
    fetch "release binary" "${RELEASE_URL}/${ASSET}" "$binary"
    fetch "release signature" "${RELEASE_URL}/${ASSET}.sig" "$signature"
    fetch "release metadata" "$API_URL" "$metadata" -H "Accept: application/vnd.github+json"

    expected="$(extract_digest "$metadata" "$ASSET")"
    [ -n "$expected" ] || {
        echo "error: no sha256 digest found for asset ${ASSET} in release metadata (${API_URL})" >&2
        exit 1
    }
    actual="$($SHA256 "$binary" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || {
        echo "error: checksum verification failed for ${ASSET} (expected ${expected}, got ${actual})" >&2
        exit 1
    }

    # CWPILOT_SIGNING_PUBKEY lets a different trust root be pointed at -- for testing
    # against a self-signed release, or after a key rotation lands upstream faster than
    # this script does. It names a KEY FILE, never disables the check.
    if [ -n "${CWPILOT_SIGNING_PUBKEY:-}" ]; then
        [ -f "$CWPILOT_SIGNING_PUBKEY" ] || {
            echo "error: CWPILOT_SIGNING_PUBKEY does not exist: ${CWPILOT_SIGNING_PUBKEY}" >&2
            exit 1
        }
        pubkey_file="$CWPILOT_SIGNING_PUBKEY"
    else
        printf '%s\n' "$PUBKEY_PEM" > "$pubkey_file"
    fi

    if ! openssl dgst -sha256 -verify "$pubkey_file" -signature "$signature" "$binary" >/dev/null 2>&1; then
        echo "error: signature verification failed for ${ASSET} -- refusing to install" >&2
        exit 1
    fi

    chmod 0755 "$binary"
    cache_tmp="${cached_binary}.tmp.$$"
    cp "$binary" "$cache_tmp"
    chmod 0755 "$cache_tmp"
    mv -f "$cache_tmp" "$cached_binary"
fi

# Replace the stable link in one rename. Readers see the old version or the new one,
# never the gap that ln -sfn would create. The relative target keeps the whole install
# tree relocatable and leaves every older versioned directory available for rollback.
link_tmp="${destination}.link.$$"
ln -s "../cwpilot-versions/${VERSION}/cwpilot" "$link_tmp"
mv -f "$link_tmp" "$destination"
echo "installed cwpilot ${VERSION} (${PLATFORM}) to ${destination}"

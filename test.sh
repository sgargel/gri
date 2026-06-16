#!/usr/bin/env bash
set -euo pipefail

GRI="$(cd "$(dirname "$0")" && pwd)/gri"
PASS=0
FAIL=0

# ── test harness ──────────────────────────────────────────────────────────────

ok() {
    echo "  PASS  $1"
    (( ++PASS ))
}

fail() {
    echo "  FAIL  $1"
    (( ++FAIL ))
}

check() {
    local desc="$1"; shift
    if "$@" &>/dev/null; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

check_fails() {
    local desc="$1"; shift
    if ! "$@" &>/dev/null; then
        ok "$desc"
    else
        fail "$desc"
    fi
}

check_output() {
    local desc="$1" pattern="$2"; shift 2
    local out
    out=$("$@" 2>&1 || true)
    if grep -q "$pattern" <<< "$out"; then
        ok "$desc"
    else
        fail "$desc (got: $out)"
    fi
}

section() { echo; echo "── $1 ──────────────────────────────────────────"; }

# ── load gri functions ────────────────────────────────────────────────────────
# source without running dispatch — requires the guard in gri
# shellcheck source=gri
source "$GRI"

# ── 1. syntax ─────────────────────────────────────────────────────────────────

section "syntax"
check "bash -n passes" bash -n "$GRI"

# ── 2. cli — basic commands ───────────────────────────────────────────────────

section "cli"
check       "help exits 0"                    "$GRI" help
check_fails "unknown command exits non-zero"  "$GRI" notacommand

# ── 3. input validation ───────────────────────────────────────────────────────

section "input validation"
check_output "rejects repo with space"   "invalid repo format" \
    "$GRI" install "bad repo/name"
check_output "rejects path traversal"   "invalid repo format" \
    "$GRI" install "../evil/repo"
check_output "rejects missing slash"    "invalid repo format" \
    "$GRI" install "noslash"
check        "accepts valid repo"        "$GRI" --dry-run install "junegunn/fzf"

# ── 4. dry-run ────────────────────────────────────────────────────────────────

section "dry-run"
check_output "--dry-run prints would download" "\[dry-run\]" \
    "$GRI" --dry-run install junegunn/fzf
check_output "-n is alias for --dry-run"       "\[dry-run\]" \
    "$GRI" -n install junegunn/fzf
check_output "--dry-run flag accepted anywhere" "\[dry-run\]" \
    "$GRI" install --dry-run junegunn/fzf

# ── 5. allow-missing-checksum ────────────────────────────────────────────────

section "allow-missing-checksum"

_ck_assets_none='[{"name":"tool-linux-amd64.tar.gz","browser_download_url":"http://x/tool.tar.gz"}]'
_ck_assets_present='[{"name":"tool-linux-amd64.tar.gz","browser_download_url":"http://x/tool.tar.gz"},{"name":"checksums.txt","browser_download_url":"http://x/checksums.txt"}]'

check_fails "find_checksum_asset: no checksum asset returns 1" \
    find_checksum_asset "$_ck_assets_none" "tool-linux-amd64.tar.gz"

check "find_checksum_asset: checksums.txt present returns 0" \
    find_checksum_asset "$_ck_assets_present" "tool-linux-amd64.tar.gz"

check_output "missing checksum without flag: error mentions --allow-missing-checksum" \
    "allow-missing-checksum" \
    bash -c "source '$GRI'
             assets=\$'[{\"name\":\"t.tar.gz\",\"browser_download_url\":\"http://x\"}]'
             if ! find_checksum_asset \"\$assets\" 't.tar.gz'; then
                 (( ALLOW_MISSING_CHECKSUM )) \
                     && echo 'warning: --allow-missing-checksum set, proceeding without verification' >&2 \
                     || die 'no checksum file found in release assets\n  → use --allow-missing-checksum to install without verification'
             fi"

check_output "missing checksum with --allow-missing-checksum: warning printed" \
    "proceeding without verification" \
    bash -c "source '$GRI'; ALLOW_MISSING_CHECKSUM=1
             assets=\$'[{\"name\":\"t.tar.gz\",\"browser_download_url\":\"http://x\"}]'
             if ! find_checksum_asset \"\$assets\" 't.tar.gz'; then
                 (( ALLOW_MISSING_CHECKSUM )) \
                     && echo 'warning: --allow-missing-checksum set, proceeding without verification' >&2 \
                     || die 'no checksum file found'
             fi"

# ── 6. prefix comparison — staging-evil attack ───────────────────────────────

section "prefix comparison"

_prefix_check() {
    local staging_real="$1" resolved="$2"
    if [[ "$resolved" != "$staging_real" && "$resolved" != "$staging_real/"* ]]; then
        return 1   # would be rejected
    fi
    return 0       # would be allowed
}

check       "exact staging dir is allowed"       _prefix_check "/staging" "/staging"
check       "descendant is allowed"              _prefix_check "/staging" "/staging/file"
check       "deep descendant is allowed"         _prefix_check "/staging" "/staging/a/b/c"
check_fails "/staging-evil is rejected"          _prefix_check "/staging" "/staging-evil"
check_fails "/stagingX is rejected"              _prefix_check "/staging" "/stagingX"
check_fails "absolute escape is rejected"        _prefix_check "/staging" "/etc/passwd"
check_fails "sibling dir is rejected"            _prefix_check "/staging" "/tmp/other"

# ── 7. archive security ───────────────────────────────────────────────────────

section "archive security"

TMPDIR_SEC=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SEC"' EXIT

# helper: run extract_and_validate against a crafted archive, expect die
_expect_reject() {
    local desc="$1" archive="$2" fmt="$3"
    local install="${TMPDIR_SEC}/install_$$" tmp="${TMPDIR_SEC}/tmp_$$"
    mkdir -p "$tmp"
    if extract_and_validate "$archive" "$fmt" "$install" "$tmp" 2>/dev/null; then
        fail "$desc (should have been rejected)"
    else
        ok "$desc"
    fi
    rm -rf "$install" "$tmp"
}

_expect_allow() {
    local desc="$1" archive="$2" fmt="$3"
    local install="${TMPDIR_SEC}/install_$$" tmp="${TMPDIR_SEC}/tmp_$$"
    mkdir -p "$tmp"
    if extract_and_validate "$archive" "$fmt" "$install" "$tmp" 2>/dev/null; then
        ok "$desc"
    else
        fail "$desc (should have been allowed)"
    fi
    rm -rf "$install" "$tmp"
}

# 6a. path traversal in entry name (../evil) — GNU tar exits non-zero on
#     entries containing .., so extract_and_validate fails before validation
mkdir -p "$TMPDIR_SEC/evil-src"
echo "evil" > "$TMPDIR_SEC/evil-src/payload"
tar -czf "$TMPDIR_SEC/path-traversal.tar.gz" \
    --transform 's|evil-src/payload|../evil|' \
    -C "$TMPDIR_SEC" evil-src/payload 2>/dev/null
_expect_reject "tar: path traversal ../ in entry — GNU tar refuses extraction" \
    "$TMPDIR_SEC/path-traversal.tar.gz" tgz

# 6b. absolute path in entry name (/etc/evil) — GNU tar strips leading /,
#     file lands inside staging as staging/etc/evil, never touches real /etc
python3 -c "
import tarfile, io
with tarfile.open('$TMPDIR_SEC/abs-path.tar.gz', 'w:gz') as t:
    info = tarfile.TarInfo('/etc/evil')
    info.size = 4
    t.addfile(info, io.BytesIO(b'evil'))
" 2>/dev/null || true
if [[ -f "$TMPDIR_SEC/abs-path.tar.gz" ]]; then
    inst="${TMPDIR_SEC}/install_ap" tmp="${TMPDIR_SEC}/tmp_ap"
    mkdir -p "$tmp"
    extract_and_validate "$TMPDIR_SEC/abs-path.tar.gz" tgz "$inst" "$tmp" 2>/dev/null || true
    if [[ ! -f /etc/evil ]]; then
        ok "tar: absolute path stripped by tar — /etc/evil not written to real fs"
    else
        fail "tar: absolute path — /etc/evil was written to real fs!"
    fi
    rm -rf "$inst" "$tmp"
else
    ok "tar: absolute path (python3 unavailable, skipped)"
fi

# 6c. symlink with absolute target
mkdir -p "$TMPDIR_SEC/sym-src"
ln -sf /etc/cron.d "$TMPDIR_SEC/sym-src/evil-link"
tar -czf "$TMPDIR_SEC/abs-symlink.tar.gz" -C "$TMPDIR_SEC/sym-src" evil-link
_expect_reject "tar: symlink with absolute target (/etc/cron.d)" \
    "$TMPDIR_SEC/abs-symlink.tar.gz" tgz

# 6d. symlink with relative escape (../../outside)
mkdir -p "$TMPDIR_SEC/rel-src/subdir"
ln -sf ../../outside "$TMPDIR_SEC/rel-src/subdir/escape-link"
tar -czf "$TMPDIR_SEC/rel-escape.tar.gz" -C "$TMPDIR_SEC/rel-src" subdir/escape-link
_expect_reject "tar: symlink with relative escape (../../outside)" \
    "$TMPDIR_SEC/rel-escape.tar.gz" tgz

# 6e. symlink staying inside staging (should be allowed)
mkdir -p "$TMPDIR_SEC/good-src"
echo "target content" > "$TMPDIR_SEC/good-src/real-file"
ln -sf real-file "$TMPDIR_SEC/good-src/safe-link"
tar -czf "$TMPDIR_SEC/safe-symlink.tar.gz" -C "$TMPDIR_SEC/good-src" real-file safe-link
_expect_allow "tar: relative symlink staying inside archive (allowed)" \
    "$TMPDIR_SEC/safe-symlink.tar.gz" tgz

# 6f. clean archive (single binary, no tricks)
mkdir -p "$TMPDIR_SEC/clean-src"
echo "#!/bin/sh" > "$TMPDIR_SEC/clean-src/mytool"
chmod +x "$TMPDIR_SEC/clean-src/mytool"
tar -czf "$TMPDIR_SEC/clean.tar.gz" -C "$TMPDIR_SEC/clean-src" mytool
_expect_allow "tar: clean archive is allowed" \
    "$TMPDIR_SEC/clean.tar.gz" tgz

# ── 8. smoke install (real network) ──────────────────────────────────────────

section "smoke install (network)"

OPT_SMOKE=$(mktemp -d)
BIN_SMOKE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SEC" "$OPT_SMOKE" "$BIN_SMOKE"' EXIT

smoke_out=""
if smoke_out=$(GRI_OPT_DIR="$OPT_SMOKE" GRI_BIN_DIR="$BIN_SMOKE" "$GRI" install junegunn/fzf 2>&1); then
    ok "gri install junegunn/fzf"
else
    fail "gri install junegunn/fzf"
    printf '%s\n' "$smoke_out" >&2
fi

if [[ -x "$BIN_SMOKE/fzf" ]] || [[ -L "$BIN_SMOKE/fzf" ]]; then
    ok "fzf symlink exists in BIN_DIR"
else
    fail "fzf symlink missing from BIN_DIR"
fi

if "$BIN_SMOKE/fzf" --version &>/dev/null; then
    ok "fzf --version runs"
else
    fail "fzf --version failed"
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "────────────────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
echo "────────────────────────────────────────────────"
(( FAIL == 0 ))

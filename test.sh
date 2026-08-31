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

# ── cleanup ───────────────────────────────────────────────────────────────────
# a single EXIT trap over a global list — registering a new trap per section
# would silently discard the previous one and orphan its temp dirs
CLEANUP_PATHS=()

# NOTE: not named `cleanup` — sourcing gri below would shadow it with gri's own
# cleanup(), leaving the trap to remove gri's tmp_dir instead of ours
# shellcheck disable=SC2317  # invoked indirectly by the EXIT trap
cleanup_tmpdirs() {
    (( ${#CLEANUP_PATHS[@]} )) && rm -rf "${CLEANUP_PATHS[@]}"
    return 0
}
trap cleanup_tmpdirs EXIT

# mktemp -d into the named variable, registered for removal at exit.
# takes the variable name rather than printing the path: command substitution
# runs in a subshell, so a printed path could not append to CLEANUP_PATHS.
# usage: mktempd VARNAME
mktempd() {
    local d
    d=$(mktemp -d)
    CLEANUP_PATHS+=("$d")
    printf -v "$1" '%s' "$d"
}

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

# ── 5. kubectl-plugin ────────────────────────────────────────────────────────

section "kubectl-plugin"

mktempd _KP_OPT; mktempd _KP_BIN_DRY
check_output "--kubectl-plugin dry-run prints kubectl symlink line" "kubectl-oidc_login" \
    env GRI_OPT_DIR="$_KP_OPT" GRI_BIN_DIR="$_KP_BIN_DRY" \
    "$GRI" --dry-run --kubectl-plugin=oidc_login install int128/kubelogin

mktempd _KP_BIN
_KP_BIN_FILE="${_KP_BIN}/kubelogin"
echo "#!/bin/sh" > "$_KP_BIN_FILE"
chmod +x "$_KP_BIN_FILE"
mktempd _KP_LINK_DIR

bash -c "
    source '$GRI'
    BIN_DIR='$_KP_LINK_DIR'
    KUBECTL_PLUGIN='oidc_login'
    do_link '$_KP_BIN_FILE' kubelogin
" &>/dev/null

check "do_link creates kubectl-<name> symlink when KUBECTL_PLUGIN is set" \
    test -L "$_KP_LINK_DIR/kubectl-oidc_login"

check "kubectl-<name> symlink points to the binary" \
    test "$(readlink "$_KP_LINK_DIR/kubectl-oidc_login")" = "$_KP_BIN_FILE"

check "normal symlink is also created alongside kubectl symlink" \
    test -L "$_KP_LINK_DIR/kubelogin"

bash -c "
    source '$GRI'
    BIN_DIR='$_KP_LINK_DIR'
    KUBECTL_PLUGIN=''
    do_link '$_KP_BIN_FILE' kubelogin
" &>/dev/null

check_fails "do_link creates no kubectl-* symlink when KUBECTL_PLUGIN is unset" \
    test -L "$_KP_LINK_DIR/kubectl-"

# ── 6. allow-missing-checksum ─────────────────────────────────────────────────

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

# ── asset selection ───────────────────────────────────────────────────────────

section "asset selection"

# signature/cert sidecars must not be scored as installable binaries
check_output "score_asset: .asc signature scores 0" "^0$" \
    score_asset "tool-linux-amd64.tar.gz.asc" linux amd64
check_output "score_asset: .sig signature scores 0" "^0$" \
    score_asset "tool-linux-amd64.tar.gz.sig" linux amd64
check_output "score_asset: real archive still scores" "^1[0-9]$" \
    score_asset "tool-linux-amd64.tar.gz" linux amd64

# helm publishes ONLY .asc files on GitHub (binaries live on get.helm.sh) —
# pick_asset must reject the release rather than install a signature file
_helm_assets='[{"name":"helm-v4.2.2-linux-amd64.tar.gz.asc","browser_download_url":"http://x/a"},{"name":"helm-v4.2.2-linux-amd64.tar.gz.sha256.asc","browser_download_url":"http://x/b"}]'
check_fails "pick_asset: all-.asc release (helm) returns 1" \
    pick_asset "$_helm_assets" linux amd64

# a release with both archive and its .asc still picks the archive
_signed_assets='[{"name":"tool-linux-amd64.tar.gz","browser_download_url":"http://x/t"},{"name":"tool-linux-amd64.tar.gz.asc","browser_download_url":"http://x/s"}]'
check_output "pick_asset: prefers archive over its .asc sidecar" "^tool-linux-amd64.tar.gz	" \
    pick_asset "$_signed_assets" linux amd64

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

mktempd TMPDIR_SEC

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

mktempd OPT_SMOKE
mktempd BIN_SMOKE

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

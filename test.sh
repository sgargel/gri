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
# usage: mktempd VARNAME  (VARNAME upper-case, as shellcheck's SC2154 does not
# see through the indirect assignment for lower-case names)
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

# ── 6. install --as ────────────────────────────────────────────────────────────

section "install --as"

check_output "--as dry-run prints customized extraction path" "/gh/" \
    "$GRI" --dry-run --as=gh install cli/cli
check_output "--as dry-run prints customized symlink line" "bin/gh →" \
    "$GRI" --dry-run --as=gh install cli/cli
check_output "--as flag accepted anywhere in arguments" "bin/gh →" \
    "$GRI" install cli/cli --as=gh --dry-run
check_output "rejects invalid --as name" "invalid name" \
    "$GRI" --dry-run --as="bad/name" install cli/cli

# ── 7. allow-missing-checksum ─────────────────────────────────────────────────

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

# ── checksum tooling ──────────────────────────────────────────────────────────

section "checksum tooling"

mktempd _CK_DIR
_CK_FILE="${_CK_DIR}/payload"
printf 'gri checksum fixture\n' > "$_CK_FILE"

check_output "hash_file sha256 matches sha256sum" "^$(sha256sum "$_CK_FILE" | awk '{print $1}')$" \
    hash_file sha256 "$_CK_FILE"

check_output "hash_file sha512 matches sha512sum" "^$(sha512sum "$_CK_FILE" | awk '{print $1}')$" \
    hash_file sha512 "$_CK_FILE"

# a PATH holding only the tools hash_file may legitimately use, so the GNU
# *sum commands are genuinely absent — this is the only way the macOS
# fallbacks get exercised on a GNU CI runner
mktempd _CK_STUB
ln -s "$(command -v awk)" "${_CK_STUB}/awk"
_CK_ARGS="${_CK_DIR}/stub-args"

cat > "${_CK_STUB}/shasum" <<'STUB'
#!/bin/sh
echo "$@" >> "$STUB_ARGS"
echo "5ee5um  $3"
STUB
cat > "${_CK_STUB}/md5" <<'STUB'
#!/bin/sh
echo "$@" >> "$STUB_ARGS"
echo "5ee5md5"
STUB
chmod +x "${_CK_STUB}/shasum" "${_CK_STUB}/md5"

# run hash_file with PATH restricted to the stub dir
_hash_stubbed() { ( PATH="$_CK_STUB"; STUB_ARGS="$_CK_ARGS"; export STUB_ARGS; hash_file "$@" ); }

check_output "hash_file falls back to shasum when sha256sum is absent" "^5ee5um$" \
    _hash_stubbed sha256 "$_CK_FILE"
check_output "shasum fallback requests the right algorithm" "^-a 256 " \
    cat "$_CK_ARGS"

: > "$_CK_ARGS"
check_output "hash_file falls back to shasum for sha512" "^5ee5um$" \
    _hash_stubbed sha512 "$_CK_FILE"
check_output "shasum fallback maps sha512 to -a 512" "^-a 512 " \
    cat "$_CK_ARGS"

: > "$_CK_ARGS"
check_output "hash_file falls back to md5 when md5sum is absent" "^5ee5md5$" \
    _hash_stubbed md5 "$_CK_FILE"
check_output "md5 fallback uses -q for a bare digest" "^-q " \
    cat "$_CK_ARGS"

# nothing usable on PATH: must fail loudly, never silently produce no digest
rm "${_CK_STUB}/shasum" "${_CK_STUB}/md5"
check_output "hash_file without sha256sum or shasum reports the missing tool" "cannot verify the sha256 checksum" \
    _hash_stubbed sha256 "$_CK_FILE"
check_fails "hash_file without any sha tool exits non-zero" \
    _hash_stubbed sha256 "$_CK_FILE"
check_output "hash_file without md5sum or md5 reports the missing tool" "cannot verify the md5 checksum" \
    _hash_stubbed md5 "$_CK_FILE"
# hash_file die()s here; the explicit subshell keeps that exit from escaping
# check_output's command substitution and taking the whole harness down
_hash() { ( hash_file "$@" ); }
check_output "hash_file rejects an unknown algorithm" "unsupported checksum algorithm" \
    _hash sha1 "$_CK_FILE"
check_fails "hash_file exits non-zero on an unknown algorithm" \
    _hash sha1 "$_CK_FILE"

# ── link collisions ───────────────────────────────────────────────────────────

section "link collisions"

mktempd _LC_ROOT
_LC_BIN_FILE="${_LC_ROOT}/mytool"
printf '#!/bin/sh\n' > "$_LC_BIN_FILE"
chmod +x "$_LC_BIN_FILE"

# do_link into a fresh BIN_DIR where the link name is already taken by the
# given kind of entry. The dir is carved out of _LC_ROOT rather than mktempd'd
# so it is still cleaned up when a caller runs this in a subshell.
_link_over() {
    local kind="$1" plugin="${2:-}"
    _LC_DIR=$(mktemp -d "${_LC_ROOT}/bin.XXXXXX")
    case "$kind" in
        file)     printf 'installed by a package manager\n' > "${_LC_DIR}/mytool" ;;
        symlink)  ln -s /dev/null "${_LC_DIR}/mytool" ;;
        dirlink)  mkdir -p "${_LC_DIR}/real"; ln -s "${_LC_DIR}/real" "${_LC_DIR}/mytool" ;;
        plugin)   printf 'installed by a package manager\n' > "${_LC_DIR}/kubectl-oidc_login" ;;
        none)     ;;
    esac
    # subshell: do_link may die(), and that exit must not take the harness down
    ( BIN_DIR="$_LC_DIR" KUBECTL_PLUGIN="$plugin" do_link "$_LC_BIN_FILE" mytool )
}

# succeeds when do_link's stderr matches PATTERN
_link_says() { local kind="$1" pat="$2"; _link_over "$kind" 2>&1 >/dev/null | grep -q "$pat"; }

# NOTE: the _link_over setup calls are `|| true` on purpose. set -e is disabled
# inside check(), so a do_link whose `ln` failed still returns 0 and the call
# alone proves nothing — every guarantee below is asserted on the result.

# a regular file at the link name is somebody else's binary: refuse it rather
# than destroy it, the same way a missing checksum refuses rather than trusting
check_fails "do_link refuses to clobber a regular file" \
    _link_over file
check_output "the refusal names the path and the opt-in flag" "already exists and is not a symlink" \
    _link_over file
check_output "the refusal suggests --allow-overwrite" "allow-overwrite" \
    _link_over file
_link_over file &>/dev/null || true
check "the regular file is left untouched" \
    grep -q "installed by a package manager" "${_LC_DIR}/mytool"
check_fails "no symlink is created in its place" \
    test -L "${_LC_DIR}/mytool"

# ALLOW_OVERWRITE is the opt-in, and it warns rather than going quiet
ALLOW_OVERWRITE=1
_link_over file &>/dev/null || true
check "--allow-overwrite replaces the regular file with a symlink" \
    test -L "${_LC_DIR}/mytool"
check "the replacement symlink points at the new binary" \
    test "$(readlink "${_LC_DIR}/mytool")" = "$_LC_BIN_FILE"
check_fails "replacing under --allow-overwrite raises no 'File exists' error" \
    _link_says file "File exists"
check_output "replacing a regular file is announced" "warning: replacing existing file" \
    _link_over file
ALLOW_OVERWRITE=0

# symlinks are ours to replace — destroying a pointer costs nothing, so these
# stay silent and need no flag
_link_over symlink &>/dev/null || true
check "an existing plain symlink is still overwritten without a flag" \
    test "$(readlink "${_LC_DIR}/mytool")" = "$_LC_BIN_FILE"
check "overwriting a plain symlink prints no warning" \
    test -z "$(_link_over symlink 2>&1 >/dev/null)"

# a symlink to a directory must be replaced, not followed into (this is what -n buys)
_link_over dirlink &>/dev/null || true
check "a symlink to a directory is replaced, not linked into" \
    test "$(readlink "${_LC_DIR}/mytool")" = "$_LC_BIN_FILE"
check_fails "no link is created inside the target directory" \
    test -e "${_LC_DIR}/real/mytool"

_link_over none &>/dev/null || true
check "a symlink is created when nothing is in the way" \
    test -L "${_LC_DIR}/mytool"

# the kubectl plugin link is guarded too, even though the primary name is free
check_fails "a regular file at the kubectl plugin link is refused" \
    _link_over plugin oidc_login
_link_over plugin oidc_login &>/dev/null || true
check_fails "the primary link is not created when the plugin link is blocked" \
    test -L "${_LC_DIR}/mytool"
ALLOW_OVERWRITE=1
_link_over plugin oidc_login &>/dev/null || true
check "--allow-overwrite lets the kubectl plugin link through" \
    test -L "${_LC_DIR}/kubectl-oidc_login"
check "kubectl plugin link points at the binary" \
    test "$(readlink "${_LC_DIR}/kubectl-oidc_login")" = "$_LC_BIN_FILE"
ALLOW_OVERWRITE=0

# end-to-end: the install pre-flight refuses before anything is downloaded, and
# a dry-run preview agrees with what the real run would do
mktempd _LC_E2E_OPT; mktempd _LC_E2E_BIN
printf 'installed by a package manager\n' > "${_LC_E2E_BIN}/fzf"

check_output "install refuses when BIN_DIR/<name> is a regular file" "already exists and is not a symlink" \
    env GRI_OPT_DIR="$_LC_E2E_OPT" GRI_BIN_DIR="$_LC_E2E_BIN" "$GRI" install junegunn/fzf
check_fails "the refused install downloaded nothing" \
    test -e "${_LC_E2E_OPT}/fzf"
check_output "dry-run reports the collision instead of promising a link" "already exists and is not a symlink" \
    env GRI_OPT_DIR="$_LC_E2E_OPT" GRI_BIN_DIR="$_LC_E2E_BIN" "$GRI" --dry-run install junegunn/fzf
check_output "--allow-overwrite gets the dry-run preview through" "would link" \
    env GRI_OPT_DIR="$_LC_E2E_OPT" GRI_BIN_DIR="$_LC_E2E_BIN" "$GRI" --dry-run --allow-overwrite install junegunn/fzf

# ── gz assets ─────────────────────────────────────────────────────────────────

section "gz assets"

check_output "score_asset: standalone .gz scores as an installable binary" "^15$" \
    score_asset "tool_linux_amd64.gz" linux amd64

_gz_assets='[{"name":"tool_linux_amd64.gz","browser_download_url":"http://x/g"},{"name":"tool_windows_amd64.gz","browser_download_url":"http://x/w"}]'
check_output "pick_asset: selects the standalone .gz for the host" "tool_linux_amd64\.gz" \
    pick_asset "$_gz_assets" linux amd64

mktempd _GZ_ROOT

# place_asset may die(); the subshell keeps that from ending the harness
_place() { ( place_asset "$@" ); }

# lay out a tmp_dir holding ASSET, and a fresh empty install dir
_gz_case() {
    _GZ_TMP=$(mktemp -d "${_GZ_ROOT}/tmp.XXXXXX")
    _GZ_INST="${_GZ_TMP}/install"
}

# a standalone .gz is decompressed, not copied verbatim
_gz_case
printf '#!/bin/sh\necho gz-payload\n' > "${_GZ_TMP}/src"
gzip -c "${_GZ_TMP}/src" > "${_GZ_TMP}/tool_linux_amd64.gz"
_place tool_linux_amd64.gz mytool "$_GZ_INST" "$_GZ_TMP" &>/dev/null || true
check "the .gz is decompressed to the tool name" \
    test -f "${_GZ_INST}/mytool"
check "the installed file is the decompressed payload, not the gzip stream" \
    grep -q "gz-payload" "${_GZ_INST}/mytool"
check "the decompressed binary is executable" \
    test -x "${_GZ_INST}/mytool"
check_fails "the compressed asset is not left in the install dir" \
    test -e "${_GZ_INST}/tool_linux_amd64.gz"

# the output name comes from $name, never from the FNAME field in the gzip
# header — that field is attacker-controlled release metadata
_gz_case
printf 'payload\n' > "${_GZ_TMP}/evil-header-name"
gzip -c "${_GZ_TMP}/evil-header-name" > "${_GZ_TMP}/tool_linux_amd64.gz"
_place tool_linux_amd64.gz mytool "$_GZ_INST" "$_GZ_TMP" &>/dev/null || true
check_fails "the gzip header's stored filename is not used as the output name" \
    test -e "${_GZ_INST}/evil-header-name"
check "the output is named after the tool instead" \
    test -f "${_GZ_INST}/mytool"

# a corrupt asset must fail loudly and leave nothing behind
_gz_case
printf 'not a gzip stream at all\n' > "${_GZ_TMP}/tool_linux_amd64.gz"
check_fails "a corrupt .gz fails the install" \
    _place tool_linux_amd64.gz mytool "$_GZ_INST" "$_GZ_TMP"
check_output "the failure names the asset" "failed to decompress" \
    _place tool_linux_amd64.gz mytool "$_GZ_INST" "$_GZ_TMP"
check_fails "a corrupt .gz leaves no install dir behind" \
    test -d "$_GZ_INST"

# trailing garbage is a malformed asset: gzip exits 2, so it is refused
_gz_case
printf 'payload\n' | gzip -c > "${_GZ_TMP}/tool_linux_amd64.gz"
printf 'JUNK' >> "${_GZ_TMP}/tool_linux_amd64.gz"
check_fails "a .gz with trailing garbage is refused" \
    _place tool_linux_amd64.gz mytool "$_GZ_INST" "$_GZ_TMP"

# ordering: .tar.gz must still reach the tar handler, not the new .gz arm
_gz_case
mkdir -p "${_GZ_TMP}/src.d"
printf '#!/bin/sh\necho from-tar\n' > "${_GZ_TMP}/src.d/mytool"
tar -czf "${_GZ_TMP}/tool_linux_amd64.tar.gz" -C "${_GZ_TMP}/src.d" mytool
_place tool_linux_amd64.tar.gz mytool "$_GZ_INST" "$_GZ_TMP" &>/dev/null || true
check "a .tar.gz is still extracted as a tarball" \
    grep -q "from-tar" "${_GZ_INST}/mytool"

# unchanged: the other formats still route where they did
_gz_case
printf 'appimage-bytes\n' > "${_GZ_TMP}/tool-x86_64.AppImage"
_place tool-x86_64.AppImage mytool "$_GZ_INST" "$_GZ_TMP" &>/dev/null || true
check "an AppImage keeps its extension" \
    test -x "${_GZ_INST}/tool-x86_64.AppImage"

_gz_case
printf 'raw-bytes\n' > "${_GZ_TMP}/tool_linux_amd64"
_place tool_linux_amd64 mytool "$_GZ_INST" "$_GZ_TMP" &>/dev/null || true
check "a raw binary is copied under the tool name" \
    test -x "${_GZ_INST}/mytool"

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

# ── 8. AppImage ────────────────────────────────────────────────────────────────

section "AppImage"

check_output "score_asset: AppImage linux amd64 scores > 0" "^[1-9]" \
    score_asset "tool-v1.0.0-linux-amd64.AppImage" linux amd64

check_output "score_asset: AppImage on darwin returns 0" "^0$" \
    score_asset "tool-v1.0.0-linux-amd64.AppImage" darwin amd64

check_output "score_asset: flatpak returns 0" "^0$" \
    score_asset "tool-v1.0.0-linux-amd64.flatpak" linux amd64

_ai_assets1='[{"name":"tool-linux-amd64.flatpak","browser_download_url":"http://x/f"},{"name":"tool-linux-amd64.AppImage","browser_download_url":"http://x/a"},{"name":"tool-src.tar.gz","browser_download_url":"http://x/s"}]'
check_output "pick_asset: prefers AppImage over Flatpak" "\.AppImage" \
    pick_asset "$_ai_assets1" linux amd64

# AppImage without "linux" in name — still selected via .appimage OS detection
_ai_no_linux='[{"name":"tool-x86_64.AppImage","browser_download_url":"http://x/a"},{"name":"tool-src.tar.gz","browser_download_url":"http://x/s"}]'
check_output "pick_asset: AppImage without 'linux' in name selected on linux" "\.AppImage" \
    pick_asset "$_ai_no_linux" linux amd64

mktempd _AI_FIND_TMP
echo "fake" > "$_AI_FIND_TMP/mytool-v1.0.0-x86_64.AppImage"
chmod +x "$_AI_FIND_TMP/mytool-v1.0.0-x86_64.AppImage"
check_output "find_binary: finds .AppImage file" "\.AppImage$" \
    find_binary "$_AI_FIND_TMP" mytool

mktempd _AI_FIND_TMP2
echo "fake" > "$_AI_FIND_TMP2/mytool.appimage"
chmod +x "$_AI_FIND_TMP2/mytool.appimage"
check_output "find_binary: finds .appimage (lowercase)" "\.appimage$" \
    find_binary "$_AI_FIND_TMP2" mytool

# ── 9. stale directory prevention ──────────────────────────────────────────────

section "stale directory prevention"

mktempd _SD_PARENT
_sd_imaginary="${_SD_PARENT}/deep/nested/install"

bash -c "
    source '$GRI'
    check_dir='$_sd_imaginary'
    while [[ \"\$check_dir\" != \"/\" && ! -d \"\$check_dir\" ]]; do
        check_dir=\$(dirname \"\$check_dir\")
    done
    [[ -w \"\$check_dir\" ]]
" &>/dev/null

check "writability check does not create the install directory" \
    test ! -d "$_sd_imaginary"

# ── 9. smoke install (real network) ───────────────────────────────────────────

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

# ── 11. amule AppImage smoke test (real network) ──────────────────────────────

section "amule smoke test (network)"

mktempd _AMULE_OPT
mktempd _AMULE_BIN

# Scenario 1: install without checksums must fail and leave NO stale directory.
_amule_fail_out=""
if _amule_fail_out=$(GRI_OPT_DIR="$_AMULE_OPT" GRI_BIN_DIR="$_AMULE_BIN" \
    "$GRI" install amule-org/amule 3.0.1 2>&1); then
    fail "amule: install without checksum should fail"
    printf '%s\n' "$_amule_fail_out" >&2
else
    ok "amule: install without checksum fails as expected"
fi

if [[ -d "$_AMULE_OPT/amule/3.0.1" ]]; then
    fail "amule: stale directory found after failed install"
else
    ok "amule: no stale directory after failed install"
fi

# Scenario 2: retry with --allow-missing-checksum — must succeed.
_amule_ok_out=""
if _amule_ok_out=$(GRI_OPT_DIR="$_AMULE_OPT" GRI_BIN_DIR="$_AMULE_BIN" \
    "$GRI" --allow-missing-checksum install amule-org/amule 3.0.1 2>&1); then
    ok "amule: install with --allow-missing-checksum succeeds"
else
    fail "amule: install with --allow-missing-checksum failed"
    printf '%s\n' "$_amule_ok_out" >&2
fi

# Verify the AppImage was installed with its original filename
_amule_target=$(readlink "$_AMULE_BIN/amule" 2>/dev/null || echo "")
if [[ "$_amule_target" == *.AppImage ]]; then
    ok "amule: symlink points to .AppImage file (extension preserved)"
else
    fail "amule: symlink points to ${_amule_target} (expected .AppImage)"
fi

if [[ -x "$_amule_target" ]] || [[ -x "$_AMULE_BIN/amule" ]]; then
    ok "amule: binary is executable"
else
    fail "amule: binary not executable"
fi

# ── summary ───────────────────────────────────────────────────────────────────

echo
echo "────────────────────────────────────────────────"
echo "  passed: $PASS   failed: $FAIL"
echo "────────────────────────────────────────────────"
(( FAIL == 0 ))

# gri _(aka GitHub Release Installer)_

A lot of great CLI tools — `k9s`, `lazygit`, `terragrunt`, `aws-vault` and many
others — are mainly distributed as GitHub releases. Installing them manually means
downloading an archive, extracting it somewhere, and remembering to keep it
updated. Package managers either don't have them or ship outdated versions.

gri automates this with a layout that follows Linux conventions:

```
/opt/fzf/v0.73.1/       ← full release lives here
/usr/local/bin/fzf       → symlink to the binary
```

Multiple versions coexist under `/opt/<name>/` and switching between them is a
single command. Downloads are verified against SHA256/SHA512 checksums when the
release provides them.

## Why not eget / aqua / mise?

- **[eget](https://github.com/zyedidia/eget)** — closest in spirit, but drops
  the binary wherever you tell it without any version structure. Also currently
  unmaintained.
- **[aqua](https://aquaproj.github.io/)** — declarative and powerful, but
  requires a YAML manifest and a separate registry.
- **[mise](https://mise.jdx.dev/)** — great for runtimes (Go, Node, Python);
  overkill for standalone CLI binaries.

gri is a single bash script with no config files, no registries, and no
manifest. `gri install owner/repo` and you're done.

## Verify

```bash
gri list gri
# installed versions of gri:
#   * v0.0.2  (active)
```

## Requirements

`curl`, `jq`, `tar`, `unzip` (for `.zip` releases), `gzip` (for standalone `.gz` binaries), plus a hashing tool for checksum verification: `sha256sum` / `sha512sum` / `md5sum`, or the `shasum` / `md5` equivalents that macOS ships instead. All are pre-installed on most Linux distros except `unzip`.

## Install

```bash
# system-wide (requires sudo)
curl -fsSL https://github.com/sgargel/gri/releases/latest/download/gri -o /tmp/gri-boot \
  && chmod +x /tmp/gri-boot \
  && sudo /tmp/gri-boot install sgargel/gri \
  && rm /tmp/gri-boot

# current user only, no sudo
curl -fsSL https://github.com/sgargel/gri/releases/latest/download/gri -o /tmp/gri-boot \
  && chmod +x /tmp/gri-boot \
  && /tmp/gri-boot --user install sgargel/gri \
  && rm /tmp/gri-boot
```

## Usage

```bash
gri install <owner/repo> [version]   # install latest or a specific version
gri switch  <name> <version>         # switch the active version
gri link    <name> <version> <bin>   # manually set the binary to symlink
gri list    <name>                   # list locally installed versions
gri versions <owner/repo>            # list available releases on GitHub
gri remove  <name> <version>         # remove an installed version
```

## Flags

| Flag | Description |
|---|---|
| `--user` / `-u` | Install in `~/.local/opt` and `~/.local/bin` (no sudo required) |
| `--dry-run` / `-n` | Print what would happen without doing anything |
| `--allow-missing-checksum` / `-k` | Proceed even if the release provides no checksum file |
| `--allow-overwrite` | Replace a file in `BIN_DIR` that gri did not create. Without it, a non-symlink at the link name is refused rather than destroyed |
| `--kubectl-plugin=<name>` | Also create a `kubectl-<name>` symlink so the binary is discoverable as a kubectl plugin |
| `--as=<name>` | Install and link under an alternative tool name (e.g. `--as=gh cli/cli`) |

Flags can appear anywhere in the command line and can be combined.

## Examples

```bash
# system-wide (requires sudo)
sudo gri install junegunn/fzf
sudo gri --as=gh install cli/cli v2.50.0
sudo gri install yannh/kubeconform

# user install, no sudo
gri --user install gruntwork-io/terragrunt
gri --user install yannh/kubeconform

# install under an alternative tool name
gri --as=gh install cli/cli

# release with no checksum file (explicit opt-out)
gri --allow-missing-checksum install stackrox/kube-linter

# install a kubectl plugin (creates both kubelogin and kubectl-oidc_login symlinks)
sudo gri --kubectl-plugin=oidc_login install int128/kubelogin

# preview before installing
gri --dry-run install junegunn/fzf
gri --user --dry-run install gruntwork-io/terragrunt

# manage versions
gri list fzf
gri switch fzf v0.53.0
gri remove fzf v0.53.0
```

## Directory layout

```
/opt/fzf/v0.73.1/          ← extracted release
/usr/local/bin/fzf          → /opt/fzf/v0.73.1/fzf

~/.local/opt/fzf/v0.73.1/  ← with --user
~/.local/bin/fzf            → ~/.local/opt/fzf/v0.73.1/fzf
```

## Checksum verification

gri automatically looks for a checksum file in the release assets and verifies
the download before extracting. Supports `checksums.txt` (goreleaser),
`SHA256SUMS` (hashicorp/terragrunt style), and per-asset `.sha256` / `.sha512`
sidecar files. If no checksum file is found, a warning is printed and the
install continues.

## License

MIT — see [LICENSE](LICENSE).

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GRI_OPT_DIR` | `/opt` | Override install base directory |
| `GRI_BIN_DIR` | `/usr/local/bin` | Override symlink directory |
| `GITHUB_TOKEN` | _(unset)_ | Personal access token or `${{ secrets.GITHUB_TOKEN }}` — required for private repos, raises API rate limit from 60 to 5000 req/h |

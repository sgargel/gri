# gri — GitHub Release Installer

A small bash script that downloads GitHub releases and installs them properly:
binaries land in `/opt/<name>/<version>/` with a symlink in `/usr/local/bin/`.

Supports multiple coexisting versions and SHA256/SHA512 checksum verification.

## Requirements

`curl`, `jq`, `sha256sum` / `sha512sum` / `md5sum` (for checksum verification — pre-installed on most Linux distros)

## Install

```bash
sudo cp gri /usr/local/bin/gri
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

Flags can appear anywhere in the command line and can be combined.

## Examples

```bash
# system-wide (requires sudo)
sudo gri install junegunn/fzf
sudo gri install cli/cli v2.50.0

# user install, no sudo
gri --user install gruntwork-io/terragrunt

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

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `GRI_OPT_DIR` | `/opt` | Override install base directory |
| `GRI_BIN_DIR` | `/usr/local/bin` | Override symlink directory |

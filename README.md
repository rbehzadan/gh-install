# gh-install

A reliable shell utility to download and install the latest (or specific) release of a binary from GitHub Releases.

- ✅ Auto-detects OS and architecture
- 🔍 Filters assets by platform and optional pattern
- 📦 Supports `.tar.gz`, `.zip`, `.bz2`, etc.
- 🔐 Installs with `sudo`, `doas`, or user directory
- 📡 Robust downloads with retries and resume support

---

## 📦 Installation

```bash
curl -fsSL https://raw.githubusercontent.com/rbehzadan/gh-install/main/gh-install.sh -o gh-install
sudo install gh-install /usr/local/bin/
```

---

## 🚀 Usage

```bash
gh-install <owner/repo> [OPTIONS]
```

### Examples

```bash
# Install latest version of k6
gh-install grafana/k6

# Install latest version of openbao
gh-install openbao/openbao --binary bao --pattern bao_

# Install a specific version of hugo extended
gh-install gohugoio/hugo --version 0.123.0 --pattern extended

# Install to custom directory
gh-install cli/cli --binary gh --install-dir ~/.local/bin
```

---

## ⚙️ Options

| Option                | Description                                        |
| --------------------- | -------------------------------------------------- |
| `--version <ver>`     | Install a specific version (default: latest)       |
| `--binary <name>`     | Set binary name (default: repo name)               |
| `--os <os>`           | Override OS detection (`linux`, `darwin`, etc.)    |
| `--arch <arch>`       | Override architecture (`amd64`, `arm64`, etc.)     |
| `--pattern <string>`  | Require substring in asset name (e.g., `extended`) |
| `--install-dir <dir>` | Install directory (default: `/usr/local/bin`)      |
| `--extracted-dir <d>` | Path inside archive that contains the binary       |
| `--force`             | Force reinstall even if binary exists              |
| `--quiet`             | Suppress non-error messages                        |
| `--debug`             | Show debug logs                                    |
| `--help`              | Show help message                                  |

---

## 🔐 Permissions

Automatically installs using:

* `sudo` or `doas` if available
* Falls back to `~/.local/bin` if no privilege escalation is possible

---

## 📁 License

MIT License © Reza Behzadan


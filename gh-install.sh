#!/usr/bin/env bash
set -euo pipefail

# === Configuration ===
REPO_OWNER=""
REPO_NAME=""
BINARY_NAME=""
GIT_SERVER="github.com"
INSTALL_DIR="/usr/local/bin"
VERSION=""
OVERRIDE_OS=""
OVERRIDE_ARCH=""
EXTRACTED_DIR=""
FORCE_INSTALL=false
QUIET=false
PATTERN=""

# === Logging Functions ===
log_info() {
    if [[ "$QUIET" != true ]]; then
        echo -e "ℹ️  $*" >&2
    fi
}

log_error() {
    echo -e "❌ $*" >&2
}

log_warn() {
    echo -e "⚠️  $*" >&2
}

log_success() {
    echo -e "✅ $*" >&2
}

log_debug() {
    # Enable debug logging by setting DEBUG=1
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "🐛 $*" >&2
    fi
}

# === System Detection Functions ===
detect_os() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        linux) echo "linux" ;;
        darwin) echo "darwin" ;;
        mingw*|msys*|cygwin*) echo "windows" ;;
        *) echo "$os" ;;
    esac
}

detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv6" ;;
        i386|i686) echo "386" ;;
        *) echo "$arch" ;;
    esac
}

get_os_patterns() {
    local os="${1:-$(detect_os)}"
    case "$os" in
        linux) echo "linux _linux" ;;
        darwin) echo "darwin _darwin macos _macos macOS _macOS osx _osx OSX _OSX" ;;
        windows) echo "windows _windows win _win Win _Win" ;;
        freebsd) echo "freebsd _freebsd" ;;
        *) echo "$os _$os" ;;
    esac
}

get_arch_patterns() {
    local arch="${1:-$(detect_arch)}"
    case "$arch" in
        amd64) echo "amd64 _amd64 x86_64 _x86_64 x64 _x64" ;;
        arm64) echo "arm64 _arm64 aarch64 _aarch64" ;;
        armv7) echo "armv7 _armv7 arm _arm" ;;
        armv6) echo "armv6 _armv6" ;;
        386) echo "386 _386 i386 _i386 i686 _i686" ;;
        *) echo "$arch _$arch" ;;
    esac
}

# === Validation Functions ===
validate_repo_format() {
    local repo="$1"
    if [[ ! "$repo" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid repository format: '$repo'"
        log_error "Expected format: owner/repo"
        return 1
    fi
}

validate_binary_name() {
    local binary="$1"
    if [[ ! "$binary" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid binary name: '$binary'"
        log_error "Binary name should contain only alphanumeric characters, dots, hyphens, and underscores"
        return 1
    fi
}

check_dependencies() {
    local missing=()
    local required_commands="curl jq"
    
    for cmd in $required_commands; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_error "Please install these commands and try again"
        return 1
    fi
    
    # Check extraction tools
    local has_tar=$(command -v tar >/dev/null 2>&1 && echo true || echo false)
    local has_unzip=$(command -v unzip >/dev/null 2>&1 && echo true || echo false)
    local has_bunzip2=$(command -v bunzip2 >/dev/null 2>&1 && echo true || echo false)
    
    if [[ "$has_tar" == false && "$has_unzip" == false && "$has_bunzip2" == false ]]; then
        log_error "No extraction tools found. Need at least one of: tar, unzip, bunzip2"
        return 1
    fi
}

# === GitHub API Functions ===
fetch_latest_version() {
    local repo_owner="$1"
    local repo_name="$2"
    local api_url="https://api.${GIT_SERVER}/repos/${repo_owner}/${repo_name}/releases/latest"
    
    log_info "Fetching latest version from ${repo_owner}/${repo_name}..."
    
    local response
    if ! response=$(curl --fail --silent --show-error --max-time 10 "$api_url" 2>&1); then
        log_error "Failed to fetch latest version:"
        log_error "$api_url"
        log_error "$response"
        return 1
    fi
    
    local version
    if ! version=$(echo "$response" | jq -r '.tag_name' 2>/dev/null); then
        log_error "Failed to parse version from API response"
        return 1
    fi
    
    if [[ "$version" == "null" || -z "$version" ]]; then
        log_error "No releases found for ${repo_owner}/${repo_name}"
        return 1
    fi
    
    # Remove 'v' prefix if present
    version="${version#v}"
    
    # Output ONLY the version to stdout
    echo "$version"
}

fetch_release_assets() {
    local repo_owner="$1"
    local repo_name="$2"
    local version="$3"
    
    log_debug "Fetching assets for ${repo_owner}/${repo_name} version ${version}"
    
    # Try both with and without 'v' prefix
    local tag_variants=("v${version}" "${version}")
    
    for tag in "${tag_variants[@]}"; do
        local api_url="https://api.${GIT_SERVER}/repos/${repo_owner}/${repo_name}/releases/tags/${tag}"
        log_debug "Trying to fetch assets for tag: $tag"
        
        local response
        if response=$(curl --fail --silent --show-error --max-time 10 "$api_url" 2>/dev/null); then
            log_debug "Successfully fetched release data for tag: $tag"
            
            # Check if assets exist first
            local assets_count
            if assets_count=$(echo "$response" | jq -r '.assets | length' 2>/dev/null); then
                log_debug "Found $assets_count assets for tag $tag"
                
                if [[ "$assets_count" -gt 0 ]]; then
                    local assets
                    if assets=$(echo "$response" | jq -r '.assets[] | "\(.name)|\(.browser_download_url)"' 2>/dev/null); then
                        if [[ -n "$assets" ]]; then
                            log_debug "Successfully parsed assets for tag $tag"
                            echo "$assets"
                            return 0
                        fi
                    fi
                fi
            fi
        else
            log_debug "Failed to fetch release for tag: $tag"
        fi
    done
    
    log_error "No assets found for version $version"
    log_error "This could be due to:"
    log_error "  - Release has no binary assets"
    log_error "  - Release is source-only"
    log_error "  - Version doesn't exist"
    log_error "Check available releases at: https://${GIT_SERVER}/${repo_owner}/${repo_name}/releases"
    return 1
}

# === Asset Filtering Functions ===
filter_assets_by_os() {
    local assets="$1"
    local target_os="$2"
    local os_patterns
    os_patterns=$(get_os_patterns "$target_os")
    
    log_debug "Filtering assets by OS patterns: $os_patterns"
    
    local filtered=""
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local asset_name="${line%|*}"
        local asset_url="${line#*|}"
        
        # Convert asset name to lowercase for case-insensitive matching
        local asset_name_lower=$(echo "$asset_name" | tr '[:upper:]' '[:lower:]')
        
        for pattern in $os_patterns; do
            local pattern_lower=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')
            if [[ "$asset_name_lower" == *"$pattern_lower"* ]]; then
                filtered+="$line"$'\n'
                log_debug "Matched OS pattern '$pattern' in asset: $asset_name"
                break
            fi
        done
    done <<< "$assets"
    
    echo "$filtered"
}

filter_assets_by_arch() {
    local assets="$1"
    local target_arch="$2"
    local arch_patterns
    arch_patterns=$(get_arch_patterns "$target_arch")
    
    log_debug "Filtering assets by ARCH patterns: $arch_patterns"
    
    local filtered=""
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local asset_name="${line%|*}"
        local asset_url="${line#*|}"
        
        # Convert asset name to lowercase for case-insensitive matching
        local asset_name_lower=$(echo "$asset_name" | tr '[:upper:]' '[:lower:]')
        
        for pattern in $arch_patterns; do
            local pattern_lower=$(echo "$pattern" | tr '[:upper:]' '[:lower:]')
            if [[ "$asset_name_lower" == *"$pattern_lower"* ]]; then
                filtered+="$line"$'\n'
                log_debug "Matched ARCH pattern '$pattern' in asset: $asset_name"
                break
            fi
        done
    done <<< "$assets"
    
    echo "$filtered"
}

select_best_asset() {
    local assets="$1"
    local best_asset=""
    local best_score=0
    
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        
        local asset_name="${line%|*}"
        local asset_url="${line#*|}"
        local score=0
        
        # Prefer certain file extensions
        case "$asset_name" in
            *.tar.gz) score=$((score + 10)) ;;
            *.tgz) score=$((score + 9)) ;;
            *.zip) score=$((score + 8)) ;;
            *.tar.bz2) score=$((score + 7)) ;;
            *.bz2) score=$((score + 6)) ;;
            *) score=$((score + 5)) ;;
        esac
        
        # Prefer shorter names (less likely to be source code)
        local name_length=${#asset_name}
        if [[ $name_length -lt 50 ]]; then
            score=$((score + 3))
        fi
        
        # Avoid source code patterns
        if [[ "$asset_name" != *"src"* && "$asset_name" != *"source"* ]]; then
            score=$((score + 2))
        fi
        
        log_debug "Asset: $asset_name, Score: $score"
        
        if [[ $score -gt $best_score ]]; then
            best_score=$score
            best_asset="$line"
        fi
    done <<< "$assets"
    
    echo "$best_asset"
}

show_available_assets() {
    local assets="$1"
    log_info "Available assets:"
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then continue; fi
        local asset_name="${line%|*}"
        echo "  - $asset_name"
    done <<< "$assets"
}

# === Download Functions ===
download_asset() {
    local asset_name="$1"
    local asset_url="$2"
    local temp_dir="$3"
    local file_path="$temp_dir/$asset_name"

    local max_retries=5
    local attempt=1
    local wait_time=2

    log_info "Downloading $asset_name..."

    while (( attempt <= max_retries )); do
        log_debug "Attempt $attempt of $max_retries: curl --fail --location --continue-at -"

        # Use --continue-at - to resume partial downloads if possible
        if curl --fail --location --silent --show-error \
                --connect-timeout 10 --max-time 300 \
                --retry 0 \
                --output "$file_path" --continue-at - \
                "$asset_url"; then

            # Ensure file is not empty
            if [[ -s "$file_path" ]]; then
                local file_size=""
                if command -v du >/dev/null 2>&1; then
                    file_size=$(du -h "$file_path" | cut -f1)
                fi
                log_success "Downloaded $asset_name ($file_size)"
                echo "$file_path"
                return 0
            else
                log_warn "Downloaded file is empty, retrying..."
            fi
        else
            log_warn "Download attempt $attempt failed"
        fi

        attempt=$((attempt + 1))
        log_info "Waiting $wait_time seconds before retry..."
        sleep $wait_time
        wait_time=$((wait_time * 2))  # exponential backoff
    done

    log_error "Failed to download $asset_name after $max_retries attempts"
    log_error "URL: $asset_url"
    return 1
}

# === Extraction Functions ===
extract_archive() {
    local file_path="$1"
    local extract_dir="$2"
    local file_name=$(basename "$file_path")
    
    cd "$extract_dir"
    
    case "$file_name" in
        *.tar.gz|*.tgz)
            log_info "Extracting tar.gz archive..."
            if ! tar -xzf "$file_path"; then
                log_error "Failed to extract tar.gz archive"
                return 1
            fi
            ;;
        *.tar.bz2)
            log_info "Extracting tar.bz2 archive..."
            if ! tar -xjf "$file_path"; then
                log_error "Failed to extract tar.bz2 archive"
                return 1
            fi
            ;;
        *.zip)
            log_info "Extracting zip archive..."
            if ! unzip -q "$file_path"; then
                log_error "Failed to extract zip archive"
                return 1
            fi
            ;;
        *.bz2)
            log_info "Extracting bz2 archive..."
            if ! bunzip2 -k "$file_path"; then
                log_error "Failed to extract bz2 archive"
                return 1
            fi
            # Rename decompressed file to binary name
            local decompressed="${file_path%.bz2}"
            if [[ -f "$decompressed" ]]; then
                mv "$decompressed" "$BINARY_NAME"
            fi
            ;;
        *)
            log_info "Treating as uncompressed binary..."
            cp "$file_path" "$BINARY_NAME"
            ;;
    esac
}

# === Binary Location Functions ===
find_binary() {
    local search_dir="$1"
    local binary_name="$2"
    local extracted_dir="$3"

    cd "$search_dir"

    if [[ -n "$extracted_dir" ]]; then
        # Look in specific directory
        if [[ -d "$extracted_dir" ]]; then
            if [[ -f "$extracted_dir/$binary_name" ]]; then
                echo "$extracted_dir/$binary_name"
                return 0
            fi
        fi
        log_error "Binary '$binary_name' not found in specified directory '$extracted_dir'"
        log_error "Available contents in '$extracted_dir':"
        if [[ -d "$extracted_dir" ]]; then
            ls -la "$extracted_dir/"
        fi
        return 1
    else
        # Search strategy: prioritize likely locations

        # 1. Check current directory first
        if [[ -f "$binary_name" ]]; then
            echo "$binary_name"
            return 0
        fi

        # 2. Look for executable files with the right name (most likely to be the binary)
        log_debug "Searching for executable files named '$binary_name'..."
        local found
        found=$(find . -name "$binary_name" -type f -executable 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            log_debug "Found executable: $found"
            echo "$found"
            return 0
        fi

        # 3. Look for files with the right name, but prioritize by location
        # Prefer files in root or bin-like directories, avoid completion/doc directories
        log_debug "Searching for files named '$binary_name' in preferred locations..."
        local candidates
        candidates=$(find . -name "$binary_name" -type f 2>/dev/null)

        if [[ -n "$candidates" ]]; then
            log_debug "Found candidates: $candidates"

            # Score candidates based on location (higher score = better)
            local best_candidate=""
            local best_score=-1

            while IFS= read -r candidate; do
                if [[ -z "$candidate" ]]; then continue; fi

                local score=0
                local dir_path=$(dirname "$candidate")

                # Prefer root directory
                if [[ "$dir_path" == "." ]]; then
                    score=$((score + 100))
                fi

                # Prefer bin-like directories
                if [[ "$dir_path" == *"bin"* ]]; then
                    score=$((score + 50))
                fi

                # Avoid completion directories
                if [[ "$dir_path" == *"completion"* || "$dir_path" == *"bash_completion"* ]]; then
                    score=$((score - 50))
                fi

                # Avoid documentation directories
                if [[ "$dir_path" == *"doc"* || "$dir_path" == *"man"* ]]; then
                    score=$((score - 30))
                fi

                # Avoid config/example directories
                if [[ "$dir_path" == *"config"* || "$dir_path" == *"example"* || "$dir_path" == *"sample"* ]]; then
                    score=$((score - 30))
                fi

                # Prefer files that are executable
                if [[ -x "$candidate" ]]; then
                    score=$((score + 20))
                fi

                # Prefer larger files (binaries are usually larger than scripts)
                local file_size
                if file_size=$(stat -c%s "$candidate" 2>/dev/null); then
                    if [[ $file_size -gt 1000000 ]]; then  # > 1MB
                        score=$((score + 10))
                    elif [[ $file_size -gt 100000 ]]; then  # > 100KB
                        score=$((score + 5))
                    fi
                fi

                log_debug "Candidate: $candidate, Score: $score"

                if [[ $score -gt $best_score ]]; then
                    best_score=$score
                    best_candidate=$candidate
                fi
            done <<< "$candidates"

            if [[ -n "$best_candidate" ]]; then
                log_debug "Selected best candidate: $best_candidate (score: $best_score)"
                echo "$best_candidate"
                return 0
            fi
        fi

        # 4. Last resort: look for any file with the binary name
        log_debug "Last resort: searching for any file named '$binary_name'..."
        found=$(find . -name "$binary_name" -type f 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            log_debug "Found file: $found"
            echo "$found"
            return 0
        fi
    fi

    log_error "Binary '$binary_name' not found in extracted files"
    log_error "Available files and directories:"
    find . -type f -name "*" | head -20
    log_error "Available directories:"
    find . -type d -name "*" | head -10
    return 1
}

# === Installation Functions ===
detect_privilege_method() {
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root"
        echo "root"
        return 0
    fi
    
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        log_info "Using sudo (passwordless)"
        echo "sudo"
        return 0
    fi
    
    if command -v sudo >/dev/null 2>&1 && sudo -v 2>/dev/null; then
        log_info "Using sudo (with password)"
        echo "sudo"
        return 0
    fi
    
    if command -v doas >/dev/null 2>&1 && doas true 2>/dev/null; then
        log_info "Using doas"
        echo "doas"
        return 0
    fi
    
    log_warn "No privilege escalation available"
    echo "none"
    return 1
}

install_binary() {
    local binary_path="$1"
    local install_dir="$2"
    local binary_name="$3"
    local privilege_method
    
    # Make binary executable
    chmod +x "$binary_path"
    
    # Try to create the install directory if it doesn't exist
    if [[ ! -d "$install_dir" ]]; then
        log_info "Creating install directory: $install_dir"
        if mkdir -p "$install_dir" 2>/dev/null; then
            log_debug "Directory created without privilege escalation"
        else
            privilege_method=$(detect_privilege_method)
            case "$privilege_method" in
                sudo)
                    sudo mkdir -p "$install_dir"
                    ;;
                doas)
                    doas mkdir -p "$install_dir"
                    ;;
                root)
                    mkdir -p "$install_dir"
                    ;;
                *)
                    log_error "Cannot create directory $install_dir"
                    return 1
                    ;;
            esac
        fi
    fi
    
    # Install binary
    local target_path="$install_dir/$binary_name"
    
    # if the user has write permission, just install directly
    if [[ -w "$install_dir" ]]; then
        log_debug "user has write permission to $install_dir"
        log_info "installing $binary_name to $install_dir..."
        cp "$binary_path" "$install_dir/$binary_name"
    else
        privilege_method=$(detect_privilege_method)
        log_info "installing $binary_name to $install_dir..."
        case "$privilege_method" in
            sudo)
                sudo cp "$binary_path" "$target_path"
                ;;
            doas)
                doas cp "$binary_path" "$target_path"
                ;;
            root)
                cp "$binary_path" "$target_path"
                ;;
            *)
                log_error "cannot install to $install_dir (permission denied)"
                return 1
                ;;
        esac
    fi
    
    log_success "Installed $binary_name to $target_path"
    return 0
}

install_to_user_directory() {
    local binary_path="$1"
    local binary_name="$2"
    local user_bin="$HOME/.local/bin"
    
    mkdir -p "$user_bin"
    chmod +x "$binary_path"
    cp "$binary_path" "$user_bin/$binary_name"
    
    log_success "Installed $binary_name to $user_bin"
    
    # Check if in PATH
    if [[ ":$PATH:" != *":$user_bin:"* ]]; then
        log_warn "Note: $user_bin is not in your PATH"
        log_warn "Add this to your shell profile: export PATH=\"\$PATH:$user_bin\""
    fi
}

# === Verification Functions ===
verify_installation() {
    local binary_name="$1"
    
    if ! command -v "$binary_name" >/dev/null 2>&1; then
        log_warn "$binary_name is not in PATH"
        return 1
    fi
    
    # Try to get version
    local version="unknown"
    for version_cmd in "--version" "-version" "version" "-V" "-v"; do
        if version_output=$($binary_name $version_cmd 2>/dev/null); then
            version=$(echo "$version_output" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "installed")
            break
        fi
    done
    
    log_success "$binary_name version $version is ready to use"
    
    # Show location
    local binary_location
    binary_location=$(command -v "$binary_name" 2>/dev/null)
    if [[ -n "$binary_location" ]]; then
        log_info "Location: $binary_location"
    fi
    
    return 0
}

# === Main Functions ===
show_help() {
    cat << EOF
Usage: $0 <owner/repo> [OPTIONS]

ARGUMENTS:
  <owner/repo>                GitHub repository (e.g., grafana/k6)

OPTIONS:
  --binary <name>             Binary name (default: repository name)
  --version <ver>             Install specific version (default: latest)
  --os <os>                   Override OS detection (linux, darwin, windows)
  --arch <arch>               Override architecture detection (amd64, arm64, etc.)
  --extracted-dir <dir>       Directory in archive containing binary
  --install-dir <path>        Install directory (default: /usr/local/bin)
  --pattern <string>          Substring required in asset name (e.g., 'extended')
  --git-server <server>       Git server (default: github.com)
  --force                     Force reinstallation
  --quiet                     Suppress non-error output
  --debug                     Enable debug output
  --help                      Show this help

EXAMPLES:
  # Install latest k6
  $0 grafana/k6

  # Install specific version
  $0 grafana/k6 --version 0.47.0

  # Install with custom binary name
  $0 cli/cli --binary gh

  # Install for different architecture
  $0 grafana/k6 --arch arm64

  # Install to custom directory
  $0 grafana/k6 --install-dir ~/bin

EOF
}

parse_arguments() {
    # Check if first argument looks like a repository (contains a slash)
    if [[ $# -gt 0 && "$1" == *"/"* && "$1" != --* ]]; then
        local repo="$1"
        REPO_OWNER="${repo%/*}"
        REPO_NAME="${repo#*/}"
        shift
    fi
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --binary)
                BINARY_NAME="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --os)
                OVERRIDE_OS="$2"
                shift 2
                ;;
            --arch)
                OVERRIDE_ARCH="$2"
                shift 2
                ;;
            --extracted-dir)
                EXTRACTED_DIR="$2"
                shift 2
                ;;
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --git-server)
                GIT_SERVER="$2"
                shift 2
                ;;
            --pattern)
                PATTERN="$2"
                shift 2
                ;;
            --force)
                FORCE_INSTALL=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --debug)
                DEBUG=1
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    
    # Validate required arguments
    if [[ -z "$REPO_OWNER" || -z "$REPO_NAME" ]]; then
        log_error "Repository is required as first argument"
        log_error "Usage: $0 <owner/repo> [OPTIONS]"
        log_error "Run '$0 --help' for usage information"
        exit 1
    fi
    
    validate_repo_format "$REPO_OWNER/$REPO_NAME"
    
    # Set default binary name
    if [[ -z "$BINARY_NAME" ]]; then
        BINARY_NAME="$REPO_NAME"
        log_info "Binary name not specified, using repository name: $BINARY_NAME"
    fi
    
    validate_binary_name "$BINARY_NAME"
    check_dependencies
    
    # Detect system info
    local target_os="${OVERRIDE_OS:-$(detect_os)}"
    local target_arch="${OVERRIDE_ARCH:-$(detect_arch)}"
    
    log_info "Target system: $target_os/$target_arch"
    
    # Get version
    if [[ -z "$VERSION" ]]; then
        log_info "Getting latest version..."
        VERSION=$(fetch_latest_version "$REPO_OWNER" "$REPO_NAME")
        if [[ $? -ne 0 ]]; then
            exit 1
        fi
    fi
    
    log_info "Target version: $VERSION"
    
    # Check if already installed
    if command -v "$BINARY_NAME" >/dev/null 2>&1 && [[ "$FORCE_INSTALL" != true ]]; then
        log_warn "$BINARY_NAME is already installed"
        log_info "Use --force to reinstall"
        exit 0
    fi
    
    # Fetch assets
    log_info "Fetching release assets..."
    local all_assets
    all_assets=$(fetch_release_assets "$REPO_OWNER" "$REPO_NAME" "$VERSION")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Filter assets
    local os_filtered
    os_filtered=$(filter_assets_by_os "$all_assets" "$target_os")
    if [[ -z "$os_filtered" ]]; then
        log_error "No assets found for OS: $target_os"
        show_available_assets "$all_assets"
        exit 1
    fi
    
    local arch_filtered
    arch_filtered=$(filter_assets_by_arch "$os_filtered" "$target_arch")
    if [[ -n "$PATTERN" ]]; then
        log_info "Filtering assets with pattern: '$PATTERN'"
        local pattern_filtered=""
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            asset_name="${line%|*}"
            if [[ "$asset_name" == *"$PATTERN"* ]]; then
                pattern_filtered+="$line"$'\n'
            fi
        done <<< "$arch_filtered"

        if [[ -z "$pattern_filtered" ]]; then
            log_error "No assets matched the pattern '$PATTERN'"
            show_available_assets "$arch_filtered"
            exit 1
        fi

        arch_filtered="$pattern_filtered"
    fi
    if [[ -z "$arch_filtered" ]]; then
        log_error "No assets found for architecture: $target_arch"
        log_error "Available assets for $target_os:"
        show_available_assets "$os_filtered"
        exit 1
    fi
    
    # Select best asset
    local best_asset
    best_asset=$(select_best_asset "$arch_filtered")
    if [[ -z "$best_asset" ]]; then
        log_error "No suitable asset found"
        show_available_assets "$arch_filtered"
        exit 1
    fi
    
    local asset_name="${best_asset%|*}"
    local asset_url="${best_asset#*|}"
    
    log_info "Selected asset: $asset_name"
    
    # Create temporary directory
    # local temp_dir
    temp_dir=$(mktemp -d)
    cleanup() {
        rm -rf "$temp_dir"
    }
    trap cleanup EXIT
    
    # Download asset
    local downloaded_file
    downloaded_file=$(download_asset "$asset_name" "$asset_url" "$temp_dir")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Extract archive
    extract_archive "$downloaded_file" "$temp_dir"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    # Find binary
    local binary_path
    binary_path=$(find_binary "$temp_dir" "$BINARY_NAME" "$EXTRACTED_DIR")
    if [[ $? -ne 0 ]]; then
        exit 1
    fi
    
    log_info "Found binary: $binary_path"
    
    # Install binary
    if install_binary "$binary_path" "$INSTALL_DIR" "$BINARY_NAME"; then
        log_success "Installation completed successfully"
    elif install_to_user_directory "$binary_path" "$BINARY_NAME"; then
        log_success "Installation completed successfully (user directory)"
    else
        log_error "Installation failed"
        exit 1
    fi
    
    # Verify installation
    verify_installation "$BINARY_NAME"
}

# Run main function
main "$@"

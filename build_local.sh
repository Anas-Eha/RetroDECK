#!/bin/bash

# Simple Local RetroDECK Builder
# Usage: ./build_local.sh [options]
# Options:
#   --clean       Clean build directories before building
#   --no-fetch    Skip fetching components (use existing ones)
#   --help, -h    Show help

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default locations
COMPONENTS_DIR="$SCRIPT_DIR/components"
BUILD_DIR="$SCRIPT_DIR/retrodeck-flatpak"
REPO_DIR="$SCRIPT_DIR/retrodeck-repo"
OUT_DIR="$SCRIPT_DIR/out"
MANIFEST="$SCRIPT_DIR/net.retrodeck.retrodeck.yml"

# Flags
CLEAN_BUILD=false
SKIP_FETCH=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --clean)
            CLEAN_BUILD=true
            shift
            ;;
        --no-fetch)
            SKIP_FETCH=true
            shift
            ;;
        --help|-h)
            echo "Simple Local RetroDECK Builder"
            echo ""
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --clean       Clean build directories before building"
            echo "  --no-fetch    Skip fetching components (use existing ones)"
            echo "  --help, -h    Show this help"
            echo ""
            echo "This script will:"
            echo "  1. Check and install dependencies (flatpak, flatpak-builder, git, curl)"
            echo "  2. Download emulator components from GitHub"
            echo "  3. Build RetroDECK flatpak"
            echo "  4. Create installable .flatpak bundle"
            echo ""
            exit 0
            ;;
    esac
done

# Helper functions
print_section() {
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Check if running on supported distro
check_distro() {
    if command -v apt-get &>/dev/null; then
        DISTRO="debian"
    elif command -v pacman &>/dev/null; then
        DISTRO="arch"
    elif command -v dnf &>/dev/null; then
        DISTRO="fedora"
    else
        print_error "Unknown distribution. This script supports Debian/Ubuntu, Arch, and Fedora."
        exit 1
    fi
}

# Install a package
install_package() {
    local pkg="$1"
    print_warning "Installing $pkg..."
    
    case "$DISTRO" in
        debian)
            sudo apt-get update
            sudo apt-get install -y "$pkg"
            ;;
        arch)
            sudo pacman -S --noconfirm "$pkg"
            ;;
        fedora)
            sudo dnf install -y "$pkg"
            ;;
    esac
}

# Check and install dependencies
check_dependencies() {
    print_section "Checking Dependencies"
    
    local deps_missing=false
    
    # Check flatpak
    if ! command -v flatpak &>/dev/null; then
        print_warning "flatpak not found"
        install_package "flatpak"
    else
        print_success "flatpak installed"
    fi
    
    # Check flatpak-builder
    if ! command -v flatpak-builder &>/dev/null; then
        print_warning "flatpak-builder not found"
        install_package "flatpak-builder"
    else
        print_success "flatpak-builder installed"
    fi
    
    # Check git
    if ! command -v git &>/dev/null; then
        print_warning "git not found"
        install_package "git"
    else
        print_success "git installed"
    fi
    
    # Check curl
    if ! command -v curl &>/dev/null; then
        print_warning "curl not found"
        install_package "curl"
    else
        print_success "curl installed"
    fi
    
    # Check jq (needed for component fetching)
    if ! command -v jq &>/dev/null; then
        print_warning "jq not found"
        install_package "jq"
    else
        print_success "jq installed"
    fi
    
    # Setup flathub if not present
    if ! flatpak remotes | grep -q flathub; then
        print_warning "Adding flathub remote..."
        flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
        print_success "flathub added"
    else
        print_success "flathub configured"
    fi
}

# Clean build directories
clean_build() {
    print_section "Cleaning Build Directories"
    
    if [[ -d "$BUILD_DIR" ]]; then
        print_warning "Removing $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi
    
    if [[ -d "$REPO_DIR" ]]; then
        print_warning "Removing $REPO_DIR"
        rm -rf "$REPO_DIR"
    fi
    
    if [[ -d "$OUT_DIR" ]]; then
        print_warning "Removing $OUT_DIR"
        rm -rf "$OUT_DIR"
    fi
    
    if [[ -d "$SCRIPT_DIR/.flatpak-builder" ]]; then
        print_warning "Removing .flatpak-builder cache"
        rm -rf "$SCRIPT_DIR/.flatpak-builder"
    fi
    
    print_success "Build directories cleaned"
}

# Create minimal fake components for testing
create_fake_components() {
    print_warning "Creating minimal fake components for testing..."
    
    mkdir -p "$COMPONENTS_DIR"
    
    # List of required components (minimal set for testing)
    local components=(
        "es-de"
        "steam-rom-manager"
        "retroarch"
    )
    
    for component in "${components[@]}"; do
        if [[ ! -f "$COMPONENTS_DIR/${component}.tar.gz" ]]; then
            print_warning "Creating fake component: $component"
            
            # Create minimal component structure
            local tmp_dir=$(mktemp -d)
            mkdir -p "$tmp_dir/$component"
            
            # Create minimal component_functions.sh
            cat > "$tmp_dir/$component/component_functions.sh" << EOF
#!/bin/bash
# Minimal stub for $component

${component}_prepare() {
    log i "Preparing $component (stub)"
}

${component}_reset() {
    log i "Resetting $component (stub)"
}
EOF
            
            # Create component manifest
            cat > "$tmp_dir/$component/component_manifest.json" << EOF
{
  "name": "$component",
  "friendly_name": "$component",
  "description": "Test component stub"
}
EOF
            
            # Create the tarball
            tar -czf "$COMPONENTS_DIR/${component}.tar.gz" -C "$tmp_dir" "$component"
            rm -rf "$tmp_dir"
        fi
    done
    
    print_success "Fake components created"
}

# Fetch components
fetch_components() {
    print_section "Fetching Components"
    
    # Create components directory
    mkdir -p "$COMPONENTS_DIR"
    
    if [[ "$SKIP_FETCH" == true ]]; then
        print_warning "Skipping component fetch (--no-fetch)"
        if [[ ! -d "$COMPONENTS_DIR" ]] || [[ -z "$(ls -A "$COMPONENTS_DIR"/*.tar.gz 2>/dev/null)" ]]; then
            print_warning "No components found, creating fake ones for testing..."
            create_fake_components
        fi
        print_success "Using existing components"
        return
    fi
    
    # Check if fetch script exists
    if [[ ! -f "$SCRIPT_DIR/automation_tools/fetch_components.sh" ]]; then
        print_error "fetch_components.sh not found"
        create_fake_components
        return
    fi
    
    # Run fetch script
    print_warning "Downloading components (this may take a while)..."
    print_warning "Select option 1 (Cooker) or 2 (Main) to download real components"
    print_warning "Select option 4 (Provided) to use fake components for testing"
    
    "$SCRIPT_DIR/automation_tools/fetch_components.sh" "$COMPONENTS_DIR"
    
    if [[ $? -ne 0 ]]; then
        print_warning "Failed to fetch components, creating fake ones..."
        create_fake_components
    fi
    
    # Check if we have components now
    if [[ -z "$(ls -A "$COMPONENTS_DIR"/*.tar.gz 2>/dev/null)" ]]; then
        print_warning "No components downloaded, creating fake ones..."
        create_fake_components
    fi
    
    print_success "Components ready"
}

# Build RetroDECK
build_retrodeck() {
    print_section "Building RetroDECK"
    
    # Check manifest exists
    if [[ ! -f "$MANIFEST" ]]; then
        print_error "Manifest not found: $MANIFEST"
        exit 1
    fi
    
    # Create output directory
    mkdir -p "$OUT_DIR"
    mkdir -p "$REPO_DIR"
    mkdir -p "$BUILD_DIR"
    
    # Determine version from metainfo
    local version
    if command -v xmlstarlet &>/dev/null; then
        version=$(xmlstarlet sel -t -v "/component/releases/release[1]/@version" "$SCRIPT_DIR/net.retrodeck.retrodeck.metainfo.xml" 2>/dev/null || echo "unknown")
    else
        version="local-build"
    fi
    
    # Create version file (required by build process)
    echo "$version" > "$SCRIPT_DIR/version"
    print_success "Version set to: $version"
    
    # Initialize git if not present (some build steps may need it)
    if [[ ! -d "$SCRIPT_DIR/.git" ]]; then
        print_warning "No git repository found, initializing temporary one..."
        git init "$SCRIPT_DIR" --quiet
        git -C "$SCRIPT_DIR" add -A --quiet 2>/dev/null || true
        git -C "$SCRIPT_DIR" commit -m "Local build" --quiet 2>/dev/null || true
    fi
    
    echo "Building RetroDECK $version"
    echo "This will take 30-60 minutes on first build..."
    echo ""
    
    # Build command
    local build_cmd="flatpak-builder --user --force-clean \
        --install-deps-from=flathub \
        --repo=\"$REPO_DIR\" \
        \"$BUILD_DIR\" \"$MANIFEST\""
    
    echo "Running: $build_cmd"
    echo ""
    
    if eval $build_cmd; then
        print_success "Build completed"
    else
        print_error "Build failed"
        exit 1
    fi
}

# Create bundle
create_bundle() {
    print_section "Creating Flatpak Bundle"
    
    local bundle_name="RetroDECK.flatpak"
    
    print_warning "Creating $bundle_name..."
    
    if flatpak build-bundle "$REPO_DIR" "$OUT_DIR/$bundle_name" net.retrodeck.retrodeck; then
        print_success "Bundle created: $OUT_DIR/$bundle_name"
        
        # Show file size
        ls -lh "$OUT_DIR/$bundle_name"
        
        # Create SHA256 checksum
        sha256sum "$OUT_DIR/$bundle_name" > "$OUT_DIR/$bundle_name.sha256"
        print_success "Checksum created: $OUT_DIR/$bundle_name.sha256"
    else
        print_error "Failed to create bundle"
        exit 1
    fi
}

# Install and test
install_and_test() {
    print_section "Install and Test"
    
    echo "Build complete!"
    echo ""
    echo -e "${GREEN}Bundle location:${NC} $OUT_DIR/RetroDECK.flatpak"
    echo ""
    echo "To install:"
    echo "  flatpak install --user $OUT_DIR/RetroDECK.flatpak"
    echo ""
    echo "To run:"
    echo "  flatpak run net.retrodeck.retrodeck"
    echo ""
    echo "To run configurator:"
    echo "  flatpak run net.retrodeck.retrodeck --configurator"
    echo ""
    
    read -rp "Do you want to install now? [y/N] " install_now
    if [[ "$install_now" =~ ^[Yy]$ ]]; then
        print_warning "Installing RetroDECK..."
        
        # Remove existing if present
        if flatpak list | grep -q net.retrodeck.retrodeck; then
            print_warning "Removing existing RetroDECK..."
            flatpak uninstall --user net.retrodeck.retrodeck -y || true
        fi
        
        if flatpak install --user "$OUT_DIR/RetroDECK.flatpak" -y; then
            print_success "RetroDECK installed!"
            
            read -rp "Start RetroDECK now? [y/N] " start_now
            if [[ "$start_now" =~ ^[Yy]$ ]]; then
                flatpak run net.retrodeck.retrodeck --configurator
            fi
        else
            print_error "Installation failed"
        fi
    fi
}

# Main execution
main() {
    echo "================================"
    echo "  RetroDECK Local Builder"
    echo "================================"
    echo ""
    
    # Check distro
    check_distro
    print_success "Detected distribution: $DISTRO"
    
    # Clean if requested
    if [[ "$CLEAN_BUILD" == true ]]; then
        clean_build
    fi
    
    # Check dependencies
    check_dependencies
    
    # Fetch components
    fetch_components
    
    # Build
    build_retrodeck
    
    # Create bundle
    create_bundle
    
    # Install and test
    install_and_test
    
    print_section "Done!"
    echo "Your RetroDECK flatpak is ready at:"
    echo "  $OUT_DIR/RetroDECK.flatpak"
    echo ""
    echo "To share with others, copy this file."
    echo "They can install with: flatpak install --user RetroDECK.flatpak"
}

# Run main
main "$@"
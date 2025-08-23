#!/bin/bash
# extractaudio-docker.sh - Docker wrapper for extractaudio tool with full codec support
# This script makes the Docker image behave like a local binary

set -e

# Configuration
DOCKER_IMAGE="rtpproxy-extractaudio:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if Docker is available
check_docker() {
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed or not in PATH"
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running or you don't have permission to use Docker"
        exit 1
    fi
}

# Function to build Docker image if it doesn't exist
build_image_if_needed() {
    if ! docker image inspect "$DOCKER_IMAGE" &> /dev/null; then
        log_info "Docker image $DOCKER_IMAGE not found. Building it now..."
        log_info "This may take a few minutes on first run..."
        
        if [ ! -f "$SCRIPT_DIR/Dockerfile.extractaudio" ]; then
            log_error "Dockerfile.extractaudio not found in $SCRIPT_DIR"
            exit 1
        fi
        
        cd "$SCRIPT_DIR"
        if docker build -f Dockerfile.extractaudio -t "$DOCKER_IMAGE" . ; then
            log_info "Docker image built successfully!"
        else
            log_error "Failed to build Docker image"
            exit 1
        fi
    else
        log_info "Using existing Docker image: $DOCKER_IMAGE"
    fi
}

# Function to show usage information
show_usage() {
    echo "extractaudio-docker.sh - Enhanced Docker wrapper for extractaudio"
    echo ""
    echo "Usage: $0 [options] <arguments>"
    echo ""
    echo "This script wraps the extractaudio tool in a Docker container with full"
    echo "codec support (GSM, G.722, G.729, Opus), Linux SLL auto-conversion,"
    echo "and true stereo extraction from dual RTP streams."
    echo ""
    echo "Special options:"
    echo "  --build-image      Force rebuild of Docker image"
    echo "  --show-info        Show Docker image information"
    echo "  --shell            Open interactive shell in container"
    echo "  --direct           Skip Linux SLL conversion (use original extractaudio)"
    echo "  --true-stereo      Split RTP streams by SSRC for true stereo (default with -s)"
    echo "  --mixed-stereo     Use single stream mixed to stereo (legacy mode)"
    echo ""
    echo "Enhanced features:"
    echo "  • Automatically detects Linux SLL (cooked) PCAP captures"
    echo "  • Splits RTP streams by SSRC for true stereo extraction"
    echo "  • Uses extractaudio -A/-B options for separate stereo channels"
    echo "  • Full codec support with automatic detection"
    echo "  • Intelligent fallback from true stereo to mixed stereo when needed"
    echo ""
    echo "All other arguments are passed to extractaudio."
    echo ""
    echo "Examples:"
    echo "  $0 -s -F wav input.pcap stereo.wav       # True stereo from dual RTP streams"
    echo "  $0 --mixed-stereo -s -F wav input.pcap out.wav  # Mixed stereo (legacy)"
    echo "  $0 -F wav input.pcap mono.wav            # Extract mono audio"
    echo "  $0 --direct -F wav input output          # Skip auto-conversion"
    echo "  $0 --build-image                         # Rebuild Docker image"
    echo ""
    echo "Note: File paths should be relative to current directory or absolute paths."
}

# Function to show Docker image info
show_info() {
    log_info "Docker image information:"
    if docker image inspect "$DOCKER_IMAGE" &> /dev/null; then
        docker image inspect "$DOCKER_IMAGE" --format '
Image: {{.RepoTags}}
Created: {{.Created}}
Size: {{.Size}} bytes
Architecture: {{.Architecture}}
OS: {{.Os}}
'
        log_info "Testing codec support:"
        docker run --rm "$DOCKER_IMAGE" 2>&1 | grep -A2 -B2 "CODEC:" || true
    else
        log_warn "Image $DOCKER_IMAGE not found locally"
    fi
}

# Function to run interactive shell
run_shell() {
    log_info "Opening interactive shell in extractaudio container..."
    docker run --rm -it \
        -v "$(pwd):/data" \
        --workdir /data \
        --user root \
        --entrypoint /bin/bash \
        "$DOCKER_IMAGE"
}

# Function to convert Windows paths to Unix format (for WSL/Git Bash compatibility)
convert_path() {
    local path="$1"
    # Convert Windows drive letters (C:\ -> /c/)
    if [[ "$path" =~ ^[A-Za-z]:\\ ]]; then
        path=$(echo "$path" | sed 's|^\([A-Za-z]\):\\|/\L\1/|' | sed 's|\\|/|g')
    fi
    echo "$path"
}

# Function to run extractaudio in Docker
run_extractaudio() {
    local args=("$@")
    local docker_args=()
    local mount_dirs=()
    
    # Find all potential file/directory paths in arguments and prepare mount points
    for arg in "${args[@]}"; do
        # Skip options (arguments starting with -)
        if [[ "$arg" == -* ]]; then
            continue
        fi
        
        # Convert path format if needed
        arg=$(convert_path "$arg")
        
        # Check if argument looks like a file path
        if [[ "$arg" == */* ]] || [[ -e "$arg" ]]; then
            # Get absolute directory path
            if [[ "$arg" == /* ]]; then
                # Absolute path
                dir_path="$(dirname "$arg")"
            else
                # Relative path
                dir_path="$(cd "$(dirname "$arg")" 2>/dev/null && pwd)" || dir_path="$(pwd)"
            fi
            
            # Add to mount directories (avoid duplicates)
            if [[ ! " ${mount_dirs[@]} " =~ " ${dir_path} " ]]; then
                mount_dirs+=("$dir_path")
            fi
        fi
    done
    
    # If no specific directories found, mount current directory
    if [ ${#mount_dirs[@]} -eq 0 ]; then
        mount_dirs=("$(pwd)")
    fi
    
    # Build Docker volume mount arguments
    for dir in "${mount_dirs[@]}"; do
        docker_args+=("-v" "${dir}:${dir}")
    done
    
    # Add current directory mount and working directory
    docker_args+=("-v" "$(pwd):/data")
    docker_args+=("--workdir" "/data")
    
    # Run the container with current user to avoid permission issues
    # Use wrapper by default for Linux SLL auto-conversion, unless --direct flag is used
    if [[ " ${args[@]} " =~ " --direct " ]]; then
        # Remove --direct flag and run extractaudio directly
        filtered_args=()
        for arg in "${args[@]}"; do
            [[ "$arg" != "--direct" ]] && filtered_args+=("$arg")
        done
        docker run --rm --user "$(id -u):$(id -g)" "${docker_args[@]}" "$DOCKER_IMAGE" "/usr/local/bin/extractaudio ${filtered_args[*]}"
    else
        # Use wrapper script for automatic Linux SLL conversion
        docker run --rm --user "$(id -u):$(id -g)" "${docker_args[@]}" "$DOCKER_IMAGE" "/usr/local/bin/extractaudio-wrapper.sh ${args[*]}"
    fi
}

# Main script execution
main() {
    # Parse special arguments first
    case "${1:-}" in
        "--help"|"-h")
            show_usage
            exit 0
            ;;
        "--build-image")
            check_docker
            log_info "Force rebuilding Docker image..."
            docker image rm "$DOCKER_IMAGE" 2>/dev/null || true
            build_image_if_needed
            exit 0
            ;;
        "--show-info")
            check_docker
            show_info
            exit 0
            ;;
        "--shell")
            check_docker
            build_image_if_needed
            run_shell
            exit 0
            ;;
    esac
    
    # Normal extractaudio execution
    check_docker
    build_image_if_needed
    run_extractaudio "$@"
}

# Execute main function with all arguments
main "$@"

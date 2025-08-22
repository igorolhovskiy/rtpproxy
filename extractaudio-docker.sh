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
    echo "extractaudio-docker.sh - Docker wrapper for extractaudio with full codec support"
    echo ""
    echo "Usage: $0 [options] <arguments>"
    echo ""
    echo "This script wraps the extractaudio tool in a Docker container with full"
    echo "codec support (GSM, G.722, G.729) and the --force-codec feature."
    echo ""
    echo "Special options:"
    echo "  --build-image    Force rebuild of Docker image"
    echo "  --show-info      Show Docker image information"
    echo "  --shell          Open interactive shell in container"
    echo ""
    echo "All other arguments are passed directly to extractaudio."
    echo ""
    echo "Examples:"
    echo "  $0                                    # Show extractaudio help"
    echo "  $0 --force-codec g729 input output   # Force G.729 decoding"
    echo "  $0 -F wav input output               # Extract as WAV file"
    echo "  $0 --build-image                     # Rebuild Docker image"
    echo ""
    echo "Note: All file paths should be relative to current directory or absolute paths"
    echo "      that will be mounted into the container."
}

# Function to show Docker image info
show_info() {
    log_info "Docker image information:"
    if docker image inspect "$DOCKER_IMAGE" &> /dev/null; then
        docker image inspect "$DOCKER_IMAGE" --format '
Image: {{.RepoTags}}
Created: {{.Created}}
Size: {{.Size}} bytes ({{printf "%.1f" (div (mul .Size 1.0) 1048576)}} MB)
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
    
    # Run the container
    docker run --rm "${docker_args[@]}" "$DOCKER_IMAGE" "${args[@]}"
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
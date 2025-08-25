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
    echo "============================================================================"
    echo ""
    echo "SYNOPSIS"
    echo "    $0 [wrapper options] [extractaudio options] rdir outfile [link1] ... [linkN]"
    echo "    $0 [wrapper options] [extractaudio options] [-A answer_cap] [-B originate_cap] outfile [link1] ... [linkN]"
    echo "    $0 [wrapper options] -S [-A answer_cap] [-B originate_cap]"
    echo "    $0 [wrapper options] -S rdir"
    echo ""
    echo "DESCRIPTION"
    echo "    Enhanced Docker wrapper for extractaudio utility that automatically handles:"
    echo "    - Linux SLL format PCAP files (auto-conversion to Ethernet)"
    echo "    - True stereo extraction from dual RTP streams (SSRC-based splitting)"
    echo "    - Multiple input formats and codecs with full libsndfile support"
    echo "    - SRTP encrypted streams (with proper keys)"
    echo "    - Automatic Docker image building and management"
    echo ""
    echo "DOCKER WRAPPER OPTIONS"
    echo "    --build-image      Force rebuild of Docker image"
    echo "    --show-info        Show Docker image information and codec support"
    echo "    --shell            Open interactive shell in container"
    echo "    --direct           Skip Linux SLL conversion (use original extractaudio)"
    echo "    --true-stereo      Split RTP streams by SSRC for true stereo (default with -s)"
    echo "    --mixed-stereo     Use single stream mixed to stereo (legacy mode)"
    echo ""
    echo "EXTRACTAUDIO OPTIONS"
    echo "    -d                 Delete input files after processing"
    echo "    -s                 Enable stereo output (2 channels)"
    echo "    -i                 Set idle priority for processing"
    echo "    -n                 Disable synchronization (nosync mode)"
    echo "    -e                 Fail on decoder errors instead of continuing"
    echo "    -S                 Scan mode - analyze files without extracting audio"
    echo ""
    echo "    -F FORMAT          Output file format (default: wav):"
    echo "                         wav, aiff, au, raw, paf, svx, nist, voc, ircam,"
    echo "                         w64, mat4, mat5, pvf, xi, htk, sds, avr, wavex,"
    echo "                         sd2, flac, caf, wve, ogg, mpc2k, rf64"
    echo ""
    echo "    -D FORMAT          Output data format:"
    echo "                         pcm_s8, pcm_16, pcm_24, pcm_32, pcm_u8, float, double,"
    echo "                         ulaw, alaw, ima_adpcm, ms_adpcm, gsm610, vox_adpcm,"
    echo "                         g721_32, g723_24, g723_40, dwvw_12, dwvw_16, dwvw_24,"
    echo "                         dwvw_n, dpcm_8, dpcm_16, vorbis"
    echo "                         (default: gsm610 for mono, ms_adpcm for stereo)"
    echo ""
    echo "    -A FILE            Answer channel capture file (PCAP or RTP stream)"
    echo "    -B FILE            Originate channel capture file (PCAP or RTP stream)"
    echo ""
    echo "    --force-codec CODEC Override RTP payload type detection:"
    echo "                         pcmu/ulaw (payload 0), pcma/alaw (payload 8),"
    echo "                         g729 (payload 18), g722 (payload 9),"
    echo "                         gsm (payload 3), opus (dynamic payload)"
    echo ""
    echo "SRTP OPTIONS (if compiled with ENABLE_SRTP/ENABLE_SRTP2)"
    echo "    --alice-crypto CSPEC  Crypto specification for Alice (answer) channel"
    echo "    --bob-crypto CSPEC    Crypto specification for Bob (originate) channel"
    echo ""
    echo "    CSPEC format: suite:key[:salt]"
    echo "    Supported suites: AES_CM_128_HMAC_SHA1_80, AES_CM_128_HMAC_SHA1_32"
    echo ""
    echo "INPUT FORMATS"
    echo "    - PCAP files (.pcap extension) - automatically detected"
    echo "    - Linux SLL format - automatically converted to Ethernet"
    echo "    - rtpproxy recording directories (rdir.a.rtp, rdir.o.rtp)"
    echo "    - Individual RTP stream files"
    echo ""
    echo "SUPPORTED CODECS (Auto-detected from RTP payload type)"
    echo "    - G.711 μ-law (PCMU) - payload type 0"
    echo "    - G.711 A-law (PCMA) - payload type 8"
    echo "    - G.729 - payload type 18"
    echo "    - G.722 - payload type 9"
    echo "    - GSM - payload type 3"
    echo "    - Opus - dynamic payload types (typically 111)"
    echo ""
    echo "DOCKER ENHANCED FEATURES"
    echo "    • Automatically detects Linux SLL (cooked) PCAP captures"
    echo "    • Splits RTP streams by SSRC for true stereo extraction"
    echo "    • Uses extractaudio -A/-B options for separate stereo channels"
    echo "    • Full codec support with automatic detection and fallback"
    echo "    • Intelligent fallback from true stereo to mixed stereo when needed"
    echo "    • Automatic Docker image building with codec dependencies"
    echo "    • Volume mounting for seamless file access"
    echo "    • Cross-platform path handling (Windows/WSL compatibility)"
    echo ""
    echo "EXAMPLES"
    echo ""
    echo "    Basic mono extraction:"
    echo "        $0 -F wav call.pcap output.wav"
    echo ""
    echo "    True stereo from dual RTP streams:"
    echo "        $0 -s -F wav call.pcap stereo_output.wav"
    echo ""
    echo "    Mixed stereo (legacy mode):"
    echo "        $0 --mixed-stereo -s -F wav call.pcap mixed_output.wav"
    echo ""
    echo "    Separate channel files:"
    echo "        $0 -A answer.pcap -B originate.pcap -s output.wav"
    echo ""
    echo "    Force specific codec:"
    echo "        $0 --force-codec g729 -F wav call.pcap output.wav"
    echo ""
    echo "    High-quality PCM output:"
    echo "        $0 -F wav -D pcm_16 call.pcap hq_output.wav"
    echo ""
    echo "    FLAC lossless compression:"
    echo "        $0 -F flac -D pcm_24 call.pcap lossless.flac"
    echo ""
    echo "    SRTP encrypted streams (if SRTP support compiled):"
    echo "        $0 --alice-crypto AES_CM_128_HMAC_SHA1_80:key1:salt1 \\"
    echo "           --bob-crypto AES_CM_128_HMAC_SHA1_80:key2:salt2 \\"
    echo "           -A encrypted_a.pcap -B encrypted_b.pcap output.wav"
    echo ""
    echo "    Scan mode (analyze without extraction):"
    echo "        $0 -S call.pcap"
    echo "        $0 -S -A answer.pcap -B originate.pcap"
    echo ""
    echo "    rtpproxy directory processing:"
    echo "        $0 -F wav /path/to/recording output.wav"
    echo ""
    echo "    Skip auto-conversion (direct extractaudio):"
    echo "        $0 --direct -F wav ethernet_format.pcap output.wav"
    echo ""
    echo "    Docker image management:"
    echo "        $0 --build-image                    # Force rebuild"
    echo "        $0 --show-info                      # Show image details"
    echo "        $0 --shell                          # Interactive shell"
    echo ""
    echo "PROCESSING WORKFLOW"
    echo "    1. Docker availability and image verification"
    echo "    2. Input format detection (SLL vs Ethernet)"
    echo "    3. RTP stream analysis and SSRC identification"
    echo "    4. Automatic format conversion if needed"
    echo "    5. Stream splitting for true stereo (if enabled)"
    echo "    6. Audio extraction with selected codec/format"
    echo "    7. Temporary file cleanup"
    echo ""
    echo "OUTPUT INFORMATION"
    echo "    The utility provides detailed statistics including:"
    echo "    - Packet counts and sequence analysis"
    echo "    - SSRC values and changes"
    echo "    - Jitter statistics (min/avg/max)"
    echo "    - Sample counts per channel"
    echo "    - Duplicate and lost packet counts"
    echo ""
    echo "NOTES"
    echo "    • Docker must be installed and accessible"
    echo "    • First run may take several minutes to build the image"
    echo "    • File paths are automatically mounted into the container"
    echo "    • libsndfile provides extensive audio format support"
    echo "    • SRTP support requires compilation with libsrtp/libsrtp2"
    echo "    • Codec support depends on build-time dependencies"
    echo ""
    echo "For detailed extractaudio options, run: $0 --direct --help"
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

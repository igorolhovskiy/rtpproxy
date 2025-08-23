#!/bin/bash
# extractaudio-dual.sh - Extract true stereo from dual RTP streams

set -e

# Configuration
DOCKER_IMAGE="rtpproxy-extractaudio:latest"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_usage() {
    echo "extractaudio-dual.sh - True stereo extraction from dual RTP streams"
    echo ""
    echo "Usage: $0 [options] input.pcap output.wav"
    echo ""
    echo "Options:"
    echo "  -F format    Output format (wav, raw, etc.) [default: wav]"
    echo "  --help       Show this help"
    echo ""
    echo "This script automatically:"
    echo "1. Detects Linux SLL format and converts if needed"
    echo "2. Splits RTP streams by SSRC into separate PCAP files"
    echo "3. Uses extractaudio -A/-B options for true stereo output"
    echo "4. Each RTP stream becomes a separate stereo channel"
    echo ""
    echo "Examples:"
    echo "  $0 input.pcap output.wav"
    echo "  $0 -F wav input.pcap stereo.wav"
    exit 1
}

# Check if Docker is available
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

# Parse arguments
OUTPUT_FORMAT="wav"
INPUT_FILE=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -F)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            ;;
        -*)
            log_error "Unknown option: $1"
            show_usage
            ;;
        *)
            if [ -z "$INPUT_FILE" ]; then
                INPUT_FILE="$1"
            elif [ -z "$OUTPUT_FILE" ]; then
                OUTPUT_FILE="$1"
            else
                log_error "Too many arguments"
                show_usage
            fi
            shift
            ;;
    esac
done

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    log_error "Missing input or output file"
    show_usage
fi

if [ ! -f "$INPUT_FILE" ]; then
    log_error "Input file '$INPUT_FILE' not found"
    exit 1
fi

log_info "Input PCAP: $INPUT_FILE"
log_info "Output file: $OUTPUT_FILE"
log_info "Format: $OUTPUT_FORMAT"

# Check Docker
check_docker

# Split RTP streams by SSRC
log_info "Splitting RTP streams by SSRC..."
TEMP_PREFIX="rtp_stream_$$"

# Use Docker to run the splitting script
log_info "Running stream splitting..."
docker run --rm --user "$(id -u):$(id -g)" \
    -v "$(pwd):/data" \
    --workdir /data \
    "$DOCKER_IMAGE" \
    python3 /usr/local/bin/split_rtp_streams.py "$INPUT_FILE" "$TEMP_PREFIX" 2>&1

# Find the created stream files in current directory
STREAM_FILES=($(ls ${TEMP_PREFIX}_*.pcap 2>/dev/null | head -20))  # Limit to prevent overflow

if [ ${#STREAM_FILES[@]} -eq 0 ]; then
    log_error "No RTP streams found in the PCAP file"
    exit 1
elif [ ${#STREAM_FILES[@]} -eq 1 ]; then
    log_warn "Only 1 RTP stream found, cannot create true stereo"
    log_info "Creating mono output from single stream..."
    
    # Extract mono from single stream
    docker run --rm --user "$(id -u):$(id -g)" \
        -v "$(pwd):/data" \
        --workdir /data \
        "$DOCKER_IMAGE" \
        extractaudio -F "$OUTPUT_FORMAT" "${STREAM_FILES[0]}" "$OUTPUT_FILE"
    
    RET_CODE=$?
else
    log_info "Found ${#STREAM_FILES[@]} RTP streams"
    
    # Sort by packet count (get the two largest streams)
    declare -A STREAM_COUNTS
    for stream in "${STREAM_FILES[@]}"; do
        count=$(docker run --rm --user "$(id -u):$(id -g)" \
            -v "$(pwd):/data" \
            --workdir /data \
            "$DOCKER_IMAGE" \
            tshark -r "$stream" -T fields -e frame.number | wc -l)
        STREAM_COUNTS["$stream"]=$count
    done
    
    # Get the two streams with most packets
    SORTED_STREAMS=($(for stream in "${!STREAM_COUNTS[@]}"; do
        echo "${STREAM_COUNTS[$stream]} $stream"
    done | sort -nr | head -2 | awk '{print $2}'))
    
    if [ ${#SORTED_STREAMS[@]} -ge 2 ]; then
        STREAM_A="${SORTED_STREAMS[0]}"
        STREAM_B="${SORTED_STREAMS[1]}"
        
        log_info "Using streams for true stereo:"
        log_info "  Channel A: $(basename $STREAM_A) (${STREAM_COUNTS[$STREAM_A]} packets)"
        log_info "  Channel B: $(basename $STREAM_B) (${STREAM_COUNTS[$STREAM_B]} packets)"
        
        # Extract true stereo using -A and -B options with -s flag
        log_info "Extracting true stereo audio..."
        docker run --rm --user "$(id -u):$(id -g)" \
            -v "$(pwd):/data" \
            --workdir /data \
            "$DOCKER_IMAGE" \
            extractaudio -s -F "$OUTPUT_FORMAT" -A "$STREAM_A" -B "$STREAM_B" "$OUTPUT_FILE"
        
        RET_CODE=$?
        
        if [ $RET_CODE -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
            log_info "True stereo extraction completed successfully"
            log_info "Output file: $OUTPUT_FILE"
            
            # Show file details
            if command -v file &> /dev/null; then
                FILE_INFO=$(file "$OUTPUT_FILE")
                log_info "File format: $FILE_INFO"
            fi
        else
            log_error "True stereo extraction failed"
            RET_CODE=1
        fi
    else
        log_error "Could not find two suitable streams for stereo"
        RET_CODE=1
    fi
fi

# Clean up temporary files
log_info "Cleaning up temporary files..."
rm -f ${TEMP_PREFIX}_*.pcap

if [ $RET_CODE -eq 0 ]; then
    log_info "Extraction completed successfully!"
else
    log_error "Extraction failed"
fi

exit $RET_CODE
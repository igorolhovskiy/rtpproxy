#!/bin/bash
# extractaudio-stereo.sh - Enhanced wrapper for true stereo extraction using separate RTP streams

set -e

# Function to show usage
show_usage() {
    echo "Usage: $0 [options] input.pcap output.wav"
    echo ""
    echo "Enhanced extractaudio wrapper that splits RTP streams for true stereo output."
    echo ""
    echo "Options:"
    echo "  -F format    Output format (wav, raw, etc.)"
    echo "  --true-stereo Use separate RTP streams for left/right channels (default)"
    echo "  --mixed-stereo Use single stream mixed to stereo"
    echo ""
    echo "This script:"
    echo "1. Detects Linux SLL format and converts if needed"
    echo "2. Splits RTP streams by SSRC into separate PCAP files"
    echo "3. Uses extractaudio -A/-B options for true stereo output"
    echo ""
    echo "Examples:"
    echo "  $0 -F wav input.pcap stereo.wav"
    echo "  $0 --mixed-stereo input.pcap mixed.wav"
    exit 1
}

# Parse arguments
ARGS=()
OUTPUT_FORMAT="wav"
TRUE_STEREO=true
INPUT_FILE=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -F)
            OUTPUT_FORMAT="$2"
            ARGS+=("-F" "$2")
            shift 2
            ;;
        --true-stereo)
            TRUE_STEREO=true
            shift
            ;;
        --mixed-stereo)
            TRUE_STEREO=false
            shift
            ;;
        -h|--help)
            show_usage
            ;;
        -*)
            ARGS+=("$1")
            shift
            ;;
        *)
            if [ -z "$INPUT_FILE" ]; then
                INPUT_FILE="$1"
            elif [ -z "$OUTPUT_FILE" ]; then
                OUTPUT_FILE="$1"
            else
                ARGS+=("$1")
            fi
            shift
            ;;
    esac
done

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Error: Missing input or output file"
    show_usage
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found"
    exit 1
fi

echo "[INFO] Input PCAP: $INPUT_FILE"
echo "[INFO] Output file: $OUTPUT_FILE"
echo "[INFO] True stereo mode: $TRUE_STEREO"

# Check if we need to convert Linux SLL format
echo "[INFO] Checking PCAP format..."
LINK_TYPE=$(python3 /usr/local/bin/split_rtp_streams.py "$INPUT_FILE" /tmp/test_split 2>/dev/null || echo "")

if tshark -r "$INPUT_FILE" -T fields -e frame.protocols 2>/dev/null | head -1 | grep -q "sll"; then
    echo "[INFO] Detected Linux SLL format"
    NEEDS_CONVERSION=true
else
    echo "[INFO] Standard format detected"
    NEEDS_CONVERSION=false
fi

if [ "$TRUE_STEREO" = true ]; then
    echo "[INFO] Splitting RTP streams for true stereo extraction..."
    
    # Split RTP streams by SSRC
    TEMP_PREFIX="/tmp/rtp_stream_$$"
    if [ "$NEEDS_CONVERSION" = true ]; then
        python3 /usr/local/bin/split_rtp_streams.py "$INPUT_FILE" "$TEMP_PREFIX"
    else
        # For non-SLL files, we still need to split by SSRC
        # For now, use the conversion script which also splits
        python3 /usr/local/bin/split_rtp_streams.py "$INPUT_FILE" "$TEMP_PREFIX"
    fi
    
    # Find the created stream files
    STREAM_FILES=($(ls ${TEMP_PREFIX}_*.pcap 2>/dev/null || true))
    
    if [ ${#STREAM_FILES[@]} -lt 2 ]; then
        echo "[WARNING] Found ${#STREAM_FILES[@]} RTP streams, need at least 2 for true stereo"
        echo "[INFO] Falling back to mixed stereo mode"
        TRUE_STEREO=false
    else
        echo "[INFO] Found ${#STREAM_FILES[@]} RTP streams: ${STREAM_FILES[@]}"
        
        # Use first two streams for stereo (A and B channels)
        STREAM_A="${STREAM_FILES[0]}"
        STREAM_B="${STREAM_FILES[1]}"
        
        echo "[INFO] Using streams:"
        echo "  Channel A: $(basename $STREAM_A)"
        echo "  Channel B: $(basename $STREAM_B)"
        
        # Extract true stereo using -A and -B options
        echo "[INFO] Extracting true stereo audio..."
        if extractaudio "${ARGS[@]}" -A "$STREAM_A" -B "$STREAM_B" "$OUTPUT_FILE"; then
            echo "[INFO] True stereo extraction completed successfully"
            RET_CODE=0
        else
            echo "[ERROR] True stereo extraction failed"
            RET_CODE=1
        fi
        
        # Clean up temporary files
        rm -f ${TEMP_PREFIX}_*.pcap
        exit $RET_CODE
    fi
fi

# Fallback to mixed stereo or if true stereo failed
if [ "$TRUE_STEREO" = false ] || [ ${#STREAM_FILES[@]} -lt 2 ]; then
    echo "[INFO] Using mixed stereo mode..."
    
    if [ "$NEEDS_CONVERSION" = true ]; then
        # Convert Linux SLL to Ethernet format
        TEMP_PCAP=$(mktemp /tmp/extractaudio_converted_XXXXXX.pcap)
        echo "[INFO] Converting Linux SLL to Ethernet format..."
        python3 /usr/local/bin/sll_to_eth.py "$INPUT_FILE" "$TEMP_PCAP"
        
        # Use converted file with -s option for mixed stereo
        if extractaudio "${ARGS[@]}" -s "$TEMP_PCAP" "$OUTPUT_FILE"; then
            echo "[INFO] Mixed stereo extraction completed successfully"
            RET_CODE=0
        else
            echo "[ERROR] Mixed stereo extraction failed"
            RET_CODE=1
        fi
        
        rm -f "$TEMP_PCAP"
        exit $RET_CODE
    else
        # Use original file directly
        if extractaudio "${ARGS[@]}" -s "$INPUT_FILE" "$OUTPUT_FILE"; then
            echo "[INFO] Mixed stereo extraction completed successfully"
            RET_CODE=0
        else
            echo "[ERROR] Mixed stereo extraction failed" 
            RET_CODE=1
        fi
        exit $RET_CODE
    fi
fi
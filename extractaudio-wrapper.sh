#!/bin/bash

# extractaudio-wrapper.sh - Wrapper script for extractaudio with Linux SLL auto-conversion
# Automatically converts Linux SLL captures to Ethernet format for compatibility

set -e

# Function to show usage
show_usage() {
    echo "Usage: $0 [extractaudio options] input.pcap output.wav"
    echo ""
    echo "Enhanced wrapper that automatically handles Linux SLL captures and"
    echo "provides true stereo extraction from dual RTP streams."
    echo ""
    echo "Options:"
    echo "  --true-stereo     Split RTP streams by SSRC for true stereo (default with -s)"
    echo "  --mixed-stereo    Use single stream mixed to stereo (legacy mode)"
    echo ""
    echo "Examples:"
    echo "  $0 -s -F wav input.pcap stereo_output.wav     # True stereo from dual streams"
    echo "  $0 --mixed-stereo -s -F wav input.pcap out.wav # Mixed stereo (legacy)"
    echo "  $0 -F wav mono_input.pcap mono_output.wav      # Mono extraction"
    echo ""
    echo "The script will:"
    echo "1. Detect if the input PCAP is Linux SLL format"
    echo "2. Split RTP streams by SSRC for true stereo (with -s flag)"
    echo "3. Use extractaudio -A/-B options for separate channels"
    echo "4. Clean up temporary files"
    exit 1
}

# Check if we have at least 2 arguments (input and output files)
if [ $# -lt 2 ]; then
    show_usage
fi

# Parse arguments to find input and output files and detect stereo mode
ARGS=("$@")
FILTERED_ARGS=()
INPUT_FILE=""
OUTPUT_FILE=""
STEREO_MODE=""
TRUE_STEREO=true
FORCE_MIXED=false

# Process arguments
for ((i=0; i<${#ARGS[@]}; i++)); do
    arg="${ARGS[i]}"
    case "$arg" in
        --true-stereo)
            TRUE_STEREO=true
            # Don't add to filtered args
            ;;
        --mixed-stereo)
            TRUE_STEREO=false
            FORCE_MIXED=true
            # Don't add to filtered args
            ;;
        -s)
            STEREO_MODE="-s"
            FILTERED_ARGS+=("$arg")
            ;;
        *.pcap)
            INPUT_FILE="$arg"
            FILTERED_ARGS+=("$arg")
            ;;
        *)
            FILTERED_ARGS+=("$arg")
            ;;
    esac
done

# Output file is the last argument
OUTPUT_FILE="${FILTERED_ARGS[-1]}"

# If -s flag is used and not forced to mixed mode, enable true stereo
if [[ "$STEREO_MODE" == "-s" ]] && [[ "$FORCE_MIXED" != "true" ]]; then
    TRUE_STEREO=true
fi

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Error: Could not identify input PCAP file or output file"
    show_usage
fi

if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found"
    exit 1
fi

echo "[INFO] Input PCAP: $INPUT_FILE"
echo "[INFO] Output file: $OUTPUT_FILE"
if [[ "$STEREO_MODE" == "-s" ]]; then
    if [[ "$TRUE_STEREO" == "true" ]]; then
        echo "[INFO] Mode: True stereo (separate RTP streams)"
    else
        echo "[INFO] Mode: Mixed stereo (single stream)"
    fi
fi

# Check the PCAP file format using tshark
echo "[INFO] Checking PCAP format..."
LINK_TYPE=$(tshark -r "$INPUT_FILE" -T fields -e frame.protocols 2>/dev/null | head -1 | grep -o "sll" || true)

if [ -n "$LINK_TYPE" ] || [[ "$STEREO_MODE" == "-s" && "$TRUE_STEREO" == "true" ]]; then
    if [ -n "$LINK_TYPE" ]; then
        echo "[INFO] Detected Linux SLL format"
    fi
    
    # For true stereo mode, split RTP streams by SSRC
    if [[ "$STEREO_MODE" == "-s" && "$TRUE_STEREO" == "true" ]]; then
        echo "[INFO] Splitting RTP streams for true stereo extraction..."
        
        # Create temporary prefix for stream files
        TEMP_PREFIX="/tmp/rtp_stream_$$"
        
        # Split RTP streams by SSRC
        python3 /usr/local/bin/pcap_converter.py split "$INPUT_FILE" "$TEMP_PREFIX" 2>/dev/null
        
        # Find the created stream files
        STREAM_FILES=($(ls ${TEMP_PREFIX}_*.pcap 2>/dev/null | head -20))
        
        if [ ${#STREAM_FILES[@]} -eq 0 ]; then
            echo "[WARNING] No RTP streams found, falling back to mixed stereo"
            TRUE_STEREO=false
        elif [ ${#STREAM_FILES[@]} -eq 1 ]; then
            echo "[WARNING] Only 1 RTP stream found, falling back to mixed stereo"
            TRUE_STEREO=false
        else
            echo "[INFO] Found ${#STREAM_FILES[@]} RTP streams"
            
            # Sort by file size (packet count) to get the two largest streams
            SORTED_STREAMS=($(ls -S ${TEMP_PREFIX}_*.pcap 2>/dev/null | head -2))
            
            if [ ${#SORTED_STREAMS[@]} -ge 2 ]; then
                STREAM_A="${SORTED_STREAMS[0]}"
                STREAM_B="${SORTED_STREAMS[1]}"
                
                echo "[INFO] Using streams for true stereo:"
                echo "[INFO]   Channel A: $(basename $STREAM_A)"
                echo "[INFO]   Channel B: $(basename $STREAM_B)"
                
                # Remove input file from filtered args and add -A/-B options
                TRUE_STEREO_ARGS=()
                for arg in "${FILTERED_ARGS[@]}"; do
                    if [ "$arg" != "$INPUT_FILE" ]; then
                        TRUE_STEREO_ARGS+=("$arg")
                    fi
                done
                
                # Extract true stereo using -A and -B options
                echo "[INFO] Extracting true stereo audio..."
                EXTRACT_OUTPUT=$(extractaudio "${TRUE_STEREO_ARGS[@]}" -A "$STREAM_A" -B "$STREAM_B" 2>&1)
                EXTRACT_EXIT_CODE=$?
                echo "$EXTRACT_OUTPUT"
                
                # Check if extraction succeeded
                if [ $EXTRACT_EXIT_CODE -eq 0 ] && [ -f "$OUTPUT_FILE" ] && ! echo "$EXTRACT_OUTPUT" | grep -q "pcount=0"; then
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
        
        # Clean up temporary files if we're falling back
        rm -f ${TEMP_PREFIX}_*.pcap
    fi
    
    # Fallback to mixed stereo or standard conversion
    if [ -n "$LINK_TYPE" ]; then
        # Create temporary file for converted PCAP
        TEMP_PCAP=$(mktemp /tmp/extractaudio_converted_XXXXXX.pcap)
        
        echo "[INFO] Converting Linux SLL to Ethernet format..."
        # Try custom Python converter first (most reliable)
        if python3 /usr/local/bin/pcap_converter.py convert "$INPUT_FILE" "$TEMP_PCAP" 2>/dev/null; then
            echo "[INFO] Used custom Python SLL to Ethernet converter"
        elif editcap -F libpcap -T ether "$INPUT_FILE" "$TEMP_PCAP" 2>/dev/null; then
            echo "[INFO] Used fallback editcap conversion"
        else
            echo "[ERROR] Failed to convert PCAP format"
            rm -f "$TEMP_PCAP"
            exit 1
        fi
        
        echo "[INFO] Conversion successful, processing with extractaudio..."
        
        # Replace input file in arguments with converted file
        NEW_ARGS=()
        for arg in "${FILTERED_ARGS[@]}"; do
            if [ "$arg" = "$INPUT_FILE" ]; then
                NEW_ARGS+=("$TEMP_PCAP")
            else
                NEW_ARGS+=("$arg")
            fi
        done
        
        # Run extractaudio with converted file
        EXTRACT_OUTPUT=$(extractaudio "${NEW_ARGS[@]}" 2>&1)
        EXTRACT_EXIT_CODE=$?
        echo "$EXTRACT_OUTPUT"
        
        # Check if extraction succeeded
        if [ $EXTRACT_EXIT_CODE -eq 0 ] && [ -f "$OUTPUT_FILE" ] && ! echo "$EXTRACT_OUTPUT" | grep -q "pcount=0"; then
            echo "[INFO] Audio extraction completed successfully"
            RET_CODE=0
        else
            echo "[ERROR] extractaudio failed or produced no output"
            RET_CODE=1
        fi
        
        # Clean up temporary file
        rm -f "$TEMP_PCAP"
        exit $RET_CODE
    else
        # No conversion needed, run extractaudio directly
        extractaudio "${FILTERED_ARGS[@]}"
    fi
else
    echo "[INFO] Standard Ethernet format detected - no conversion needed"
    
    # Run extractaudio directly
    extractaudio "${FILTERED_ARGS[@]}"
fi
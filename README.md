Important note: this is a fork of original [`RTPProxy`](https://github.com/sippy/rtpproxy) tool focused exclusively on `extractaudio` tool.</br>
These modifications were mostly vibe-coded mainly to quickly serve one task - extract audio from `pcap` files produced by [`sngrep`](https://github.com/irontec/sngrep) utility with possibility to force the output codec.

# ExtractAudio Tool

A powerful Docker-based audio extraction tool for RTP streams from PCAP files, rtpproxy recordings, and RTP stream data.

## Overview

The `extractaudio-docker.sh` tool provides enhanced audio extraction capabilities with:
- Automatic Docker image building and management
- Support for multiple audio formats and codecs
- Linux SLL format PCAP conversion
- True stereo extraction from dual RTP streams
- SRTP encrypted stream support (when compiled with libsrtp)

## Building

The tool automatically builds the required Docker image on first use. To manually build:

```bash
./extractaudio-docker.sh --build-image
```

## Usage

Basic syntax:
```bash
./extractaudio-docker.sh [wrapper options] [extractaudio options] input_file output_file
```

### Docker Wrapper Options

- `--build-image` - Force rebuild of Docker image
- `--show-info` - Show Docker image information and codec support
- `--shell` - Open interactive shell in container
- `--direct` - Skip Linux SLL conversion (use original extractaudio)
- `--true-stereo` - Split RTP streams by SSRC for true stereo (default with -s)
- `--mixed-stereo` - Use single stream mixed to stereo (legacy mode)

### Audio Extraction Options

- `-d` - Delete input files after processing
- `-s` - Enable stereo output (2 channels)
- `-i` - Set idle priority for processing
- `-n` - Disable synchronization (nosync mode)
- `-e` - Fail on decoder errors instead of continuing
- `-S` - Scan mode - analyze files without extracting audio

- `-F FORMAT` - Output file format (wav, aiff, flac, ogg, etc.)
- `-D FORMAT` - Output data format (pcm_16, pcm_24, float, etc.)
- `-A FILE` - Answer channel capture file
- `-B FILE` - Originate channel capture file

### SRTP Options (if compiled with SRTP support)

- `--alice-crypto CSPEC` - Crypto specification for Alice (answer) channel
- `--bob-crypto CSPEC` - Crypto specification for Bob (originate) channel

CSPEC format: `suite:key[:salt]`

### Examples

Basic mono extraction:
```bash
./extractaudio-docker.sh -F wav call.pcap output.wav
```

True stereo from dual RTP streams:
```bash
./extractaudio-docker.sh -s -F wav call.pcap stereo_output.wav
```

Separate channel files:
```bash
./extractaudio-docker.sh -A answer.pcap -B originate.pcap -s output.wav
```

High-quality PCM output:
```bash
./extractaudio-docker.sh -F wav -D pcm_16 call.pcap hq_output.wav
```

FLAC lossless compression:
```bash
./extractaudio-docker.sh -F flac -D pcm_24 call.pcap lossless.flac
```

Scan mode (analyze without extraction):
```bash
./extractaudio-docker.sh -S call.pcap
```

## Supported Formats

### Input Formats
- PCAP files (.pcap extension)
- Linux SLL format (automatically converted)
- rtpproxy recording directories (rdir.a.rtp, rdir.o.rtp)
- Individual RTP stream files

### Supported Codecs
- G.711 μ-law (PCMU) - payload type 0
- G.711 A-law (PCMA) - payload type 8
- G.729 - payload type 18
- G.722 - payload type 9
- GSM - payload type 3
- Opus - dynamic payload types

### Output Formats
- WAV, AIFF, AU, RAW, PAF, SVX, NIST, VOC
- IRCAM, W64, MAT4, MAT5, PVF, XI, HTK
- SDS, AVR, WAVEX, SD2, FLAC, CAF, WVE
- OGG, MPC2K, RF64

## Requirements

- Docker must be installed and accessible
- First run may take several minutes to build the image
- File paths are automatically mounted into the container

## Getting Help

For detailed options and examples:
```bash
./extractaudio-docker.sh --help
```

For Docker image information:
```bash
./extractaudio-docker.sh --show-info
```

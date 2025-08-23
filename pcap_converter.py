#!/usr/bin/env python3
"""
Comprehensive PCAP converter and RTP stream processor
Handles Linux SLL to Ethernet conversion and RTP stream splitting
"""

import sys
import struct
import argparse
import os

def convert_sll_to_eth(input_file, output_file):
    """Convert Linux SLL PCAP to Ethernet PCAP"""
    
    # Ethernet header template (14 bytes)
    # dst_mac(6) + src_mac(6) + ethertype(2)
    ETH_HEADER_SIZE = 14
    SLL_HEADER_SIZE = 16
    
    with open(input_file, 'rb') as fin, open(output_file, 'wb') as fout:
        # Copy PCAP global header (24 bytes)
        global_header = fin.read(24)
        if len(global_header) != 24:
            raise ValueError("Invalid PCAP file")
        
        # Modify network type in global header from Linux SLL (113) to Ethernet (1)
        header_data = bytearray(global_header)
        header_data[20:24] = struct.pack('<I', 1)  # DLT_EN10MB = 1
        fout.write(header_data)
        
        packet_count = 0
        
        while True:
            # Read packet record header (16 bytes)
            pkt_header = fin.read(16)
            if len(pkt_header) != 16:
                break  # End of file
                
            # Parse packet header
            ts_sec, ts_usec, incl_len, orig_len = struct.unpack('<IIII', pkt_header)
            
            # Read packet data
            packet_data = fin.read(incl_len)
            if len(packet_data) != incl_len:
                break
                
            # Check if this is a Linux SLL packet with IP protocol
            if incl_len >= SLL_HEADER_SIZE:
                # Parse Linux SLL header
                sll_data = packet_data[:SLL_HEADER_SIZE]
                packet_type, device_type, addr_len = struct.unpack('>HHH', sll_data[:6])
                address = sll_data[6:14]  # 8 bytes
                protocol = struct.unpack('>H', sll_data[14:16])[0]
                
                # Only convert IP packets (protocol 0x0800)
                if protocol == 0x0800 and incl_len > SLL_HEADER_SIZE:
                    # IP data starts after SLL header
                    ip_data = packet_data[SLL_HEADER_SIZE:]
                    
                    # Verify this is a valid IP packet with minimum length
                    if len(ip_data) < 20:  # Minimum IP header length
                        continue
                        
                    # Parse IP header to ensure it's valid
                    ip_header = ip_data[:20]
                    version_ihl = ip_header[0]
                    version = (version_ihl >> 4) & 0xF
                    ihl = version_ihl & 0xF
                    
                    # Only process IPv4 packets
                    if version != 4:
                        continue
                        
                    # Calculate actual IP header length
                    ip_hdr_len = ihl * 4
                    if ip_hdr_len < 20 or ip_hdr_len > len(ip_data):
                        continue
                        
                    # For extractaudio compatibility, we need to ensure the IP header is exactly 20 bytes
                    # If it has options, we'll create a new header without them
                    if ip_hdr_len != 20:
                        # Extract essential fields and create a new 20-byte header
                        version_ihl_new = 0x45  # Version 4, IHL 5 (20 bytes)
                        tos = ip_header[1]
                        total_length = struct.unpack('>H', ip_header[2:4])[0]
                        identification = ip_header[4:6]
                        flags_fragment = ip_header[6:8]
                        ttl = ip_header[8]
                        protocol_field = ip_header[9]
                        src_ip = ip_header[12:16]
                        dst_ip = ip_header[16:20]
                        
                        # Recalculate total length for new header
                        new_total_length = total_length - (ip_hdr_len - 20)
                        
                        # Create new IP header (20 bytes, no options)
                        new_ip_header = struct.pack('>BBHHHBBH4s4s',
                            version_ihl_new, tos, new_total_length,
                            struct.unpack('>H', identification)[0],
                            struct.unpack('>H', flags_fragment)[0],
                            ttl, protocol_field, 0,  # checksum will be 0
                            src_ip, dst_ip
                        )
                        
                        # Get payload after original IP header
                        payload = ip_data[ip_hdr_len:]
                        ip_data = new_ip_header + payload
                    
                    # Create Ethernet header
                    dst_mac = b'\x00\x01\x02\x03\x04\x05'
                    src_mac = b'\x00\x01\x02\x03\x04\x06'
                    ethertype = struct.pack('>H', 0x0800)  # IP
                    
                    eth_header = dst_mac + src_mac + ethertype
                    
                    # Create new packet
                    new_packet = eth_header + ip_data
                    new_incl_len = len(new_packet)
                    new_orig_len = orig_len - SLL_HEADER_SIZE + ETH_HEADER_SIZE - (ip_hdr_len - 20) if ip_hdr_len != 20 else orig_len - SLL_HEADER_SIZE + ETH_HEADER_SIZE
                    
                    # Write new packet header
                    new_pkt_header = struct.pack('<IIII', ts_sec, ts_usec, new_incl_len, new_orig_len)
                    fout.write(new_pkt_header)
                    fout.write(new_packet)
                    
                    packet_count += 1
                    continue
            
            # For non-IP packets or invalid packets, skip them
            # (or you could write them as-is, but extractaudio only needs IP/UDP/RTP)
        
        print(f"Converted {packet_count} packets from Linux SLL to Ethernet format")
        return packet_count

def split_rtp_streams(input_file, output_prefix):
    """Split RTP streams by SSRC into separate PCAP files"""
    
    # Ethernet header template (14 bytes)
    ETH_HEADER_SIZE = 14
    SLL_HEADER_SIZE = 16
    
    stream_files = {}
    stream_counts = {}
    
    # Global PCAP header for output files
    global_header = None
    
    with open(input_file, 'rb') as fin:
        # Read and store PCAP global header (24 bytes)
        global_header = fin.read(24)
        if len(global_header) != 24:
            raise ValueError("Invalid PCAP file")
        
        # Modify network type to Ethernet (DLT_EN10MB = 1)
        global_header = bytearray(global_header)
        global_header[20:24] = struct.pack('<I', 1)  # DLT_EN10MB = 1
        global_header = bytes(global_header)
        
        while True:
            # Read packet record header (16 bytes)
            pkt_header = fin.read(16)
            if len(pkt_header) != 16:
                break  # End of file
                
            # Parse packet header
            ts_sec, ts_usec, incl_len, orig_len = struct.unpack('<IIII', pkt_header)
            
            # Read packet data
            packet_data = fin.read(incl_len)
            if len(packet_data) != incl_len:
                break
                
            # Check if this is a Linux SLL packet with IP protocol
            if incl_len >= SLL_HEADER_SIZE:
                # Parse Linux SLL header
                sll_data = packet_data[:SLL_HEADER_SIZE]
                protocol = struct.unpack('>H', sll_data[14:16])[0]
                
                # Only process IP packets (protocol 0x0800)
                if protocol == 0x0800 and incl_len > SLL_HEADER_SIZE:
                    # IP data starts after SLL header
                    ip_data = packet_data[SLL_HEADER_SIZE:]
                    
                    # Verify this is a valid IP packet
                    if len(ip_data) < 20:
                        continue
                        
                    # Parse IP header
                    ip_header = ip_data[:20]
                    version_ihl = ip_header[0]
                    version = (version_ihl >> 4) & 0xF
                    ihl = version_ihl & 0xF
                    
                    # Only process IPv4 packets
                    if version != 4:
                        continue
                        
                    # Calculate IP header length
                    ip_hdr_len = ihl * 4
                    if ip_hdr_len < 20 or ip_hdr_len > len(ip_data):
                        continue
                    
                    # Check if this is UDP
                    protocol_field = ip_header[9]
                    if protocol_field != 17:  # UDP
                        continue
                    
                    # Get UDP header
                    if len(ip_data) < ip_hdr_len + 8:  # IP header + UDP header
                        continue
                        
                    udp_header = ip_data[ip_hdr_len:ip_hdr_len + 8]
                    src_port, dst_port, udp_len, udp_checksum = struct.unpack('>HHHH', udp_header)
                    
                    # Get RTP payload
                    rtp_data = ip_data[ip_hdr_len + 8:]
                    if len(rtp_data) < 12:  # Minimum RTP header
                        continue
                    
                    # Parse RTP header to get SSRC
                    rtp_header = rtp_data[:12]
                    version_byte = rtp_header[0]
                    rtp_version = (version_byte >> 6) & 0x3
                    
                    # Only process RTP version 2
                    if rtp_version != 2:
                        continue
                    
                    # Extract SSRC (bytes 8-12 of RTP header)
                    ssrc = struct.unpack('>I', rtp_header[8:12])[0]
                    ssrc_hex = f"0x{ssrc:08x}"
                    
                    # Create Ethernet packet with standardized 20-byte IP header
                    if ip_hdr_len != 20:
                        # Extract essential fields and create new 20-byte header
                        tos = ip_header[1]
                        total_length = struct.unpack('>H', ip_header[2:4])[0]
                        identification = ip_header[4:6]
                        flags_fragment = ip_header[6:8]
                        ttl = ip_header[8]
                        src_ip = ip_header[12:16]
                        dst_ip = ip_header[16:20]
                        
                        # Recalculate total length for new header
                        new_total_length = total_length - (ip_hdr_len - 20)
                        
                        # Create new IP header (20 bytes, no options)
                        new_ip_header = struct.pack('>BBHHHBBH4s4s',
                            0x45, tos, new_total_length,  # Version 4, IHL 5, TOS, Total Length
                            struct.unpack('>H', identification)[0],
                            struct.unpack('>H', flags_fragment)[0],
                            ttl, protocol_field, 0,  # TTL, Protocol, Checksum (0)
                            src_ip, dst_ip
                        )
                        
                        # Get payload after original IP header
                        payload = ip_data[ip_hdr_len:]
                        ip_data = new_ip_header + payload
                    
                    # Create Ethernet header
                    dst_mac = b'\x00\x01\x02\x03\x04\x05'
                    src_mac = b'\x00\x01\x02\x03\x04\x06'
                    ethertype = struct.pack('>H', 0x0800)  # IP
                    
                    eth_header = dst_mac + src_mac + ethertype
                    
                    # Create new packet
                    new_packet = eth_header + ip_data
                    new_incl_len = len(new_packet)
                    new_orig_len = orig_len - SLL_HEADER_SIZE + ETH_HEADER_SIZE - (ip_hdr_len - 20) if ip_hdr_len != 20 else orig_len - SLL_HEADER_SIZE + ETH_HEADER_SIZE
                    
                    # Open output file for this SSRC if not already open
                    if ssrc_hex not in stream_files:
                        filename = f"{output_prefix}_{ssrc_hex}.pcap"
                        stream_files[ssrc_hex] = open(filename, 'wb')
                        stream_files[ssrc_hex].write(global_header)
                        stream_counts[ssrc_hex] = 0
                        print(f"Created stream file: {filename} for SSRC {ssrc_hex}")
                    
                    # Write packet to appropriate stream file
                    new_pkt_header = struct.pack('<IIII', ts_sec, ts_usec, new_incl_len, new_orig_len)
                    stream_files[ssrc_hex].write(new_pkt_header)
                    stream_files[ssrc_hex].write(new_packet)
                    stream_counts[ssrc_hex] += 1

    # Close all output files
    for ssrc_hex, file_handle in stream_files.items():
        file_handle.close()
        print(f"Stream {ssrc_hex}: {stream_counts[ssrc_hex]} packets written")
    
    return list(stream_files.keys())

def analyze_pcap(input_file):
    """Analyze PCAP file and show information about RTP streams"""
    
    SLL_HEADER_SIZE = 16
    ETH_HEADER_SIZE = 14
    stream_info = {}
    total_packets = 0
    rtp_packets = 0
    is_sll_format = False
    
    with open(input_file, 'rb') as fin:
        # Read PCAP global header
        global_header = fin.read(24)
        if len(global_header) != 24:
            raise ValueError("Invalid PCAP file")
        
        # Check link layer type
        linktype = struct.unpack('<I', global_header[20:24])[0]
        if linktype == 113:  # DLT_LINUX_SLL
            is_sll_format = True
            print("PCAP format: Linux SLL (cooked capture)")
        elif linktype == 1:  # DLT_EN10MB
            print("PCAP format: Ethernet")
        else:
            print(f"PCAP format: Unknown (linktype={linktype})")
        
        while True:
            # Read packet record header
            pkt_header = fin.read(16)
            if len(pkt_header) != 16:
                break
                
            ts_sec, ts_usec, incl_len, orig_len = struct.unpack('<IIII', pkt_header)
            packet_data = fin.read(incl_len)
            if len(packet_data) != incl_len:
                break
            
            total_packets += 1
            
            # Parse based on format
            if is_sll_format and incl_len >= SLL_HEADER_SIZE:
                sll_data = packet_data[:SLL_HEADER_SIZE]
                protocol = struct.unpack('>H', sll_data[14:16])[0]
                if protocol == 0x0800:  # IP
                    ip_data = packet_data[SLL_HEADER_SIZE:]
                else:
                    continue
            elif not is_sll_format and incl_len >= ETH_HEADER_SIZE:
                eth_header = packet_data[:ETH_HEADER_SIZE]
                ethertype = struct.unpack('>H', eth_header[12:14])[0]
                if ethertype == 0x0800:  # IP
                    ip_data = packet_data[ETH_HEADER_SIZE:]
                else:
                    continue
            else:
                continue
            
            # Parse IP header
            if len(ip_data) < 20:
                continue
                
            ip_header = ip_data[:20]
            version_ihl = ip_header[0]
            version = (version_ihl >> 4) & 0xF
            ihl = version_ihl & 0xF
            
            if version != 4:
                continue
                
            ip_hdr_len = ihl * 4
            if ip_hdr_len < 20 or ip_hdr_len > len(ip_data):
                continue
            
            protocol_field = ip_header[9]
            if protocol_field != 17:  # UDP
                continue
            
            # Parse UDP header
            if len(ip_data) < ip_hdr_len + 8:
                continue
                
            udp_header = ip_data[ip_hdr_len:ip_hdr_len + 8]
            src_port, dst_port, udp_len, udp_checksum = struct.unpack('>HHHH', udp_header)
            
            # Get RTP data
            rtp_data = ip_data[ip_hdr_len + 8:]
            if len(rtp_data) < 12:
                continue
            
            # Parse RTP header
            rtp_header = rtp_data[:12]
            version_byte = rtp_header[0]
            rtp_version = (version_byte >> 6) & 0x3
            
            if rtp_version != 2:
                continue
            
            rtp_packets += 1
            
            # Extract SSRC
            ssrc = struct.unpack('>I', rtp_header[8:12])[0]
            ssrc_hex = f"0x{ssrc:08x}"
            
            if ssrc_hex not in stream_info:
                stream_info[ssrc_hex] = {
                    'packets': 0,
                    'first_timestamp': ts_sec + ts_usec / 1000000,
                    'last_timestamp': ts_sec + ts_usec / 1000000
                }
            
            stream_info[ssrc_hex]['packets'] += 1
            stream_info[ssrc_hex]['last_timestamp'] = ts_sec + ts_usec / 1000000
    
    # Print analysis results
    print(f"Total packets: {total_packets}")
    print(f"RTP packets: {rtp_packets}")
    print(f"RTP streams found: {len(stream_info)}")
    
    if stream_info:
        print("\nRTP Stream Details:")
        for ssrc, info in sorted(stream_info.items(), key=lambda x: x[1]['packets'], reverse=True):
            duration = info['last_timestamp'] - info['first_timestamp']
            print(f"  SSRC {ssrc}: {info['packets']} packets, duration: {duration:.2f}s")
    
    return stream_info

def main():
    parser = argparse.ArgumentParser(description='Comprehensive PCAP converter and RTP stream processor')
    parser.add_argument('command', choices=['convert', 'split', 'analyze'], 
                       help='Operation to perform')
    parser.add_argument('input', help='Input PCAP file')
    parser.add_argument('output', nargs='?', help='Output file or prefix')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.input):
        print(f"Error: Input file '{args.input}' not found")
        sys.exit(1)
    
    try:
        if args.command == 'convert':
            if not args.output:
                print("Error: Output file required for convert command")
                sys.exit(1)
            packet_count = convert_sll_to_eth(args.input, args.output)
            print(f"Conversion completed successfully - {packet_count} packets converted")
            
        elif args.command == 'split':
            if not args.output:
                print("Error: Output prefix required for split command")
                sys.exit(1)
            ssrcs = split_rtp_streams(args.input, args.output)
            print(f"Successfully split {len(ssrcs)} RTP streams: {', '.join(ssrcs)}")
            
        elif args.command == 'analyze':
            analyze_pcap(args.input)
            
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
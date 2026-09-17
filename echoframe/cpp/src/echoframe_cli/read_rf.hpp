/**
 * @file read_rf.hpp
 * @author BrainEcho Lab
 * @brief RF Data File Reader Utilities (Header)
 * @details This header declares functions and structures for reading RF
 * acquisition data buffers and header information from binary files. It
 * provides an interface for extracting header metadata and loading individual
 * RF data buffers for offline or batch processing in the EchoFrame CLI.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#pragma once
#include <cstdint>
#include <string>
#include <vector>

#include "../beamformer/resources.h"  // for ReceiveSpec

/**
 * @brief Structure representing the header of an RF data file.
 */
struct Header {
    uint64_t version;
    uint64_t headerSize;
    uint64_t buffersStored;
    uint64_t effectiveBufferSize;
    uint64_t paddingBytes;
    uint64_t dataType;  // only v1, otherwise 0
};

/**
 * @brief Structure holding header info and offset to first buffer.
 */
struct HeaderInfo {
    Header hdr;
    std::streamoff data0;  // offset of first buffer
};

/**
 * @brief Reads the header from an RF data file stream.
 * @param f Input file stream.
 * @return HeaderInfo Structure containing header and data offset.
 */
HeaderInfo readHeader(std::ifstream &f);

/**
 * @brief Reads a single RF data buffer from file into a vector.
 * @param f Input file stream.
 * @param H Header structure.
 * @param bufIdx Index of the buffer to read.
 * @param R ReceiveSpec structure describing buffer layout.
 * @param dst Destination vector for the buffer data.
 */
void readOneRFBuffer(std::ifstream &f, const Header &H, size_t bufIdx,
                     const Beamform::ReceiveSpec &R, std::vector<int16_t> &dst);

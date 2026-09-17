/**
 * @file read_rf.cpp
 * @author BrainEcho Lab
 * @brief RF Data File Reader Utilities
 * @details This file implements functions for reading RF acquisition data
 * buffers and header information from binary files. It provides utilities to
 * extract header metadata and load individual RF data buffers for offline or
 * batch processing in the EchoFrame CLI.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include "read_rf.hpp"

#include <fstream>
#include <iostream>
#include <stdexcept>

HeaderInfo readHeader(std::ifstream &f) {
    HeaderInfo I{};
    f.read(reinterpret_cast<char *>(&I.hdr.version), sizeof(uint64_t));

    const size_t n64 = (I.hdr.version == 0) ? 4 : 5;
    f.read(reinterpret_cast<char *>(&I.hdr.headerSize), n64 * sizeof(uint64_t));

    I.data0 = static_cast<std::streamoff>(I.hdr.headerSize);
    return I;
}

void readOneRFBuffer(std::ifstream &f, const Header &H, size_t bufIdx,
                     const Beamform::ReceiveSpec &R,
                     std::vector<int16_t> &dst)  // reused
{
    const size_t elemsPerBuf = static_cast<size_t>(H.effectiveBufferSize);

    if (dst.size() != elemsPerBuf) dst.resize(elemsPerBuf);

    /* absolute byte offset of this buffer in the file */
    std::streamoff off =
        static_cast<std::streamoff>(H.headerSize) +
        static_cast<std::streamoff>(bufIdx) *
            static_cast<std::streamoff>(elemsPerBuf * sizeof(int16_t) +
                                        H.paddingBytes);

    f.seekg(off, std::ios::beg);
    f.read(reinterpret_cast<char *>(dst.data()),
           static_cast<std::streamsize>(elemsPerBuf * sizeof(int16_t)));

    if (static_cast<size_t>(f.gcount()) != elemsPerBuf * sizeof(int16_t))
        throw std::runtime_error("RF buffer #" + std::to_string(bufIdx) +
                                 " too small");
}

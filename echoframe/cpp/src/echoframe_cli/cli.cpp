/**
 * @file cli.cpp
 * @author BrainEcho Lab
 * @brief EchoFrame Command-Line Interface (CLI) Application
 * @details This file implements a command-line tool for batch processing of RF
 * data using the EchoFrame core. It loads scan parameters from a MATLAB .mat
 * file, reads RF acquisition data, and processes each buffer using the
 * EchoFrame backend. The CLI provides a simple interface for offline processing
 * and benchmarking.
 * @version 0.1
 * @date 2025-06-23
 *
 * @copyright Copyright (c) 2025
 *
 */

#include <chrono>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <numeric>
#include <random>
#include <stdexcept>
#include <vector>

#include "../efcore/echoframe_ci_interface.h"
#include "load_specs_from_mat.hpp"
#include "read_rf.hpp"

/**
 * @brief Parses an optional positive iteration count.
 *
 * @param value Command-line value to parse.
 * @return Parsed iteration count.
 * @throws std::runtime_error If `value` is not a positive integer.
 */
static int parseIterationCount(const char *value) {
    char *end = nullptr;
    const long count = std::strtol(value, &end, 10);
    if (*value == '\0' || *end != '\0' || count <= 0 ||
        count > std::numeric_limits<int>::max()) {
        throw std::runtime_error("Iteration count must be a positive integer.");
    }
    return static_cast<int>(count);
}

/**
 * @brief Runs EchoFrame on deterministic synthetic RF for profiler capture.
 *
 * @param ef Initialized EchoFrame handle.
 * @param receiveSpec Receive dimensions defining the RF buffer.
 * @param iterations Number of measured process calls.
 * @throws std::runtime_error If the requested RF buffer is too large.
 */
static void runSyntheticBenchmark(EchoFrameHandle *ef,
                                  const Beamform::ReceiveSpec &receiveSpec,
                                  const int iterations) {
    const size_t nSamples = static_cast<size_t>(receiveSpec.nSamples);
    const size_t nTX = static_cast<size_t>(receiveSpec.nTX);
    const size_t nRepeats = static_cast<size_t>(receiveSpec.nRepeats);
    const size_t nChannels = static_cast<size_t>(receiveSpec.nChannels);
    if (nSamples == 0 || nTX == 0 || nRepeats == 0 || nChannels == 0 ||
        nSamples > std::numeric_limits<size_t>::max() / nTX ||
        nSamples * nTX > std::numeric_limits<size_t>::max() / nRepeats ||
        nSamples * nTX * nRepeats >
            std::numeric_limits<size_t>::max() / nChannels) {
        throw std::runtime_error("Invalid RF dimensions.");
    }

    std::vector<int16_t> rf(nSamples * nTX * nRepeats * nChannels);
    std::minstd_rand generator(0);
    std::uniform_int_distribution<int16_t> distribution(
        std::numeric_limits<int16_t>::min(),
        std::numeric_limits<int16_t>::max());
    for (int16_t &sample : rf) sample = distribution(generator);

    std::cout << "Benchmarking " << rf.size() << " int16 RF samples ("
              << (rf.size() * sizeof(int16_t)) / (1024.0 * 1024.0 * 1024.0)
              << " GiB), " << iterations << " measured iteration(s).\n";
    for (int warmup = 0; warmup < 3; ++warmup) {
        EchoFrameProcess(ef, rf.data(), false);
    }

    std::vector<double> elapsedMs;
    elapsedMs.reserve(iterations);
    for (int iteration = 0; iteration < iterations; ++iteration) {
        const auto start = std::chrono::steady_clock::now();
        EchoFrameProcess(ef, rf.data(), false);
        const auto end = std::chrono::steady_clock::now();
        elapsedMs.push_back(
            std::chrono::duration<double, std::milli>(end - start).count());
    }

    const double meanMs =
        std::accumulate(elapsedMs.begin(), elapsedMs.end(), 0.0) / iterations;
    std::cout << std::fixed << std::setprecision(2)
              << "Mean process time: " << meanMs << " ms\n";
}

/**
 * @brief Main entry point for the EchoFrame CLI application.
 *
 * @param argc Number of command-line arguments.
 * @param argv Array of command-line argument strings.
 * @return Exit code.
 */
int main(int argc, char *argv[]) {
    const bool benchmark = argc >= 2 && std::string(argv[1]) == "--benchmark";
    if ((!benchmark && argc != 3) || (benchmark && (argc < 3 || argc > 4))) {
        std::cerr << "Usage: " << argv[0] << " ScanParameters.mat rf_acq.dat\n"
                  << "       " << argv[0]
                  << " --benchmark ScanParameters.mat [iterations]\n";
        return 1;
    }
    const std::string paramPath = argv[benchmark ? 2 : 1];
    const std::string rfPath = benchmark ? "" : argv[2];

    EchoframeResources res{};
    try {
        loadSpecsFromMat(paramPath, res);
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 2;
    }

    std::unique_ptr<EchoFrameHandle, void (*)(EchoFrameHandle *)> ef(
        EchoFrameCreate(&res, false), EchoFrameDestroy);
    if (!ef) {
        std::cerr << "EchoFrameCreate failed\n";
        return 4;
    }

    if (benchmark) {
        try {
            runSyntheticBenchmark(ef.get(), res.receiveSpec,
                                  argc == 4 ? parseIterationCount(argv[3]) : 1);
        } catch (const std::exception &e) {
            std::cerr << e.what() << '\n';
            return 5;
        }
        return 0;
    }

    /* ---- open RF file once ---- */
    std::ifstream rfFile(rfPath, std::ios::binary);
    if (!rfFile) {
        std::cerr << "Cannot open " << rfPath << '\n';
        return 3;
    }

    /* ---- read header & allocate reusable buffer ---- */
    HeaderInfo Hinfo = readHeader(rfFile);
    std::vector<int16_t> rfBuf;  // reused for every iteration

    std::cout << "Processing " << Hinfo.hdr.buffersStored
              << " RF buffers ...\n";

    try {
        {
            for (size_t b = 0; b < Hinfo.hdr.buffersStored; ++b) {
                // for (size_t b = 0; b < 10; ++b) {
                readOneRFBuffer(rfFile, Hinfo.hdr, b, res.receiveSpec, rfBuf);
                auto t0 = std::chrono::high_resolution_clock::now();

                auto out = EchoFrameProcessAndGetOutputs(ef.get(), rfBuf.data(),
                                                         false);
                auto t1 = std::chrono::high_resolution_clock::now();

                // measure in microseconds; use nanoseconds if you prefer:
                auto elapsed_us =
                    std::chrono::duration_cast<std::chrono::milliseconds>(t1 -
                                                                          t0)
                        .count();

                std::cout << "Buffer " << (b + 1) << '/'
                          << Hinfo.hdr.buffersStored << " done in "
                          << elapsed_us << " ms\n";
            }
        }
    } catch (const std::exception &e) {
        std::cerr << e.what() << std::endl;
    }

    std::cout << "All buffers processed.\n";

    // TODO: implement storage

    std::cout << "Finished\n";
    return 0;
}

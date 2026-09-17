/**
 * @file cuda_event_timer.hpp
 * @author BrainEcho Lab
 * @brief CUDA Event Timing Utility
 * @details This header defines the CudaEventTimer class, which provides
 * convenient methods for timing CUDA GPU operations using named event pairs. It
 * supports multiple timing stages, elapsed time queries, and automatic resource
 * cleanup, enabling detailed performance profiling in the EchoFrame codebase.
 * @version 0.1
 * @date 2025-06-20
 *
 * @copyright Copyright (c) 2025
 *
 */
#pragma once

#include <stdexcept>
#include <string>
#include <unordered_map>

#include <cuda_runtime.h>

/**
 * @brief Utility class for timing CUDA GPU operations using named event pairs.
 */
class CudaEventTimer {
   private:
    /**
     * @brief Structure to store start/stop CUDA events for a timing stage.
     */
    struct EventPair {
        cudaEvent_t startEvent;
        cudaEvent_t stopEvent;
        // Set once a full start/stop pair has run. elapsedTime() must not query
        // an unrecorded pair: cudaEventElapsedTime on unrecorded events returns
        // cudaErrorInvalidResourceHandle (400). Paths that record only some
        // stages (e.g. processPDIOnly) rely on this.
        bool recorded = false;
    };

    /**
     * @brief Map to hold multiple named event pairs for different timing
     * stages.
     */
    std::unordered_map<std::string, EventPair> events;

   public:
    /**
     * @brief Construct a new CudaEventTimer and create common events.
     */
    CudaEventTimer() { createCommonEvents(); }

    /**
     * @brief Destroy the CudaEventTimer and release all CUDA events.
     */
    ~CudaEventTimer() {
        for (auto &event : events) {
            cudaEventDestroy(event.second.startEvent);
            cudaEventDestroy(event.second.stopEvent);
        }
    }

    /**
     * @brief Initialize a named event pair (create start and stop events).
     * @param name Name of the timing stage/event.
     */
    void createEvent(const std::string &name) {
        EventPair eventPair;
        cudaEventCreate(&eventPair.startEvent);
        cudaEventCreate(&eventPair.stopEvent);
        events[name] = eventPair;
    }

    /**
     * @brief Start timing for a specific event (by name).
     * @param name Name of the timing stage/event.
     * @throws std::invalid_argument if the event does not exist.
     */
    void start(const std::string &name) {
        if (events.find(name) == events.end()) {
            throw std::invalid_argument(
                "Event '" + name + "' does not exist. Call createEvent first.");
        }
        cudaEventRecord(events[name].startEvent, 0);
    }

    /**
     * @brief Stop timing for a specific event (by name).
     * @param name Name of the timing stage/event.
     * @throws std::invalid_argument if the event does not exist.
     */
    void stop(const std::string &name) {
        if (events.find(name) == events.end()) {
            throw std::invalid_argument(
                "Event '" + name + "' does not exist. Call createEvent first.");
        }
        cudaEventRecord(events[name].stopEvent, 0);
        cudaEventSynchronize(events[name].stopEvent);
        events[name].recorded = true;
    }

    /**
     * @brief Get elapsed time in seconds for a specific event.
     * @param name Name of the timing stage/event.
     * @return float Elapsed time in seconds.
     * @throws std::invalid_argument if the event does not exist.
     */
    float elapsedTime(const std::string &name) {
        if (events.find(name) == events.end()) {
            throw std::invalid_argument(
                "Event '" + name + "' does not exist. Call createEvent first.");
        }
        // A stage this run never timed. Querying it would raise error 400; report 0.
        if (!events[name].recorded) {
            return 0.0f;
        }
        float milliseconds = 0;
        cudaEventElapsedTime(&milliseconds, events[name].startEvent,
                             events[name].stopEvent);
        return milliseconds / 1000.0f;  // Return in seconds
    }

    /**
     * @brief Create a set of common events for typical EchoFrame processing
     * stages.
     */
    void createCommonEvents() {
        createEvent("RFTransfer");
        createEvent("RFFormatting");
        createEvent("Beamforming");
        createEvent("BFFormatting");
        createEvent("PDIProcessing");
        createEvent("PDITransfer");
        createEvent("BFStorage");
        createEvent("PDIStorage");
        createEvent("TotalTime");
        createEvent("ExternalBFTransfer");
    }

    /**
     * @brief Get the total elapsed time for the "TotalTime" event.
     * @return float Elapsed time in seconds.
     */
    float getTotalElapsedTime() { return elapsedTime("TotalTime"); }
};

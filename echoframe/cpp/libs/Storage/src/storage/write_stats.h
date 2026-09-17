//
// Write instrumentation for the storage layer.
//
// The handler does not copy: the caller's pointer is handed straight to the
// async write, so the disk reads that memory until the write completes. These
// are the completion-side numbers -- the existing per-stage timers stop when a
// write is queued, which is a different thing.
//

#ifndef CUBE_STORAGE_WRITE_STATS_H
#define CUBE_STORAGE_WRITE_STATS_H

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>

namespace Storage {

using StorageClock = std::chrono::steady_clock;

/// Per-file write instrumentation.
struct WriteStats {
    // Queued -> completed. The window in which the source must not be touched.
    uint64_t completed{0};
    // Of those, the ones that carry an elapsed time. Drain completions are
    // counted in `completed` but not here, so the mean below has the right
    // divisor: dividing by `completed` scaled every mean down by whatever
    // fraction of the run settled during the drain, and reported 0 ms for a
    // stream where all of it did.
    uint64_t timed{0};
    double latencySumMs{0.0};
    double latencyMaxMs{0.0};
    double latencyLastMs{0.0};

    // Concurrent outstanding writes; the peak is what must stay below the
    // producer's ring depth.
    int outstanding{0};
    int outstandingHighWater{0};

    // Time storeBuffer spent waiting for a free slot.
    double blockedSumMs{0.0};
    double blockedMaxMs{0.0};

    // Source-change detector (EF_STORAGE_VERIFY).
    uint64_t verified{0};
    uint64_t corrupted{0};
    uint64_t firstCorruptRecord{0};
    bool anyCorrupt{false};

    double latencyMeanMs() const {
        return timed ? latencySumMs / static_cast<double>(timed) : 0.0;
    }

    void recordLatency(double ms) {
        ++completed;
        ++timed;
        latencyLastMs = ms;
        latencySumMs += ms;
        if (ms > latencyMaxMs) latencyMaxMs = ms;
    }

    // A write that settled during the final drain. Counted, but its elapsed
    // time is the wait for the file to close rather than the disk, so it is
    // left out of the latency.
    void recordCompletedUntimed() { ++completed; }

    void recordBlocked(double ms) {
        blockedSumMs += ms;
        if (ms > blockedMaxMs) blockedMaxMs = ms;
    }

    void writeIssued() {
        ++outstanding;
        if (outstanding > outstandingHighWater) outstandingHighWater = outstanding;
    }

    void writeCompleted() {
        if (outstanding > 0) --outstanding;
    }

    void recordCorrupt(uint64_t recordIndex) {
        if (!anyCorrupt) {
            anyCorrupt = true;
            firstCorruptRecord = recordIndex;
        }
        ++corrupted;
    }
};

/// A write held back by EF_STORAGE_DELAY_WRITE_MS. The record index is fixed
/// when the caller hands the buffer over, so deferring cannot reorder records.
struct PendingWrite {
    void *buffer{nullptr};
    uint64_t recordIndex{0};
    uint64_t digest{0};
    size_t digestBytes{0};
    StorageClock::time_point queuedAt{};
    StorageClock::time_point releaseAt{};
};

/// Debug knobs, re-read at every init: echoframe_mex calls mexLock(), so a
/// value cached for the process would outlive the session it was set for.
/// How much the library prints. Shared by the storage layer and the core, so
/// one setting covers both sides rather than each having its own switch.
enum LogLevel {
    kLogQuiet = 0,    ///< warnings and errors only
    kLogNormal = 1,   ///< + banners and end-of-recording summaries (default)
    kLogVerbose = 2,  ///< + one line per acquisition frame
    kLogTrace = 3     ///< + per-stage timings and per-frame storage deltas
};

struct StorageDebugFlags {
    bool verify{false};   ///< EF_STORAGE_VERIFY: detect a source overwritten in flight
    int probes{64};       ///< EF_STORAGE_VERIFY_PROBES: sampled chunks per buffer
    int delayWriteMs{0};  ///< EF_STORAGE_DELAY_WRITE_MS: hold writes back (testing only)
    bool report{true};    ///< EF_STORAGE_STATS: print the per-file summary on close
    /// EF_LOG_LEVEL: quiet|normal|verbose|trace, or 0-3. Unlike the four above,
    /// this is re-read on every MEX call -- see refreshLogLevel.
    int logLevel{kLogNormal};
    /// False until the environment has been read into EVERY field once. Without
    /// it the defaults above are indistinguishable from a real reading of them.
    /// refreshLogLevel does not set it, because it reads one field.
    bool envRead{false};
};

namespace detail {
inline const char *envRaw(const char *name) {
    const char *v = std::getenv(name);
    return (v == nullptr || v[0] == '\0') ? nullptr : v;
}

inline bool envFlag(const char *name, bool fallback) {
    const char *v = envRaw(name);
    return v == nullptr ? fallback : (v[0] == '1');
}

inline int envLogLevel(const char *name, int fallback) {
    const char *v = envRaw(name);
    if (v == nullptr) return fallback;
    // Names first, because they are what the documentation tells people to set.
    // Digits stay accepted so a script can compare or increment a level.
    if (v[0] == 'q' || v[0] == 'Q') return kLogQuiet;
    if (v[0] == 'n' || v[0] == 'N') return kLogNormal;
    if (v[0] == 'v' || v[0] == 'V') return kLogVerbose;
    if (v[0] == 't' || v[0] == 'T') return kLogTrace;
    char *end = nullptr;
    long parsed = std::strtol(v, &end, 10);
    if (end == v || parsed < kLogQuiet || parsed > kLogTrace) return fallback;
    // Anything left after the digits means this was never a level: "2.7" is a
    // typo, not verbose. MATLAB's ef_log rejects it the same way, so no value
    // can mean one thing here and another there.
    while (*end == ' ' || *end == '\t') ++end;
    if (*end != '\0') return fallback;
    return static_cast<int>(parsed);
}

inline int envInt(const char *name, int fallback) {
    const char *v = envRaw(name);
    if (v == nullptr) return fallback;
    char *end = nullptr;
    long parsed = std::strtol(v, &end, 10);
    if (end == v || parsed < 0) return fallback;
    return static_cast<int>(parsed);
}
}  // namespace detail

inline StorageDebugFlags &storageDebugFlagsMutable() {
    static StorageDebugFlags flags;
    return flags;
}

inline const StorageDebugFlags &refreshStorageDebugFlags();

/// The flags, populating them from the environment if nothing has yet.
///
/// The lazy first read matters: a freshly loaded module starts at the struct's
/// defaults, and kLogNormal is indistinguishable from "the environment says
/// normal". Anything that printed before the first refreshStorageDebugFlags()
/// therefore printed at normal no matter what EF_LOG_LEVEL said, and the
/// symptom is a line that fails to go quiet -- no crash, nothing to notice.
/// Reading on first use instead means a site that has not been audited for
/// ordering is still right the first time round.
///
/// The storage knobs still change only at an init: verify, probes,
/// delayWriteMs and report configure a recording that is already open, so
/// re-reading them mid-recording would change the rules under it. The log level
/// is different and is refreshed per call -- see refreshLogLevel.
inline const StorageDebugFlags &storageDebugFlags() {
    const StorageDebugFlags &f = storageDebugFlagsMutable();
    if (!f.envRead) return refreshStorageDebugFlags();
    return f;
}

/// Re-read every knob. Returns them so callers can print the configuration.
inline const StorageDebugFlags &refreshStorageDebugFlags() {
    StorageDebugFlags &f = storageDebugFlagsMutable();
    f.envRead = true;
    f.verify = detail::envFlag("EF_STORAGE_VERIFY", false);
    f.probes = detail::envInt("EF_STORAGE_VERIFY_PROBES", 64);
    if (f.probes < 2) f.probes = 2;
    f.delayWriteMs = detail::envInt("EF_STORAGE_DELAY_WRITE_MS", 0);
    f.report = detail::envFlag("EF_STORAGE_STATS", true);
    f.logLevel = detail::envLogLevel("EF_LOG_LEVEL", kLogNormal);
    return f;
}

/// Re-read ONLY the log level. Called at the top of the MEX dispatch, so
/// verbosity responds to EF_LOG_LEVEL immediately rather than at the next init.
///
/// Why per call. ef_log re-reads on every call, so with the level latched at
/// init the two halves of the same log disagreed for the rest of a session: set
/// EF_LOG_LEVEL=verbose to chase a problem and the MATLAB side obeyed while the
/// C++ side did not. Worse in the other direction -- a level raised mid-session
/// produced nothing at all until something happened to re-init, which is a
/// diagnostic control ignoring you at the moment you reach for it. Nobody chose
/// that; it was where the refresh happened to sit.
///
/// Deliberately does NOT set envRead. That flag means "the environment has been
/// read into every field", and this reads one. Setting it here would skip the
/// lazy population in storageDebugFlags() and leave verify, probes,
/// delayWriteMs and report on their struct defaults for the life of the module
/// -- silently, and looking like the storage knobs had stopped working.
inline void refreshLogLevel() {
    storageDebugFlagsMutable().logLevel =
        detail::envLogLevel("EF_LOG_LEVEL", kLogNormal);
}

/// True when the library should print something of this level.
inline bool logAtLeast(int level) {
    return storageDebugFlags().logLevel >= level;
}

/// FNV-1a over evenly spaced chunks, always including the first and last.
/// Sampling keeps this cheap for large buffers; a producer refilling its buffer
/// rewrites the whole frame, so a spread of probes is enough to see it.
inline uint64_t probeDigest(const void *buffer, size_t bytes, int probes) {
    constexpr uint64_t kOffsetBasis = 1469598103934665603ULL;
    constexpr uint64_t kPrime = 1099511628211ULL;
    constexpr size_t kChunk = 64;

    const unsigned char *p = static_cast<const unsigned char *>(buffer);
    uint64_t hash = kOffsetBasis;
    if (p == nullptr || bytes == 0) return hash;

    auto absorb = [&](const unsigned char *at, size_t n) {
        for (size_t i = 0; i < n; ++i) {
            hash ^= static_cast<uint64_t>(at[i]);
            hash *= kPrime;
        }
    };

    if (bytes <= static_cast<size_t>(probes) * kChunk) {
        absorb(p, bytes);
        return hash;
    }

    const size_t span = bytes - kChunk;  // offset of the last chunk
    const size_t steps = static_cast<size_t>(probes) - 1;
    for (size_t i = 0; i <= steps; ++i) absorb(p + (span * i) / steps, kChunk);

    // Fold in the length so a size change cannot alias.
    hash ^= static_cast<uint64_t>(bytes);
    hash *= kPrime;
    return hash;
}

inline double msSince(const StorageClock::time_point &t0) {
    return std::chrono::duration<double, std::milli>(StorageClock::now() - t0)
        .count();
}

}  // namespace Storage

#endif  // CUBE_STORAGE_WRITE_STATS_H

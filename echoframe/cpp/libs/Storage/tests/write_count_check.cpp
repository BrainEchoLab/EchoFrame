// Checks that the write instrumentation counts exactly one completion per
// stored buffer, with and without the deferred-write knob, and that the source
// digest is checked on every one of them.
//
// The existing write_stats_check covers the knobs and the digest in isolation;
// this drives a real Handler through a file, which is where the counting lives.
//
//   cl /EHsc /std:c++17 /I ..\src write_count_check.cpp
//
// Needs SeManageVolumePrivilege on Windows: run elevated. No MATLAB or GPU.
// Exits non-zero on failure.

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "storage/Handler.t.hpp"

static int failures = 0;

static void expect(const char *what, long got, long want) {
    if (got != want) {
        std::printf("  FAIL %-34s got %ld, want %ld\n", what, got, want);
        ++failures;
    } else {
        std::printf("  ok   %-34s %ld\n", what, got);
    }
}

static void setEnv(const char *name, const char *value) {
#ifdef _WIN32
    _putenv_s(name, value);
#else
    if (value[0] == '\0')
        unsetenv(name);
    else
        setenv(name, value, 1);
#endif
}

// One buffer, sector aligned so FILE_FLAG_NO_BUFFERING accepts it without
// padding. The Handler takes its buffer size in elements, not bytes.
// Large enough that a write is genuinely in flight for a while: the queue has
// to reach capacity for getAvailableWorker to take its blocking branch, which
// is where a worker can be reused before its completion is consumed.
static constexpr size_t kBufferBytes = 128u << 20;
static constexpr size_t kElems = kBufferBytes / sizeof(int16_t);
static constexpr int kSlots = 4;    // producer ring, as a real stream has
static constexpr int kFrames = 10;  // more than the ring, so slots are reused

// Runs kFrames stores through a Handler and returns its stats. paceMs spaces
// the stores out, so held writes are released between them rather than all at
// the drain -- that is the acquisition's regime, and the one that races.
static Storage::WriteStats runStream(const char *label, const char *delayMs,
                                     const char *verify, int paceMs = 0) {
    setEnv("EF_STORAGE_DELAY_WRITE_MS", delayMs);
    setEnv("EF_STORAGE_VERIFY", verify);
    setEnv("EF_STORAGE_STATS", "0");   // the summary is not what is under test
    Storage::refreshStorageDebugFlags();

    // Distinct source slots, refilled each time round, like a producer ring.
    static std::vector<std::vector<int16_t>> slots;
    slots.assign(kSlots, std::vector<int16_t>(kElems, 0));

    std::string path = std::string(std::getenv("TEMP") ? std::getenv("TEMP") : ".") +
                       "\\ef_write_count_" + label + ".dat";
    std::remove(path.c_str());

    std::printf("  [%s] file %s\n", label, path.c_str());
    std::string dtype = "int16";
    Storage::WriteStats stats;
    {
        Storage::Handler<int16_t> h(path, dtype, kElems, 1, kFrames + 4,
                                    kSlots, false, false);
        // storeBuffer is the whole API: it records the pointer and issues the
        // write itself. initiateStorage() is not an opener -- it writes the
        // current slot, and calling it here would read an unset one.
        for (int f = 0; f < kFrames; ++f) {
            auto &src = slots[f % kSlots];
            for (size_t i = 0; i < kElems; ++i)
                src[i] = static_cast<int16_t>(f * 7 + i);
            h.storeBuffer(src.data());
            if (paceMs > 0)
                std::this_thread::sleep_for(std::chrono::milliseconds(paceMs));
        }
        // What the core does before its producers are torn down.
        h.finishWrites();
        stats = h.getWriteStats();
    }
    std::remove(path.c_str());
    return stats;
}

int main() {
    // Unbuffered: a crash mid-run must not swallow what got that far.
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    std::printf("no delay, verify on\n");
    Storage::WriteStats s = runStream("plain", "0", "1");
    expect("completed == frames stored", static_cast<long>(s.completed), kFrames);
    expect("verified == frames stored", static_cast<long>(s.verified), kFrames);
    expect("corrupted", static_cast<long>(s.corrupted), 0);

    std::printf("deferred writes (EF_STORAGE_DELAY_WRITE_MS), verify on\n");
    Storage::WriteStats d = runStream("delayed", "40", "1");
    expect("completed == frames stored", static_cast<long>(d.completed), kFrames);
    expect("verified == frames stored", static_cast<long>(d.verified), kFrames);
    expect("corrupted", static_cast<long>(d.corrupted), 0);

    // The acquisition's regime: stores spaced out, with the delay long enough
    // that writes are released between them. A worker settled by the poll can
    // then be handed out again before its completion packet is consumed.
    std::printf("deferred writes, paced like an acquisition\n");
    Storage::WriteStats p = runStream("paced", "200", "1", 30);
    expect("completed == frames stored", static_cast<long>(p.completed), kFrames);
    expect("verified == frames stored", static_cast<long>(p.verified), kFrames);
    expect("corrupted", static_cast<long>(p.corrupted), 0);

    std::printf("no delay, verify off\n");
    Storage::WriteStats n = runStream("noverify", "0", "0");
    expect("completed == frames stored", static_cast<long>(n.completed), kFrames);
    expect("verified stays zero", static_cast<long>(n.verified), 0);

    setEnv("EF_STORAGE_DELAY_WRITE_MS", "");
    setEnv("EF_STORAGE_VERIFY", "");
    setEnv("EF_STORAGE_STATS", "");

    if (failures)
        std::printf("\nFAILED (%d)\n", failures);
    else
        std::printf("\nall passed\n");
    return failures ? 1 : 0;
}

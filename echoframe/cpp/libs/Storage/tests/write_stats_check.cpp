// Checks that the storage debug knobs are re-read rather than cached, that
// EF_LOG_LEVEL parses as MATLAB's ef_log parses it and refreshes per call, and
// that the source digest notices an overwritten buffer. Needs no MATLAB or GPU.
//
//   cl /EHsc /std:c++17 /I ..\src write_stats_check.cpp
//   g++ -std=c++17 -I ../src write_stats_check.cpp -o write_stats_check
//
// Exits non-zero on failure.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "storage/write_stats.h"

static int failures = 0;

static void expect(const char *what, long got, long want) {
    if (got != want) {
        std::printf("  FAIL %-30s got %ld, want %ld\n", what, got, want);
        ++failures;
    } else {
        std::printf("  ok   %-30s %ld\n", what, got);
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

static void clearKnobs() {
    setEnv("EF_STORAGE_VERIFY", "");
    setEnv("EF_STORAGE_VERIFY_PROBES", "");
    setEnv("EF_STORAGE_DELAY_WRITE_MS", "");
    setEnv("EF_STORAGE_STATS", "");
}

int main() {
    std::printf("knobs unset -> defaults\n");
    clearKnobs();
    Storage::refreshStorageDebugFlags();
    expect("verify", Storage::storageDebugFlags().verify, 0);
    expect("probes", Storage::storageDebugFlags().probes, 64);
    expect("delayWriteMs", Storage::storageDebugFlags().delayWriteMs, 0);
    expect("report", Storage::storageDebugFlags().report, 1);

    // The values must follow the environment, as they do when a MATLAB session
    // calls setenv between runs.
    std::printf("knobs changed mid-session\n");
    setEnv("EF_STORAGE_VERIFY", "1");
    setEnv("EF_STORAGE_VERIFY_PROBES", "256");
    setEnv("EF_STORAGE_DELAY_WRITE_MS", "1500");
    setEnv("EF_STORAGE_STATS", "0");
    Storage::refreshStorageDebugFlags();
    expect("verify", Storage::storageDebugFlags().verify, 1);
    expect("probes", Storage::storageDebugFlags().probes, 256);
    expect("delayWriteMs", Storage::storageDebugFlags().delayWriteMs, 1500);
    expect("report", Storage::storageDebugFlags().report, 0);

    std::printf("knobs cleared again\n");
    clearKnobs();
    Storage::refreshStorageDebugFlags();
    expect("verify", Storage::storageDebugFlags().verify, 0);
    expect("probes", Storage::storageDebugFlags().probes, 64);
    expect("delayWriteMs", Storage::storageDebugFlags().delayWriteMs, 0);
    expect("report", Storage::storageDebugFlags().report, 1);

    std::printf("EF_RF_STORAGE_BUFFERS\n");
    setEnv("EF_RF_STORAGE_BUFFERS", "");
    expect("unset", Storage::detail::envInt("EF_RF_STORAGE_BUFFERS", 0), 0);
    setEnv("EF_RF_STORAGE_BUFFERS", "8");
    expect("set to 8", Storage::detail::envInt("EF_RF_STORAGE_BUFFERS", 0), 8);
    setEnv("EF_RF_STORAGE_BUFFERS", "4");
    expect("set to 4", Storage::detail::envInt("EF_RF_STORAGE_BUFFERS", 0), 4);
    setEnv("EF_RF_STORAGE_BUFFERS", "junk");
    expect("junk falls back",
           Storage::detail::envInt("EF_RF_STORAGE_BUFFERS", 0), 0);
    setEnv("EF_RF_STORAGE_BUFFERS", "");

    // A value must not mean one thing here and another in MATLAB's ef_log, so
    // the rejections matter as much as the accepted spellings.
    std::printf("EF_LOG_LEVEL parsing\n");
    setEnv("EF_LOG_LEVEL", "");
    expect("unset falls back",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogNormal);
    setEnv("EF_LOG_LEVEL", "quiet");
    expect("quiet",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogQuiet);
    setEnv("EF_LOG_LEVEL", "VERBOSE");
    expect("case-insensitive",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogVerbose);
    setEnv("EF_LOG_LEVEL", "t");
    expect("first letter is enough",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogTrace);
    setEnv("EF_LOG_LEVEL", "3");
    expect("plain digit",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogTrace);
    setEnv("EF_LOG_LEVEL", "9");
    expect("out of range falls back",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogNormal);
    setEnv("EF_LOG_LEVEL", "2.7");
    expect("trailing junk falls back",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogNormal);
    setEnv("EF_LOG_LEVEL", "0x2");
    expect("hex falls back",
           Storage::detail::envLogLevel("EF_LOG_LEVEL", Storage::kLogNormal),
           Storage::kLogNormal);

    std::printf("refreshLogLevel is live and leaves the latched knobs alone\n");
    Storage::StorageDebugFlags &flags = Storage::storageDebugFlagsMutable();
    flags = Storage::StorageDebugFlags{};  // a freshly loaded module
    setEnv("EF_STORAGE_VERIFY", "1");
    setEnv("EF_STORAGE_VERIFY_PROBES", "256");
    setEnv("EF_STORAGE_DELAY_WRITE_MS", "1500");
    setEnv("EF_STORAGE_STATS", "0");
    setEnv("EF_LOG_LEVEL", "trace");

    Storage::refreshLogLevel();
    expect("level follows env", flags.logLevel, Storage::kLogTrace);
    // It reads one field, so it must not claim the whole environment has been
    // read. If it did, the lazy population below would be skipped and the four
    // knobs would stay on their struct defaults for the life of the module.
    expect("envRead still false", flags.envRead, 0);

    const Storage::StorageDebugFlags &lazy = Storage::storageDebugFlags();
    expect("verify still populated", lazy.verify, 1);
    expect("probes still populated", lazy.probes, 256);
    expect("delayWriteMs still populated", lazy.delayWriteMs, 1500);
    expect("report still populated", lazy.report, 0);
    expect("level survives the refresh", lazy.logLevel, Storage::kLogTrace);

    std::printf("logAtLeast gates on the current level\n");
    setEnv("EF_LOG_LEVEL", "quiet");
    Storage::refreshLogLevel();
    expect("quiet suppresses normal", Storage::logAtLeast(Storage::kLogNormal),
           0);
    expect("quiet keeps quiet", Storage::logAtLeast(Storage::kLogQuiet), 1);
    setEnv("EF_LOG_LEVEL", "verbose");
    Storage::refreshLogLevel();
    expect("verbose allows verbose", Storage::logAtLeast(Storage::kLogVerbose),
           1);
    expect("verbose suppresses trace", Storage::logAtLeast(Storage::kLogTrace),
           0);
    setEnv("EF_LOG_LEVEL", "");
    clearKnobs();

    std::printf("digest notices an overwritten source\n");
    static unsigned char buf[1 << 20];  // static: 1 MB overflows the default stack
    for (size_t i = 0; i < sizeof(buf); ++i)
        buf[i] = static_cast<unsigned char>(i);
    const uint64_t before = Storage::probeDigest(buf, sizeof(buf), 64);
    expect("unchanged buffer matches",
           Storage::probeDigest(buf, sizeof(buf), 64) == before, 1);

    buf[0] ^= 0xFF;  // an RF frame carries its time tag in the first samples
    expect("first byte", Storage::probeDigest(buf, sizeof(buf), 64) != before, 1);
    buf[0] ^= 0xFF;

    buf[sizeof(buf) - 1] ^= 0xFF;
    expect("last byte", Storage::probeDigest(buf, sizeof(buf), 64) != before, 1);
    buf[sizeof(buf) - 1] ^= 0xFF;

    for (size_t i = 0; i < sizeof(buf); ++i)
        buf[i] = static_cast<unsigned char>(i + 1);
    expect("whole frame refilled",
           Storage::probeDigest(buf, sizeof(buf), 64) != before, 1);

    if (failures)
        std::printf("\nFAILED (%d)\n", failures);
    else
        std::printf("\nall passed\n");
    return failures ? 1 : 0;
}

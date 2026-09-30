// Checks how a statx(STATX_DIOALIGN) result is resolved into the O_DIRECT
// offset/length and buffer-address alignments.
//
// The case that matters is a mask without STATX_DIOALIGN, which a pre-6.1
// kernel or a filesystem that does not implement the query returns: storage
// used to throw there, so it could not write at all on such a host. That mask
// cannot be produced by a real filesystem on a modern kernel, hence driving
// resolveDioAlignment() directly.
//
//   c++ -std=c++17 -I ..\src linux_alignment_check.cpp
//
// Linux only: it includes the Linux backend's statx header. No MATLAB, no GPU,
// no file I/O. Exits non-zero on failure.

#include <cstdint>
#include <cstdio>

#include "storage/Linux/linux_statx.h"

static int failures = 0;

static void expect(const char *what, uint64_t got, uint64_t want) {
    if (got != want) {
        std::printf("  FAIL %-46s got %llu, want %llu\n", what,
                    static_cast<unsigned long long>(got),
                    static_cast<unsigned long long>(want));
        ++failures;
    } else {
        std::printf("  ok   %-46s %llu\n", what,
                    static_cast<unsigned long long>(got));
    }
}

static void expectTrue(const char *what, bool got) {
    if (!got) {
        std::printf("  FAIL %-46s false, want true\n", what);
        ++failures;
    } else {
        std::printf("  ok   %-46s true\n", what);
    }
}

using Storage::detail::EfStatx;
using Storage::detail::kEfStatxBasicStats;
using Storage::detail::kEfStatxDioalign;
using Storage::detail::resolveDioAlignment;

int main() {
    const uint64_t page = Storage::detail::pageSize();
    expectTrue("page size is a power of two", (page & (page - 1)) == 0);
    expectTrue("page size is at least 4096", page >= 4096);

    // A 512e drive: 512 B minimum offset/length alignment, but the block size
    // is the 4096 B physical sector, which is where writes should land.
    {
        EfStatx stx{};
        stx.stx_mask = kEfStatxDioalign | kEfStatxBasicStats;
        stx.stx_blksize = 4096;
        stx.stx_dio_offset_align = 512;
        stx.stx_dio_mem_align = 512;
        const auto a = resolveDioAlignment(stx);
        expectTrue("512e: reported", a.reported);
        expect("512e: sector size prefers the physical sector", a.sectorSize,
               4096);
        expect("512e: mem align is taken verbatim", a.memAlign, 512);
    }

    // A block size that is not a multiple of the minimum alignment is not a
    // usable sector size, so the minimum stands.
    {
        EfStatx stx{};
        stx.stx_mask = kEfStatxDioalign | kEfStatxBasicStats;
        stx.stx_blksize = 3000;
        stx.stx_dio_offset_align = 512;
        stx.stx_dio_mem_align = 512;
        const auto a = resolveDioAlignment(stx);
        expect("non-multiple block size keeps the minimum", a.sectorSize, 512);
    }

    // STATX_BASIC_STABS absent, so stx_blksize cannot be trusted.
    {
        EfStatx stx{};
        stx.stx_mask = kEfStatxDioalign;
        stx.stx_blksize = 4096;  // must be ignored
        stx.stx_dio_offset_align = 512;
        stx.stx_dio_mem_align = 4096;
        const auto a = resolveDioAlignment(stx);
        expect("no basic stats: sector size is the minimum", a.sectorSize, 512);
    }

    // tmpfs: reports the query but does not enforce it. The caller rejects
    // these on the zero, which is why they must come through as 0 rather than
    // as the conservative fallback.
    {
        EfStatx stx{};
        stx.stx_mask = kEfStatxDioalign | kEfStatxBasicStats;
        stx.stx_blksize = 4096;
        stx.stx_dio_offset_align = 0;
        stx.stx_dio_mem_align = 0;
        const auto a = resolveDioAlignment(stx);
        expectTrue("tmpfs: reported", a.reported);
        expect("tmpfs: sector size is 0", a.sectorSize, 0);
        expect("tmpfs: mem align is 0", a.memAlign, 0);
    }

    // The regression: no STATX_DIOALIGN falls back to the page size even when
    // a smaller block size is available.
    {
        EfStatx stx{};
        stx.stx_mask = kEfStatxBasicStats;
        stx.stx_blksize = 512;
        const auto a = resolveDioAlignment(stx);
        expectTrue("no STATX_DIOALIGN: not reported", !a.reported);
        expect("no STATX_DIOALIGN: sector size is the page size", a.sectorSize,
               page);
        expect("no STATX_DIOALIGN: mem align is the page size", a.memAlign,
               page);
    }

    // The regression with nothing to go on at all: the page size is still used.
    {
        EfStatx stx{};
        stx.stx_mask = kEfStatxBasicStats;
        stx.stx_blksize = 0;  // must be ignored
        const auto a = resolveDioAlignment(stx);
        expectTrue("empty mask: not reported", !a.reported);
        expect("empty mask: sector size is the page size", a.sectorSize, page);
        expect("empty mask: mem align is the page size", a.memAlign, page);
    }

    {
        EfStatx stx{};
        stx.stx_mask = 0;
        const auto a = resolveDioAlignment(stx);
        expect("no mask at all: sector size is the page size", a.sectorSize,
               page);
        expect("no mask at all: mem align is the page size", a.memAlign, page);
    }

    if (failures) {
        std::printf("\n%d check(s) failed\n", failures);
        return 1;
    }
    std::printf("\nall checks passed\n");
    return 0;
}

//
// O_DIRECT alignment reported by statx(STATX_DIOALIGN), and how to resolve it
// into the two alignments EchoFrame needs.
//
// Split out of LinuxFileIO.t.hpp so the resolution can be exercised directly
// from tests/linux_alignment_check.cpp. It is header-only and safe to include
// from more than one translation unit.
//

#ifndef CUBE_STORAGE_LINUX_STATX_H
#define CUBE_STORAGE_LINUX_STATX_H

#include <unistd.h>

#include <cstdint>

namespace Storage {
namespace detail {

// The kernel's statx layout, transcribed. glibc's struct statx and
// <linux/stat.h> cannot be included together (same tag, different members),
// and neither reliably declares stx_dio_mem_align/stx_dio_offset_align. The
// raw syscall is used rather than glibc's wrapper, which is typed against
// glibc's own struct.
struct EfStatxTimestamp {
    int64_t tv_sec;
    uint32_t tv_nsec;
    int32_t __reserved;
};

struct EfStatx {
    uint32_t stx_mask;
    uint32_t stx_blksize;
    uint64_t stx_attributes;
    uint32_t stx_nlink;
    uint32_t stx_uid;
    uint32_t stx_gid;
    uint16_t stx_mode;
    uint16_t __spare0[1];
    uint64_t stx_ino;
    uint64_t stx_size;
    uint64_t stx_blocks;
    uint64_t stx_attributes_mask;
    EfStatxTimestamp stx_atime;
    EfStatxTimestamp stx_btime;
    EfStatxTimestamp stx_ctime;
    EfStatxTimestamp stx_mtime;
    uint32_t stx_rdev_major;
    uint32_t stx_rdev_minor;
    uint32_t stx_dev_major;
    uint32_t stx_dev_minor;
    uint64_t stx_mnt_id;
    uint32_t stx_dio_mem_align;
    uint32_t stx_dio_offset_align;
    uint64_t __spare3[12];  // reserved space for fields added after these
};

// statx(2) takes no buffer-length argument: the kernel always writes a fixed
// 256-byte struct. A smaller struct here would be overflowed by the syscall.
static_assert(sizeof(EfStatx) == 256,
              "EfStatx must match the kernel's fixed statx(2) ABI size");

constexpr uint32_t kEfStatxDioalign = 0x00002000U;  // STATX_DIOALIGN
constexpr uint32_t kEfStatxBasicStats =
    0x000007ffU;  // STATX_BASIC_STATS (covers stx_blksize)

/// @return The runtime page size, which bounds any O_DIRECT buffer-address
/// alignment. Falls back to 4096 if the query fails, which is the smallest
/// page size Linux allows on the platforms EchoFrame targets.
inline uint64_t pageSize() {
    const long ps = sysconf(_SC_PAGESIZE);
    return ps > 0 ? static_cast<uint64_t>(ps) : 4096;
}

/// The two alignments an O_DIRECT write has to satisfy, and whether the
/// filesystem reported them.
struct DioAlignment {
    uint64_t sectorSize;  // required offset/length alignment
    uint64_t memAlign;    // required buffer-address alignment
    bool reported;        // false when the kernel did not report STATX_DIOALIGN
};

/// Resolve a statx result into the O_DIRECT offset/length and buffer-address
/// alignments.
///
/// Offset/length alignment (stx_dio_offset_align) and buffer-address alignment
/// (stx_dio_mem_align) are reported separately and are not guaranteed equal.
/// Both come back as 0 from a filesystem that accepts O_DIRECT without
/// enforcing it (e.g. tmpfs); the caller is expected to reject that, so they
/// are passed through rather than replaced by the conservative fallback.
///
/// A kernel that does not report STATX_DIOALIGN at all -- before Linux 6.1, or
/// a filesystem that does not implement the query -- yields `reported == false`
/// and a conservative alignment: stx_blksize as the sector size when the
/// kernel reported it, else the page size, and the page size for the buffer
/// address. The page size is a multiple of every sector size such a
/// filesystem uses, so a buffer aligned to it satisfies any of them.
inline DioAlignment resolveDioAlignment(const EfStatx &stx) {
    if (!(stx.stx_mask & kEfStatxDioalign)) {
        const uint64_t fallback =
            (stx.stx_mask & kEfStatxBasicStats) && stx.stx_blksize > 0
                ? stx.stx_blksize
                : pageSize();
        return {fallback, pageSize(), false};
    }

    if (stx.stx_dio_offset_align == 0 || stx.stx_dio_mem_align == 0)
        return {0, 0, true};

    // dio_offset_align is only the required minimum: on a 512e drive (512 B
    // logical, 4096 B physical) it is 512, and writing at that alignment forces
    // a device-side read-modify-write per block. Prefer stx_blksize (typically
    // the physical sector) when it is a whole multiple of dio_offset_align, so
    // writes land on physical-sector boundaries; fall back to dio_offset_align.
    uint64_t sectorSize = stx.stx_dio_offset_align;
    if ((stx.stx_mask & kEfStatxBasicStats) && stx.stx_blksize > sectorSize &&
        stx.stx_blksize % stx.stx_dio_offset_align == 0) {
        sectorSize = stx.stx_blksize;
    }
    return {sectorSize, stx.stx_dio_mem_align, true};
}

}  // namespace detail
}  // namespace Storage

#endif  // CUBE_STORAGE_LINUX_STATX_H

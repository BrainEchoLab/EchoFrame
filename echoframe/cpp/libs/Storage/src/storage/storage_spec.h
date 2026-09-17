#pragma once
namespace Storage {

struct StorageSpec {
    bool save{false};
    bool crop{false};
    bool preallocateFullFile{false};  // New flag for full file preallocation
    std::string filepath;
    std::string dataType;
    unsigned long long bufferSize{0};
    int maxNBuffers{0};
    int nWritesPerBuffer{0};
    int nBuffers{0};
};
}  // namespace Storage
//
// Created by petros on 25/04/2022.
//

#ifndef CUBE_STORAGE_ERROR_H
#define CUBE_STORAGE_ERROR_H

#include <stdexcept>

namespace Storage {
    class storageException : public std::runtime_error {

    public:
        explicit storageException(const std::string &msg) : std::runtime_error(msg) {};
    };
}

#endif //CUBE_STORAGE_ERROR_H

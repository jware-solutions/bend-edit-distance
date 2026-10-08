// Global, unlimited, unit-cost distance oracle using the vendored C++ Edlib.
#include "edlib.h"

#include <climits>
#include <cstdio>
#include <cstring>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "Expected QUERY TARGET\n");
        return 2;
    }
    const auto query_length = std::strlen(argv[1]);
    const auto target_length = std::strlen(argv[2]);
    if (query_length > INT_MAX || target_length > INT_MAX) {
        std::fprintf(stderr, "Sequence length exceeds Edlib's int range\n");
        return 2;
    }
    const auto config = edlibNewAlignConfig(
        -1, EDLIB_MODE_NW, EDLIB_TASK_DISTANCE, nullptr, 0);
    auto result = edlibAlign(argv[1], static_cast<int>(query_length),
                             argv[2], static_cast<int>(target_length), config);
    const int status = result.status;
    const int distance = status == EDLIB_STATUS_OK ? result.editDistance : -1;
    edlibFreeAlignResult(result);
    if (status != EDLIB_STATUS_OK || distance < 0) {
        std::fprintf(stderr, "edlibAlign failed (status=%d)\n", status);
        return 1;
    }
    std::printf("%d\n", distance);
    return 0;
}

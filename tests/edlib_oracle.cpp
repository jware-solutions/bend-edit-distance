// Structured oracle against the pinned, vendored Edlib implementation.
#include "edlib.h"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {
bool ascii(const char* value, std::size_t maximum) {
    const auto length = std::strlen(value);
    if (length > maximum) return false;
    for (std::size_t i = 0; i < length; ++i)
        if (static_cast<unsigned char>(value[i]) > 127) return false;
    return true;
}

bool threshold(const char* text, int& value) {
    if (std::strcmp(text, "-1") == 0) { value = -1; return true; }
    if (!*text) return false;
    value = 0;
    for (const char* p = text; *p; ++p) {
        if (*p < '0' || *p > '9' || value > (INT_MAX - (*p - '0')) / 10) return false;
        value = value * 10 + (*p - '0');
    }
    return true;
}

void locations(const int* values, int count) {
    if (!values) { std::printf("null"); return; }
    std::printf("[");
    for (int i = 0; i < count; ++i) std::printf("%s%d", i ? "," : "", values[i]);
    std::printf("]");
}
}  // namespace

int main(int argc, char** argv) {
    auto config = edlibDefaultAlignConfig();
    auto format = EDLIB_CIGAR_EXTENDED;
    const char* query;
    const char* target;
    std::vector<EdlibEqualityPair> pairs;
    if (argc == 3) {
        query = argv[1]; target = argv[2];
    } else if (argc == 9 && std::strcmp(argv[1], "--config") == 0) {
        if (std::strcmp(argv[2], "NW") == 0) config.mode = EDLIB_MODE_NW;
        else if (std::strcmp(argv[2], "SHW") == 0) config.mode = EDLIB_MODE_SHW;
        else if (std::strcmp(argv[2], "HW") == 0) config.mode = EDLIB_MODE_HW;
        else { std::fprintf(stderr, "Invalid alignment mode\n"); return 2; }
        if (std::strcmp(argv[3], "DISTANCE") == 0) config.task = EDLIB_TASK_DISTANCE;
        else if (std::strcmp(argv[3], "LOC") == 0) config.task = EDLIB_TASK_LOC;
        else if (std::strcmp(argv[3], "PATH") == 0) config.task = EDLIB_TASK_PATH;
        else { std::fprintf(stderr, "Invalid alignment task\n"); return 2; }
        if (!threshold(argv[4], config.k)) {
            std::fprintf(stderr, "Invalid alignment threshold\n"); return 2;
        }
        const auto pair_length = std::strlen(argv[5]);
        if (!ascii(argv[5], 4096) || pair_length % 2) {
            std::fprintf(stderr, "Invalid ASCII equality pairs (maximum of 4096 characters)\n"); return 2;
        }
        for (std::size_t i = 0; i < pair_length; i += 2)
            pairs.push_back({argv[5][i], argv[5][i + 1]});
        config.additionalEqualities = pairs.empty() ? nullptr : pairs.data();
        config.additionalEqualitiesLength = static_cast<int>(pairs.size());
        if (std::strcmp(argv[6], "STANDARD") == 0) format = EDLIB_CIGAR_STANDARD;
        else if (std::strcmp(argv[6], "EXTENDED") != 0) {
            std::fprintf(stderr, "Invalid CIGAR format\n"); return 2;
        }
        query = argv[7]; target = argv[8];
    } else {
        std::fprintf(stderr, "Expected QUERY TARGET or --config MODE TASK K PAIRS CIGAR QUERY TARGET\n");
        return 2;
    }
    if (!ascii(query, 4096) || !ascii(target, 4096)) {
        std::fprintf(stderr, "Sequences must be non-NUL ASCII, maximum of 4096 characters\n"); return 2;
    }

    auto result = edlibAlign(query, static_cast<int>(std::strlen(query)),
                             target, static_cast<int>(std::strlen(target)), config);
    // Other fields are undefined on ERROR. Normalize without reading them.
    if (result.status != EDLIB_STATUS_OK) {
        std::printf("{\"status\":%d,\"edit_distance\":-1,\"end_locations\":[],"
                    "\"start_locations\":null,\"alignment\":null,\"cigar\":null}\n", result.status);
        edlibFreeAlignResult(result);
        return 0;
    }
    std::printf("{\"status\":%d,\"edit_distance\":%d,\"end_locations\":",
                result.status, result.editDistance);
    if (result.endLocations) locations(result.endLocations, result.numLocations);
    else std::printf("[]");
    std::printf(",\"start_locations\":");
    locations(result.startLocations, result.numLocations);
    std::printf(",\"alignment\":");
    char* cigar = nullptr;
    if (result.alignment) {
        std::printf("[");
        for (int i = 0; i < result.alignmentLength; ++i)
            std::printf("%s%u", i ? "," : "", static_cast<unsigned>(result.alignment[i]));
        std::printf("]");
        cigar = edlibAlignmentToCigar(result.alignment, result.alignmentLength, format);
    } else std::printf("null");
    std::printf(",\"cigar\":");
    // CIGAR contains only digits and MID=X; no JSON escaping is required.
    if (cigar) std::printf("\"%s\"", cigar);
    else std::printf("null");
    std::printf("}\n");
    std::free(cigar);
    edlibFreeAlignResult(result);
    return 0;
}

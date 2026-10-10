// Structured oracle against the pinned, vendored Edlib implementation.
#include "edlib.h"
#define BEND_EDLIB_ORACLE
#include "../transport.c"

#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
bool ascii(const std::string& value, std::size_t maximum) {
    const auto length = value.size();
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

void append_u32(std::vector<unsigned char>& bytes, uint32_t n) {
    const auto size = bytes.size();
    bytes.resize(size + 4);
    be_put_u32(bytes.data() + size, n);
}

void binary_result(const EdlibAlignResult& result, EdlibCigarFormat format) {
    // Never read undefined result fields on ERROR.
    const bool ok = result.status == EDLIB_STATUS_OK;
    const bool found = ok && result.editDistance >= 0;
    char* cigar = found && result.alignment ? edlibAlignmentToCigar(
        result.alignment, result.alignmentLength, format) : nullptr;
    const std::string cigar_text = cigar ? cigar : "";
    std::vector<unsigned char> bytes{'B', 'E', 'R', '1'};
    append_u32(bytes, ok ? 0 : 1);
    append_u32(bytes, found ? static_cast<uint32_t>(result.editDistance) : BE_NULL);
    append_u32(bytes, found ? result.numLocations : 0);
    append_u32(bytes, found && result.startLocations ? result.numLocations : BE_NULL);
    append_u32(bytes, found && result.alignment ? result.alignmentLength : BE_NULL);
    append_u32(bytes, cigar ? static_cast<uint32_t>(cigar_text.size()) : BE_NULL);
    if (found) {
        for (int i = 0; i < result.numLocations; ++i)
            append_u32(bytes, static_cast<uint32_t>(result.endLocations[i]));
        if (result.startLocations)
            for (int i = 0; i < result.numLocations; ++i)
                append_u32(bytes, static_cast<uint32_t>(result.startLocations[i]));
        if (result.alignment)
            bytes.insert(bytes.end(), result.alignment, result.alignment + result.alignmentLength);
    }
    bytes.insert(bytes.end(), cigar_text.begin(), cigar_text.end());
    be_write_frame(bytes.data(), bytes.size());
    std::free(cigar);
}

int worker() {
    BeRequest request;
    while (int state = be_read_request(&request)) {
        if (state == 2) {
            EdlibAlignResult error{};
            error.status = EDLIB_STATUS_ERROR;
            binary_result(error, EDLIB_CIGAR_EXTENDED);
        } else {
            std::vector<EdlibEqualityPair> pairs;
            for (uint32_t i = 0; i < request.pair_count; ++i)
                pairs.push_back({static_cast<char>(request.pairs[2 * i]),
                                 static_cast<char>(request.pairs[2 * i + 1])});
            auto config = edlibNewAlignConfig(
                request.threshold == BE_NULL ? -1 : static_cast<int>(request.threshold),
                static_cast<EdlibAlignMode>(request.mode), static_cast<EdlibAlignTask>(request.task),
                pairs.empty() ? nullptr : pairs.data(), static_cast<int>(pairs.size()));
            auto result = edlibAlign(
                reinterpret_cast<const char*>(request.query), static_cast<int>(request.query_length),
                reinterpret_cast<const char*>(request.target), static_cast<int>(request.target_length), config);
            binary_result(result, static_cast<EdlibCigarFormat>(request.format));
            edlibFreeAlignResult(result);
        }
        std::free(request.data);
    }
    return 0;
}
}  // namespace

int main(int argc, char** argv) {
    if (argc == 2 && std::strcmp(argv[1], "--worker") == 0) return worker();
    auto config = edlibDefaultAlignConfig();
    auto format = EDLIB_CIGAR_EXTENDED;
    std::string query;
    std::string target;
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
        const auto pair_length = std::string(argv[5]).size();
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

    auto result = edlibAlign(query.data(), static_cast<int>(query.size()),
                             target.data(), static_cast<int>(target.size()), config);
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

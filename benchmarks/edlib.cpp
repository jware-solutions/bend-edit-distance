// Benchmark-only access to the exact vendored static routines; no Edlib edits.
#include "../vendor/edlib/edlib/src/edlib.cpp"
#include <chrono>
#include <cstdio>
#include <stdexcept>
#include <memory>

static uint64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

int main(int argc, char** argv) {
    const uint64_t ready = now_ns();
    std::printf("ready,%llu\n", (unsigned long long)ready);
    std::fflush(stdout);
    uint64_t last = now_ns(), phases[8] = {};
    auto mark = [&](int phase) {
        uint64_t current = now_ns();
        phases[phase] = current - last;
        last = current;
    };
    try {
        if (argc != 5) throw std::runtime_error("Expected MODE DEPTH QUERY TARGET");
        // Copy from argv, like IO.args materializes Bend Strings. Kernel argv
        // transport itself happens before ready and is part of startup/E2E.
        const std::string mode(argv[1]), depth_text(argv[2]);
        const std::string query_original(argv[3]), target_original(argv[4]);
        mark(0);
        size_t end = 0;
        int depth = std::stoi(depth_text, &end);
        if (end != depth_text.size() || depth < 1 || depth > 10)
            throw std::runtime_error("Depth must be 1..10");
        int count = 1 << (depth - 1);
        for (auto sequence : {&query_original, &target_original}) {
            if (sequence->size() > 4096) throw std::runtime_error("Sequence too long");
            for (unsigned char c : *sequence)
                if (c == 0 || c > 127) throw std::runtime_error("Non-ASCII input");
        }
        // Preserve ORDER for Edlib's public API, exactly as the correctness
        // oracle does. Bend internally chooses the shorter query. Record this
        // asymmetry rather than silently swapping Edlib's arguments.
        int qn = query_original.size(), tn = target_original.size();
        uint64_t checksum = 0;
        if (mode == "full") {
            mark(1);
            auto config = edlibNewAlignConfig(-1, EDLIB_MODE_NW, EDLIB_TASK_DISTANCE, nullptr, 0);
            for (int i = 0; i < count; ++i) {
                auto result = edlibAlign(query_original.data(), qn, target_original.data(), tn, config);
                int status = result.status, distance = result.editDistance;
                edlibFreeAlignResult(result);
                if (status != EDLIB_STATUS_OK || distance < 0)
                    throw std::runtime_error("edlibAlign failed");
                checksum += distance;
            }
            mark(3);
        } else if (mode == "prepared") {
            unsigned char *query_raw, *target_raw;
            std::string alphabet = transformSequences(query_original.data(), qn,
                target_original.data(), tn, &query_raw, &target_raw);
            std::unique_ptr<unsigned char, decltype(&std::free)> query(query_raw, &std::free);
            std::unique_ptr<unsigned char, decltype(&std::free)> target(target_raw, &std::free);
            EqualityDefinition equality(alphabet);
            int blocks = ceilDiv(qn, WORD_SIZE), padding = blocks * WORD_SIZE - qn;
            mark(1);
            std::unique_ptr<Word[]> profile((qn && tn)
                ? buildPeq(alphabet.size(), query.get(), qn, equality) : nullptr);
            mark(2);
            for (int i = 0; i < count; ++i) {
                int score = std::max(qn, tn), position = -1;
                if (qn && tn) {
                    int k = WORD_SIZE;
                    AlignmentData* alignment = nullptr;
                    do {
                        int status = myersCalcEditDistanceNW(profile.get(), padding, blocks,
                            qn, target.get(), tn, k, &score, &position, false, &alignment, -1);
                        if (status != EDLIB_STATUS_OK) throw std::runtime_error("NW failed");
                        k *= 2;
                    } while (score == -1);
                }
                checksum += score;
            }
            mark(3);
            // Release persistent buffers as a distinct teardown phase. Full
            // mode already includes each alignment's frees in phase 3.
            profile.reset(); query.reset(); target.reset();
            mark(4);
        } else {
            throw std::runtime_error("Expected full or prepared");
        }
        for (int i = 0; i < 8; ++i)
            std::printf("phase,%d,%llu\n", i, (unsigned long long)phases[i]);
        std::printf("checksum,%llu\n", (unsigned long long)checksum);
        return 0;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 2;
    }
}

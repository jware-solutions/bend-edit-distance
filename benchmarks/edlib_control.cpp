// Maintained BED2 references; supported domain: NW DISTANCE, all bytes,
// symmetric nontransitive equalities, unlimited/finite thresholds, empty inputs.
// Both controls use persistent C++ threads and the shipped native frame parser.
#define BEND_EDLIB_CONTROL
#include "../src/transport.c"
#ifndef EDLIB_CONTROL_SOURCE
#define EDLIB_CONTROL_SOURCE "../vendor/edlib/edlib/src/edlib.cpp"
#endif
#include EDLIB_CONTROL_SOURCE
#ifdef EDLIB_CONTROL_WORD_BITS
static_assert(sizeof(Word) * 8 == EDLIB_CONTROL_WORD_BITS, "unexpected diagnostic word width");
#endif
#include <array>
#include <memory>
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#ifdef BEND_EDLIB_NATIVE_METRICS
#include <chrono>
#endif

struct Query {
    std::string text;
    std::vector<EdlibEqualityPair> pairs;
    uint32_t bytes;
    int maximum = -1;
#ifdef CACHED_PROFILE
    std::array<unsigned char,256> codebook;
    std::unique_ptr<Word[]> profile;
    int blocks = 0, padding = 0;
#endif
};
using Span = std::pair<const char *, int>;
#ifdef CACHED_PROFILE
// Internal NW diagnostic: retained word-sized Peq/codebook; block scratch is allocated
// inside myersCalcEditDistanceNW on EVERY call. Target mapping is thread-local.
static void prepare_profile(Query &q) {
    bool used[256] = {};
    std::string alphabet;
    auto include = [&](unsigned char c) { if (!used[c]) { used[c]=true; alphabet.push_back((char)c); } };
    for (unsigned char c: q.text) include(c);
    for (auto pair: q.pairs) { include((unsigned char)pair.first); include((unsigned char)pair.second); }
    unsigned unknown = alphabet.size();
    if (unknown < 256) { unsigned c=0; while (used[c]) ++c; include((unsigned char)c); }
    q.codebook.fill((unsigned char)unknown);
    for (unsigned i=0;i<alphabet.size();++i) q.codebook[(unsigned char)alphabet[i]]=(unsigned char)i;
    q.blocks = ceilDiv((int)q.text.size(),WORD_SIZE);
    q.padding = q.blocks*WORD_SIZE-(int)q.text.size();
    if (!q.text.empty()) {
        std::vector<unsigned char> query(q.text.size());
        for (size_t i=0;i<q.text.size();++i) query[i]=q.codebook[(unsigned char)q.text[i]];
        EqualityDefinition equality(alphabet,q.pairs.data(),(int)q.pairs.size());
        q.profile.reset(buildPeq((int)alphabet.size(),query.data(),(int)query.size(),equality));
    }
    q.bytes += (uint32_t)((alphabet.size()+1)*q.blocks*sizeof(Word)+q.codebook.size());
}
static int score(const Query &q, Span t, int maximum) {
    int qn=(int)q.text.size(), tn=t.second;
    if (!qn || !tn) return std::max(qn,tn);
    if (maximum>=0 && maximum<std::abs(qn-tn)) return -1;
    thread_local std::vector<unsigned char> mapped;
    mapped.resize(tn);
    for (int i=0;i<tn;++i) mapped[i]=q.codebook[(unsigned char)t.first[i]];
    int cap=std::max(qn,tn), bound=maximum<0 ? std::min(cap,std::max(WORD_SIZE,std::abs(qn-tn))) : std::min(cap,maximum);
    for (;;) {
        int distance=-1, position=-1;
        AlignmentData *alignment=nullptr;
        int status=myersCalcEditDistanceNW(q.profile.get(),q.padding,q.blocks,qn,mapped.data(),tn,bound,
            &distance,&position,false,&alignment,-1);
        if (status!=EDLIB_STATUS_OK || alignment) be_die("Prepared NW alignment failed");
        if (distance>=0 || maximum>=0) return distance;
        if (bound==cap) be_die("Prepared NW retry exhausted");
        bound=std::min(cap,2*bound);
    }
}
#else
static void prepare_profile(Query &) {}
// Public API control: retain raw query/equalities only; disposal is timed.
static int score(const Query &q, Span t, int maximum) {
    auto cfg = edlibNewAlignConfig(maximum, EDLIB_MODE_NW, EDLIB_TASK_DISTANCE,
                                  q.pairs.data(), (int)q.pairs.size());
    auto r = edlibAlign(q.text.data(), (int)q.text.size(), t.first, t.second, cfg);
    if (r.status != EDLIB_STATUS_OK) be_die("Edlib alignment failed");
    int distance = r.editDistance;
    edlibFreeAlignResult(r);
    return distance;
}
#endif
class Workers {
    unsigned threads, epoch = 0, remaining = 0;
    bool stopping = false;
    std::vector<std::thread> workers;
    std::mutex mutex;
    std::condition_variable ready, done;
    std::atomic<size_t> next{0};
    const Query *query = nullptr;
    const std::vector<Query> *jobs = nullptr;
    const std::vector<Span> *targets = nullptr;
    std::vector<int> *results = nullptr;
    int maximum = -1;
    void work() {
        unsigned seen = 0;
        for (;;) {
            std::unique_lock<std::mutex> lock(mutex);
            ready.wait(lock, [&] { return stopping || seen != epoch; });
            if (stopping) return;
            seen = epoch;
            auto q = query; auto js = jobs; auto ts = targets; auto rs = results; int k = maximum;
            lock.unlock();
            for (;;) {
                size_t i = next.fetch_add(1, std::memory_order_relaxed);
                if (i >= ts->size()) break;
                (*rs)[i] = js ? score((*js)[i], (*ts)[i], (*js)[i].maximum) : score(*q, (*ts)[i], k);
            }
            lock.lock();
            if (!--remaining) done.notify_one();
        }
    }
public:
    explicit Workers(unsigned n): threads(n) {
        if (n > 1) for (unsigned i = 0; i < n; ++i) workers.emplace_back([this]{work();});
    }
    ~Workers() {
        { std::lock_guard<std::mutex> lock(mutex); stopping = true; }
        ready.notify_all(); for (auto &thread: workers) thread.join();
    }
    std::vector<int> run(const Query &q, const std::vector<Span> &ts, int k, const std::vector<Query> *js = nullptr) {
        std::vector<int> rs(ts.size());
        if (threads == 1) {
            for (size_t i = 0; i < ts.size(); ++i) rs[i] = js ? score((*js)[i], ts[i], (*js)[i].maximum) : score(q, ts[i], k);
            return rs;
        }
        std::unique_lock<std::mutex> lock(mutex);
        query = &q; jobs = js; targets = &ts; results = &rs; maximum = k;
        next = 0; remaining = threads; ++epoch; ready.notify_all();
        done.wait(lock, [&] { return !remaining; });
        return rs;
    }
};
// Optional attribution binary only. The service controls leave this disabled.
// This boundary includes result-vector allocation, thread dispatch, public
// edlibAlign/free (or explicitly internal cached search), and the ordered join.
#ifdef BEND_EDLIB_NATIVE_METRICS
static std::vector<int> native_run(Workers &workers, const Query &q,
                                 const std::vector<Span> &ts, int maximum,
                                 const std::vector<Query> *jobs = nullptr) {
    const auto started = std::chrono::steady_clock::now();
    auto scores = workers.run(q, ts, maximum, jobs);
    auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - started).count();
    fprintf(stderr, "BEND_EDLIB_NATIVE {\"native_api_ns\":%llu,\"count\":%zu,\"word_bits\":%zu,\"backend\":\"%s\"}\n",
        (unsigned long long)ns, ts.size(), sizeof(Word) * 8,
#ifdef CACHED_PROFILE
        "internal-cached-edlib"
#else
        "public-edlib"
#endif
    );
    return scores;
}
#else
#define native_run(workers, ...) (workers).run(__VA_ARGS__)
#endif
static void control(unsigned op, unsigned status, uint32_t handle, uint32_t bytes, uint32_t count) {
    unsigned char out[24]; memcpy(out, "BER2", 4);
    uint32_t values[5] = {op, status, handle, bytes, count};
    for (unsigned i = 0; i < 5; ++i) be_put_u32(out+4+4*i, values[i]);
    be_write_frame(out, sizeof(out));
}
static void result(int distance, int length) {
    unsigned char out[32]; memcpy(out, "BER1", 4);
    uint32_t values[6] = {0, (uint32_t)distance, distance < 0 ? 0u : 1u, BE_NULL, BE_NULL, BE_NULL};
    for (unsigned i = 0; i < 6; ++i) be_put_u32(out+4+4*i, values[i]);
    be_put_u32(out+28, (uint32_t)(length-1));
    be_write_frame(out, distance < 0 ? 28 : 32);
}
static Query ordinary_query(const BeRequest &r) {
    if (r.version != 1 || r.mode || r.task) be_die("reference supports NW DISTANCE only");
    Query q;
    q.text.assign((const char *)r.query, r.query_length);
    q.maximum = (int32_t)r.threshold;
    for (uint32_t i = 0; i < r.pair_count; ++i)
        q.pairs.push_back({(char)r.pairs[2*i], (char)r.pairs[2*i+1]});
    q.bytes = 0;
    prepare_profile(q);
    return q;
}
int main(int argc, char **argv) {
    unsigned threads = argc == 2 ? std::stoul(argv[1]) : 1;
    if (threads != 1 && threads != 2 && threads != 4) return 2;
    Workers workers(threads); std::map<uint32_t, Query> queries;
    uint32_t next = 1, retained = 0;
    for (;;) {
        BeRequest r; int valid = be_read_request(&r);
        if (!valid) break;
        if (valid == 2 && r.version == 2) { control(r.operation,1,0,retained,0); free(r.data); continue; }
        if (valid != 1) be_die("expected valid reference protocol");
        if (r.version == 1) {
            auto q = ordinary_query(r);
            result(score(q, {(const char *)r.target, (int)r.target_length}, q.maximum), r.target_length);
            free(r.data);
            continue;
        }
        if (r.operation == 4) {
            // Ordinary requests retain no query/profile across calls. Each job
            // uses public edlibAlign, with the SAME BED1 body framing as Bend.
            std::vector<Query> jobs;
            std::vector<BeRequest> requests(r.query_length);
            std::vector<Span> targets;
            jobs.reserve(r.query_length);
            for (auto &request : requests) {
                if (be_read_request(&request) != 1) be_die("invalid ordinary batch job");
                jobs.push_back(ordinary_query(request));
                targets.push_back({(const char *)request.target, (int)request.target_length});
            }
            Query dummy;
            auto scores = native_run(workers, dummy, targets, -1, &jobs);
            control(4, 0, 0, retained, (uint32_t)targets.size());
            be_batch_output = 1;
            for (size_t i = 0; i < scores.size(); ++i) result(scores[i], targets[i].second);
            be_batch_output = 0;
            if (fflush(stdout)) be_die("write failed");
            for (auto &request : requests) free(request.data);
            free(r.data);
            continue;
        }
        uint32_t handle = r.query_length;
        if (r.operation == 1) {
            Query q; q.text.assign((const char *)r.query, r.query_length);
            for (uint32_t i = 0; i < r.pair_count; ++i)
                q.pairs.push_back({(char)r.pairs[2*i], (char)r.pairs[2*i+1]});
            q.bytes = 4096 + 2*r.query_length + 4*r.pair_count;
            prepare_profile(q);
            if (queries.size() == 32 || q.bytes > 64*1024*1024-retained) control(1,1,0,retained,0);
            else { handle=next++; retained+=q.bytes; queries.emplace(handle,std::move(q)); control(1,0,handle,retained,1); }
        } else if (r.operation == 3) {
            auto it = queries.find(handle); bool exists = it != queries.end();
            if (exists) { retained-=it->second.bytes; queries.erase(it); }
            control(3,!exists,handle,retained,0);
        } else if (r.operation == 6 || r.operation == 7 || r.operation == 8) {
            control(r.operation,1,0,retained,0);
        } else if (r.operation == 2 || r.operation == 5) {
            auto it = queries.find(handle);
            if (it == queries.end() || r.mode || r.task) be_die("unsupported alignment request");
            std::vector<Span> ts;
            if (r.operation == 2) ts.push_back({(const char *)r.target,(int)r.target_length});
            else {
                size_t pos = 0;
                for (uint32_t i = 0; i < r.target_length; ++i) {
                    uint32_t n = be_u32(r.data+pos); pos+=4;
                    ts.push_back({(const char *)r.data+pos,(int)n}); pos+=n;
                }
            }
            auto scores = native_run(workers, it->second, ts, (int32_t)r.threshold);
            if (r.operation == 5) { control(5,0,handle,retained,(uint32_t)ts.size()); be_batch_output=1; }
            for (size_t i = 0; i < ts.size(); ++i) result(scores[i],ts[i].second);
            if (r.operation == 5) { be_batch_output=0; if (fflush(stdout)) be_die("write failed"); }
        } else be_die("unsupported operation");
        free(r.data);
    }
}

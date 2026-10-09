// Launch from a small native address space so ru_maxrss is not floored by a
// forked Python interpreter's RSS. All output passes through to the runner.
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/resource.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) abort();
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    uint64_t spawned = now_ns();
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 2; }
    if (!child) {
        execv(argv[1], &argv[1]);
        perror("execv");
        _exit(2);
    }
    int status;
    struct rusage usage;
    if (wait4(child, &status, 0, &usage) < 0) { perror("wait4"); return 2; }
    uint64_t ended = now_ns();
    uint64_t cpu_ns = (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000000000ull
                     + (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) * 1000ull;
    printf("usage,%" PRIu64 ",%" PRIu64 ",%ld,%" PRIu64 "\n",
           spawned, ended, usage.ru_maxrss, cpu_ns);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

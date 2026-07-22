// MDLBSG App 82 true-detach launcher.
// Starts argv[1..] in a detached grandchild and returns immediately.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static void detach_file_descriptors(void) {
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        (void)dup2(fd, STDIN_FILENO);
        (void)dup2(fd, STDOUT_FILENO);
        (void)dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) close(fd);
    }

    // AppleScript's `do shell script` can keep waiting if any inherited pipe
    // remains open, even after stdin/stdout/stderr are redirected. Close every
    // other descriptor before exec so the caller sees a genuinely detached job.
    struct rlimit lim;
    rlim_t max_fd = 1024;
    if (getrlimit(RLIMIT_NOFILE, &lim) == 0 && lim.rlim_cur != RLIM_INFINITY) {
        max_fd = lim.rlim_cur;
    }
    if (max_fd > 65536) max_fd = 65536;
    for (int n = 3; n < (int)max_fd; ++n) close(n);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: mdlbsg_detached_spawn command [args...]\\n");
        return 64;
    }

    pid_t first = fork();
    if (first < 0) {
        perror("fork");
        return 71;
    }
    if (first > 0) {
        return 0;
    }

    if (setsid() < 0) _exit(72);

    pid_t second = fork();
    if (second < 0) _exit(73);
    if (second > 0) _exit(0);

    (void)signal(SIGHUP, SIG_IGN);
    (void)chdir("/");
    detach_file_descriptors();

    execv(argv[1], &argv[1]);
    _exit(errno == ENOENT ? 127 : 126);
}

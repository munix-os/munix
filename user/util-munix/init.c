#include <sys/syscall.h>
#include <unistd.h>

int main(int argc, char** argv) {
    syscall(SYS_debug_log, "init: hello, world!");
    syscall(SYS_debug_log, "init: dumping argv...");

    for (int i = 0; i < argc; i++) {
        syscall(SYS_debug_log, argv);
    }
}

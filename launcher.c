/*
 * iMessage MCP launcher: the executable inside "iMessage MCP.app".
 *
 * The Claude app starts local MCP servers through a "disclaimer" helper, so
 * macOS does not treat Claude as responsible for them: privacy permissions
 * (Full Disk Access, control of Messages) are checked against the server's own
 * executable. If that executable were python3, the grant would cover every
 * Python script on the Mac.
 *
 * This program is the executable instead. It starts Python as a child, which
 * keeps this app as the responsible process, so the permission is granted to
 * "iMessage MCP" alone. PYTHON and SERVER are fixed at build time by
 * install.py so the binary cannot be pointed at anything else.
 */

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>

extern char **environ;

static pid_t child = 0;

static void forward(int sig) {
    if (child > 0) kill(child, sig);
}

int main(int argc, char **argv) {
    char **args = calloc((size_t)argc + 2, sizeof(char *));
    if (!args) return 127;
    args[0] = PYTHON;
    args[1] = SERVER;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];

    signal(SIGTERM, forward);
    signal(SIGINT, forward);
    signal(SIGHUP, forward);

    int err = posix_spawn(&child, PYTHON, NULL, NULL, args, environ);
    if (err != 0) {
        fprintf(stderr, "imessage-mcp: cannot start %s: error %d\n", PYTHON, err);
        return 127;
    }

    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return 1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 1;
}

#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>

/* Resolve the adjacent private interpreter after the application is moved.
 * Isolated mode excludes user Python configuration; -B keeps the signed bundle
 * read-only. Every URL and option remains a separate exec argument. */
int main(int argc, char **argv) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *executable = malloc(size);
    if (!executable || _NSGetExecutablePath(executable, &size) != 0) return 70;
    char resolved[PATH_MAX];
    if (!realpath(executable, resolved)) { perror("MVD media launcher"); free(executable); return 70; }
    free(executable);
    char *separator = strrchr(resolved, '/');
    if (!separator) return 70;
    *separator = '\0';
    char interpreter[PATH_MAX];
    if (snprintf(interpreter, sizeof(interpreter), "%s/Python/bin/python3.14", resolved) >= sizeof(interpreter)) return 70;
    char **arguments = calloc((size_t)argc + 5, sizeof(char *));
    if (!arguments) return 70;
    arguments[0] = interpreter;
    arguments[1] = "-I";
    arguments[2] = "-B";
    arguments[3] = "-m";
    arguments[4] = "yt_dlp";
    for (int index = 1; index < argc; index++) arguments[index + 4] = argv[index];
    execv(interpreter, arguments);
    perror("MVD bundled Python");
    free(arguments);
    return 70;
}

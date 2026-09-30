#include "process.h"

// Private libquarantine API, also used by Activity Monitor-style tools to attribute helpers to apps.
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t pid);

pid_t logmac_responsible_pid(pid_t pid) {
    pid_t responsible = responsibility_get_pid_responsible_for_pid(pid);
    return responsible > 0 ? responsible : pid;
}

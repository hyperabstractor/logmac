#ifndef PROCESS_H
#define PROCESS_H

#include <sys/types.h>

/// The pid macOS holds responsible for `pid`, e.g. the app that owns a helper process.
/// Returns `pid` itself when there is no separate responsible process.
pid_t logmac_responsible_pid(pid_t pid);

#endif

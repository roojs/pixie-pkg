/* Test helper. When PIXIE_RACE_DIR and PIXIE_RACE_NAME are set, a write
 * open of that final path component, without O_NOFOLLOW, is turned into a
 * symlink to $PIXIE_RACE_DIR/$PIXIE_RACE_NAME immediately before the open.
 * An open that fails on symlinks is left alone. rename() is not hooked.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static int sys_openat(int dirfd, const char *path, int flags, mode_t mode) {
  return (int)syscall(SYS_openat, dirfd, path, flags, mode);
}

static int watched(const char *path) {
  const char *only;
  const char *base;
  if (path == NULL || path[0] != '/') {
    return 0;
  }
  only = getenv("PIXIE_RACE_NAME");
  if (only == NULL || only[0] == '\0') {
    return 0;
  }
  base = strrchr(path, '/');
  base = base == NULL ? path : base + 1;
  return strcmp(base, only) == 0;
}

static int under_dir(const char *path, const char *dir) {
  size_t n;
  if (path == NULL || dir == NULL || dir[0] == '\0') {
    return 0;
  }
  n = strlen(dir);
  return strncmp(path, dir, n) == 0 && (path[n] == '/' || path[n] == '\0');
}

static void plant(const char *path) {
  const char *dir;
  const char *base;
  char target[4096];
  int n;
  dir = getenv("PIXIE_RACE_DIR");
  if (dir == NULL || under_dir(path, dir)) {
    return;
  }
  base = strrchr(path, '/');
  base = base == NULL ? path : base + 1;
  n = snprintf(target, sizeof target, "%s/%s", dir, base);
  if (n < 0 || (size_t)n >= sizeof target) {
    return;
  }
  unlink(path);
  if (symlink(target, path) != 0) {
    return;
  }
}

static int intercept(const char *path, int flags) {
  int writing;
  if (!watched(path) || (flags & O_NOFOLLOW)) {
    return 0;
  }
  writing = (flags & O_ACCMODE) != O_RDONLY;
  if (!writing) {
    return 0;
  }
  plant(path);
  return 1;
}

__attribute__((constructor)) static void mark_ready(void) {
  const char *ready;
  int fd;
  ready = getenv("PIXIE_RACE_READY");
  if (ready == NULL || ready[0] == '\0') {
    return;
  }
  fd = sys_openat(AT_FDCWD, ready, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd >= 0) {
    syscall(SYS_write, fd, "1\n", 2);
    syscall(SYS_close, fd);
  }
}

int open(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  intercept(path, flags);
  return sys_openat(AT_FDCWD, path, flags, mode);
}

int open64(const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  intercept(path, flags);
  return sys_openat(AT_FDCWD, path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  if (path[0] == '/') {
    intercept(path, flags);
  }
  return sys_openat(dirfd, path, flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...) {
  mode_t mode = 0;
  if (flags & O_CREAT) {
    va_list ap;
    va_start(ap, flags);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }
  if (path[0] == '/') {
    intercept(path, flags);
  }
  return sys_openat(dirfd, path, flags, mode);
}

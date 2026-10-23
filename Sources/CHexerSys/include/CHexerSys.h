#ifndef CHEXERSYS_H
#define CHEXERSYS_H

#include <stdint.h>

/// Small POSIX helpers that Swift cannot express directly: descriptor passing over UNIX
/// sockets (SCM_RIGHTS) and the <sys/disk.h> ioctls. All return -1 and set errno on failure.

/// Receives one descriptor sent with SCM_RIGHTS over the stream socket `socket`, skipping any
/// plain data that precedes it. The descriptor is returned with FD_CLOEXEC set; extra
/// descriptors in the same message are closed. End of stream before a descriptor arrives fails
/// with ENOMSG, a truncated control message with EMSGSIZE.
int hexer_recv_fd(int socket);

/// Sends `fd` with SCM_RIGHTS over `socket`, together with one byte of data. Returns 0.
int hexer_send_fd(int socket, int fd);

/// DKIOCGETBLOCKSIZE: the device's logical block (sector) size.
int hexer_block_size(int fd, uint32_t *size);

/// DKIOCGETBLOCKCOUNT: the number of logical blocks on the device.
int hexer_block_count(int fd, uint64_t *count);

/// DKIOCGETPHYSICALBLOCKSIZE: the physical block size, which may exceed the logical one.
int hexer_physical_block_size(int fd, uint32_t *size);

/// DKIOCISWRITABLE: whether the media accepts writes.
int hexer_is_writable(int fd, int *writable);

/// DKIOCSYNCHRONIZE (falling back to DKIOCSYNCHRONIZECACHE): flushes the device's write cache.
int hexer_synchronize(int fd);

#endif

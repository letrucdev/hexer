#include "CHexerSys.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

int hexer_recv_fd(int socket) {
    for (;;) {
        char data[64];
        struct iovec iov = { .iov_base = data, .iov_len = sizeof data };
        union {
            struct cmsghdr header;
            char buffer[CMSG_SPACE(sizeof(int) * 8)];
        } control;
        memset(&control, 0, sizeof control);
        struct msghdr message;
        memset(&message, 0, sizeof message);
        message.msg_iov = &iov;
        message.msg_iovlen = 1;
        message.msg_control = control.buffer;
        message.msg_controllen = sizeof control.buffer;

        ssize_t n = recvmsg(socket, &message, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) {
            errno = ENOMSG;
            return -1;
        }
        int received = -1;
        for (struct cmsghdr *c = CMSG_FIRSTHDR(&message); c != NULL; c = CMSG_NXTHDR(&message, c)) {
            if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
            size_t count = (c->cmsg_len - CMSG_LEN(0)) / sizeof(int);
            for (size_t i = 0; i < count; i++) {
                int fd;
                memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof fd);
                if (received < 0) {
                    received = fd;
                } else {
                    close(fd);
                }
            }
        }
        if (received >= 0) {
            fcntl(received, F_SETFD, FD_CLOEXEC);
            return received;
        }
        if (message.msg_flags & MSG_CTRUNC) {
            errno = EMSGSIZE;
            return -1;
        }
    }
}

int hexer_send_fd(int socket, int fd) {
    char byte = 0;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    union {
        struct cmsghdr header;
        char buffer[CMSG_SPACE(sizeof(int))];
    } control;
    memset(&control, 0, sizeof control);
    struct msghdr message;
    memset(&message, 0, sizeof message);
    message.msg_iov = &iov;
    message.msg_iovlen = 1;
    message.msg_control = control.buffer;
    message.msg_controllen = sizeof control.buffer;
    struct cmsghdr *c = CMSG_FIRSTHDR(&message);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(c), &fd, sizeof fd);
    for (;;) {
        ssize_t n = sendmsg(socket, &message, 0);
        if (n >= 0) return 0;
        if (errno != EINTR) return -1;
    }
}

int hexer_block_size(int fd, uint32_t *size) {
    return ioctl(fd, DKIOCGETBLOCKSIZE, size) == 0 ? 0 : -1;
}

int hexer_block_count(int fd, uint64_t *count) {
    return ioctl(fd, DKIOCGETBLOCKCOUNT, count) == 0 ? 0 : -1;
}

int hexer_physical_block_size(int fd, uint32_t *size) {
    return ioctl(fd, DKIOCGETPHYSICALBLOCKSIZE, size) == 0 ? 0 : -1;
}

int hexer_is_writable(int fd, int *writable) {
    uint32_t value = 0;
    if (ioctl(fd, DKIOCISWRITABLE, &value) != 0) return -1;
    *writable = value != 0;
    return 0;
}

int hexer_synchronize(int fd) {
    dk_synchronize_t request;
    memset(&request, 0, sizeof request);
    if (ioctl(fd, DKIOCSYNCHRONIZE, &request) == 0) return 0;
    return ioctl(fd, DKIOCSYNCHRONIZECACHE) == 0 ? 0 : -1;
}

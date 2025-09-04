#include <stdint.h>
#include <stdio.h>
#include <sys/socket.h>
#include <linux/un.h>

int main(void) {
    int fd = -1;
    char cmsg_buf[CMSG_SPACE(sizeof(fd))];
    struct msghdr msg = {
        .msg_control=cmsg_buf,
        .msg_controllen=CMSG_LEN(sizeof(fd)),
    };
    struct cmsghdr *control_header = CMSG_FIRSTHDR(&msg);
    control_header->cmsg_len = CMSG_LEN(sizeof(fd));
    control_header->cmsg_level=SOL_SOCKET;
        control_header->cmsg_type=SCM_RIGHTS;

    printf("CMSG_LEN=%lu, CMSG_SPACE=%lu CMSG_DATA(offset)=%lu", CMSG_LEN(sizeof(fd)), CMSG_SPACE(sizeof(fd)), (uintptr_t)CMSG_DATA(control_header) - (uintptr_t)control_header);
    printf("control_buf_size = %lu\n", CMSG_SPACE(253 * sizeof(int)));
    return 0;
}

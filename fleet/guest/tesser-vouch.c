#include <stdio.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <sys/time.h>
#include <unistd.h>

int main(void) {
  struct sockaddr_vm host = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_HOST, .svm_port = 1025};
  struct timeval wait = {.tv_sec = 5};
  static char out[16385];
  size_t len = 0;
  ssize_t n = 0;
  int s = socket(AF_VSOCK, SOCK_STREAM, 0);
  if (s < 0) return perror("socket"), 1;
  setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
  if (connect(s, (struct sockaddr *)&host, sizeof host) < 0) return perror("connect"), 1;
  while (len < sizeof out && (n = read(s, out + len, sizeof out - len)) > 0) len += n;
  if (n < 0) return perror("read"), 1;
  if (len == sizeof out) return fputs("tesser-vouch: the host sent more than 16384 bytes\n", stderr), 1;
  for (size_t off = 0; off < len; off += n)
    if ((n = write(1, out + off, len - off)) <= 0) return perror("write"), 1;
  return 0;
}

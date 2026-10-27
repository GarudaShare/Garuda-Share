/* ISO-TP high-throughput sender for the patched kernel.
 *
 * build: arm-poky-linux-gnueabi-gcc -O2 -I <kernel-source>/include/uapi \
 *        isotp-fast-tx.c -o isotp-fast-tx
 * usage: isotp-fast-tx <iface> <tx_id_hex> <rx_id_hex> <bytes> [fd]
 *
 * Needs the kernel patched with CAN_ISOTP_TX_FASTPATH / CAN_ISOTP_FORCE_FC
 * (include/uapi/linux/can/isotp.h in this tree; use that header, not the
 * system one, which does not define them).
 */
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

#include <linux/can.h>
#include <linux/can/isotp.h>

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "usage: %s <iface> <tx_id> <rx_id> <bytes> [fd]\n",
			argv[0]);
		return 1;
	}

	int fd_mode = argc > 5 && !strcmp(argv[5], "fd");
	size_t len = strtoul(argv[4], NULL, 0);
	int s = socket(PF_CAN, SOCK_DGRAM, CAN_ISOTP);
	if (s < 0) {
		perror("socket");
		return 1;
	}

	/* Zero separation time at the socket boundary, fast path, and ignore
	 * the peer's STmin/BS. TX_PADDING is dropped: padding costs bus time.
	 * Do NOT add CAN_ISOTP_LISTEN_MODE: it makes the socket receive-only
	 * (no FF/CF/FC transmission), i.e. it is for sniffing, not sending.
	 */
	struct can_isotp_options opts = {
		.flags = CAN_ISOTP_TX_FASTPATH | CAN_ISOTP_FORCE_FC |
			 CAN_ISOTP_FORCE_TXSTMIN | CAN_ISOTP_WAIT_TX_DONE,
		.frame_txtime = 0,
	};
	if (setsockopt(s, SOL_CAN_ISOTP, CAN_ISOTP_OPTS, &opts, sizeof(opts)) < 0) {
		perror("CAN_ISOTP_OPTS");
		return 1;
	}

	/* force_tx_stmin = 0 ns, used because of CAN_ISOTP_FORCE_TXSTMIN */
	__u32 stmin = 0;
	if (setsockopt(s, SOL_CAN_ISOTP, CAN_ISOTP_TX_STMIN, &stmin, sizeof(stmin)) < 0) {
		perror("CAN_ISOTP_TX_STMIN");
		return 1;
	}

	/* FD: 64 byte frames with bit-rate switching */
	struct can_isotp_ll_options ll = {
		.mtu = fd_mode ? CANFD_MTU : CAN_MTU,
		.tx_dl = fd_mode ? 64 : 8,
		.tx_flags = fd_mode ? CANFD_BRS : 0,
	};
	if (setsockopt(s, SOL_CAN_ISOTP, CAN_ISOTP_LL_OPTS, &ll, sizeof(ll)) < 0) {
		perror("CAN_ISOTP_LL_OPTS");
		return 1;
	}

	/* Socket send buffer: must hold at least one whole PDU of copy
	 * overhead; the kernel doubles the value. Capped by
	 * net.core.wmem_max.
	 */
	int sndbuf = 1 << 20;
	if (setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf)) < 0)
		perror("SO_SNDBUF (raise net.core.wmem_max?)");

	struct sockaddr_can addr = { .can_family = AF_CAN };
	addr.can_addr.tp.tx_id = strtoul(argv[2], NULL, 16);
	addr.can_addr.tp.rx_id = strtoul(argv[3], NULL, 16);
	addr.can_ifindex = if_nametoindex(argv[1]);
	if (!addr.can_ifindex) {
		perror("if_nametoindex");
		return 1;
	}
	if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		perror("bind");
		return 1;
	}

	unsigned char *buf = malloc(len);
	if (!buf)
		return 1;
	for (size_t i = 0; i < len; i++)
		buf[i] = (unsigned char)i;

	ssize_t n = write(s, buf, len);
	if (n < 0) {
		perror("write");
		return 1;
	}
	printf("sent %zd bytes\n", n);
	return 0;
}

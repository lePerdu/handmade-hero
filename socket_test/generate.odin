package constants

import "core:fmt"
import "core:os"
import "core:sys/posix"

main :: proc() {
	// output := os.args[1]
	// f, err := os.open(output, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0x600)
	// if err != nil {
	// 	fmt.fprintln(os.stderr, "failed to open file:", err)
	// 	os.exit(1)
	// }
	// defer os.close(f)

	data_buf := [1]posix.iovec{}
	control_buf := struct #align (size_of(posix.cmsghdr)) {
		buf: [64]u8,
	}{}
	msg_header := posix.msghdr {
		msg_iov        = &data_buf[0],
		msg_iovlen     = 1,
		msg_control    = &control_buf.buf[1],
		msg_controllen = 63,
	}

	fmt.printfln("size_of(cmsghdr) = {}", size_of(posix.cmsghdr))
	fmt.printfln("align_of(cmsghdr) = {}", align_of(posix.cmsghdr))

	first_header := posix.CMSG_FIRSTHDR(&msg_header)
	fmt.printfln(
		"start({:x})->first({:x}) = {}",
		uintptr(&control_buf.buf[1]),
		uintptr(first_header),
		uintptr(&control_buf.buf[1]) - uintptr(first_header),
	)
	first_header^ = posix.cmsghdr {
		cmsg_len   = size_of(posix.cmsghdr),
		cmsg_level = posix.SOL_SOCKET,
		cmsg_type  = posix.SCM_RIGHTS,
	}

	first_data := posix.CMSG_DATA(first_header)
	second_header := posix.CMSG_NXTHDR(&msg_header, first_header)

	fmt.printfln(
		"first({})->second = {}",
		first_header.cmsg_len,
		uintptr(second_header) - uintptr(first_header),
	)
	fmt.printfln(
		"first({})->data = {}",
		first_header.cmsg_len,
		uintptr(first_data) - uintptr(first_header),
	)

	first_header.cmsg_len = size_of(posix.cmsghdr) + size_of(posix.FD)

	first_data = posix.CMSG_DATA(first_header)
	second_header = posix.CMSG_NXTHDR(&msg_header, first_header)

	fmt.printfln(
		"first({})->second = {}",
		first_header.cmsg_len,
		uintptr(second_header) - uintptr(first_header),
	)
	fmt.printfln(
		"first({})->data = {}",
		first_header.cmsg_len,
		uintptr(first_data) - uintptr(first_header),
	)
}

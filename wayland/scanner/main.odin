package scanner

import "core:fmt"
import "core:log"
import "core:os"

main :: proc() {
	context.logger = log.create_console_logger()
	// The program is one-shot, so there is never a need to de-allocate
	context.allocator = context.temp_allocator

	protocol_filename := os.args[1]
	output_filename := os.args[2]

	proto, proto_err := protocol_load(protocol_filename)
	if proto_err != nil {
		fmt.fprintln(os.stderr, "failed to parse protocol:", proto_err)
		os.exit(1)
	}

	if gen_err := generate(output_filename, proto); gen_err != nil {
		fmt.fprintln(os.stderr, "failed to generate code:", gen_err)
		os.exit(1)
	}
}

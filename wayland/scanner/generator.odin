package scanner

import "core:bufio"
import "core:fmt"
import "core:io"
import "core:log"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Proto_Error :: enum {
	None = 0,
}

Generate_Error :: union #shared_nil {
	Proto_Error,
	os.Errno,
}

generate :: proc(filename: string, proto: Protocol) -> Generate_Error {
	f := os.open(filename, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, 0o644) or_return
	defer os.close(f)
	raw_writer := os.stream_from_handle(f)
	buf_writer: bufio.Writer
	bufio.writer_init(&buf_writer, raw_writer)
	defer bufio.writer_flush(&buf_writer)
	w := bufio.writer_to_stream(&buf_writer)

	// TODO: Catch writer errors throughout?
	fmt.wprintfln(
		w,
		`// This file is generated. Re-generate it by running:
// odin run wayland/scanner -- {} {}
`,
		proto.filename,
		filename,
	)

	copyright_text := proto.copyright
	for line in strings.split_lines_iterator(&copyright_text) {
		fmt.wprintln(w, "//", strings.trim_left_space(line))
	}

	fmt.wprintln(
		w,
		`
package wayland

import "core:bytes"
import "core:io"
import "core:log"
import "core:sys/posix"
`,
	)

	for iface in proto.interfaces {
		codegen_interface(w, iface)
	}
	return nil
}

codegen_interface :: proc(w: io.Writer, iface: Interface) -> Generate_Error {
	// TODO: Make distinct
	codegen_doc_comment(w, iface.description)
	fmt.wprintfln(w, "{} :: Object_Id", iface.name_ada)
	fmt.wprintln(w)

	for enum_ in iface.enums {
		codegen_enum(w, iface, enum_)
	}
	for request, index in iface.requests {
		codegen_request(w, iface, request, index)
	}
	for event, index in iface.events {
		codegen_event(w, iface, event, index)
	}
	return nil
}

@(private)
compare_enum_value :: proc(a: Enum_Entry, b: Enum_Entry) -> bool {
	return a.value < b.value
}

codegen_enum :: proc(w: io.Writer, interface: Interface, enum_: Enum) -> Generate_Error {
	// bitfields need elements sorted, regular enums are nicer to read when sorted
	slice.sort_by(enum_.entries[:], compare_enum_value)

	codegen_doc_comment(w, enum_.description)
	if enum_.bitfield {
		fmt.wprintfln(
			w,
			"{}_{}_Enum :: distinct bit_set[enum u32 {{",
			interface.name_ada,
			enum_.name_ada,
		)
		next_expected_value: u32 = 1
		for entry in enum_.entries {
			if entry.value == 0 {
				continue
			}

			codegen_doc_comment(w, entry.description, "\t")

			if entry.value & (entry.value - 1) != 0 {
				// Some protocols provide entry definitions for "combined" bitfield enums
				// IMO, these enums should just not be bitfields, but we have to make due
				log.warnf(
					"{}.{}.{}: invalid value for bitfield: {}: omitting",
					interface.name,
					enum_.name,
					entry.name,
					entry.value,
				)
				// Write out comment for now
				fmt.wprintfln(w, "\t// {} = {},", entry.name_ada, entry.value)
				continue
			}
			// Add in placeholders in case the enum values are not contiguous
			for next_expected_value < entry.value {
				fmt.wprintln(w, "\t_,")
				next_expected_value <<= 1
			}

			fmt.wprintfln(w, "\t{} /* = {} */,", entry.name_ada, entry.value)
			next_expected_value <<= 1
		}
		fmt.wprintln(w, "}; u32]")
	} else {
		fmt.wprintfln(w, "{}_{}_Enum :: enum u32 {{", interface.name_ada, enum_.name_ada)
		for entry in enum_.entries {
			codegen_doc_comment(w, entry.description, "\t")
			// Need to prefix enum names starting with a number
			prefix := tokenizer.is_letter(utf8.rune_at_pos(entry.name_ada, 0)) ? "" : "_"
			fmt.wprintfln(w, "\t{}{} = {},", prefix, entry.name_ada, entry.value)
		}
		fmt.wprintln(w, "}")
	}

	return nil
}

codegen_request :: proc(
	w: io.Writer,
	interface: Interface,
	req: Message,
	index: int,
) -> Generate_Error {
	// TODO: use SCREAMING_SNAKE_CASE for opcodes?
	fmt.wprintfln(w, "{}_{}_OPCODE: Opcode : {}", interface.name_upper, req.name_upper, index)

	// Start with this, and append argument summaries to the doc comment
	codegen_doc_comment(w, req.description)

	args_builder := strings.builder_make()
	returns_builder := strings.builder_make()
	for arg in req.args {
		if arg.description.summary != "" {
			// TODO: Do any arguments actually have a <description> tag?
			fmt.wprintfln(w, "// - {}: {}", arg.name, arg.description.summary)
		}
		switch arg_type in arg.type {
		case Primitive_Type:
			type_name: string
			switch arg_type {
			case .Int:
				type_name = "i32"
			case .Uint:
				type_name = "u32"
			case .Fixed:
				type_name = "Fixed"
			case .String:
				type_name = "string"
			case .Array:
				type_name = "[]u8"
			case .Fd:
				type_name = "posix.FD"
			}
			fmt.sbprintf(&args_builder, "{}: {}, ", arg.name, type_name)
		case Object_Type:
			arg_type_name: string
			if arg_type.interface != "" {
				arg_type_name = strings.to_ada_case(arg_type.interface)
			} else {
				arg_type_name = "Object_Id"
			}

			fmt.sbprintf(
				arg_type.is_new ? &returns_builder : &args_builder,
				"{}: {}, ",
				arg.name,
				arg_type_name,
			)
		case Enum_Type:
			fmt.sbprintf(
				&args_builder,
				"{}: {}, ",
				arg.name,
				make_enum_type_name(arg_type.name, interface.name_ada),
			)
		}
	}

	fmt.wprintfln(
		w,
		`{}_{} :: proc(conn_: ^Connection, target_: {}, {}) -> ({}err_: Conn_Error) {{
	writer_ := connection_writer(conn_)`,
		interface.name_snake,
		req.name,
		interface.name_ada,
		strings.to_string(args_builder),
		strings.to_string(returns_builder),
	)

	static_size: u16 = 0
	for arg in req.args {
		switch arg_type in arg.type {
		case Primitive_Type:
			switch arg_type {
			case .Int:
				static_size += size_of(i32)
			case .Uint:
				static_size += size_of(u32)
			case .Fixed:
				static_size += size_of(u32)
			case .String, .Array: // runtime-known
			case .Fd: // not included
			}
		case Object_Type:
			static_size += size_of(u32)
		case Enum_Type:
			static_size += size_of(u32)
		}
	}

	// TODO: Check size bounds?
	fmt.wprintfln(w, "\tmsg_size_ :u16 = message_header_size + {}", static_size)
	// Add in dynamic size
	for arg in req.args {
		#partial switch arg_type in arg.type {
		case Primitive_Type:
			#partial switch arg_type {
			case .String:
				fmt.wprintfln(w, "\tmsg_size_ += message_string_size(len({}))", arg.name)
			case .Array:
				fmt.wprintfln(w, "\tmsg_size_ += message_array_size(len({}))", arg.name)
			}
		}
	}

	fmt.wprintfln(
		w,
		"\tmessage_write_header(writer_, target_, {}_{}_OPCODE, msg_size_) or_return",
		interface.name_upper,
		req.name_upper,
	)

	// Write out arguments in-order
	write_arg_values: for arg in req.args {
		#partial switch arg_type in arg.type {
		case Primitive_Type:
			#partial switch arg_type {
			case .Fd:
				// These are written in the out-of-band Unix socket data
				fmt.wprintfln(w, "\tconnection_write_fd(conn_, {}) or_return", arg.name)
				continue write_arg_values // skip message_write
			}
		case Object_Type:
			if arg_type.is_new {
				fmt.wprintfln(w, "\t{} = connection_alloc_id(conn_) or_return", arg.name)
			}
		}
		// message_write overloads cover all the cases
		fmt.wprintfln(w, "\tmessage_write(writer_, {}) or_return", arg.name)
	}

	switch req.type {
	case .Basic: // no-op
	case .Destructor:
		// TODO: Remove this and wait for a wl_display.delete_id event to free the ID?
		fmt.wprintln(w, "\tconnection_free_id(conn_, target_)")
	}

	fmt.wprintf(
		w,
		"\t" + `log.debugf("-> " + {:q} + "@{{}}." + {:q} + ":"`,
		interface.name,
		req.name,
	)
	for arg in req.args {
		fmt.wprintf(w, ` + " " + {:q} + "={{}}"`, arg.name)
	}
	fmt.wprint(w, ", target_")
	for arg in req.args {
		fmt.wprint(w, ',', arg.name)
	}
	fmt.wprintln(w, ")")

	fmt.wprintln(w, "\treturn\n}\n")

	return nil
}

codegen_event :: proc(
	w: io.Writer,
	interface: Interface,
	event: Message,
	index: int,
) -> Generate_Error {
	codegen_doc_comment(w, event.description)
	fmt.wprintfln(
		w,
		`{}_{}_Event :: struct {{
	target: {},`,
		interface.name_ada,
		event.name_ada,
		interface.name_ada,
	)

	for arg in event.args {
		if arg.description.summary != "" {
			fmt.wprintln(w, "\t//", arg.description.summary)
		}
		switch arg_type in arg.type {
		case Primitive_Type:
			type_name: string
			switch arg_type {
			case .Int:
				type_name = "i32"
			case .Uint:
				type_name = "u32"
			case .Fixed:
				type_name = "Fixed"
			case .String:
				type_name = "string"
			case .Array:
				type_name = "[]u8"
			case .Fd:
				type_name = "posix.FD"
			}
			fmt.wprintfln(w, "\t{}: {},", arg.name, type_name)
		case Object_Type:
			if arg_type.is_new {
				// TODO: Figure out if something special needs to happen for new_id's sent from the server
				log.warnf(
					"{}.{}.{}: unhandled new_id arg: interface={:q}",
					interface.name,
					event.name,
					arg.name,
					arg_type.interface,
				)
			}

			arg_type_name := arg_type.interface != "" ? arg_type.interface_ada : "Object_Id"
			fmt.wprintfln(w, "\t{}: {},", arg.name, arg_type_name)
		case Enum_Type:
			fmt.wprintf(
				w,
				"\t{}: {},",
				arg.name,
				make_enum_type_name(arg_type.name, interface.name_ada),
			)
		}
	}
	fmt.wprintln(w, "}")

	// TODO: use SCREAMING_SNAKE_CASE for event codes?
	fmt.wprintfln(
		w,
		"{}_{}_EVENT_OPCODE: Event_Opcode : {}",
		interface.name_upper,
		event.name_upper,
		index,
	)

	fmt.wprintfln(
		w,
		`{}_{}_parse :: proc(conn: ^Connection, message: Message) -> (event: {}_{}_Event, err: Conn_Error) {{
	assert(message.header.target != 0)
	assert(message.header.opcode == {}_{}_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target`,
		interface.name_snake,
		event.name_snake,
		interface.name_ada,
		event.name_ada,
		interface.name_upper,
		event.name_upper,
	)

	for arg in event.args {
		switch arg_type in arg.type {
		case Primitive_Type:
			type_name: string
			switch arg_type {
			case .Int:
				fmt.wprintfln(w, "\tevent.{} = message_read_i32(&reader) or_return", arg.name)
			case .Uint:
				fmt.wprintfln(w, "\tevent.{} = message_read_u32(&reader) or_return", arg.name)
			case .Fixed:
				fmt.wprintfln(w, "\tevent.{} = message_read_fixed(&reader) or_return", arg.name)
			case .String:
				fmt.wprintfln(w, "\tevent.{} = message_read_string(&reader) or_return", arg.name)
			case .Array:
				fmt.wprintfln(w, "\tevent.{} = message_read_array(&reader) or_return", arg.name)
			case .Fd:
				fmt.wprintfln(w, "\tevent.{} = connection_read_fd(conn) or_return", arg.name)
			}
		case Object_Type:
			arg_type_name := arg_type.interface != "" ? arg_type.interface_ada : "Object_Id"
			fmt.wprintfln(
				w,
				"\tevent.{} = message_read_object_id(&reader, {}) or_return",
				arg.name,
				arg_type_name,
			)
		case Enum_Type:
			fmt.wprintfln(
				w,
				"\tevent.{} = message_read_enum(&reader, {}) or_return",
				arg.name,
				make_enum_type_name(arg_type.name, interface.name_ada),
			)
		}
	}
	switch event.type {
	case .Basic: // no-op
	case .Destructor:
		fmt.wprintln(w, "\tconnection_free_id(conn, message.header.target)")
	}

	fmt.wprintln(
		w,
		`
	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}`,
	)

	fmt.wprintf(
		w,
		"\t" + `log.debugf("<- " + {:q} + "@{{}}." + {:q} + ":"`,
		interface.name,
		event.name,
	)
	for arg in event.args {

		fmt.wprintf(w, ` + " " + {:q} + "={{}}"`, arg.name)
	}
	fmt.wprint(w, ", event.target")
	for arg in event.args {
		fmt.wprintf(w, ", event.{}", arg.name)
	}
	fmt.wprintln(w, `)`)

	fmt.wprintln(w, "\treturn\n}\n")
	return nil
}

make_enum_type_name :: proc(enum_name: string, default_iface_type_name: string) -> string {
	iface_type_name, enum_type_name: string
	if dot_idx := strings.index_byte(enum_name, '.'); dot_idx > 0 {
		iface_type_name = strings.to_ada_case(enum_name[:dot_idx])
		enum_type_name = strings.to_ada_case(enum_name[dot_idx + 1:])
	} else {
		iface_type_name = default_iface_type_name
		enum_type_name = strings.to_ada_case(enum_name)
	}
	suffix :: "_Enum"
	sb := strings.builder_make(0, len(iface_type_name) + 1 + len(enum_type_name) + len(suffix))
	strings.write_string(&sb, iface_type_name)
	strings.write_byte(&sb, '_')
	strings.write_string(&sb, enum_type_name)
	strings.write_string(&sb, suffix)
	return strings.to_string(sb)
}

codegen_doc_comment :: proc(w: io.Writer, desc: Descrition, indent := "") -> Generate_Error {
	if desc.summary != "" {
		fmt.wprintfln(w, "{}// {}", indent, desc.summary)
	}
	body := desc.body
	if body != "" {
		fmt.wprintfln(w, "{}//", indent)
	}
	for line in strings.split_lines_iterator(&body) {
		fmt.wprintfln(w, "{}// {}", indent, strings.trim_left_space(line))
	}
	return nil
}

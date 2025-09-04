package wayland

import "base:intrinsics"
import "core:bytes"
import "core:io"
import "core:math/fixed"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import "core:strings"

Object_Id :: distinct u32
Opcode :: distinct u16
Event_Opcode :: distinct u16
Fixed :: fixed.Fixed(u32, 8)

OBJECT_ID_NIL: Object_Id : 0
MIN_CLIENT_ID: Object_Id : 1
MAX_CLIENT_ID: Object_Id : 0xFEFFFFFF
MIN_SERVER_ID: Object_Id : 0xFF000000
MAX_SERVER_ID: Object_Id : 0xFFFFFFFF

message_header_size :: 8

Event_Header :: struct {
	target: Object_Id,
	opcode: Event_Opcode,
	size:   u16,
}

Message :: struct {
	header:  Event_Header,
	payload: []u8,
}

message_parse_header :: proc(buf: [message_header_size]u8) -> (header: Event_Header) {
	buf := buf
	mem.copy(&header.target, &buf[0], size_of(header.target))
	mem.copy(&header.opcode, &buf[4], size_of(header.opcode))
	mem.copy(&header.size, &buf[6], size_of(header.size))
	return
}

message_read_u32 :: proc(reader: ^bytes.Reader) -> (n: u32, err: io.Error) {
	_, err = bytes.reader_read(reader, mem.ptr_to_bytes(&n))
	return
}

message_read_i32 :: proc(reader: ^bytes.Reader) -> (n: i32, err: io.Error) {
	_, err = bytes.reader_read(reader, mem.ptr_to_bytes(&n))
	return
}

message_read_fixed :: proc(reader: ^bytes.Reader) -> (n: Fixed, err: io.Error) {
	n.i, err = message_read_u32(reader)
	return
}

message_read_object_id :: #force_inline proc(
	reader: ^bytes.Reader,
	$T: typeid,
) -> (
	id: T,
	err: io.Error,
) where intrinsics.type_is_integer(T) &&
	size_of(T) == size_of(u32) {
	n: u32
	n, err = message_read_u32(reader)
	return T(n), err
}

message_read_enum :: proc(
	reader: ^bytes.Reader,
	$T: typeid,
) -> (
	val: T,
	err: io.Error,
) where (intrinsics.type_is_enum(T) || intrinsics.type_is_bit_set(T)) &&
	size_of(T) == size_of(u32) {
	n: u32
	n, err = message_read_u32(reader)

	when intrinsics.type_is_enum(T) {
		// TODO: Just cast and hope? Check in generated code?
		for v in reflect.enum_field_values(T) {
			if i64(n) == i64(v) {
				return T(n), .None
			}
		}

		// TODO: Custom error for enums
		err = .Unknown
		return
	} else {
		// Can't check bit_set as easily
		return transmute(T)(n), .None
	}
}

// The returned array references the buffer in `reader`
message_read_array :: proc(reader: ^bytes.Reader) -> (arr: []u8, err: io.Error) {
	arr_size: u32
	arr_size, err = message_read_u32(reader)
	if err != .None do return

	padded_size := align_4(arr_size)
	if bytes.reader_length(reader) < padded_size {
		err = .Short_Buffer
		return
	}
	arr = reader.s[reader.i:][:arr_size]
	reader.i += i64(padded_size)
	return
}

// The returned string references the buffer in `reader`
message_read_string :: proc(reader: ^bytes.Reader) -> (str: string, err: io.Error) {
	arr: []u8
	arr, err = message_read_array(reader)
	if err != .None do return
	// Leave off null byte
	return string(arr[:len(arr) - 1]), err
}

message_write_header :: proc(
	writer: io.Writer,
	target: Object_Id,
	opcode: Opcode,
	size: u16,
) -> io.Error {
	target := target
	opcode := opcode
	size := size
	// Copy to local buf to reduce io.write calls
	header := [8]u8{}
	mem.copy(&header[0], &target, size_of(target))
	mem.copy(&header[4], &opcode, size_of(opcode))
	mem.copy(&header[6], &size, size_of(size))
	_, err := io.write(writer, header[:])
	return err
}

message_write_u32 :: proc(writer: io.Writer, n: u32) -> io.Error {
	n := n
	_, err := io.write_ptr(writer, &n, size_of(n))
	return err
}

message_write_i32 :: proc(writer: io.Writer, n: i32) -> io.Error {
	// TODO: Make sure this is a bitcast, not a checked cast
	return message_write_u32(writer, u32(n))
}

message_write_object_id :: #force_inline proc(
	writer: io.Writer,
	id: $T,
) -> io.Error where intrinsics.type_is_integer(T) &&
	size_of(T) == size_of(u32) {
	return message_write_u32(writer, u32(id))
}

message_write_enum :: #force_inline proc(
	writer: io.Writer,
	val: $T,
) -> io.Error where intrinsics.type_is_enum(T) &&
	size_of(T) == size_of(u32) {
	return message_write_u32(writer, u32(val))
}

message_write_bit_set :: #force_inline proc(
	writer: io.Writer,
	val: $T,
) -> io.Error where intrinsics.type_is_bit_set(T) &&
	size_of(T) == size_of(u32) {
	return message_write_u32(writer, transmute(u32)(val))
}

@(private)
align_4 :: #force_inline proc(#any_int n: int) -> int {
	return (n + 3) &~ 3
}

message_string_size :: proc(str_len: int) -> u16 {
	return u16(size_of(u32) + align_4(str_len + 1))
}

message_write_string :: proc(writer: io.Writer, str: string) -> io.Error {
	len_with_0 := len(str) + 1
	err := message_write(writer, u32(len_with_0))
	if err != .None do return err

	_, err = io.write_string(writer, str)
	if err != .None do return err
	err = io.write_byte(writer, 0)
	if err != .None do return err

	pad_len := align_4(len_with_0) - len_with_0
	if pad_len > 0 {
		padding := [3]u8{}
		_, err = io.write(writer, padding[:pad_len])
	}
	return err
}

// TODO: Handle non-byte arrays?
message_array_size :: proc(arr_len_bytes: int) -> u16 {
	return u16(size_of(u32) + align_4(arr_len_bytes))
}

message_write_array :: proc(writer: io.Writer, arr: []u8) -> io.Error {
	err := message_write(writer, u32(len(arr)))
	if err != .None do return err

	_, err = io.write(writer, arr)
	if err != .None do return err

	pad_len := align_4(len(arr)) - len(arr)
	if pad_len > 0 {
		padding := [3]u8{}
		_, err = io.write(writer, padding[:pad_len])
	}
	return err
}

message_write :: proc {
	message_write_u32,
	message_write_i32,
	message_write_object_id,
	message_write_enum,
	message_write_bit_set,
	message_write_string,
	message_write_array,
}

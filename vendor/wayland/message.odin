package wayland

import "base:intrinsics"
import "core:math/fixed"
import "core:mem"
import "core:reflect"

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

// TODO: Use same struct as Msg_Writer?
Msg_Reader :: struct {
	buf: []u8,
	off: int,
}

Parse_Error :: enum {
	None = 0,
	Message_Too_Short,
	Message_Too_Long,
	Invalid_Enum,
}

message_parse_header :: proc(buf: [message_header_size]u8) -> (header: Event_Header) {
	buf := buf
	mem.copy(&header.target, &buf[0], size_of(header.target))
	mem.copy(&header.opcode, &buf[4], size_of(header.opcode))
	mem.copy(&header.size, &buf[6], size_of(header.size))
	return
}

@(private)
_reader_check_len :: #force_inline proc(reader: ^Msg_Reader, size: int) -> Parse_Error {
	if reader.off + size <= len(reader.buf) do return nil
	return .Message_Too_Short
}

message_reader_check_empty :: proc(reader: Msg_Reader) -> Parse_Error {
	if reader.off < len(reader.buf) do return .Message_Too_Long
	return nil
}

message_read_u32 :: proc(reader: ^Msg_Reader) -> (n: u32, err: Parse_Error) {
	_reader_check_len(reader, size_of(u32)) or_return
	n = mem.reinterpret_copy(u32, &reader.buf[reader.off])
	reader.off += size_of(u32)
	return
}

message_read_i32 :: proc(reader: ^Msg_Reader) -> (n: i32, err: Parse_Error) {
	_reader_check_len(reader, size_of(i32)) or_return
	n = mem.reinterpret_copy(i32, &reader.buf[reader.off])
	reader.off += size_of(i32)
	return
}

message_read_fixed :: proc(reader: ^Msg_Reader) -> (n: Fixed, err: Parse_Error) {
	n = Fixed{message_read_u32(reader) or_return}
	return
}

message_read_object_id :: #force_inline proc(
	reader: ^Msg_Reader,
	$T: typeid,
) -> (
	id: T,
	err: Parse_Error,
) where intrinsics.type_is_integer(T) &&
	size_of(T) == size_of(u32) {
	id = T(message_read_u32(reader) or_return)
	return
}

message_read_enum :: proc(
	reader: ^Msg_Reader,
	$T: typeid,
) -> (
	val: T,
	err: Parse_Error,
) where (intrinsics.type_is_enum(T) || intrinsics.type_is_bit_set(T)) &&
	size_of(T) == size_of(u32) {
	n := message_read_u32(reader) or_return

	when intrinsics.type_is_enum(T) {
		// TODO: Just cast and hope? Check in generated code?
		for v in reflect.enum_field_values(T) {
			if i64(n) == i64(v) {
				return T(n), nil
			}
		}

		// TODO: Custom error for enums
		return {}, .Invalid_Enum
	} else {
		// Can't check bit_set as easily
		return transmute(T)(n), nil
	}
}

// The returned array references the buffer in `reader`
message_read_array :: proc(reader: ^Msg_Reader) -> (arr: []u8, err: Parse_Error) {
	arr_len: u32
	arr_len = message_read_u32(reader) or_return

	padded_len := _align_4(arr_len)
	_reader_check_len(reader, padded_len) or_return
	arr = reader.buf[reader.off:][:arr_len]
	reader.off += padded_len
	return
}

// The returned string references the buffer in `reader`
message_read_string :: proc(reader: ^Msg_Reader) -> (str: string, err: Parse_Error) {
	arr: []u8
	arr = message_read_array(reader) or_return
	// Leave off null byte
	return string(arr[:len(arr) - 1]), nil
}

Msg_Writer :: struct {
	buf: []u8,
	off: int,
}

@(private)
_writer_assert_space :: proc(writer: ^Msg_Writer, size: int) {
	assert(writer.off + size <= len(writer.buf))
}

message_writer_assert_full :: proc(writer: Msg_Writer) {
	assert(writer.off == len(writer.buf))
}

message_write_header :: proc(writer: ^Msg_Writer, target: Object_Id, opcode: Opcode, size: u16) {
	_writer_assert_space(writer, message_header_size)
	target := target
	opcode := opcode
	size := size
	mem.copy(&writer.buf[writer.off], &target, size_of(target))
	mem.copy(&writer.buf[writer.off + 4], &opcode, size_of(opcode))
	mem.copy(&writer.buf[writer.off + 6], &size, size_of(size))
	writer.off += message_header_size
}

message_write_u32 :: proc(writer: ^Msg_Writer, n: u32) {
	_writer_assert_space(writer, size_of(n))
	n := n
	mem.copy(&writer.buf[writer.off], &n, size_of(n))
	writer.off += size_of(n)
}

message_write_i32 :: proc(writer: ^Msg_Writer, n: i32) {
	_writer_assert_space(writer, size_of(n))
	n := n
	mem.copy(&writer.buf[writer.off], &n, size_of(n))
	writer.off += size_of(n)
}

message_write_object_id :: #force_inline proc(
	writer: ^Msg_Writer,
	id: $T,
) where intrinsics.type_is_integer(T) &&
	size_of(T) == size_of(u32) {
	message_write_u32(writer, u32(id))
}

message_write_enum :: #force_inline proc(
	writer: ^Msg_Writer,
	val: $T,
) where intrinsics.type_is_enum(T) &&
	size_of(T) == size_of(u32) {
	message_write_u32(writer, u32(val))
}

message_write_bit_set :: #force_inline proc(
	writer: ^Msg_Writer,
	val: $T,
) where intrinsics.type_is_bit_set(T) &&
	size_of(T) == size_of(u32) {
	message_write_u32(writer, transmute(u32)(val))
}

@(private)
_align_4 :: #force_inline proc(#any_int n: int) -> int {
	return (n + 3) &~ 3
}

message_string_size :: proc(str_len: int) -> u16 {
	return u16(_align_4(str_len + 1))
}

message_write_string :: proc(writer: ^Msg_Writer, str: string) {
	padded_len := int(message_string_size(len(str)))
	_writer_assert_space(writer, size_of(u32) + padded_len)
	len_with_0 := len(str) + 1
	message_write_u32(writer, u32(len_with_0))

	copy(writer.buf[writer.off:], str)
	writer.buf[writer.off + len(str)] = 0
	writer.off += padded_len
}

// TODO: Handle non-byte arrays?
message_array_size :: proc(arr_len_bytes: int) -> u16 {
	return u16(_align_4(arr_len_bytes))
}

message_write_array :: proc(writer: ^Msg_Writer, arr: []u8) {
	padded_len := int(message_array_size(len(arr)))
	_writer_assert_space(writer, size_of(u32) + padded_len)
	message_write_u32(writer, u32(len(arr)))

	copy(writer.buf[writer.off:], arr)
	writer.off += padded_len
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

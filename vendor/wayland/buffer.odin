package wayland

import "base:runtime"
import "core:io"
import "core:mem"

// Growable I/O buffer
// Similar to bytes.Buffer, but supports lower-level operations, such as
// getting slices to read from / write into, as opposed to relying on io.Stream
Buffer :: struct {
	data:      []u8,
	// Storing allocator is essentially the same as using a dynamic array, but I
	// often want to get slices that aren't in the "active" region, so it's easier
	// to just store a slice referencing the full capacity.
	allocator: runtime.Allocator,
	// Start and end of the active region
	start:     int,
	end:       int,
}

@(private)
BUFFER_MIN_SIZE :: 16

buffer_init :: proc(
	buffer: ^Buffer,
	cap: int,
	allocator := context.allocator,
) -> (
	err: runtime.Allocator_Error,
) {
	buffer.data, err = make([]u8, cap, allocator)
	buffer.allocator = allocator
	buffer.start = 0
	buffer.end = 0
	return
}

buffer_destroy :: proc(buffer: ^Buffer) -> runtime.Allocator_Error {
	return delete(buffer.data)
}

// Get slice that can be read-from
buffer_readable :: #force_inline proc(buffer: Buffer) -> []u8 {
	return buffer.data[buffer.start:buffer.end]
}

// Readable length
buffer_len :: #force_inline proc(buffer: Buffer) -> int {
	return len(buffer_readable(buffer))
}

buffer_commit_read :: #force_inline proc(buffer: ^Buffer, n: int) {
	assert(buffer.start + n <= buffer.end)
	buffer.start += n
}

// Get slice that can be written-to
buffer_writable :: #force_inline proc(buffer: Buffer) -> []u8 {
	return buffer.data[buffer.end:]
}

buffer_commit_write :: #force_inline proc(buffer: ^Buffer, n: int) {
	assert(buffer.end + n <= len(buffer.data))
	buffer.end += n
}

// Writable length
buffer_space :: #force_inline proc(buffer: Buffer) -> int {
	return len(buffer_writable(buffer))
}

// Total capacity
buffer_cap :: #force_inline proc(buffer: Buffer) -> int {
	return len(buffer.data)
}

@(private)
_buffer_copy_back :: proc(buffer: ^Buffer) {
	init_len := buffer_len(buffer^)
	copy(buffer.data, buffer_readable(buffer^))
	buffer.start = 0
	buffer.end = init_len
}

buffer_ensure_space :: proc(buffer: ^Buffer, space: int) -> runtime.Allocator_Error {
	// TODO: Include this in buffer_readable and buffer_writable?
	if buffer.start >= buffer.end {
		buffer.start = 0
		buffer.end = 0
	}

	if space <= buffer_space(buffer^) {
		return nil
	} else if buffer.end + space <= len(buffer.data) {
		// Check if we can move data around to make the space
		// TODO: Grow buffer when the buffer is "mostly full" even if data
		// could be moved to fit the requested space

		_buffer_copy_back(buffer)
		return nil
	} else {
		// TODO: Smarter expanding strategy?
		new_cap := max(len(buffer.data) * 2, len(buffer.data) + space)
		// TODO: Is there a good way to do:
		// - If data can be resized in-place, do that
		// - Otherwise, just allocate a new, empty buffer
		new_data := mem.resize_bytes_non_zeroed(
			buffer.data,
			new_cap,
			allocator = buffer.allocator,
		) or_return
		buffer.data = new_data
		_buffer_copy_back(buffer)
		return nil
	}
}

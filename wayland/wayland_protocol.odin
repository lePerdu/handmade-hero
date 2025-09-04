// This file is generated. Re-generate it by running:
// odin run wayland/scanner -- /usr/share/wayland/wayland.xml wayland/wayland_protocol.odin

// Copyright © 2008-2011 Kristian Høgsberg
// Copyright © 2010-2011 Intel Corporation
// Copyright © 2012-2013 Collabora, Ltd.
// 
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software,
// and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
// 
// The above copyright notice and this permission notice (including the
// next paragraph) shall be included in all copies or substantial
// portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

package wayland

import "core:bytes"
import "core:io"
import "core:log"
import "core:sys/posix"

// core global object
//
// The core global object.  This is a special singleton object.  It
// is used for internal Wayland protocol features.
Wl_Display :: Object_Id

// global error values
//
// These errors are global and can be emitted in response to any
// server request.
Wl_Display_Error_Enum :: enum u32 {
	// server couldn't find object
	Invalid_Object = 0,
	// method doesn't exist on the specified interface or malformed request
	Invalid_Method = 1,
	// server is out of memory
	No_Memory = 2,
	// implementation error in compositor
	Implementation = 3,
}
WL_DISPLAY_SYNC_OPCODE: Opcode : 0
// asynchronous roundtrip
//
// The sync request asks the server to emit the 'done' event
// on the returned wl_callback object.  Since requests are
// handled in-order and events are delivered in-order, this can
// be used as a barrier to ensure all previous requests and the
// resulting events have been handled.
// 
// The object returned by this request will be destroyed by the
// compositor after the callback is fired and as such the client must not
// attempt to use it after that point.
// 
// The callback_data passed in the callback is the event serial.
// - callback: callback object for the sync request
wl_display_sync :: proc(conn_: ^Connection, target_: Wl_Display, ) -> (callback: Wl_Callback, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_DISPLAY_SYNC_OPCODE, msg_size_) or_return
	callback = connection_alloc_id(conn_) or_return
	message_write(writer_, callback) or_return
	log.debugf("-> " + "wl_display" + "@{}." + "sync" + ":" + " " + "callback" + "={}", target_, callback)
	return
}

WL_DISPLAY_GET_REGISTRY_OPCODE: Opcode : 1
// get global registry object
//
// This request creates a registry object that allows the client
// to list and bind the global objects available from the
// compositor.
// 
// It should be noted that the server side resources consumed in
// response to a get_registry request can only be released when the
// client disconnects, not when the client side proxy is destroyed.
// Therefore, clients should invoke get_registry as infrequently as
// possible to avoid wasting memory.
// - registry: global registry object
wl_display_get_registry :: proc(conn_: ^Connection, target_: Wl_Display, ) -> (registry: Wl_Registry, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_DISPLAY_GET_REGISTRY_OPCODE, msg_size_) or_return
	registry = connection_alloc_id(conn_) or_return
	message_write(writer_, registry) or_return
	log.debugf("-> " + "wl_display" + "@{}." + "get_registry" + ":" + " " + "registry" + "={}", target_, registry)
	return
}

// fatal error event
//
// The error event is sent out when a fatal (non-recoverable)
// error has occurred.  The object_id argument is the object
// where the error occurred, most often in response to a request
// to that object.  The code identifies the error and is defined
// by the object interface.  As such, each interface defines its
// own set of error codes.  The message is a brief description
// of the error, for (debugging) convenience.
Wl_Display_Error_Event :: struct {
	target: Wl_Display,
	// object where the error occurred
	object_id: Object_Id,
	// error code
	code: u32,
	// error description
	message: string,
}
WL_DISPLAY_ERROR_EVENT_OPCODE: Event_Opcode : 0
wl_display_error_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Display_Error_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DISPLAY_ERROR_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.object_id = message_read_object_id(&reader, Object_Id) or_return
	event.code = message_read_u32(&reader) or_return
	event.message = message_read_string(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_display" + "@{}." + "error" + ":" + " " + "object_id" + "={}" + " " + "code" + "={}" + " " + "message" + "={}", event.target, event.object_id, event.code, event.message)
	return
}

// acknowledge object ID deletion
//
// This event is used internally by the object ID management
// logic. When a client deletes an object that it had created,
// the server will send this event to acknowledge that it has
// seen the delete request. When the client receives this event,
// it will know that it can safely reuse the object ID.
Wl_Display_Delete_Id_Event :: struct {
	target: Wl_Display,
	// deleted object ID
	id: u32,
}
WL_DISPLAY_DELETE_ID_EVENT_OPCODE: Event_Opcode : 1
wl_display_delete_id_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Display_Delete_Id_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DISPLAY_DELETE_ID_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.id = message_read_u32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_display" + "@{}." + "delete_id" + ":" + " " + "id" + "={}", event.target, event.id)
	return
}

// global registry object
//
// The singleton global registry object.  The server has a number of
// global objects that are available to all clients.  These objects
// typically represent an actual object in the server (for example,
// an input device) or they are singleton objects that provide
// extension functionality.
// 
// When a client creates a registry object, the registry object
// will emit a global event for each global currently in the
// registry.  Globals come and go as a result of device or
// monitor hotplugs, reconfiguration or other events, and the
// registry will send out global and global_remove events to
// keep the client up to date with the changes.  To mark the end
// of the initial burst of events, the client can use the
// wl_display.sync request immediately after calling
// wl_display.get_registry.
// 
// A client can bind to a global object by using the bind
// request.  This creates a client-side handle that lets the object
// emit events to the client and lets the client invoke requests on
// the object.
Wl_Registry :: Object_Id

WL_REGISTRY_BIND_OPCODE: Opcode : 0
// bind an object to the display
//
// Binds a new, client-created object to the server using the
// specified name as the identifier.
// - name: unique numeric name of the object
// - id: bounded object
wl_registry_bind :: proc(conn_: ^Connection, target_: Wl_Registry, name: u32, interface: string, version: u32, ) -> (id: Object_Id, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 12
	msg_size_ += message_string_size(len(interface))
	message_write_header(writer_, target_, WL_REGISTRY_BIND_OPCODE, msg_size_) or_return
	message_write(writer_, name) or_return
	message_write(writer_, interface) or_return
	message_write(writer_, version) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_registry" + "@{}." + "bind" + ":" + " " + "name" + "={}" + " " + "interface" + "={}" + " " + "version" + "={}" + " " + "id" + "={}", target_, name, interface, version, id)
	return
}

// announce global object
//
// Notify the client of global objects.
// 
// The event notifies the client that a global object with
// the given name is now available, and it implements the
// given version of the given interface.
Wl_Registry_Global_Event :: struct {
	target: Wl_Registry,
	// numeric name of the global object
	name: u32,
	// interface implemented by the object
	interface: string,
	// interface version
	version: u32,
}
WL_REGISTRY_GLOBAL_EVENT_OPCODE: Event_Opcode : 0
wl_registry_global_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Registry_Global_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_REGISTRY_GLOBAL_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.name = message_read_u32(&reader) or_return
	event.interface = message_read_string(&reader) or_return
	event.version = message_read_u32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_registry" + "@{}." + "global" + ":" + " " + "name" + "={}" + " " + "interface" + "={}" + " " + "version" + "={}", event.target, event.name, event.interface, event.version)
	return
}

// announce removal of global object
//
// Notify the client of removed global objects.
// 
// This event notifies the client that the global identified
// by name is no longer available.  If the client bound to
// the global using the bind request, the client should now
// destroy that object.
// 
// The object remains valid and requests to the object will be
// ignored until the client destroys it, to avoid races between
// the global going away and a client sending a request to it.
Wl_Registry_Global_Remove_Event :: struct {
	target: Wl_Registry,
	// numeric name of the global object
	name: u32,
}
WL_REGISTRY_GLOBAL_REMOVE_EVENT_OPCODE: Event_Opcode : 1
wl_registry_global_remove_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Registry_Global_Remove_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_REGISTRY_GLOBAL_REMOVE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.name = message_read_u32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_registry" + "@{}." + "global_remove" + ":" + " " + "name" + "={}", event.target, event.name)
	return
}

// callback object
//
// Clients can handle the 'done' event to get notified when
// the related request is done.
// 
// Note, because wl_callback objects are created from multiple independent
// factory interfaces, the wl_callback interface is frozen at version 1.
Wl_Callback :: Object_Id

// done event
//
// Notify the client when the related request is done.
Wl_Callback_Done_Event :: struct {
	target: Wl_Callback,
	// request-specific data for the callback
	callback_data: u32,
}
WL_CALLBACK_DONE_EVENT_OPCODE: Event_Opcode : 0
wl_callback_done_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Callback_Done_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_CALLBACK_DONE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.callback_data = message_read_u32(&reader) or_return
	connection_free_id(conn, message.header.target)

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_callback" + "@{}." + "done" + ":" + " " + "callback_data" + "={}", event.target, event.callback_data)
	return
}

// the compositor singleton
//
// A compositor.  This object is a singleton global.  The
// compositor is in charge of combining the contents of multiple
// surfaces into one displayable output.
Wl_Compositor :: Object_Id

WL_COMPOSITOR_CREATE_SURFACE_OPCODE: Opcode : 0
// create new surface
//
// Ask the compositor to create a new surface.
// - id: the new surface
wl_compositor_create_surface :: proc(conn_: ^Connection, target_: Wl_Compositor, ) -> (id: Wl_Surface, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_COMPOSITOR_CREATE_SURFACE_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_compositor" + "@{}." + "create_surface" + ":" + " " + "id" + "={}", target_, id)
	return
}

WL_COMPOSITOR_CREATE_REGION_OPCODE: Opcode : 1
// create new region
//
// Ask the compositor to create a new region.
// - id: the new region
wl_compositor_create_region :: proc(conn_: ^Connection, target_: Wl_Compositor, ) -> (id: Wl_Region, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_COMPOSITOR_CREATE_REGION_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_compositor" + "@{}." + "create_region" + ":" + " " + "id" + "={}", target_, id)
	return
}

// a shared memory pool
//
// The wl_shm_pool object encapsulates a piece of memory shared
// between the compositor and client.  Through the wl_shm_pool
// object, the client can allocate shared memory wl_buffer objects.
// All objects created through the same pool share the same
// underlying mapped memory. Reusing the mapped memory avoids the
// setup/teardown overhead and is useful when interactively resizing
// a surface or for many small buffers.
Wl_Shm_Pool :: Object_Id

WL_SHM_POOL_CREATE_BUFFER_OPCODE: Opcode : 0
// create a buffer from the pool
//
// Create a wl_buffer object from the pool.
// 
// The buffer is created offset bytes into the pool and has
// width and height as specified.  The stride argument specifies
// the number of bytes from the beginning of one row to the beginning
// of the next.  The format is the pixel format of the buffer and
// must be one of those advertised through the wl_shm.format event.
// 
// A buffer will keep a reference to the pool it was created from
// so it is valid to destroy the pool immediately after creating
// a buffer from it.
// - id: buffer to create
// - offset: buffer byte offset within the pool
// - width: buffer width, in pixels
// - height: buffer height, in pixels
// - stride: number of bytes from the beginning of one row to the beginning of the next row
// - format: buffer pixel format
wl_shm_pool_create_buffer :: proc(conn_: ^Connection, target_: Wl_Shm_Pool, offset: i32, width: i32, height: i32, stride: i32, format: Wl_Shm_Format_Enum, ) -> (id: Wl_Buffer, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 24
	message_write_header(writer_, target_, WL_SHM_POOL_CREATE_BUFFER_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	message_write(writer_, offset) or_return
	message_write(writer_, width) or_return
	message_write(writer_, height) or_return
	message_write(writer_, stride) or_return
	message_write(writer_, format) or_return
	log.debugf("-> " + "wl_shm_pool" + "@{}." + "create_buffer" + ":" + " " + "id" + "={}" + " " + "offset" + "={}" + " " + "width" + "={}" + " " + "height" + "={}" + " " + "stride" + "={}" + " " + "format" + "={}", target_, id, offset, width, height, stride, format)
	return
}

WL_SHM_POOL_DESTROY_OPCODE: Opcode : 1
// destroy the pool
//
// Destroy the shared memory pool.
// 
// The mmapped memory will be released when all
// buffers that have been created from this pool
// are gone.
wl_shm_pool_destroy :: proc(conn_: ^Connection, target_: Wl_Shm_Pool, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SHM_POOL_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_shm_pool" + "@{}." + "destroy" + ":", target_)
	return
}

WL_SHM_POOL_RESIZE_OPCODE: Opcode : 2
// change the size of the pool mapping
//
// This request will cause the server to remap the backing memory
// for the pool from the file descriptor passed when the pool was
// created, but using the new size.  This request can only be
// used to make the pool bigger.
// 
// This request only changes the amount of bytes that are mmapped
// by the server and does not touch the file corresponding to the
// file descriptor passed at creation time. It is the client's
// responsibility to ensure that the file is at least as big as
// the new pool size.
// - size: new size of the pool, in bytes
wl_shm_pool_resize :: proc(conn_: ^Connection, target_: Wl_Shm_Pool, size: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SHM_POOL_RESIZE_OPCODE, msg_size_) or_return
	message_write(writer_, size) or_return
	log.debugf("-> " + "wl_shm_pool" + "@{}." + "resize" + ":" + " " + "size" + "={}", target_, size)
	return
}

// shared memory support
//
// A singleton global object that provides support for shared
// memory.
// 
// Clients can create wl_shm_pool objects using the create_pool
// request.
// 
// On binding the wl_shm object one or more format events
// are emitted to inform clients about the valid pixel formats
// that can be used for buffers.
Wl_Shm :: Object_Id

// wl_shm error values
//
// These errors can be emitted in response to wl_shm requests.
Wl_Shm_Error_Enum :: enum u32 {
	// buffer format is not known
	Invalid_Format = 0,
	// invalid size or stride during pool or buffer creation
	Invalid_Stride = 1,
	// mmapping the file descriptor failed
	Invalid_Fd = 2,
}
// pixel formats
//
// This describes the memory layout of an individual pixel.
// 
// All renderers should support argb8888 and xrgb8888 but any other
// formats are optional and may not be supported by the particular
// renderer in use.
// 
// The drm format codes match the macros defined in drm_fourcc.h, except
// argb8888 and xrgb8888. The formats actually supported by the compositor
// will be reported by the format event.
// 
// For all wl_shm formats and unless specified in another protocol
// extension, pre-multiplied alpha is used for pixel values.
Wl_Shm_Format_Enum :: enum u32 {
	// 32-bit ARGB format, [31:0] A:R:G:B 8:8:8:8 little endian
	Argb8888 = 0,
	// 32-bit RGB format, [31:0] x:R:G:B 8:8:8:8 little endian
	Xrgb8888 = 1,
	// 8-bit color index format, [7:0] C
	C8 = 538982467,
	// [7:0] R
	R8 = 538982482,
	// [15:0] R little endian
	R16 = 540422482,
	// 2x2 subsampled Cr:Cb plane 10 bits per channel
	P010 = 808530000,
	// 2x1 subsampled Cr:Cb plane, 10 bit per channel
	P210 = 808530512,
	// [63:0] Cr0:0:Y1:0:Cb0:0:Y0:0 10:6:10:6:10:6:10:6 little endian per 2 Y pixels
	Y210 = 808530521,
	Q410 = 808531025,
	// [31:0] A:Cr:Y:Cb 2:10:10:10 little endian
	Y410 = 808531033,
	// [63:0] A:x:B:x:G:x:R:x 10:6:10:6:10:6:10:6 little endian
	Axbxgxrx106106106106 = 808534593,
	Yuv420_10bit = 808539481,
	// 32-bit BGRA format, [31:0] B:G:R:A 10:10:10:2 little endian
	Bgra1010102 = 808665410,
	// 32-bit RGBA format, [31:0] R:G:B:A 10:10:10:2 little endian
	Rgba1010102 = 808665426,
	// 32-bit ABGR format, [31:0] A:B:G:R 2:10:10:10 little endian
	Abgr2101010 = 808665665,
	// 32-bit xBGR format, [31:0] x:B:G:R 2:10:10:10 little endian
	Xbgr2101010 = 808665688,
	// 32-bit ARGB format, [31:0] A:R:G:B 2:10:10:10 little endian
	Argb2101010 = 808669761,
	// 32-bit xRGB format, [31:0] x:R:G:B 2:10:10:10 little endian
	Xrgb2101010 = 808669784,
	// Y followed by U then V, 10:10:10. Non-linear modifier only
	Vuy101010 = 808670550,
	// [31:0] X:Cr:Y:Cb 2:10:10:10 little endian
	Xvyu2101010 = 808670808,
	// 32-bit BGRx format, [31:0] B:G:R:x 10:10:10:2 little endian
	Bgrx1010102 = 808671298,
	// 32-bit RGBx format, [31:0] R:G:B:x 10:10:10:2 little endian
	Rgbx1010102 = 808671314,
	// [63:0] X3:X2:Y3:0:Cr0:0:Y2:0:X1:X0:Y1:0:Cb0:0:Y0:0 1:1:8:2:8:2:8:2:1:1:8:2:8:2:8:2 little endian
	X0l0 = 810299480,
	// [63:0] A3:A2:Y3:0:Cr0:0:Y2:0:A1:A0:Y1:0:Cb0:0:Y0:0 1:1:8:2:8:2:8:2:1:1:8:2:8:2:8:2 little endian
	Y0l0 = 810299481,
	Q401 = 825242705,
	// 3 plane YCbCr format, 4x1 subsampled Cb (1) and Cr (2) planes
	Yuv411 = 825316697,
	// 3 plane YCbCr format, 4x1 subsampled Cr (1) and Cb (2) planes
	Yvu411 = 825316953,
	// 2 plane YCbCr Cb:Cr format, 2x2 subsampled Cb:Cr plane
	Nv21 = 825382478,
	// 2 plane YCbCr Cb:Cr format, 2x1 subsampled Cb:Cr plane
	Nv61 = 825644622,
	// 2x2 subsampled Cr:Cb plane 12 bits per channel
	P012 = 842084432,
	// [63:0] Cr0:0:Y1:0:Cb0:0:Y0:0 12:4:12:4:12:4:12:4 little endian per 2 Y pixels
	Y212 = 842084953,
	// [63:0] A:0:Cr:0:Y:0:Cb:0 12:4:12:4:12:4:12:4 little endian
	Y412 = 842085465,
	// 16-bit BGRA format, [15:0] B:G:R:A 4:4:4:4 little endian
	Bgra4444 = 842088770,
	// 16-bit RBGA format, [15:0] R:G:B:A 4:4:4:4 little endian
	Rgba4444 = 842088786,
	// 16-bit ABGR format, [15:0] A:B:G:R 4:4:4:4 little endian
	Abgr4444 = 842089025,
	// 16-bit xBGR format, [15:0] x:B:G:R 4:4:4:4 little endian
	Xbgr4444 = 842089048,
	// 16-bit ARGB format, [15:0] A:R:G:B 4:4:4:4 little endian
	Argb4444 = 842093121,
	// 16-bit xRGB format, [15:0] x:R:G:B 4:4:4:4 little endian
	Xrgb4444 = 842093144,
	// 3 plane YCbCr format, 2x2 subsampled Cb (1) and Cr (2) planes
	Yuv420 = 842093913,
	// 2 plane YCbCr Cr:Cb format, 2x2 subsampled Cr:Cb plane
	Nv12 = 842094158,
	// 3 plane YCbCr format, 2x2 subsampled Cr (1) and Cb (2) planes
	Yvu420 = 842094169,
	// 16-bit BGRx format, [15:0] B:G:R:x 4:4:4:4 little endian
	Bgrx4444 = 842094658,
	// 16-bit RGBx format, [15:0] R:G:B:x 4:4:4:4 little endian
	Rgbx4444 = 842094674,
	// [31:0] R:G 16:16 little endian
	Rg1616 = 842221394,
	// [31:0] G:R 16:16 little endian
	Gr1616 = 842224199,
	// non-subsampled Cb:Cr plane
	Nv42 = 842290766,
	// [63:0] X3:X2:Y3:Cr0:Y2:X1:X0:Y1:Cb0:Y0 1:1:10:10:10:1:1:10:10:10 little endian
	X0l2 = 843853912,
	// [63:0] A3:A2:Y3:Cr0:Y2:A1:A0:Y1:Cb0:Y0 1:1:10:10:10:1:1:10:10:10 little endian
	Y0l2 = 843853913,
	// 32-bit BGRA format, [31:0] B:G:R:A 8:8:8:8 little endian
	Bgra8888 = 875708738,
	// 32-bit RGBA format, [31:0] R:G:B:A 8:8:8:8 little endian
	Rgba8888 = 875708754,
	// 32-bit ABGR format, [31:0] A:B:G:R 8:8:8:8 little endian
	Abgr8888 = 875708993,
	// 32-bit xBGR format, [31:0] x:B:G:R 8:8:8:8 little endian
	Xbgr8888 = 875709016,
	// 24-bit BGR format, [23:0] B:G:R little endian
	Bgr888 = 875710274,
	// 24-bit RGB format, [23:0] R:G:B little endian
	Rgb888 = 875710290,
	// [23:0] Cr:Cb:Y 8:8:8 little endian
	Vuy888 = 875713878,
	// 3 plane YCbCr format, non-subsampled Cb (1) and Cr (2) planes
	Yuv444 = 875713881,
	// non-subsampled Cr:Cb plane
	Nv24 = 875714126,
	// 3 plane YCbCr format, non-subsampled Cr (1) and Cb (2) planes
	Yvu444 = 875714137,
	// 32-bit BGRx format, [31:0] B:G:R:x 8:8:8:8 little endian
	Bgrx8888 = 875714626,
	// 32-bit RGBx format, [31:0] R:G:B:x 8:8:8:8 little endian
	Rgbx8888 = 875714642,
	// 16-bit BGRA 5551 format, [15:0] B:G:R:A 5:5:5:1 little endian
	Bgra5551 = 892420418,
	// 16-bit RGBA 5551 format, [15:0] R:G:B:A 5:5:5:1 little endian
	Rgba5551 = 892420434,
	// 16-bit ABGR 1555 format, [15:0] A:B:G:R 1:5:5:5 little endian
	Abgr1555 = 892420673,
	// 16-bit xBGR 1555 format, [15:0] x:B:G:R 1:5:5:5 little endian
	Xbgr1555 = 892420696,
	// 16-bit ARGB 1555 format, [15:0] A:R:G:B 1:5:5:5 little endian
	Argb1555 = 892424769,
	// 16-bit xRGB format, [15:0] x:R:G:B 1:5:5:5 little endian
	Xrgb1555 = 892424792,
	// 2x2 subsampled Cr:Cb plane
	Nv15 = 892425806,
	// 16-bit BGRx 5551 format, [15:0] B:G:R:x 5:5:5:1 little endian
	Bgrx5551 = 892426306,
	// 16-bit RGBx 5551 format, [15:0] R:G:B:x 5:5:5:1 little endian
	Rgbx5551 = 892426322,
	// 2x2 subsampled Cr:Cb plane 16 bits per channel
	P016 = 909193296,
	// [63:0] Cr0:Y1:Cb0:Y0 16:16:16:16 little endian per 2 Y pixels
	Y216 = 909193817,
	// [63:0] A:Cr:Y:Cb 16:16:16:16 little endian
	Y416 = 909194329,
	// 16-bit BGR 565 format, [15:0] B:G:R 5:6:5 little endian
	Bgr565 = 909199170,
	// 16-bit RGB 565 format, [15:0] R:G:B 5:6:5 little endian
	Rgb565 = 909199186,
	// 3 plane YCbCr format, 2x1 subsampled Cb (1) and Cr (2) planes
	Yuv422 = 909202777,
	// 2 plane YCbCr Cr:Cb format, 2x1 subsampled Cr:Cb plane
	Nv16 = 909203022,
	// 3 plane YCbCr format, 2x1 subsampled Cr (1) and Cb (2) planes
	Yvu422 = 909203033,
	// [63:0] X:0:Cr:0:Y:0:Cb:0 12:4:12:4:12:4:12:4 little endian
	Xvyu12_16161616 = 909334104,
	Yuv420_8bit = 942691673,
	// [63:0] A:B:G:R 16:16:16:16 little endian
	Abgr16161616 = 942948929,
	// [63:0] x:B:G:R 16:16:16:16 little endian
	Xbgr16161616 = 942948952,
	// [63:0] A:R:G:B 16:16:16:16 little endian
	Argb16161616 = 942953025,
	// [63:0] x:R:G:B 16:16:16:16 little endian
	Xrgb16161616 = 942953048,
	// [63:0] X:Cr:Y:Cb 16:16:16:16 little endian
	Xvyu16161616 = 942954072,
	// [15:0] R:G 8:8 little endian
	Rg88 = 943212370,
	// [15:0] G:R 8:8 little endian
	Gr88 = 943215175,
	Bgr565_A8 = 943797570,
	Rgb565_A8 = 943797586,
	Bgr888_A8 = 943798338,
	Rgb888_A8 = 943798354,
	Xbgr8888_A8 = 943800920,
	Xrgb8888_A8 = 943805016,
	Bgrx8888_A8 = 943806530,
	Rgbx8888_A8 = 943806546,
	// 8-bit RGB format, [7:0] R:G:B 3:3:2
	Rgb332 = 943867730,
	// 8-bit BGR format, [7:0] B:G:R 2:3:3
	Bgr233 = 944916290,
	// 3 plane YCbCr format, 4x4 subsampled Cr (1) and Cb (2) planes
	Yvu410 = 961893977,
	// 3 plane YCbCr format, 4x4 subsampled Cb (1) and Cr (2) planes
	Yuv410 = 961959257,
	// [63:0] A:B:G:R 16:16:16:16 little endian
	Abgr16161616f = 1211384385,
	// [63:0] x:B:G:R 16:16:16:16 little endian
	Xbgr16161616f = 1211384408,
	// [63:0] A:R:G:B 16:16:16:16 little endian
	Argb16161616f = 1211388481,
	// [63:0] x:R:G:B 16:16:16:16 little endian
	Xrgb16161616f = 1211388504,
	// packed YCbCr format, [31:0] Cb0:Y1:Cr0:Y0 8:8:8:8 little endian
	Yvyu = 1431918169,
	// packed AYCbCr format, [31:0] A:Y:Cb:Cr 8:8:8:8 little endian
	Ayuv = 1448433985,
	// [31:0] X:Y:Cb:Cr 8:8:8:8 little endian
	Xyuv8888 = 1448434008,
	// packed YCbCr format, [31:0] Cr0:Y1:Cb0:Y0 8:8:8:8 little endian
	Yuyv = 1448695129,
	// packed YCbCr format, [31:0] Y1:Cb0:Y0:Cr0 8:8:8:8 little endian
	Vyuy = 1498765654,
	// packed YCbCr format, [31:0] Y1:Cr0:Y0:Cb0 8:8:8:8 little endian
	Uyvy = 1498831189,
}
WL_SHM_CREATE_POOL_OPCODE: Opcode : 0
// create a shm pool
//
// Create a new wl_shm_pool object.
// 
// The pool can be used to create shared memory based buffer
// objects.  The server will mmap size bytes of the passed file
// descriptor, to use as backing memory for the pool.
// - id: pool to create
// - fd: file descriptor for the pool
// - size: pool size, in bytes
wl_shm_create_pool :: proc(conn_: ^Connection, target_: Wl_Shm, fd: posix.FD, size: i32, ) -> (id: Wl_Shm_Pool, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_SHM_CREATE_POOL_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	connection_write_fd(conn_, fd) or_return
	message_write(writer_, size) or_return
	log.debugf("-> " + "wl_shm" + "@{}." + "create_pool" + ":" + " " + "id" + "={}" + " " + "fd" + "={}" + " " + "size" + "={}", target_, id, fd, size)
	return
}

// pixel format description
//
// Informs the client about a valid pixel format that
// can be used for buffers. Known formats include
// argb8888 and xrgb8888.
Wl_Shm_Format_Event :: struct {
	target: Wl_Shm,
	// buffer pixel format
	format: Wl_Shm_Format_Enum,}
WL_SHM_FORMAT_EVENT_OPCODE: Event_Opcode : 0
wl_shm_format_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Shm_Format_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SHM_FORMAT_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.format = message_read_enum(&reader, Wl_Shm_Format_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_shm" + "@{}." + "format" + ":" + " " + "format" + "={}", event.target, event.format)
	return
}

// content for a wl_surface
//
// A buffer provides the content for a wl_surface. Buffers are
// created through factory interfaces such as wl_shm, wp_linux_buffer_params
// (from the linux-dmabuf protocol extension) or similar. It has a width and
// a height and can be attached to a wl_surface, but the mechanism by which a
// client provides and updates the contents is defined by the buffer factory
// interface.
// 
// If the buffer uses a format that has an alpha channel, the alpha channel
// is assumed to be premultiplied in the color channels unless otherwise
// specified.
// 
// Note, because wl_buffer objects are created from multiple independent
// factory interfaces, the wl_buffer interface is frozen at version 1.
Wl_Buffer :: Object_Id

WL_BUFFER_DESTROY_OPCODE: Opcode : 0
// destroy a buffer
//
// Destroy a buffer. If and how you need to release the backing
// storage is defined by the buffer factory interface.
// 
// For possible side-effects to a surface, see wl_surface.attach.
wl_buffer_destroy :: proc(conn_: ^Connection, target_: Wl_Buffer, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_BUFFER_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_buffer" + "@{}." + "destroy" + ":", target_)
	return
}

// compositor releases buffer
//
// Sent when this wl_buffer is no longer used by the compositor.
// The client is now free to reuse or destroy this buffer and its
// backing storage.
// 
// If a client receives a release event before the frame callback
// requested in the same wl_surface.commit that attaches this
// wl_buffer to a surface, then the client is immediately free to
// reuse the buffer and its backing storage, and does not need a
// second buffer for the next surface content update. Typically
// this is possible, when the compositor maintains a copy of the
// wl_surface contents, e.g. as a GL texture. This is an important
// optimization for GL(ES) compositors with wl_shm clients.
Wl_Buffer_Release_Event :: struct {
	target: Wl_Buffer,
}
WL_BUFFER_RELEASE_EVENT_OPCODE: Event_Opcode : 0
wl_buffer_release_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Buffer_Release_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_BUFFER_RELEASE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_buffer" + "@{}." + "release" + ":", event.target)
	return
}

// offer to transfer data
//
// A wl_data_offer represents a piece of data offered for transfer
// by another client (the source client).  It is used by the
// copy-and-paste and drag-and-drop mechanisms.  The offer
// describes the different mime types that the data can be
// converted to and provides the mechanism for transferring the
// data directly from the source client.
Wl_Data_Offer :: Object_Id

Wl_Data_Offer_Error_Enum :: enum u32 {
	// finish request was called untimely
	Invalid_Finish = 0,
	// action mask contains invalid values
	Invalid_Action_Mask = 1,
	// action argument has an invalid value
	Invalid_Action = 2,
	// offer doesn't accept this request
	Invalid_Offer = 3,
}
WL_DATA_OFFER_ACCEPT_OPCODE: Opcode : 0
// accept one of the offered mime types
//
// Indicate that the client can accept the given mime type, or
// NULL for not accepted.
// 
// For objects of version 2 or older, this request is used by the
// client to give feedback whether the client can receive the given
// mime type, or NULL if none is accepted; the feedback does not
// determine whether the drag-and-drop operation succeeds or not.
// 
// For objects of version 3 or newer, this request determines the
// final result of the drag-and-drop operation. If the end result
// is that no mime types were accepted, the drag-and-drop operation
// will be cancelled and the corresponding drag source will receive
// wl_data_source.cancelled. Clients may still use this event in
// conjunction with wl_data_source.action for feedback.
// - serial: serial number of the accept request
// - mime_type: mime type accepted by the client
wl_data_offer_accept :: proc(conn_: ^Connection, target_: Wl_Data_Offer, serial: u32, mime_type: string, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	msg_size_ += message_string_size(len(mime_type))
	message_write_header(writer_, target_, WL_DATA_OFFER_ACCEPT_OPCODE, msg_size_) or_return
	message_write(writer_, serial) or_return
	message_write(writer_, mime_type) or_return
	log.debugf("-> " + "wl_data_offer" + "@{}." + "accept" + ":" + " " + "serial" + "={}" + " " + "mime_type" + "={}", target_, serial, mime_type)
	return
}

WL_DATA_OFFER_RECEIVE_OPCODE: Opcode : 1
// request that the data is transferred
//
// To transfer the offered data, the client issues this request
// and indicates the mime type it wants to receive.  The transfer
// happens through the passed file descriptor (typically created
// with the pipe system call).  The source client writes the data
// in the mime type representation requested and then closes the
// file descriptor.
// 
// The receiving client reads from the read end of the pipe until
// EOF and then closes its end, at which point the transfer is
// complete.
// 
// This request may happen multiple times for different mime types,
// both before and after wl_data_device.drop. Drag-and-drop destination
// clients may preemptively fetch data or examine it more closely to
// determine acceptance.
// - mime_type: mime type desired by receiver
// - fd: file descriptor for data transfer
wl_data_offer_receive :: proc(conn_: ^Connection, target_: Wl_Data_Offer, mime_type: string, fd: posix.FD, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	msg_size_ += message_string_size(len(mime_type))
	message_write_header(writer_, target_, WL_DATA_OFFER_RECEIVE_OPCODE, msg_size_) or_return
	message_write(writer_, mime_type) or_return
	connection_write_fd(conn_, fd) or_return
	log.debugf("-> " + "wl_data_offer" + "@{}." + "receive" + ":" + " " + "mime_type" + "={}" + " " + "fd" + "={}", target_, mime_type, fd)
	return
}

WL_DATA_OFFER_DESTROY_OPCODE: Opcode : 2
// destroy data offer
//
// Destroy the data offer.
wl_data_offer_destroy :: proc(conn_: ^Connection, target_: Wl_Data_Offer, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_DATA_OFFER_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_data_offer" + "@{}." + "destroy" + ":", target_)
	return
}

WL_DATA_OFFER_FINISH_OPCODE: Opcode : 3
// the offer will no longer be used
//
// Notifies the compositor that the drag destination successfully
// finished the drag-and-drop operation.
// 
// Upon receiving this request, the compositor will emit
// wl_data_source.dnd_finished on the drag source client.
// 
// It is a client error to perform other requests than
// wl_data_offer.destroy after this one. It is also an error to perform
// this request after a NULL mime type has been set in
// wl_data_offer.accept or no action was received through
// wl_data_offer.action.
// 
// If wl_data_offer.finish request is received for a non drag and drop
// operation, the invalid_finish protocol error is raised.
wl_data_offer_finish :: proc(conn_: ^Connection, target_: Wl_Data_Offer, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_DATA_OFFER_FINISH_OPCODE, msg_size_) or_return
	log.debugf("-> " + "wl_data_offer" + "@{}." + "finish" + ":", target_)
	return
}

WL_DATA_OFFER_SET_ACTIONS_OPCODE: Opcode : 4
// set the available/preferred drag-and-drop actions
//
// Sets the actions that the destination side client supports for
// this operation. This request may trigger the emission of
// wl_data_source.action and wl_data_offer.action events if the compositor
// needs to change the selected action.
// 
// This request can be called multiple times throughout the
// drag-and-drop operation, typically in response to wl_data_device.enter
// or wl_data_device.motion events.
// 
// This request determines the final result of the drag-and-drop
// operation. If the end result is that no action is accepted,
// the drag source will receive wl_data_source.cancelled.
// 
// The dnd_actions argument must contain only values expressed in the
// wl_data_device_manager.dnd_actions enum, and the preferred_action
// argument must only contain one of those values set, otherwise it
// will result in a protocol error.
// 
// While managing an "ask" action, the destination drag-and-drop client
// may perform further wl_data_offer.receive requests, and is expected
// to perform one last wl_data_offer.set_actions request with a preferred
// action other than "ask" (and optionally wl_data_offer.accept) before
// requesting wl_data_offer.finish, in order to convey the action selected
// by the user. If the preferred action is not in the
// wl_data_offer.source_actions mask, an error will be raised.
// 
// If the "ask" action is dismissed (e.g. user cancellation), the client
// is expected to perform wl_data_offer.destroy right away.
// 
// This request can only be made on drag-and-drop offers, a protocol error
// will be raised otherwise.
// - dnd_actions: actions supported by the destination client
// - preferred_action: action preferred by the destination client
wl_data_offer_set_actions :: proc(conn_: ^Connection, target_: Wl_Data_Offer, dnd_actions: Wl_Data_Device_Manager_Dnd_Action_Enum, preferred_action: Wl_Data_Device_Manager_Dnd_Action_Enum, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_DATA_OFFER_SET_ACTIONS_OPCODE, msg_size_) or_return
	message_write(writer_, dnd_actions) or_return
	message_write(writer_, preferred_action) or_return
	log.debugf("-> " + "wl_data_offer" + "@{}." + "set_actions" + ":" + " " + "dnd_actions" + "={}" + " " + "preferred_action" + "={}", target_, dnd_actions, preferred_action)
	return
}

// advertise offered mime type
//
// Sent immediately after creating the wl_data_offer object.  One
// event per offered mime type.
Wl_Data_Offer_Offer_Event :: struct {
	target: Wl_Data_Offer,
	// offered mime type
	mime_type: string,
}
WL_DATA_OFFER_OFFER_EVENT_OPCODE: Event_Opcode : 0
wl_data_offer_offer_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Offer_Offer_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_OFFER_OFFER_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.mime_type = message_read_string(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_offer" + "@{}." + "offer" + ":" + " " + "mime_type" + "={}", event.target, event.mime_type)
	return
}

// notify the source-side available actions
//
// This event indicates the actions offered by the data source. It
// will be sent immediately after creating the wl_data_offer object,
// or anytime the source side changes its offered actions through
// wl_data_source.set_actions.
Wl_Data_Offer_Source_Actions_Event :: struct {
	target: Wl_Data_Offer,
	// actions offered by the data source
	source_actions: Wl_Data_Device_Manager_Dnd_Action_Enum,}
WL_DATA_OFFER_SOURCE_ACTIONS_EVENT_OPCODE: Event_Opcode : 1
wl_data_offer_source_actions_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Offer_Source_Actions_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_OFFER_SOURCE_ACTIONS_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.source_actions = message_read_enum(&reader, Wl_Data_Device_Manager_Dnd_Action_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_offer" + "@{}." + "source_actions" + ":" + " " + "source_actions" + "={}", event.target, event.source_actions)
	return
}

// notify the selected action
//
// This event indicates the action selected by the compositor after
// matching the source/destination side actions. Only one action (or
// none) will be offered here.
// 
// This event can be emitted multiple times during the drag-and-drop
// operation in response to destination side action changes through
// wl_data_offer.set_actions.
// 
// This event will no longer be emitted after wl_data_device.drop
// happened on the drag-and-drop destination, the client must
// honor the last action received, or the last preferred one set
// through wl_data_offer.set_actions when handling an "ask" action.
// 
// Compositors may also change the selected action on the fly, mainly
// in response to keyboard modifier changes during the drag-and-drop
// operation.
// 
// The most recent action received is always the valid one. Prior to
// receiving wl_data_device.drop, the chosen action may change (e.g.
// due to keyboard modifiers being pressed). At the time of receiving
// wl_data_device.drop the drag-and-drop destination must honor the
// last action received.
// 
// Action changes may still happen after wl_data_device.drop,
// especially on "ask" actions, where the drag-and-drop destination
// may choose another action afterwards. Action changes happening
// at this stage are always the result of inter-client negotiation, the
// compositor shall no longer be able to induce a different action.
// 
// Upon "ask" actions, it is expected that the drag-and-drop destination
// may potentially choose a different action and/or mime type,
// based on wl_data_offer.source_actions and finally chosen by the
// user (e.g. popping up a menu with the available options). The
// final wl_data_offer.set_actions and wl_data_offer.accept requests
// must happen before the call to wl_data_offer.finish.
Wl_Data_Offer_Action_Event :: struct {
	target: Wl_Data_Offer,
	// action selected by the compositor
	dnd_action: Wl_Data_Device_Manager_Dnd_Action_Enum,}
WL_DATA_OFFER_ACTION_EVENT_OPCODE: Event_Opcode : 2
wl_data_offer_action_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Offer_Action_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_OFFER_ACTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.dnd_action = message_read_enum(&reader, Wl_Data_Device_Manager_Dnd_Action_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_offer" + "@{}." + "action" + ":" + " " + "dnd_action" + "={}", event.target, event.dnd_action)
	return
}

// offer to transfer data
//
// The wl_data_source object is the source side of a wl_data_offer.
// It is created by the source client in a data transfer and
// provides a way to describe the offered data and a way to respond
// to requests to transfer the data.
Wl_Data_Source :: Object_Id

Wl_Data_Source_Error_Enum :: enum u32 {
	// action mask contains invalid values
	Invalid_Action_Mask = 0,
	// source doesn't accept this request
	Invalid_Source = 1,
}
WL_DATA_SOURCE_OFFER_OPCODE: Opcode : 0
// add an offered mime type
//
// This request adds a mime type to the set of mime types
// advertised to targets.  Can be called several times to offer
// multiple types.
// - mime_type: mime type offered by the data source
wl_data_source_offer :: proc(conn_: ^Connection, target_: Wl_Data_Source, mime_type: string, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	msg_size_ += message_string_size(len(mime_type))
	message_write_header(writer_, target_, WL_DATA_SOURCE_OFFER_OPCODE, msg_size_) or_return
	message_write(writer_, mime_type) or_return
	log.debugf("-> " + "wl_data_source" + "@{}." + "offer" + ":" + " " + "mime_type" + "={}", target_, mime_type)
	return
}

WL_DATA_SOURCE_DESTROY_OPCODE: Opcode : 1
// destroy the data source
//
// Destroy the data source.
wl_data_source_destroy :: proc(conn_: ^Connection, target_: Wl_Data_Source, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_DATA_SOURCE_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_data_source" + "@{}." + "destroy" + ":", target_)
	return
}

WL_DATA_SOURCE_SET_ACTIONS_OPCODE: Opcode : 2
// set the available drag-and-drop actions
//
// Sets the actions that the source side client supports for this
// operation. This request may trigger wl_data_source.action and
// wl_data_offer.action events if the compositor needs to change the
// selected action.
// 
// The dnd_actions argument must contain only values expressed in the
// wl_data_device_manager.dnd_actions enum, otherwise it will result
// in a protocol error.
// 
// This request must be made once only, and can only be made on sources
// used in drag-and-drop, so it must be performed before
// wl_data_device.start_drag. Attempting to use the source other than
// for drag-and-drop will raise a protocol error.
// - dnd_actions: actions supported by the data source
wl_data_source_set_actions :: proc(conn_: ^Connection, target_: Wl_Data_Source, dnd_actions: Wl_Data_Device_Manager_Dnd_Action_Enum, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_DATA_SOURCE_SET_ACTIONS_OPCODE, msg_size_) or_return
	message_write(writer_, dnd_actions) or_return
	log.debugf("-> " + "wl_data_source" + "@{}." + "set_actions" + ":" + " " + "dnd_actions" + "={}", target_, dnd_actions)
	return
}

// a target accepts an offered mime type
//
// Sent when a target accepts pointer_focus or motion events.  If
// a target does not accept any of the offered types, type is NULL.
// 
// Used for feedback during drag-and-drop.
Wl_Data_Source_Target_Event :: struct {
	target: Wl_Data_Source,
	// mime type accepted by the target
	mime_type: string,
}
WL_DATA_SOURCE_TARGET_EVENT_OPCODE: Event_Opcode : 0
wl_data_source_target_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Source_Target_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_SOURCE_TARGET_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.mime_type = message_read_string(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_source" + "@{}." + "target" + ":" + " " + "mime_type" + "={}", event.target, event.mime_type)
	return
}

// send the data
//
// Request for data from the client.  Send the data as the
// specified mime type over the passed file descriptor, then
// close it.
Wl_Data_Source_Send_Event :: struct {
	target: Wl_Data_Source,
	// mime type for the data
	mime_type: string,
	// file descriptor for the data
	fd: posix.FD,
}
WL_DATA_SOURCE_SEND_EVENT_OPCODE: Event_Opcode : 1
wl_data_source_send_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Source_Send_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_SOURCE_SEND_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.mime_type = message_read_string(&reader) or_return
	event.fd = connection_read_fd(conn) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_source" + "@{}." + "send" + ":" + " " + "mime_type" + "={}" + " " + "fd" + "={}", event.target, event.mime_type, event.fd)
	return
}

// selection was cancelled
//
// This data source is no longer valid. There are several reasons why
// this could happen:
// 
// - The data source has been replaced by another data source.
// - The drag-and-drop operation was performed, but the drop destination
// did not accept any of the mime types offered through
// wl_data_source.target.
// - The drag-and-drop operation was performed, but the drop destination
// did not select any of the actions present in the mask offered through
// wl_data_source.action.
// - The drag-and-drop operation was performed but didn't happen over a
// surface.
// - The compositor cancelled the drag-and-drop operation (e.g. compositor
// dependent timeouts to avoid stale drag-and-drop transfers).
// 
// The client should clean up and destroy this data source.
// 
// For objects of version 2 or older, wl_data_source.cancelled will
// only be emitted if the data source was replaced by another data
// source.
Wl_Data_Source_Cancelled_Event :: struct {
	target: Wl_Data_Source,
}
WL_DATA_SOURCE_CANCELLED_EVENT_OPCODE: Event_Opcode : 2
wl_data_source_cancelled_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Source_Cancelled_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_SOURCE_CANCELLED_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_source" + "@{}." + "cancelled" + ":", event.target)
	return
}

// the drag-and-drop operation physically finished
//
// The user performed the drop action. This event does not indicate
// acceptance, wl_data_source.cancelled may still be emitted afterwards
// if the drop destination does not accept any mime type.
// 
// However, this event might however not be received if the compositor
// cancelled the drag-and-drop operation before this event could happen.
// 
// Note that the data_source may still be used in the future and should
// not be destroyed here.
Wl_Data_Source_Dnd_Drop_Performed_Event :: struct {
	target: Wl_Data_Source,
}
WL_DATA_SOURCE_DND_DROP_PERFORMED_EVENT_OPCODE: Event_Opcode : 3
wl_data_source_dnd_drop_performed_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Source_Dnd_Drop_Performed_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_SOURCE_DND_DROP_PERFORMED_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_source" + "@{}." + "dnd_drop_performed" + ":", event.target)
	return
}

// the drag-and-drop operation concluded
//
// The drop destination finished interoperating with this data
// source, so the client is now free to destroy this data source and
// free all associated data.
// 
// If the action used to perform the operation was "move", the
// source can now delete the transferred data.
Wl_Data_Source_Dnd_Finished_Event :: struct {
	target: Wl_Data_Source,
}
WL_DATA_SOURCE_DND_FINISHED_EVENT_OPCODE: Event_Opcode : 4
wl_data_source_dnd_finished_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Source_Dnd_Finished_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_SOURCE_DND_FINISHED_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_source" + "@{}." + "dnd_finished" + ":", event.target)
	return
}

// notify the selected action
//
// This event indicates the action selected by the compositor after
// matching the source/destination side actions. Only one action (or
// none) will be offered here.
// 
// This event can be emitted multiple times during the drag-and-drop
// operation, mainly in response to destination side changes through
// wl_data_offer.set_actions, and as the data device enters/leaves
// surfaces.
// 
// It is only possible to receive this event after
// wl_data_source.dnd_drop_performed if the drag-and-drop operation
// ended in an "ask" action, in which case the final wl_data_source.action
// event will happen immediately before wl_data_source.dnd_finished.
// 
// Compositors may also change the selected action on the fly, mainly
// in response to keyboard modifier changes during the drag-and-drop
// operation.
// 
// The most recent action received is always the valid one. The chosen
// action may change alongside negotiation (e.g. an "ask" action can turn
// into a "move" operation), so the effects of the final action must
// always be applied in wl_data_offer.dnd_finished.
// 
// Clients can trigger cursor surface changes from this point, so
// they reflect the current action.
Wl_Data_Source_Action_Event :: struct {
	target: Wl_Data_Source,
	// action selected by the compositor
	dnd_action: Wl_Data_Device_Manager_Dnd_Action_Enum,}
WL_DATA_SOURCE_ACTION_EVENT_OPCODE: Event_Opcode : 5
wl_data_source_action_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Source_Action_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_SOURCE_ACTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.dnd_action = message_read_enum(&reader, Wl_Data_Device_Manager_Dnd_Action_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_source" + "@{}." + "action" + ":" + " " + "dnd_action" + "={}", event.target, event.dnd_action)
	return
}

// data transfer device
//
// There is one wl_data_device per seat which can be obtained
// from the global wl_data_device_manager singleton.
// 
// A wl_data_device provides access to inter-client data transfer
// mechanisms such as copy-and-paste and drag-and-drop.
Wl_Data_Device :: Object_Id

Wl_Data_Device_Error_Enum :: enum u32 {
	// given wl_surface has another role
	Role = 0,
}
WL_DATA_DEVICE_START_DRAG_OPCODE: Opcode : 0
// start drag-and-drop operation
//
// This request asks the compositor to start a drag-and-drop
// operation on behalf of the client.
// 
// The source argument is the data source that provides the data
// for the eventual data transfer. If source is NULL, enter, leave
// and motion events are sent only to the client that initiated the
// drag and the client is expected to handle the data passing
// internally. If source is destroyed, the drag-and-drop session will be
// cancelled.
// 
// The origin surface is the surface where the drag originates and
// the client must have an active implicit grab that matches the
// serial.
// 
// The icon surface is an optional (can be NULL) surface that
// provides an icon to be moved around with the cursor.  Initially,
// the top-left corner of the icon surface is placed at the cursor
// hotspot, but subsequent wl_surface.attach request can move the
// relative position. Attach requests must be confirmed with
// wl_surface.commit as usual. The icon surface is given the role of
// a drag-and-drop icon. If the icon surface already has another role,
// it raises a protocol error.
// 
// The input region is ignored for wl_surfaces with the role of a
// drag-and-drop icon.
// - source: data source for the eventual transfer
// - origin: surface where the drag originates
// - icon: drag-and-drop icon surface
// - serial: serial number of the implicit grab on the origin
wl_data_device_start_drag :: proc(conn_: ^Connection, target_: Wl_Data_Device, source: Wl_Data_Source, origin: Wl_Surface, icon: Wl_Surface, serial: u32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_DATA_DEVICE_START_DRAG_OPCODE, msg_size_) or_return
	message_write(writer_, source) or_return
	message_write(writer_, origin) or_return
	message_write(writer_, icon) or_return
	message_write(writer_, serial) or_return
	log.debugf("-> " + "wl_data_device" + "@{}." + "start_drag" + ":" + " " + "source" + "={}" + " " + "origin" + "={}" + " " + "icon" + "={}" + " " + "serial" + "={}", target_, source, origin, icon, serial)
	return
}

WL_DATA_DEVICE_SET_SELECTION_OPCODE: Opcode : 1
// copy data to the selection
//
// This request asks the compositor to set the selection
// to the data from the source on behalf of the client.
// 
// To unset the selection, set the source to NULL.
// - source: data source for the selection
// - serial: serial number of the event that triggered this request
wl_data_device_set_selection :: proc(conn_: ^Connection, target_: Wl_Data_Device, source: Wl_Data_Source, serial: u32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_DATA_DEVICE_SET_SELECTION_OPCODE, msg_size_) or_return
	message_write(writer_, source) or_return
	message_write(writer_, serial) or_return
	log.debugf("-> " + "wl_data_device" + "@{}." + "set_selection" + ":" + " " + "source" + "={}" + " " + "serial" + "={}", target_, source, serial)
	return
}

WL_DATA_DEVICE_RELEASE_OPCODE: Opcode : 2
// destroy data device
//
// This request destroys the data device.
wl_data_device_release :: proc(conn_: ^Connection, target_: Wl_Data_Device, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_DATA_DEVICE_RELEASE_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_data_device" + "@{}." + "release" + ":", target_)
	return
}

// introduce a new wl_data_offer
//
// The data_offer event introduces a new wl_data_offer object,
// which will subsequently be used in either the
// data_device.enter event (for drag-and-drop) or the
// data_device.selection event (for selections).  Immediately
// following the data_device.data_offer event, the new data_offer
// object will send out data_offer.offer events to describe the
// mime types it offers.
Wl_Data_Device_Data_Offer_Event :: struct {
	target: Wl_Data_Device,
	// the new data_offer object
	id: Wl_Data_Offer,
}
WL_DATA_DEVICE_DATA_OFFER_EVENT_OPCODE: Event_Opcode : 0
wl_data_device_data_offer_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Device_Data_Offer_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_DEVICE_DATA_OFFER_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.id = message_read_object_id(&reader, Wl_Data_Offer) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_device" + "@{}." + "data_offer" + ":" + " " + "id" + "={}", event.target, event.id)
	return
}

// initiate drag-and-drop session
//
// This event is sent when an active drag-and-drop pointer enters
// a surface owned by the client.  The position of the pointer at
// enter time is provided by the x and y arguments, in surface-local
// coordinates.
Wl_Data_Device_Enter_Event :: struct {
	target: Wl_Data_Device,
	// serial number of the enter event
	serial: u32,
	// client surface entered
	surface: Wl_Surface,
	// surface-local x coordinate
	x: Fixed,
	// surface-local y coordinate
	y: Fixed,
	// source data_offer object
	id: Wl_Data_Offer,
}
WL_DATA_DEVICE_ENTER_EVENT_OPCODE: Event_Opcode : 1
wl_data_device_enter_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Device_Enter_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_DEVICE_ENTER_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.surface = message_read_object_id(&reader, Wl_Surface) or_return
	event.x = message_read_fixed(&reader) or_return
	event.y = message_read_fixed(&reader) or_return
	event.id = message_read_object_id(&reader, Wl_Data_Offer) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_device" + "@{}." + "enter" + ":" + " " + "serial" + "={}" + " " + "surface" + "={}" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "id" + "={}", event.target, event.serial, event.surface, event.x, event.y, event.id)
	return
}

// end drag-and-drop session
//
// This event is sent when the drag-and-drop pointer leaves the
// surface and the session ends.  The client must destroy the
// wl_data_offer introduced at enter time at this point.
Wl_Data_Device_Leave_Event :: struct {
	target: Wl_Data_Device,
}
WL_DATA_DEVICE_LEAVE_EVENT_OPCODE: Event_Opcode : 2
wl_data_device_leave_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Device_Leave_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_DEVICE_LEAVE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_device" + "@{}." + "leave" + ":", event.target)
	return
}

// drag-and-drop session motion
//
// This event is sent when the drag-and-drop pointer moves within
// the currently focused surface. The new position of the pointer
// is provided by the x and y arguments, in surface-local
// coordinates.
Wl_Data_Device_Motion_Event :: struct {
	target: Wl_Data_Device,
	// timestamp with millisecond granularity
	time: u32,
	// surface-local x coordinate
	x: Fixed,
	// surface-local y coordinate
	y: Fixed,
}
WL_DATA_DEVICE_MOTION_EVENT_OPCODE: Event_Opcode : 3
wl_data_device_motion_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Device_Motion_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_DEVICE_MOTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.time = message_read_u32(&reader) or_return
	event.x = message_read_fixed(&reader) or_return
	event.y = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_device" + "@{}." + "motion" + ":" + " " + "time" + "={}" + " " + "x" + "={}" + " " + "y" + "={}", event.target, event.time, event.x, event.y)
	return
}

// end drag-and-drop session successfully
//
// The event is sent when a drag-and-drop operation is ended
// because the implicit grab is removed.
// 
// The drag-and-drop destination is expected to honor the last action
// received through wl_data_offer.action, if the resulting action is
// "copy" or "move", the destination can still perform
// wl_data_offer.receive requests, and is expected to end all
// transfers with a wl_data_offer.finish request.
// 
// If the resulting action is "ask", the action will not be considered
// final. The drag-and-drop destination is expected to perform one last
// wl_data_offer.set_actions request, or wl_data_offer.destroy in order
// to cancel the operation.
Wl_Data_Device_Drop_Event :: struct {
	target: Wl_Data_Device,
}
WL_DATA_DEVICE_DROP_EVENT_OPCODE: Event_Opcode : 4
wl_data_device_drop_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Device_Drop_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_DEVICE_DROP_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_device" + "@{}." + "drop" + ":", event.target)
	return
}

// advertise new selection
//
// The selection event is sent out to notify the client of a new
// wl_data_offer for the selection for this device.  The
// data_device.data_offer and the data_offer.offer events are
// sent out immediately before this event to introduce the data
// offer object.  The selection event is sent to a client
// immediately before receiving keyboard focus and when a new
// selection is set while the client has keyboard focus.  The
// data_offer is valid until a new data_offer or NULL is received
// or until the client loses keyboard focus.  Switching surface with
// keyboard focus within the same client doesn't mean a new selection
// will be sent.  The client must destroy the previous selection
// data_offer, if any, upon receiving this event.
Wl_Data_Device_Selection_Event :: struct {
	target: Wl_Data_Device,
	// selection data_offer object
	id: Wl_Data_Offer,
}
WL_DATA_DEVICE_SELECTION_EVENT_OPCODE: Event_Opcode : 5
wl_data_device_selection_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Data_Device_Selection_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_DATA_DEVICE_SELECTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.id = message_read_object_id(&reader, Wl_Data_Offer) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_data_device" + "@{}." + "selection" + ":" + " " + "id" + "={}", event.target, event.id)
	return
}

// data transfer interface
//
// The wl_data_device_manager is a singleton global object that
// provides access to inter-client data transfer mechanisms such as
// copy-and-paste and drag-and-drop.  These mechanisms are tied to
// a wl_seat and this interface lets a client get a wl_data_device
// corresponding to a wl_seat.
// 
// Depending on the version bound, the objects created from the bound
// wl_data_device_manager object will have different requirements for
// functioning properly. See wl_data_source.set_actions,
// wl_data_offer.accept and wl_data_offer.finish for details.
Wl_Data_Device_Manager :: Object_Id

// drag and drop actions
//
// This is a bitmask of the available/preferred actions in a
// drag-and-drop operation.
// 
// In the compositor, the selected action is a result of matching the
// actions offered by the source and destination sides.  "action" events
// with a "none" action will be sent to both source and destination if
// there is no match. All further checks will effectively happen on
// (source actions ∩ destination actions).
// 
// In addition, compositors may also pick different actions in
// reaction to key modifiers being pressed. One common design that
// is used in major toolkits (and the behavior recommended for
// compositors) is:
// 
// - If no modifiers are pressed, the first match (in bit order)
// will be used.
// - Pressing Shift selects "move", if enabled in the mask.
// - Pressing Control selects "copy", if enabled in the mask.
// 
// Behavior beyond that is considered implementation-dependent.
// Compositors may for example bind other modifiers (like Alt/Meta)
// or drags initiated with other buttons than BTN_LEFT to specific
// actions (e.g. "ask").
Wl_Data_Device_Manager_Dnd_Action_Enum :: distinct bit_set[enum u32 {
	// copy action
	Copy /* = 1 */,
	// move action
	Move /* = 2 */,
	// ask action
	Ask /* = 4 */,
}; u32]
WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE_OPCODE: Opcode : 0
// create a new data source
//
// Create a new data source.
// - id: data source to create
wl_data_device_manager_create_data_source :: proc(conn_: ^Connection, target_: Wl_Data_Device_Manager, ) -> (id: Wl_Data_Source, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_data_device_manager" + "@{}." + "create_data_source" + ":" + " " + "id" + "={}", target_, id)
	return
}

WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE_OPCODE: Opcode : 1
// create a new data device
//
// Create a new data device for a given seat.
// - id: data device to create
// - seat: seat associated with the data device
wl_data_device_manager_get_data_device :: proc(conn_: ^Connection, target_: Wl_Data_Device_Manager, seat: Wl_Seat, ) -> (id: Wl_Data_Device, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	message_write(writer_, seat) or_return
	log.debugf("-> " + "wl_data_device_manager" + "@{}." + "get_data_device" + ":" + " " + "id" + "={}" + " " + "seat" + "={}", target_, id, seat)
	return
}

// create desktop-style surfaces
//
// This interface is implemented by servers that provide
// desktop-style user interfaces.
// 
// It allows clients to associate a wl_shell_surface with
// a basic surface.
// 
// Note! This protocol is deprecated and not intended for production use.
// For desktop-style user interfaces, use xdg_shell. Compositors and clients
// should not implement this interface.
Wl_Shell :: Object_Id

Wl_Shell_Error_Enum :: enum u32 {
	// given wl_surface has another role
	Role = 0,
}
WL_SHELL_GET_SHELL_SURFACE_OPCODE: Opcode : 0
// create a shell surface from a surface
//
// Create a shell surface for an existing surface. This gives
// the wl_surface the role of a shell surface. If the wl_surface
// already has another role, it raises a protocol error.
// 
// Only one shell surface can be associated with a given surface.
// - id: shell surface to create
// - surface: surface to be given the shell surface role
wl_shell_get_shell_surface :: proc(conn_: ^Connection, target_: Wl_Shell, surface: Wl_Surface, ) -> (id: Wl_Shell_Surface, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_SHELL_GET_SHELL_SURFACE_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	message_write(writer_, surface) or_return
	log.debugf("-> " + "wl_shell" + "@{}." + "get_shell_surface" + ":" + " " + "id" + "={}" + " " + "surface" + "={}", target_, id, surface)
	return
}

// desktop-style metadata interface
//
// An interface that may be implemented by a wl_surface, for
// implementations that provide a desktop-style user interface.
// 
// It provides requests to treat surfaces like toplevel, fullscreen
// or popup windows, move, resize or maximize them, associate
// metadata like title and class, etc.
// 
// On the server side the object is automatically destroyed when
// the related wl_surface is destroyed. On the client side,
// wl_shell_surface_destroy() must be called before destroying
// the wl_surface object.
Wl_Shell_Surface :: Object_Id

// edge values for resizing
//
// These values are used to indicate which edge of a surface
// is being dragged in a resize operation. The server may
// use this information to adapt its behavior, e.g. choose
// an appropriate cursor image.
Wl_Shell_Surface_Resize_Enum :: distinct bit_set[enum u32 {
	// top edge
	Top /* = 1 */,
	// bottom edge
	Bottom /* = 2 */,
	// left edge
	Left /* = 4 */,
	// top and left edges
	// Top_Left = 5,
	// bottom and left edges
	// Bottom_Left = 6,
	// right edge
	Right /* = 8 */,
	// top and right edges
	// Top_Right = 9,
	// bottom and right edges
	// Bottom_Right = 10,
}; u32]
// details of transient behaviour
//
// These flags specify details of the expected behaviour
// of transient surfaces. Used in the set_transient request.
Wl_Shell_Surface_Transient_Enum :: distinct bit_set[enum u32 {
	// do not set keyboard focus
	Inactive /* = 1 */,
}; u32]
// different method to set the surface fullscreen
//
// Hints to indicate to the compositor how to deal with a conflict
// between the dimensions of the surface and the dimensions of the
// output. The compositor is free to ignore this parameter.
Wl_Shell_Surface_Fullscreen_Method_Enum :: enum u32 {
	// no preference, apply default policy
	Default = 0,
	// scale, preserve the surface's aspect ratio and center on output
	Scale = 1,
	// switch output mode to the smallest mode that can fit the surface, add black borders to compensate size mismatch
	Driver = 2,
	// no upscaling, center on output and add black borders to compensate size mismatch
	Fill = 3,
}
WL_SHELL_SURFACE_PONG_OPCODE: Opcode : 0
// respond to a ping event
//
// A client must respond to a ping event with a pong request or
// the client may be deemed unresponsive.
// - serial: serial number of the ping event
wl_shell_surface_pong :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, serial: u32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SHELL_SURFACE_PONG_OPCODE, msg_size_) or_return
	message_write(writer_, serial) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "pong" + ":" + " " + "serial" + "={}", target_, serial)
	return
}

WL_SHELL_SURFACE_MOVE_OPCODE: Opcode : 1
// start an interactive move
//
// Start a pointer-driven move of the surface.
// 
// This request must be used in response to a button press event.
// The server may ignore move requests depending on the state of
// the surface (e.g. fullscreen or maximized).
// - seat: seat whose pointer is used
// - serial: serial number of the implicit grab on the pointer
wl_shell_surface_move :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, seat: Wl_Seat, serial: u32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_SHELL_SURFACE_MOVE_OPCODE, msg_size_) or_return
	message_write(writer_, seat) or_return
	message_write(writer_, serial) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "move" + ":" + " " + "seat" + "={}" + " " + "serial" + "={}", target_, seat, serial)
	return
}

WL_SHELL_SURFACE_RESIZE_OPCODE: Opcode : 2
// start an interactive resize
//
// Start a pointer-driven resizing of the surface.
// 
// This request must be used in response to a button press event.
// The server may ignore resize requests depending on the state of
// the surface (e.g. fullscreen or maximized).
// - seat: seat whose pointer is used
// - serial: serial number of the implicit grab on the pointer
// - edges: which edge or corner is being dragged
wl_shell_surface_resize :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, seat: Wl_Seat, serial: u32, edges: Wl_Shell_Surface_Resize_Enum, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 12
	message_write_header(writer_, target_, WL_SHELL_SURFACE_RESIZE_OPCODE, msg_size_) or_return
	message_write(writer_, seat) or_return
	message_write(writer_, serial) or_return
	message_write(writer_, edges) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "resize" + ":" + " " + "seat" + "={}" + " " + "serial" + "={}" + " " + "edges" + "={}", target_, seat, serial, edges)
	return
}

WL_SHELL_SURFACE_SET_TOPLEVEL_OPCODE: Opcode : 3
// make the surface a toplevel surface
//
// Map the surface as a toplevel surface.
// 
// A toplevel surface is not fullscreen, maximized or transient.
wl_shell_surface_set_toplevel :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_TOPLEVEL_OPCODE, msg_size_) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_toplevel" + ":", target_)
	return
}

WL_SHELL_SURFACE_SET_TRANSIENT_OPCODE: Opcode : 4
// make the surface a transient surface
//
// Map the surface relative to an existing surface.
// 
// The x and y arguments specify the location of the upper left
// corner of the surface relative to the upper left corner of the
// parent surface, in surface-local coordinates.
// 
// The flags argument controls details of the transient behaviour.
// - parent: parent surface
// - x: surface-local x coordinate
// - y: surface-local y coordinate
// - flags: transient surface behavior
wl_shell_surface_set_transient :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, parent: Wl_Surface, x: i32, y: i32, flags: Wl_Shell_Surface_Transient_Enum, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_TRANSIENT_OPCODE, msg_size_) or_return
	message_write(writer_, parent) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	message_write(writer_, flags) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_transient" + ":" + " " + "parent" + "={}" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "flags" + "={}", target_, parent, x, y, flags)
	return
}

WL_SHELL_SURFACE_SET_FULLSCREEN_OPCODE: Opcode : 5
// make the surface a fullscreen surface
//
// Map the surface as a fullscreen surface.
// 
// If an output parameter is given then the surface will be made
// fullscreen on that output. If the client does not specify the
// output then the compositor will apply its policy - usually
// choosing the output on which the surface has the biggest surface
// area.
// 
// The client may specify a method to resolve a size conflict
// between the output size and the surface size - this is provided
// through the method parameter.
// 
// The framerate parameter is used only when the method is set
// to "driver", to indicate the preferred framerate. A value of 0
// indicates that the client does not care about framerate.  The
// framerate is specified in mHz, that is framerate of 60000 is 60Hz.
// 
// A method of "scale" or "driver" implies a scaling operation of
// the surface, either via a direct scaling operation or a change of
// the output mode. This will override any kind of output scaling, so
// that mapping a surface with a buffer size equal to the mode can
// fill the screen independent of buffer_scale.
// 
// A method of "fill" means we don't scale up the buffer, however
// any output scale is applied. This means that you may run into
// an edge case where the application maps a buffer with the same
// size of the output mode but buffer_scale 1 (thus making a
// surface larger than the output). In this case it is allowed to
// downscale the results to fit the screen.
// 
// The compositor must reply to this request with a configure event
// with the dimensions for the output on which the surface will
// be made fullscreen.
// - method: method for resolving size conflict
// - framerate: framerate in mHz
// - output: output on which the surface is to be fullscreen
wl_shell_surface_set_fullscreen :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, method: Wl_Shell_Surface_Fullscreen_Method_Enum, framerate: u32, output: Wl_Output, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 12
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_FULLSCREEN_OPCODE, msg_size_) or_return
	message_write(writer_, method) or_return
	message_write(writer_, framerate) or_return
	message_write(writer_, output) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_fullscreen" + ":" + " " + "method" + "={}" + " " + "framerate" + "={}" + " " + "output" + "={}", target_, method, framerate, output)
	return
}

WL_SHELL_SURFACE_SET_POPUP_OPCODE: Opcode : 6
// make the surface a popup surface
//
// Map the surface as a popup.
// 
// A popup surface is a transient surface with an added pointer
// grab.
// 
// An existing implicit grab will be changed to owner-events mode,
// and the popup grab will continue after the implicit grab ends
// (i.e. releasing the mouse button does not cause the popup to
// be unmapped).
// 
// The popup grab continues until the window is destroyed or a
// mouse button is pressed in any other client's window. A click
// in any of the client's surfaces is reported as normal, however,
// clicks in other clients' surfaces will be discarded and trigger
// the callback.
// 
// The x and y arguments specify the location of the upper left
// corner of the surface relative to the upper left corner of the
// parent surface, in surface-local coordinates.
// - seat: seat whose pointer is used
// - serial: serial number of the implicit grab on the pointer
// - parent: parent surface
// - x: surface-local x coordinate
// - y: surface-local y coordinate
// - flags: transient surface behavior
wl_shell_surface_set_popup :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, seat: Wl_Seat, serial: u32, parent: Wl_Surface, x: i32, y: i32, flags: Wl_Shell_Surface_Transient_Enum, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 24
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_POPUP_OPCODE, msg_size_) or_return
	message_write(writer_, seat) or_return
	message_write(writer_, serial) or_return
	message_write(writer_, parent) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	message_write(writer_, flags) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_popup" + ":" + " " + "seat" + "={}" + " " + "serial" + "={}" + " " + "parent" + "={}" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "flags" + "={}", target_, seat, serial, parent, x, y, flags)
	return
}

WL_SHELL_SURFACE_SET_MAXIMIZED_OPCODE: Opcode : 7
// make the surface a maximized surface
//
// Map the surface as a maximized surface.
// 
// If an output parameter is given then the surface will be
// maximized on that output. If the client does not specify the
// output then the compositor will apply its policy - usually
// choosing the output on which the surface has the biggest surface
// area.
// 
// The compositor will reply with a configure event telling
// the expected new surface size. The operation is completed
// on the next buffer attach to this surface.
// 
// A maximized surface typically fills the entire output it is
// bound to, except for desktop elements such as panels. This is
// the main difference between a maximized shell surface and a
// fullscreen shell surface.
// 
// The details depend on the compositor implementation.
// - output: output on which the surface is to be maximized
wl_shell_surface_set_maximized :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, output: Wl_Output, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_MAXIMIZED_OPCODE, msg_size_) or_return
	message_write(writer_, output) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_maximized" + ":" + " " + "output" + "={}", target_, output)
	return
}

WL_SHELL_SURFACE_SET_TITLE_OPCODE: Opcode : 8
// set surface title
//
// Set a short title for the surface.
// 
// This string may be used to identify the surface in a task bar,
// window list, or other user interface elements provided by the
// compositor.
// 
// The string must be encoded in UTF-8.
// - title: surface title
wl_shell_surface_set_title :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, title: string, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	msg_size_ += message_string_size(len(title))
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_TITLE_OPCODE, msg_size_) or_return
	message_write(writer_, title) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_title" + ":" + " " + "title" + "={}", target_, title)
	return
}

WL_SHELL_SURFACE_SET_CLASS_OPCODE: Opcode : 9
// set surface class
//
// Set a class for the surface.
// 
// The surface class identifies the general class of applications
// to which the surface belongs. A common convention is to use the
// file name (or the full path if it is a non-standard location) of
// the application's .desktop file as the class.
// - class_: surface class
wl_shell_surface_set_class :: proc(conn_: ^Connection, target_: Wl_Shell_Surface, class_: string, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	msg_size_ += message_string_size(len(class_))
	message_write_header(writer_, target_, WL_SHELL_SURFACE_SET_CLASS_OPCODE, msg_size_) or_return
	message_write(writer_, class_) or_return
	log.debugf("-> " + "wl_shell_surface" + "@{}." + "set_class" + ":" + " " + "class_" + "={}", target_, class_)
	return
}

// ping client
//
// Ping a client to check if it is receiving events and sending
// requests. A client is expected to reply with a pong request.
Wl_Shell_Surface_Ping_Event :: struct {
	target: Wl_Shell_Surface,
	// serial number of the ping
	serial: u32,
}
WL_SHELL_SURFACE_PING_EVENT_OPCODE: Event_Opcode : 0
wl_shell_surface_ping_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Shell_Surface_Ping_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SHELL_SURFACE_PING_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_shell_surface" + "@{}." + "ping" + ":" + " " + "serial" + "={}", event.target, event.serial)
	return
}

// suggest resize
//
// The configure event asks the client to resize its surface.
// 
// The size is a hint, in the sense that the client is free to
// ignore it if it doesn't resize, pick a smaller size (to
// satisfy aspect ratio or resize in steps of NxM pixels).
// 
// The edges parameter provides a hint about how the surface
// was resized. The client may use this information to decide
// how to adjust its content to the new size (e.g. a scrolling
// area might adjust its content position to leave the viewable
// content unmoved).
// 
// The client is free to dismiss all but the last configure
// event it received.
// 
// The width and height arguments specify the size of the window
// in surface-local coordinates.
Wl_Shell_Surface_Configure_Event :: struct {
	target: Wl_Shell_Surface,
	// how the surface was resized
	edges: Wl_Shell_Surface_Resize_Enum,	// new width of the surface
	width: i32,
	// new height of the surface
	height: i32,
}
WL_SHELL_SURFACE_CONFIGURE_EVENT_OPCODE: Event_Opcode : 1
wl_shell_surface_configure_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Shell_Surface_Configure_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SHELL_SURFACE_CONFIGURE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.edges = message_read_enum(&reader, Wl_Shell_Surface_Resize_Enum) or_return
	event.width = message_read_i32(&reader) or_return
	event.height = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_shell_surface" + "@{}." + "configure" + ":" + " " + "edges" + "={}" + " " + "width" + "={}" + " " + "height" + "={}", event.target, event.edges, event.width, event.height)
	return
}

// popup interaction is done
//
// The popup_done event is sent out when a popup grab is broken,
// that is, when the user clicks a surface that doesn't belong
// to the client owning the popup surface.
Wl_Shell_Surface_Popup_Done_Event :: struct {
	target: Wl_Shell_Surface,
}
WL_SHELL_SURFACE_POPUP_DONE_EVENT_OPCODE: Event_Opcode : 2
wl_shell_surface_popup_done_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Shell_Surface_Popup_Done_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SHELL_SURFACE_POPUP_DONE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_shell_surface" + "@{}." + "popup_done" + ":", event.target)
	return
}

// an onscreen surface
//
// A surface is a rectangular area that may be displayed on zero
// or more outputs, and shown any number of times at the compositor's
// discretion. They can present wl_buffers, receive user input, and
// define a local coordinate system.
// 
// The size of a surface (and relative positions on it) is described
// in surface-local coordinates, which may differ from the buffer
// coordinates of the pixel content, in case a buffer_transform
// or a buffer_scale is used.
// 
// A surface without a "role" is fairly useless: a compositor does
// not know where, when or how to present it. The role is the
// purpose of a wl_surface. Examples of roles are a cursor for a
// pointer (as set by wl_pointer.set_cursor), a drag icon
// (wl_data_device.start_drag), a sub-surface
// (wl_subcompositor.get_subsurface), and a window as defined by a
// shell protocol (e.g. wl_shell.get_shell_surface).
// 
// A surface can have only one role at a time. Initially a
// wl_surface does not have a role. Once a wl_surface is given a
// role, it is set permanently for the whole lifetime of the
// wl_surface object. Giving the current role again is allowed,
// unless explicitly forbidden by the relevant interface
// specification.
// 
// Surface roles are given by requests in other interfaces such as
// wl_pointer.set_cursor. The request should explicitly mention
// that this request gives a role to a wl_surface. Often, this
// request also creates a new protocol object that represents the
// role and adds additional functionality to wl_surface. When a
// client wants to destroy a wl_surface, they must destroy this role
// object before the wl_surface, otherwise a defunct_role_object error is
// sent.
// 
// Destroying the role object does not remove the role from the
// wl_surface, but it may stop the wl_surface from "playing the role".
// For instance, if a wl_subsurface object is destroyed, the wl_surface
// it was created for will be unmapped and forget its position and
// z-order. It is allowed to create a wl_subsurface for the same
// wl_surface again, but it is not allowed to use the wl_surface as
// a cursor (cursor is a different role than sub-surface, and role
// switching is not allowed).
Wl_Surface :: Object_Id

// wl_surface error values
//
// These errors can be emitted in response to wl_surface requests.
Wl_Surface_Error_Enum :: enum u32 {
	// buffer scale value is invalid
	Invalid_Scale = 0,
	// buffer transform value is invalid
	Invalid_Transform = 1,
	// buffer size is invalid
	Invalid_Size = 2,
	// buffer offset is invalid
	Invalid_Offset = 3,
	// surface was destroyed before its role object
	Defunct_Role_Object = 4,
}
WL_SURFACE_DESTROY_OPCODE: Opcode : 0
// delete surface
//
// Deletes the surface and invalidates its object ID.
wl_surface_destroy :: proc(conn_: ^Connection, target_: Wl_Surface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SURFACE_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_surface" + "@{}." + "destroy" + ":", target_)
	return
}

WL_SURFACE_ATTACH_OPCODE: Opcode : 1
// set the surface contents
//
// Set a buffer as the content of this surface.
// 
// The new size of the surface is calculated based on the buffer
// size transformed by the inverse buffer_transform and the
// inverse buffer_scale. This means that at commit time the supplied
// buffer size must be an integer multiple of the buffer_scale. If
// that's not the case, an invalid_size error is sent.
// 
// The x and y arguments specify the location of the new pending
// buffer's upper left corner, relative to the current buffer's upper
// left corner, in surface-local coordinates. In other words, the
// x and y, combined with the new surface size define in which
// directions the surface's size changes. Setting anything other than 0
// as x and y arguments is discouraged, and should instead be replaced
// with using the separate wl_surface.offset request.
// 
// When the bound wl_surface version is 5 or higher, passing any
// non-zero x or y is a protocol violation, and will result in an
// 'invalid_offset' error being raised. The x and y arguments are ignored
// and do not change the pending state. To achieve equivalent semantics,
// use wl_surface.offset.
// 
// Surface contents are double-buffered state, see wl_surface.commit.
// 
// The initial surface contents are void; there is no content.
// wl_surface.attach assigns the given wl_buffer as the pending
// wl_buffer. wl_surface.commit makes the pending wl_buffer the new
// surface contents, and the size of the surface becomes the size
// calculated from the wl_buffer, as described above. After commit,
// there is no pending buffer until the next attach.
// 
// Committing a pending wl_buffer allows the compositor to read the
// pixels in the wl_buffer. The compositor may access the pixels at
// any time after the wl_surface.commit request. When the compositor
// will not access the pixels anymore, it will send the
// wl_buffer.release event. Only after receiving wl_buffer.release,
// the client may reuse the wl_buffer. A wl_buffer that has been
// attached and then replaced by another attach instead of committed
// will not receive a release event, and is not used by the
// compositor.
// 
// If a pending wl_buffer has been committed to more than one wl_surface,
// the delivery of wl_buffer.release events becomes undefined. A well
// behaved client should not rely on wl_buffer.release events in this
// case. Alternatively, a client could create multiple wl_buffer objects
// from the same backing storage or use wp_linux_buffer_release.
// 
// Destroying the wl_buffer after wl_buffer.release does not change
// the surface contents. Destroying the wl_buffer before wl_buffer.release
// is allowed as long as the underlying buffer storage isn't re-used (this
// can happen e.g. on client process termination). However, if the client
// destroys the wl_buffer before receiving the wl_buffer.release event and
// mutates the underlying buffer storage, the surface contents become
// undefined immediately.
// 
// If wl_surface.attach is sent with a NULL wl_buffer, the
// following wl_surface.commit will remove the surface content.
// - buffer: buffer of surface contents
// - x: surface-local x coordinate
// - y: surface-local y coordinate
wl_surface_attach :: proc(conn_: ^Connection, target_: Wl_Surface, buffer: Wl_Buffer, x: i32, y: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 12
	message_write_header(writer_, target_, WL_SURFACE_ATTACH_OPCODE, msg_size_) or_return
	message_write(writer_, buffer) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "attach" + ":" + " " + "buffer" + "={}" + " " + "x" + "={}" + " " + "y" + "={}", target_, buffer, x, y)
	return
}

WL_SURFACE_DAMAGE_OPCODE: Opcode : 2
// mark part of the surface damaged
//
// This request is used to describe the regions where the pending
// buffer is different from the current surface contents, and where
// the surface therefore needs to be repainted. The compositor
// ignores the parts of the damage that fall outside of the surface.
// 
// Damage is double-buffered state, see wl_surface.commit.
// 
// The damage rectangle is specified in surface-local coordinates,
// where x and y specify the upper left corner of the damage rectangle.
// 
// The initial value for pending damage is empty: no damage.
// wl_surface.damage adds pending damage: the new pending damage
// is the union of old pending damage and the given rectangle.
// 
// wl_surface.commit assigns pending damage as the current damage,
// and clears pending damage. The server will clear the current
// damage as it repaints the surface.
// 
// Note! New clients should not use this request. Instead damage can be
// posted with wl_surface.damage_buffer which uses buffer coordinates
// instead of surface coordinates.
// - x: surface-local x coordinate
// - y: surface-local y coordinate
// - width: width of damage rectangle
// - height: height of damage rectangle
wl_surface_damage :: proc(conn_: ^Connection, target_: Wl_Surface, x: i32, y: i32, width: i32, height: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_SURFACE_DAMAGE_OPCODE, msg_size_) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	message_write(writer_, width) or_return
	message_write(writer_, height) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "damage" + ":" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "width" + "={}" + " " + "height" + "={}", target_, x, y, width, height)
	return
}

WL_SURFACE_FRAME_OPCODE: Opcode : 3
// request a frame throttling hint
//
// Request a notification when it is a good time to start drawing a new
// frame, by creating a frame callback. This is useful for throttling
// redrawing operations, and driving animations.
// 
// When a client is animating on a wl_surface, it can use the 'frame'
// request to get notified when it is a good time to draw and commit the
// next frame of animation. If the client commits an update earlier than
// that, it is likely that some updates will not make it to the display,
// and the client is wasting resources by drawing too often.
// 
// The frame request will take effect on the next wl_surface.commit.
// The notification will only be posted for one frame unless
// requested again. For a wl_surface, the notifications are posted in
// the order the frame requests were committed.
// 
// The server must send the notifications so that a client
// will not send excessive updates, while still allowing
// the highest possible update rate for clients that wait for the reply
// before drawing again. The server should give some time for the client
// to draw and commit after sending the frame callback events to let it
// hit the next output refresh.
// 
// A server should avoid signaling the frame callbacks if the
// surface is not visible in any way, e.g. the surface is off-screen,
// or completely obscured by other opaque surfaces.
// 
// The object returned by this request will be destroyed by the
// compositor after the callback is fired and as such the client must not
// attempt to use it after that point.
// 
// The callback_data passed in the callback is the current time, in
// milliseconds, with an undefined base.
// - callback: callback object for the frame request
wl_surface_frame :: proc(conn_: ^Connection, target_: Wl_Surface, ) -> (callback: Wl_Callback, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SURFACE_FRAME_OPCODE, msg_size_) or_return
	callback = connection_alloc_id(conn_) or_return
	message_write(writer_, callback) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "frame" + ":" + " " + "callback" + "={}", target_, callback)
	return
}

WL_SURFACE_SET_OPAQUE_REGION_OPCODE: Opcode : 4
// set opaque region
//
// This request sets the region of the surface that contains
// opaque content.
// 
// The opaque region is an optimization hint for the compositor
// that lets it optimize the redrawing of content behind opaque
// regions.  Setting an opaque region is not required for correct
// behaviour, but marking transparent content as opaque will result
// in repaint artifacts.
// 
// The opaque region is specified in surface-local coordinates.
// 
// The compositor ignores the parts of the opaque region that fall
// outside of the surface.
// 
// Opaque region is double-buffered state, see wl_surface.commit.
// 
// wl_surface.set_opaque_region changes the pending opaque region.
// wl_surface.commit copies the pending region to the current region.
// Otherwise, the pending and current regions are never changed.
// 
// The initial value for an opaque region is empty. Setting the pending
// opaque region has copy semantics, and the wl_region object can be
// destroyed immediately. A NULL wl_region causes the pending opaque
// region to be set to empty.
// - region: opaque region of the surface
wl_surface_set_opaque_region :: proc(conn_: ^Connection, target_: Wl_Surface, region: Wl_Region, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SURFACE_SET_OPAQUE_REGION_OPCODE, msg_size_) or_return
	message_write(writer_, region) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "set_opaque_region" + ":" + " " + "region" + "={}", target_, region)
	return
}

WL_SURFACE_SET_INPUT_REGION_OPCODE: Opcode : 5
// set input region
//
// This request sets the region of the surface that can receive
// pointer and touch events.
// 
// Input events happening outside of this region will try the next
// surface in the server surface stack. The compositor ignores the
// parts of the input region that fall outside of the surface.
// 
// The input region is specified in surface-local coordinates.
// 
// Input region is double-buffered state, see wl_surface.commit.
// 
// wl_surface.set_input_region changes the pending input region.
// wl_surface.commit copies the pending region to the current region.
// Otherwise the pending and current regions are never changed,
// except cursor and icon surfaces are special cases, see
// wl_pointer.set_cursor and wl_data_device.start_drag.
// 
// The initial value for an input region is infinite. That means the
// whole surface will accept input. Setting the pending input region
// has copy semantics, and the wl_region object can be destroyed
// immediately. A NULL wl_region causes the input region to be set
// to infinite.
// - region: input region of the surface
wl_surface_set_input_region :: proc(conn_: ^Connection, target_: Wl_Surface, region: Wl_Region, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SURFACE_SET_INPUT_REGION_OPCODE, msg_size_) or_return
	message_write(writer_, region) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "set_input_region" + ":" + " " + "region" + "={}", target_, region)
	return
}

WL_SURFACE_COMMIT_OPCODE: Opcode : 6
// commit pending surface state
//
// Surface state (input, opaque, and damage regions, attached buffers,
// etc.) is double-buffered. Protocol requests modify the pending state,
// as opposed to the current state in use by the compositor. A commit
// request atomically applies all pending state, replacing the current
// state. After commit, the new pending state is as documented for each
// related request.
// 
// On commit, a pending wl_buffer is applied first, and all other state
// second. This means that all coordinates in double-buffered state are
// relative to the new wl_buffer coming into use, except for
// wl_surface.attach itself. If there is no pending wl_buffer, the
// coordinates are relative to the current surface contents.
// 
// All requests that need a commit to become effective are documented
// to affect double-buffered state.
// 
// Other interfaces may add further double-buffered surface state.
wl_surface_commit :: proc(conn_: ^Connection, target_: Wl_Surface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SURFACE_COMMIT_OPCODE, msg_size_) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "commit" + ":", target_)
	return
}

WL_SURFACE_SET_BUFFER_TRANSFORM_OPCODE: Opcode : 7
// sets the buffer transformation
//
// This request sets an optional transformation on how the compositor
// interprets the contents of the buffer attached to the surface. The
// accepted values for the transform parameter are the values for
// wl_output.transform.
// 
// Buffer transform is double-buffered state, see wl_surface.commit.
// 
// A newly created surface has its buffer transformation set to normal.
// 
// wl_surface.set_buffer_transform changes the pending buffer
// transformation. wl_surface.commit copies the pending buffer
// transformation to the current one. Otherwise, the pending and current
// values are never changed.
// 
// The purpose of this request is to allow clients to render content
// according to the output transform, thus permitting the compositor to
// use certain optimizations even if the display is rotated. Using
// hardware overlays and scanning out a client buffer for fullscreen
// surfaces are examples of such optimizations. Those optimizations are
// highly dependent on the compositor implementation, so the use of this
// request should be considered on a case-by-case basis.
// 
// Note that if the transform value includes 90 or 270 degree rotation,
// the width of the buffer will become the surface height and the height
// of the buffer will become the surface width.
// 
// If transform is not one of the values from the
// wl_output.transform enum the invalid_transform protocol error
// is raised.
// - transform: transform for interpreting buffer contents
wl_surface_set_buffer_transform :: proc(conn_: ^Connection, target_: Wl_Surface, transform: Wl_Output_Transform_Enum, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SURFACE_SET_BUFFER_TRANSFORM_OPCODE, msg_size_) or_return
	message_write(writer_, transform) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "set_buffer_transform" + ":" + " " + "transform" + "={}", target_, transform)
	return
}

WL_SURFACE_SET_BUFFER_SCALE_OPCODE: Opcode : 8
// sets the buffer scaling factor
//
// This request sets an optional scaling factor on how the compositor
// interprets the contents of the buffer attached to the window.
// 
// Buffer scale is double-buffered state, see wl_surface.commit.
// 
// A newly created surface has its buffer scale set to 1.
// 
// wl_surface.set_buffer_scale changes the pending buffer scale.
// wl_surface.commit copies the pending buffer scale to the current one.
// Otherwise, the pending and current values are never changed.
// 
// The purpose of this request is to allow clients to supply higher
// resolution buffer data for use on high resolution outputs. It is
// intended that you pick the same buffer scale as the scale of the
// output that the surface is displayed on. This means the compositor
// can avoid scaling when rendering the surface on that output.
// 
// Note that if the scale is larger than 1, then you have to attach
// a buffer that is larger (by a factor of scale in each dimension)
// than the desired surface size.
// 
// If scale is not positive the invalid_scale protocol error is
// raised.
// - scale: positive scale for interpreting buffer contents
wl_surface_set_buffer_scale :: proc(conn_: ^Connection, target_: Wl_Surface, scale: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SURFACE_SET_BUFFER_SCALE_OPCODE, msg_size_) or_return
	message_write(writer_, scale) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "set_buffer_scale" + ":" + " " + "scale" + "={}", target_, scale)
	return
}

WL_SURFACE_DAMAGE_BUFFER_OPCODE: Opcode : 9
// mark part of the surface damaged using buffer coordinates
//
// This request is used to describe the regions where the pending
// buffer is different from the current surface contents, and where
// the surface therefore needs to be repainted. The compositor
// ignores the parts of the damage that fall outside of the surface.
// 
// Damage is double-buffered state, see wl_surface.commit.
// 
// The damage rectangle is specified in buffer coordinates,
// where x and y specify the upper left corner of the damage rectangle.
// 
// The initial value for pending damage is empty: no damage.
// wl_surface.damage_buffer adds pending damage: the new pending
// damage is the union of old pending damage and the given rectangle.
// 
// wl_surface.commit assigns pending damage as the current damage,
// and clears pending damage. The server will clear the current
// damage as it repaints the surface.
// 
// This request differs from wl_surface.damage in only one way - it
// takes damage in buffer coordinates instead of surface-local
// coordinates. While this generally is more intuitive than surface
// coordinates, it is especially desirable when using wp_viewport
// or when a drawing library (like EGL) is unaware of buffer scale
// and buffer transform.
// 
// Note: Because buffer transformation changes and damage requests may
// be interleaved in the protocol stream, it is impossible to determine
// the actual mapping between surface and buffer damage until
// wl_surface.commit time. Therefore, compositors wishing to take both
// kinds of damage into account will have to accumulate damage from the
// two requests separately and only transform from one to the other
// after receiving the wl_surface.commit.
// - x: buffer-local x coordinate
// - y: buffer-local y coordinate
// - width: width of damage rectangle
// - height: height of damage rectangle
wl_surface_damage_buffer :: proc(conn_: ^Connection, target_: Wl_Surface, x: i32, y: i32, width: i32, height: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_SURFACE_DAMAGE_BUFFER_OPCODE, msg_size_) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	message_write(writer_, width) or_return
	message_write(writer_, height) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "damage_buffer" + ":" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "width" + "={}" + " " + "height" + "={}", target_, x, y, width, height)
	return
}

WL_SURFACE_OFFSET_OPCODE: Opcode : 10
// set the surface contents offset
//
// The x and y arguments specify the location of the new pending
// buffer's upper left corner, relative to the current buffer's upper
// left corner, in surface-local coordinates. In other words, the
// x and y, combined with the new surface size define in which
// directions the surface's size changes.
// 
// Surface location offset is double-buffered state, see
// wl_surface.commit.
// 
// This request is semantically equivalent to and the replaces the x and y
// arguments in the wl_surface.attach request in wl_surface versions prior
// to 5. See wl_surface.attach for details.
// - x: surface-local x coordinate
// - y: surface-local y coordinate
wl_surface_offset :: proc(conn_: ^Connection, target_: Wl_Surface, x: i32, y: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_SURFACE_OFFSET_OPCODE, msg_size_) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	log.debugf("-> " + "wl_surface" + "@{}." + "offset" + ":" + " " + "x" + "={}" + " " + "y" + "={}", target_, x, y)
	return
}

// surface enters an output
//
// This is emitted whenever a surface's creation, movement, or resizing
// results in some part of it being within the scanout region of an
// output.
// 
// Note that a surface may be overlapping with zero or more outputs.
Wl_Surface_Enter_Event :: struct {
	target: Wl_Surface,
	// output entered by the surface
	output: Wl_Output,
}
WL_SURFACE_ENTER_EVENT_OPCODE: Event_Opcode : 0
wl_surface_enter_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Surface_Enter_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SURFACE_ENTER_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.output = message_read_object_id(&reader, Wl_Output) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_surface" + "@{}." + "enter" + ":" + " " + "output" + "={}", event.target, event.output)
	return
}

// surface leaves an output
//
// This is emitted whenever a surface's creation, movement, or resizing
// results in it no longer having any part of it within the scanout region
// of an output.
// 
// Clients should not use the number of outputs the surface is on for frame
// throttling purposes. The surface might be hidden even if no leave event
// has been sent, and the compositor might expect new surface content
// updates even if no enter event has been sent. The frame event should be
// used instead.
Wl_Surface_Leave_Event :: struct {
	target: Wl_Surface,
	// output left by the surface
	output: Wl_Output,
}
WL_SURFACE_LEAVE_EVENT_OPCODE: Event_Opcode : 1
wl_surface_leave_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Surface_Leave_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SURFACE_LEAVE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.output = message_read_object_id(&reader, Wl_Output) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_surface" + "@{}." + "leave" + ":" + " " + "output" + "={}", event.target, event.output)
	return
}

// preferred buffer scale for the surface
//
// This event indicates the preferred buffer scale for this surface. It is
// sent whenever the compositor's preference changes.
// 
// It is intended that scaling aware clients use this event to scale their
// content and use wl_surface.set_buffer_scale to indicate the scale they
// have rendered with. This allows clients to supply a higher detail
// buffer.
Wl_Surface_Preferred_Buffer_Scale_Event :: struct {
	target: Wl_Surface,
	// preferred scaling factor
	factor: i32,
}
WL_SURFACE_PREFERRED_BUFFER_SCALE_EVENT_OPCODE: Event_Opcode : 2
wl_surface_preferred_buffer_scale_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Surface_Preferred_Buffer_Scale_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SURFACE_PREFERRED_BUFFER_SCALE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.factor = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_surface" + "@{}." + "preferred_buffer_scale" + ":" + " " + "factor" + "={}", event.target, event.factor)
	return
}

// preferred buffer transform for the surface
//
// This event indicates the preferred buffer transform for this surface.
// It is sent whenever the compositor's preference changes.
// 
// It is intended that transform aware clients use this event to apply the
// transform to their content and use wl_surface.set_buffer_transform to
// indicate the transform they have rendered with.
Wl_Surface_Preferred_Buffer_Transform_Event :: struct {
	target: Wl_Surface,
	// preferred transform
	transform: Wl_Output_Transform_Enum,}
WL_SURFACE_PREFERRED_BUFFER_TRANSFORM_EVENT_OPCODE: Event_Opcode : 3
wl_surface_preferred_buffer_transform_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Surface_Preferred_Buffer_Transform_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SURFACE_PREFERRED_BUFFER_TRANSFORM_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.transform = message_read_enum(&reader, Wl_Output_Transform_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_surface" + "@{}." + "preferred_buffer_transform" + ":" + " " + "transform" + "={}", event.target, event.transform)
	return
}

// group of input devices
//
// A seat is a group of keyboards, pointer and touch devices. This
// object is published as a global during start up, or when such a
// device is hot plugged.  A seat typically has a pointer and
// maintains a keyboard focus and a pointer focus.
Wl_Seat :: Object_Id

// seat capability bitmask
//
// This is a bitmask of capabilities this seat has; if a member is
// set, then it is present on the seat.
Wl_Seat_Capability_Enum :: distinct bit_set[enum u32 {
	// the seat has pointer devices
	Pointer /* = 1 */,
	// the seat has one or more keyboards
	Keyboard /* = 2 */,
	// the seat has touch devices
	Touch /* = 4 */,
}; u32]
// wl_seat error values
//
// These errors can be emitted in response to wl_seat requests.
Wl_Seat_Error_Enum :: enum u32 {
	// get_pointer, get_keyboard or get_touch called on seat without the matching capability
	Missing_Capability = 0,
}
WL_SEAT_GET_POINTER_OPCODE: Opcode : 0
// return pointer object
//
// The ID provided will be initialized to the wl_pointer interface
// for this seat.
// 
// This request only takes effect if the seat has the pointer
// capability, or has had the pointer capability in the past.
// It is a protocol violation to issue this request on a seat that has
// never had the pointer capability. The missing_capability error will
// be sent in this case.
// - id: seat pointer
wl_seat_get_pointer :: proc(conn_: ^Connection, target_: Wl_Seat, ) -> (id: Wl_Pointer, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SEAT_GET_POINTER_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_seat" + "@{}." + "get_pointer" + ":" + " " + "id" + "={}", target_, id)
	return
}

WL_SEAT_GET_KEYBOARD_OPCODE: Opcode : 1
// return keyboard object
//
// The ID provided will be initialized to the wl_keyboard interface
// for this seat.
// 
// This request only takes effect if the seat has the keyboard
// capability, or has had the keyboard capability in the past.
// It is a protocol violation to issue this request on a seat that has
// never had the keyboard capability. The missing_capability error will
// be sent in this case.
// - id: seat keyboard
wl_seat_get_keyboard :: proc(conn_: ^Connection, target_: Wl_Seat, ) -> (id: Wl_Keyboard, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SEAT_GET_KEYBOARD_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_seat" + "@{}." + "get_keyboard" + ":" + " " + "id" + "={}", target_, id)
	return
}

WL_SEAT_GET_TOUCH_OPCODE: Opcode : 2
// return touch object
//
// The ID provided will be initialized to the wl_touch interface
// for this seat.
// 
// This request only takes effect if the seat has the touch
// capability, or has had the touch capability in the past.
// It is a protocol violation to issue this request on a seat that has
// never had the touch capability. The missing_capability error will
// be sent in this case.
// - id: seat touch interface
wl_seat_get_touch :: proc(conn_: ^Connection, target_: Wl_Seat, ) -> (id: Wl_Touch, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SEAT_GET_TOUCH_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	log.debugf("-> " + "wl_seat" + "@{}." + "get_touch" + ":" + " " + "id" + "={}", target_, id)
	return
}

WL_SEAT_RELEASE_OPCODE: Opcode : 3
// release the seat object
//
// Using this request a client can tell the server that it is not going to
// use the seat object anymore.
wl_seat_release :: proc(conn_: ^Connection, target_: Wl_Seat, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SEAT_RELEASE_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_seat" + "@{}." + "release" + ":", target_)
	return
}

// seat capabilities changed
//
// This is emitted whenever a seat gains or loses the pointer,
// keyboard or touch capabilities.  The argument is a capability
// enum containing the complete set of capabilities this seat has.
// 
// When the pointer capability is added, a client may create a
// wl_pointer object using the wl_seat.get_pointer request. This object
// will receive pointer events until the capability is removed in the
// future.
// 
// When the pointer capability is removed, a client should destroy the
// wl_pointer objects associated with the seat where the capability was
// removed, using the wl_pointer.release request. No further pointer
// events will be received on these objects.
// 
// In some compositors, if a seat regains the pointer capability and a
// client has a previously obtained wl_pointer object of version 4 or
// less, that object may start sending pointer events again. This
// behavior is considered a misinterpretation of the intended behavior
// and must not be relied upon by the client. wl_pointer objects of
// version 5 or later must not send events if created before the most
// recent event notifying the client of an added pointer capability.
// 
// The above behavior also applies to wl_keyboard and wl_touch with the
// keyboard and touch capabilities, respectively.
Wl_Seat_Capabilities_Event :: struct {
	target: Wl_Seat,
	// capabilities of the seat
	capabilities: Wl_Seat_Capability_Enum,}
WL_SEAT_CAPABILITIES_EVENT_OPCODE: Event_Opcode : 0
wl_seat_capabilities_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Seat_Capabilities_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SEAT_CAPABILITIES_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.capabilities = message_read_enum(&reader, Wl_Seat_Capability_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_seat" + "@{}." + "capabilities" + ":" + " " + "capabilities" + "={}", event.target, event.capabilities)
	return
}

// unique identifier for this seat
//
// In a multi-seat configuration the seat name can be used by clients to
// help identify which physical devices the seat represents.
// 
// The seat name is a UTF-8 string with no convention defined for its
// contents. Each name is unique among all wl_seat globals. The name is
// only guaranteed to be unique for the current compositor instance.
// 
// The same seat names are used for all clients. Thus, the name can be
// shared across processes to refer to a specific wl_seat global.
// 
// The name event is sent after binding to the seat global. This event is
// only sent once per seat object, and the name does not change over the
// lifetime of the wl_seat global.
// 
// Compositors may re-use the same seat name if the wl_seat global is
// destroyed and re-created later.
Wl_Seat_Name_Event :: struct {
	target: Wl_Seat,
	// seat identifier
	name: string,
}
WL_SEAT_NAME_EVENT_OPCODE: Event_Opcode : 1
wl_seat_name_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Seat_Name_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_SEAT_NAME_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.name = message_read_string(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_seat" + "@{}." + "name" + ":" + " " + "name" + "={}", event.target, event.name)
	return
}

// pointer input device
//
// The wl_pointer interface represents one or more input devices,
// such as mice, which control the pointer location and pointer_focus
// of a seat.
// 
// The wl_pointer interface generates motion, enter and leave
// events for the surfaces that the pointer is located over,
// and button and axis events for button presses, button releases
// and scrolling.
Wl_Pointer :: Object_Id

Wl_Pointer_Error_Enum :: enum u32 {
	// given wl_surface has another role
	Role = 0,
}
// physical button state
//
// Describes the physical state of a button that produced the button
// event.
Wl_Pointer_Button_State_Enum :: enum u32 {
	// the button is not pressed
	Released = 0,
	// the button is pressed
	Pressed = 1,
}
// axis types
//
// Describes the axis types of scroll events.
Wl_Pointer_Axis_Enum :: enum u32 {
	// vertical axis
	Vertical_Scroll = 0,
	// horizontal axis
	Horizontal_Scroll = 1,
}
// axis source types
//
// Describes the source types for axis events. This indicates to the
// client how an axis event was physically generated; a client may
// adjust the user interface accordingly. For example, scroll events
// from a "finger" source may be in a smooth coordinate space with
// kinetic scrolling whereas a "wheel" source may be in discrete steps
// of a number of lines.
// 
// The "continuous" axis source is a device generating events in a
// continuous coordinate space, but using something other than a
// finger. One example for this source is button-based scrolling where
// the vertical motion of a device is converted to scroll events while
// a button is held down.
// 
// The "wheel tilt" axis source indicates that the actual device is a
// wheel but the scroll event is not caused by a rotation but a
// (usually sideways) tilt of the wheel.
Wl_Pointer_Axis_Source_Enum :: enum u32 {
	// a physical wheel rotation
	Wheel = 0,
	// finger on a touch surface
	Finger = 1,
	// continuous coordinate space
	Continuous = 2,
	// a physical wheel tilt
	Wheel_Tilt = 3,
}
// axis relative direction
//
// This specifies the direction of the physical motion that caused a
// wl_pointer.axis event, relative to the wl_pointer.axis direction.
Wl_Pointer_Axis_Relative_Direction_Enum :: enum u32 {
	// physical motion matches axis direction
	Identical = 0,
	// physical motion is the inverse of the axis direction
	Inverted = 1,
}
WL_POINTER_SET_CURSOR_OPCODE: Opcode : 0
// set the pointer surface
//
// Set the pointer surface, i.e., the surface that contains the
// pointer image (cursor). This request gives the surface the role
// of a cursor. If the surface already has another role, it raises
// a protocol error.
// 
// The cursor actually changes only if the pointer
// focus for this device is one of the requesting client's surfaces
// or the surface parameter is the current pointer surface. If
// there was a previous surface set with this request it is
// replaced. If surface is NULL, the pointer image is hidden.
// 
// The parameters hotspot_x and hotspot_y define the position of
// the pointer surface relative to the pointer location. Its
// top-left corner is always at (x, y) - (hotspot_x, hotspot_y),
// where (x, y) are the coordinates of the pointer location, in
// surface-local coordinates.
// 
// On surface.attach requests to the pointer surface, hotspot_x
// and hotspot_y are decremented by the x and y parameters
// passed to the request. Attach must be confirmed by
// wl_surface.commit as usual.
// 
// The hotspot can also be updated by passing the currently set
// pointer surface to this request with new values for hotspot_x
// and hotspot_y.
// 
// The input region is ignored for wl_surfaces with the role of
// a cursor. When the use as a cursor ends, the wl_surface is
// unmapped.
// 
// The serial parameter must match the latest wl_pointer.enter
// serial number sent to the client. Otherwise the request will be
// ignored.
// - serial: serial number of the enter event
// - surface: pointer surface
// - hotspot_x: surface-local x coordinate
// - hotspot_y: surface-local y coordinate
wl_pointer_set_cursor :: proc(conn_: ^Connection, target_: Wl_Pointer, serial: u32, surface: Wl_Surface, hotspot_x: i32, hotspot_y: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_POINTER_SET_CURSOR_OPCODE, msg_size_) or_return
	message_write(writer_, serial) or_return
	message_write(writer_, surface) or_return
	message_write(writer_, hotspot_x) or_return
	message_write(writer_, hotspot_y) or_return
	log.debugf("-> " + "wl_pointer" + "@{}." + "set_cursor" + ":" + " " + "serial" + "={}" + " " + "surface" + "={}" + " " + "hotspot_x" + "={}" + " " + "hotspot_y" + "={}", target_, serial, surface, hotspot_x, hotspot_y)
	return
}

WL_POINTER_RELEASE_OPCODE: Opcode : 1
// release the pointer object
//
// Using this request a client can tell the server that it is not going to
// use the pointer object anymore.
// 
// This request destroys the pointer proxy object, so clients must not call
// wl_pointer_destroy() after using this request.
wl_pointer_release :: proc(conn_: ^Connection, target_: Wl_Pointer, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_POINTER_RELEASE_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_pointer" + "@{}." + "release" + ":", target_)
	return
}

// enter event
//
// Notification that this seat's pointer is focused on a certain
// surface.
// 
// When a seat's focus enters a surface, the pointer image
// is undefined and a client should respond to this event by setting
// an appropriate pointer image with the set_cursor request.
Wl_Pointer_Enter_Event :: struct {
	target: Wl_Pointer,
	// serial number of the enter event
	serial: u32,
	// surface entered by the pointer
	surface: Wl_Surface,
	// surface-local x coordinate
	surface_x: Fixed,
	// surface-local y coordinate
	surface_y: Fixed,
}
WL_POINTER_ENTER_EVENT_OPCODE: Event_Opcode : 0
wl_pointer_enter_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Enter_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_ENTER_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.surface = message_read_object_id(&reader, Wl_Surface) or_return
	event.surface_x = message_read_fixed(&reader) or_return
	event.surface_y = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "enter" + ":" + " " + "serial" + "={}" + " " + "surface" + "={}" + " " + "surface_x" + "={}" + " " + "surface_y" + "={}", event.target, event.serial, event.surface, event.surface_x, event.surface_y)
	return
}

// leave event
//
// Notification that this seat's pointer is no longer focused on
// a certain surface.
// 
// The leave notification is sent before the enter notification
// for the new focus.
Wl_Pointer_Leave_Event :: struct {
	target: Wl_Pointer,
	// serial number of the leave event
	serial: u32,
	// surface left by the pointer
	surface: Wl_Surface,
}
WL_POINTER_LEAVE_EVENT_OPCODE: Event_Opcode : 1
wl_pointer_leave_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Leave_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_LEAVE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.surface = message_read_object_id(&reader, Wl_Surface) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "leave" + ":" + " " + "serial" + "={}" + " " + "surface" + "={}", event.target, event.serial, event.surface)
	return
}

// pointer motion event
//
// Notification of pointer location change. The arguments
// surface_x and surface_y are the location relative to the
// focused surface.
Wl_Pointer_Motion_Event :: struct {
	target: Wl_Pointer,
	// timestamp with millisecond granularity
	time: u32,
	// surface-local x coordinate
	surface_x: Fixed,
	// surface-local y coordinate
	surface_y: Fixed,
}
WL_POINTER_MOTION_EVENT_OPCODE: Event_Opcode : 2
wl_pointer_motion_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Motion_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_MOTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.time = message_read_u32(&reader) or_return
	event.surface_x = message_read_fixed(&reader) or_return
	event.surface_y = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "motion" + ":" + " " + "time" + "={}" + " " + "surface_x" + "={}" + " " + "surface_y" + "={}", event.target, event.time, event.surface_x, event.surface_y)
	return
}

// pointer button event
//
// Mouse button click and release notifications.
// 
// The location of the click is given by the last motion or
// enter event.
// The time argument is a timestamp with millisecond
// granularity, with an undefined base.
// 
// The button is a button code as defined in the Linux kernel's
// linux/input-event-codes.h header file, e.g. BTN_LEFT.
// 
// Any 16-bit button code value is reserved for future additions to the
// kernel's event code list. All other button codes above 0xFFFF are
// currently undefined but may be used in future versions of this
// protocol.
Wl_Pointer_Button_Event :: struct {
	target: Wl_Pointer,
	// serial number of the button event
	serial: u32,
	// timestamp with millisecond granularity
	time: u32,
	// button that produced the event
	button: u32,
	// physical state of the button
	state: Wl_Pointer_Button_State_Enum,}
WL_POINTER_BUTTON_EVENT_OPCODE: Event_Opcode : 3
wl_pointer_button_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Button_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_BUTTON_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.time = message_read_u32(&reader) or_return
	event.button = message_read_u32(&reader) or_return
	event.state = message_read_enum(&reader, Wl_Pointer_Button_State_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "button" + ":" + " " + "serial" + "={}" + " " + "time" + "={}" + " " + "button" + "={}" + " " + "state" + "={}", event.target, event.serial, event.time, event.button, event.state)
	return
}

// axis event
//
// Scroll and other axis notifications.
// 
// For scroll events (vertical and horizontal scroll axes), the
// value parameter is the length of a vector along the specified
// axis in a coordinate space identical to those of motion events,
// representing a relative movement along the specified axis.
// 
// For devices that support movements non-parallel to axes multiple
// axis events will be emitted.
// 
// When applicable, for example for touch pads, the server can
// choose to emit scroll events where the motion vector is
// equivalent to a motion event vector.
// 
// When applicable, a client can transform its content relative to the
// scroll distance.
Wl_Pointer_Axis_Event :: struct {
	target: Wl_Pointer,
	// timestamp with millisecond granularity
	time: u32,
	// axis type
	axis: Wl_Pointer_Axis_Enum,	// length of vector in surface-local coordinate space
	value: Fixed,
}
WL_POINTER_AXIS_EVENT_OPCODE: Event_Opcode : 4
wl_pointer_axis_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Axis_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_AXIS_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.time = message_read_u32(&reader) or_return
	event.axis = message_read_enum(&reader, Wl_Pointer_Axis_Enum) or_return
	event.value = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "axis" + ":" + " " + "time" + "={}" + " " + "axis" + "={}" + " " + "value" + "={}", event.target, event.time, event.axis, event.value)
	return
}

// end of a pointer event sequence
//
// Indicates the end of a set of events that logically belong together.
// A client is expected to accumulate the data in all events within the
// frame before proceeding.
// 
// All wl_pointer events before a wl_pointer.frame event belong
// logically together. For example, in a diagonal scroll motion the
// compositor will send an optional wl_pointer.axis_source event, two
// wl_pointer.axis events (horizontal and vertical) and finally a
// wl_pointer.frame event. The client may use this information to
// calculate a diagonal vector for scrolling.
// 
// When multiple wl_pointer.axis events occur within the same frame,
// the motion vector is the combined motion of all events.
// When a wl_pointer.axis and a wl_pointer.axis_stop event occur within
// the same frame, this indicates that axis movement in one axis has
// stopped but continues in the other axis.
// When multiple wl_pointer.axis_stop events occur within the same
// frame, this indicates that these axes stopped in the same instance.
// 
// A wl_pointer.frame event is sent for every logical event group,
// even if the group only contains a single wl_pointer event.
// Specifically, a client may get a sequence: motion, frame, button,
// frame, axis, frame, axis_stop, frame.
// 
// The wl_pointer.enter and wl_pointer.leave events are logical events
// generated by the compositor and not the hardware. These events are
// also grouped by a wl_pointer.frame. When a pointer moves from one
// surface to another, a compositor should group the
// wl_pointer.leave event within the same wl_pointer.frame.
// However, a client must not rely on wl_pointer.leave and
// wl_pointer.enter being in the same wl_pointer.frame.
// Compositor-specific policies may require the wl_pointer.leave and
// wl_pointer.enter event being split across multiple wl_pointer.frame
// groups.
Wl_Pointer_Frame_Event :: struct {
	target: Wl_Pointer,
}
WL_POINTER_FRAME_EVENT_OPCODE: Event_Opcode : 5
wl_pointer_frame_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Frame_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_FRAME_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "frame" + ":", event.target)
	return
}

// axis source event
//
// Source information for scroll and other axes.
// 
// This event does not occur on its own. It is sent before a
// wl_pointer.frame event and carries the source information for
// all events within that frame.
// 
// The source specifies how this event was generated. If the source is
// wl_pointer.axis_source.finger, a wl_pointer.axis_stop event will be
// sent when the user lifts the finger off the device.
// 
// If the source is wl_pointer.axis_source.wheel,
// wl_pointer.axis_source.wheel_tilt or
// wl_pointer.axis_source.continuous, a wl_pointer.axis_stop event may
// or may not be sent. Whether a compositor sends an axis_stop event
// for these sources is hardware-specific and implementation-dependent;
// clients must not rely on receiving an axis_stop event for these
// scroll sources and should treat scroll sequences from these scroll
// sources as unterminated by default.
// 
// This event is optional. If the source is unknown for a particular
// axis event sequence, no event is sent.
// Only one wl_pointer.axis_source event is permitted per frame.
// 
// The order of wl_pointer.axis_discrete and wl_pointer.axis_source is
// not guaranteed.
Wl_Pointer_Axis_Source_Event :: struct {
	target: Wl_Pointer,
	// source of the axis event
	axis_source: Wl_Pointer_Axis_Source_Enum,}
WL_POINTER_AXIS_SOURCE_EVENT_OPCODE: Event_Opcode : 6
wl_pointer_axis_source_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Axis_Source_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_AXIS_SOURCE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.axis_source = message_read_enum(&reader, Wl_Pointer_Axis_Source_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "axis_source" + ":" + " " + "axis_source" + "={}", event.target, event.axis_source)
	return
}

// axis stop event
//
// Stop notification for scroll and other axes.
// 
// For some wl_pointer.axis_source types, a wl_pointer.axis_stop event
// is sent to notify a client that the axis sequence has terminated.
// This enables the client to implement kinetic scrolling.
// See the wl_pointer.axis_source documentation for information on when
// this event may be generated.
// 
// Any wl_pointer.axis events with the same axis_source after this
// event should be considered as the start of a new axis motion.
// 
// The timestamp is to be interpreted identical to the timestamp in the
// wl_pointer.axis event. The timestamp value may be the same as a
// preceding wl_pointer.axis event.
Wl_Pointer_Axis_Stop_Event :: struct {
	target: Wl_Pointer,
	// timestamp with millisecond granularity
	time: u32,
	// the axis stopped with this event
	axis: Wl_Pointer_Axis_Enum,}
WL_POINTER_AXIS_STOP_EVENT_OPCODE: Event_Opcode : 7
wl_pointer_axis_stop_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Axis_Stop_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_AXIS_STOP_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.time = message_read_u32(&reader) or_return
	event.axis = message_read_enum(&reader, Wl_Pointer_Axis_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "axis_stop" + ":" + " " + "time" + "={}" + " " + "axis" + "={}", event.target, event.time, event.axis)
	return
}

// axis click event
//
// Discrete step information for scroll and other axes.
// 
// This event carries the axis value of the wl_pointer.axis event in
// discrete steps (e.g. mouse wheel clicks).
// 
// This event is deprecated with wl_pointer version 8 - this event is not
// sent to clients supporting version 8 or later.
// 
// This event does not occur on its own, it is coupled with a
// wl_pointer.axis event that represents this axis value on a
// continuous scale. The protocol guarantees that each axis_discrete
// event is always followed by exactly one axis event with the same
// axis number within the same wl_pointer.frame. Note that the protocol
// allows for other events to occur between the axis_discrete and
// its coupled axis event, including other axis_discrete or axis
// events. A wl_pointer.frame must not contain more than one axis_discrete
// event per axis type.
// 
// This event is optional; continuous scrolling devices
// like two-finger scrolling on touchpads do not have discrete
// steps and do not generate this event.
// 
// The discrete value carries the directional information. e.g. a value
// of -2 is two steps towards the negative direction of this axis.
// 
// The axis number is identical to the axis number in the associated
// axis event.
// 
// The order of wl_pointer.axis_discrete and wl_pointer.axis_source is
// not guaranteed.
Wl_Pointer_Axis_Discrete_Event :: struct {
	target: Wl_Pointer,
	// axis type
	axis: Wl_Pointer_Axis_Enum,	// number of steps
	discrete: i32,
}
WL_POINTER_AXIS_DISCRETE_EVENT_OPCODE: Event_Opcode : 8
wl_pointer_axis_discrete_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Axis_Discrete_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_AXIS_DISCRETE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.axis = message_read_enum(&reader, Wl_Pointer_Axis_Enum) or_return
	event.discrete = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "axis_discrete" + ":" + " " + "axis" + "={}" + " " + "discrete" + "={}", event.target, event.axis, event.discrete)
	return
}

// axis high-resolution scroll event
//
// Discrete high-resolution scroll information.
// 
// This event carries high-resolution wheel scroll information,
// with each multiple of 120 representing one logical scroll step
// (a wheel detent). For example, an axis_value120 of 30 is one quarter of
// a logical scroll step in the positive direction, a value120 of
// -240 are two logical scroll steps in the negative direction within the
// same hardware event.
// Clients that rely on discrete scrolling should accumulate the
// value120 to multiples of 120 before processing the event.
// 
// The value120 must not be zero.
// 
// This event replaces the wl_pointer.axis_discrete event in clients
// supporting wl_pointer version 8 or later.
// 
// Where a wl_pointer.axis_source event occurs in the same
// wl_pointer.frame, the axis source applies to this event.
// 
// The order of wl_pointer.axis_value120 and wl_pointer.axis_source is
// not guaranteed.
Wl_Pointer_Axis_Value120_Event :: struct {
	target: Wl_Pointer,
	// axis type
	axis: Wl_Pointer_Axis_Enum,	// scroll distance as fraction of 120
	value120: i32,
}
WL_POINTER_AXIS_VALUE120_EVENT_OPCODE: Event_Opcode : 9
wl_pointer_axis_value120_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Axis_Value120_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_AXIS_VALUE120_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.axis = message_read_enum(&reader, Wl_Pointer_Axis_Enum) or_return
	event.value120 = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "axis_value120" + ":" + " " + "axis" + "={}" + " " + "value120" + "={}", event.target, event.axis, event.value120)
	return
}

// axis relative physical direction event
//
// Relative directional information of the entity causing the axis
// motion.
// 
// For a wl_pointer.axis event, the wl_pointer.axis_relative_direction
// event specifies the movement direction of the entity causing the
// wl_pointer.axis event. For example:
// - if a user's fingers on a touchpad move down and this
// causes a wl_pointer.axis vertical_scroll down event, the physical
// direction is 'identical'
// - if a user's fingers on a touchpad move down and this causes a
// wl_pointer.axis vertical_scroll up scroll up event ('natural
// scrolling'), the physical direction is 'inverted'.
// 
// A client may use this information to adjust scroll motion of
// components. Specifically, enabling natural scrolling causes the
// content to change direction compared to traditional scrolling.
// Some widgets like volume control sliders should usually match the
// physical direction regardless of whether natural scrolling is
// active. This event enables clients to match the scroll direction of
// a widget to the physical direction.
// 
// This event does not occur on its own, it is coupled with a
// wl_pointer.axis event that represents this axis value.
// The protocol guarantees that each axis_relative_direction event is
// always followed by exactly one axis event with the same
// axis number within the same wl_pointer.frame. Note that the protocol
// allows for other events to occur between the axis_relative_direction
// and its coupled axis event.
// 
// The axis number is identical to the axis number in the associated
// axis event.
// 
// The order of wl_pointer.axis_relative_direction,
// wl_pointer.axis_discrete and wl_pointer.axis_source is not
// guaranteed.
Wl_Pointer_Axis_Relative_Direction_Event :: struct {
	target: Wl_Pointer,
	// axis type
	axis: Wl_Pointer_Axis_Enum,	// physical direction relative to axis motion
	direction: Wl_Pointer_Axis_Relative_Direction_Enum,}
WL_POINTER_AXIS_RELATIVE_DIRECTION_EVENT_OPCODE: Event_Opcode : 10
wl_pointer_axis_relative_direction_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Pointer_Axis_Relative_Direction_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_POINTER_AXIS_RELATIVE_DIRECTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.axis = message_read_enum(&reader, Wl_Pointer_Axis_Enum) or_return
	event.direction = message_read_enum(&reader, Wl_Pointer_Axis_Relative_Direction_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_pointer" + "@{}." + "axis_relative_direction" + ":" + " " + "axis" + "={}" + " " + "direction" + "={}", event.target, event.axis, event.direction)
	return
}

// keyboard input device
//
// The wl_keyboard interface represents one or more keyboards
// associated with a seat.
Wl_Keyboard :: Object_Id

// keyboard mapping format
//
// This specifies the format of the keymap provided to the
// client with the wl_keyboard.keymap event.
Wl_Keyboard_Keymap_Format_Enum :: enum u32 {
	// no keymap; client must understand how to interpret the raw keycode
	No_Keymap = 0,
	// libxkbcommon compatible, null-terminated string; to determine the xkb keycode, clients must add 8 to the key event keycode
	Xkb_V1 = 1,
}
// physical key state
//
// Describes the physical state of a key that produced the key event.
Wl_Keyboard_Key_State_Enum :: enum u32 {
	// key is not pressed
	Released = 0,
	// key is pressed
	Pressed = 1,
}
WL_KEYBOARD_RELEASE_OPCODE: Opcode : 0
// release the keyboard object
wl_keyboard_release :: proc(conn_: ^Connection, target_: Wl_Keyboard, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_KEYBOARD_RELEASE_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_keyboard" + "@{}." + "release" + ":", target_)
	return
}

// keyboard mapping
//
// This event provides a file descriptor to the client which can be
// memory-mapped in read-only mode to provide a keyboard mapping
// description.
// 
// From version 7 onwards, the fd must be mapped with MAP_PRIVATE by
// the recipient, as MAP_SHARED may fail.
Wl_Keyboard_Keymap_Event :: struct {
	target: Wl_Keyboard,
	// keymap format
	format: Wl_Keyboard_Keymap_Format_Enum,	// keymap file descriptor
	fd: posix.FD,
	// keymap size, in bytes
	size: u32,
}
WL_KEYBOARD_KEYMAP_EVENT_OPCODE: Event_Opcode : 0
wl_keyboard_keymap_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Keyboard_Keymap_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_KEYBOARD_KEYMAP_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.format = message_read_enum(&reader, Wl_Keyboard_Keymap_Format_Enum) or_return
	event.fd = connection_read_fd(conn) or_return
	event.size = message_read_u32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_keyboard" + "@{}." + "keymap" + ":" + " " + "format" + "={}" + " " + "fd" + "={}" + " " + "size" + "={}", event.target, event.format, event.fd, event.size)
	return
}

// enter event
//
// Notification that this seat's keyboard focus is on a certain
// surface.
// 
// The compositor must send the wl_keyboard.modifiers event after this
// event.
Wl_Keyboard_Enter_Event :: struct {
	target: Wl_Keyboard,
	// serial number of the enter event
	serial: u32,
	// surface gaining keyboard focus
	surface: Wl_Surface,
	// the currently pressed keys
	keys: []u8,
}
WL_KEYBOARD_ENTER_EVENT_OPCODE: Event_Opcode : 1
wl_keyboard_enter_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Keyboard_Enter_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_KEYBOARD_ENTER_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.surface = message_read_object_id(&reader, Wl_Surface) or_return
	event.keys = message_read_array(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_keyboard" + "@{}." + "enter" + ":" + " " + "serial" + "={}" + " " + "surface" + "={}" + " " + "keys" + "={}", event.target, event.serial, event.surface, event.keys)
	return
}

// leave event
//
// Notification that this seat's keyboard focus is no longer on
// a certain surface.
// 
// The leave notification is sent before the enter notification
// for the new focus.
// 
// After this event client must assume that all keys, including modifiers,
// are lifted and also it must stop key repeating if there's some going on.
Wl_Keyboard_Leave_Event :: struct {
	target: Wl_Keyboard,
	// serial number of the leave event
	serial: u32,
	// surface that lost keyboard focus
	surface: Wl_Surface,
}
WL_KEYBOARD_LEAVE_EVENT_OPCODE: Event_Opcode : 2
wl_keyboard_leave_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Keyboard_Leave_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_KEYBOARD_LEAVE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.surface = message_read_object_id(&reader, Wl_Surface) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_keyboard" + "@{}." + "leave" + ":" + " " + "serial" + "={}" + " " + "surface" + "={}", event.target, event.serial, event.surface)
	return
}

// key event
//
// A key was pressed or released.
// The time argument is a timestamp with millisecond
// granularity, with an undefined base.
// 
// The key is a platform-specific key code that can be interpreted
// by feeding it to the keyboard mapping (see the keymap event).
// 
// If this event produces a change in modifiers, then the resulting
// wl_keyboard.modifiers event must be sent after this event.
Wl_Keyboard_Key_Event :: struct {
	target: Wl_Keyboard,
	// serial number of the key event
	serial: u32,
	// timestamp with millisecond granularity
	time: u32,
	// key that produced the event
	key: u32,
	// physical state of the key
	state: Wl_Keyboard_Key_State_Enum,}
WL_KEYBOARD_KEY_EVENT_OPCODE: Event_Opcode : 3
wl_keyboard_key_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Keyboard_Key_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_KEYBOARD_KEY_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.time = message_read_u32(&reader) or_return
	event.key = message_read_u32(&reader) or_return
	event.state = message_read_enum(&reader, Wl_Keyboard_Key_State_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_keyboard" + "@{}." + "key" + ":" + " " + "serial" + "={}" + " " + "time" + "={}" + " " + "key" + "={}" + " " + "state" + "={}", event.target, event.serial, event.time, event.key, event.state)
	return
}

// modifier and group state
//
// Notifies clients that the modifier and/or group state has
// changed, and it should update its local state.
Wl_Keyboard_Modifiers_Event :: struct {
	target: Wl_Keyboard,
	// serial number of the modifiers event
	serial: u32,
	// depressed modifiers
	mods_depressed: u32,
	// latched modifiers
	mods_latched: u32,
	// locked modifiers
	mods_locked: u32,
	// keyboard layout
	group: u32,
}
WL_KEYBOARD_MODIFIERS_EVENT_OPCODE: Event_Opcode : 4
wl_keyboard_modifiers_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Keyboard_Modifiers_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_KEYBOARD_MODIFIERS_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.mods_depressed = message_read_u32(&reader) or_return
	event.mods_latched = message_read_u32(&reader) or_return
	event.mods_locked = message_read_u32(&reader) or_return
	event.group = message_read_u32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_keyboard" + "@{}." + "modifiers" + ":" + " " + "serial" + "={}" + " " + "mods_depressed" + "={}" + " " + "mods_latched" + "={}" + " " + "mods_locked" + "={}" + " " + "group" + "={}", event.target, event.serial, event.mods_depressed, event.mods_latched, event.mods_locked, event.group)
	return
}

// repeat rate and delay
//
// Informs the client about the keyboard's repeat rate and delay.
// 
// This event is sent as soon as the wl_keyboard object has been created,
// and is guaranteed to be received by the client before any key press
// event.
// 
// Negative values for either rate or delay are illegal. A rate of zero
// will disable any repeating (regardless of the value of delay).
// 
// This event can be sent later on as well with a new value if necessary,
// so clients should continue listening for the event past the creation
// of wl_keyboard.
Wl_Keyboard_Repeat_Info_Event :: struct {
	target: Wl_Keyboard,
	// the rate of repeating keys in characters per second
	rate: i32,
	// delay in milliseconds since key down until repeating starts
	delay: i32,
}
WL_KEYBOARD_REPEAT_INFO_EVENT_OPCODE: Event_Opcode : 5
wl_keyboard_repeat_info_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Keyboard_Repeat_Info_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_KEYBOARD_REPEAT_INFO_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.rate = message_read_i32(&reader) or_return
	event.delay = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_keyboard" + "@{}." + "repeat_info" + ":" + " " + "rate" + "={}" + " " + "delay" + "={}", event.target, event.rate, event.delay)
	return
}

// touchscreen input device
//
// The wl_touch interface represents a touchscreen
// associated with a seat.
// 
// Touch interactions can consist of one or more contacts.
// For each contact, a series of events is generated, starting
// with a down event, followed by zero or more motion events,
// and ending with an up event. Events relating to the same
// contact point can be identified by the ID of the sequence.
Wl_Touch :: Object_Id

WL_TOUCH_RELEASE_OPCODE: Opcode : 0
// release the touch object
wl_touch_release :: proc(conn_: ^Connection, target_: Wl_Touch, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_TOUCH_RELEASE_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_touch" + "@{}." + "release" + ":", target_)
	return
}

// touch down event and beginning of a touch sequence
//
// A new touch point has appeared on the surface. This touch point is
// assigned a unique ID. Future events from this touch point reference
// this ID. The ID ceases to be valid after a touch up event and may be
// reused in the future.
Wl_Touch_Down_Event :: struct {
	target: Wl_Touch,
	// serial number of the touch down event
	serial: u32,
	// timestamp with millisecond granularity
	time: u32,
	// surface touched
	surface: Wl_Surface,
	// the unique ID of this touch point
	id: i32,
	// surface-local x coordinate
	x: Fixed,
	// surface-local y coordinate
	y: Fixed,
}
WL_TOUCH_DOWN_EVENT_OPCODE: Event_Opcode : 0
wl_touch_down_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Down_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_DOWN_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.time = message_read_u32(&reader) or_return
	event.surface = message_read_object_id(&reader, Wl_Surface) or_return
	event.id = message_read_i32(&reader) or_return
	event.x = message_read_fixed(&reader) or_return
	event.y = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "down" + ":" + " " + "serial" + "={}" + " " + "time" + "={}" + " " + "surface" + "={}" + " " + "id" + "={}" + " " + "x" + "={}" + " " + "y" + "={}", event.target, event.serial, event.time, event.surface, event.id, event.x, event.y)
	return
}

// end of a touch event sequence
//
// The touch point has disappeared. No further events will be sent for
// this touch point and the touch point's ID is released and may be
// reused in a future touch down event.
Wl_Touch_Up_Event :: struct {
	target: Wl_Touch,
	// serial number of the touch up event
	serial: u32,
	// timestamp with millisecond granularity
	time: u32,
	// the unique ID of this touch point
	id: i32,
}
WL_TOUCH_UP_EVENT_OPCODE: Event_Opcode : 1
wl_touch_up_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Up_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_UP_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.serial = message_read_u32(&reader) or_return
	event.time = message_read_u32(&reader) or_return
	event.id = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "up" + ":" + " " + "serial" + "={}" + " " + "time" + "={}" + " " + "id" + "={}", event.target, event.serial, event.time, event.id)
	return
}

// update of touch point coordinates
//
// A touch point has changed coordinates.
Wl_Touch_Motion_Event :: struct {
	target: Wl_Touch,
	// timestamp with millisecond granularity
	time: u32,
	// the unique ID of this touch point
	id: i32,
	// surface-local x coordinate
	x: Fixed,
	// surface-local y coordinate
	y: Fixed,
}
WL_TOUCH_MOTION_EVENT_OPCODE: Event_Opcode : 2
wl_touch_motion_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Motion_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_MOTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.time = message_read_u32(&reader) or_return
	event.id = message_read_i32(&reader) or_return
	event.x = message_read_fixed(&reader) or_return
	event.y = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "motion" + ":" + " " + "time" + "={}" + " " + "id" + "={}" + " " + "x" + "={}" + " " + "y" + "={}", event.target, event.time, event.id, event.x, event.y)
	return
}

// end of touch frame event
//
// Indicates the end of a set of events that logically belong together.
// A client is expected to accumulate the data in all events within the
// frame before proceeding.
// 
// A wl_touch.frame terminates at least one event but otherwise no
// guarantee is provided about the set of events within a frame. A client
// must assume that any state not updated in a frame is unchanged from the
// previously known state.
Wl_Touch_Frame_Event :: struct {
	target: Wl_Touch,
}
WL_TOUCH_FRAME_EVENT_OPCODE: Event_Opcode : 3
wl_touch_frame_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Frame_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_FRAME_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "frame" + ":", event.target)
	return
}

// touch session cancelled
//
// Sent if the compositor decides the touch stream is a global
// gesture. No further events are sent to the clients from that
// particular gesture. Touch cancellation applies to all touch points
// currently active on this client's surface. The client is
// responsible for finalizing the touch points, future touch points on
// this surface may reuse the touch point ID.
Wl_Touch_Cancel_Event :: struct {
	target: Wl_Touch,
}
WL_TOUCH_CANCEL_EVENT_OPCODE: Event_Opcode : 4
wl_touch_cancel_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Cancel_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_CANCEL_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "cancel" + ":", event.target)
	return
}

// update shape of touch point
//
// Sent when a touchpoint has changed its shape.
// 
// This event does not occur on its own. It is sent before a
// wl_touch.frame event and carries the new shape information for
// any previously reported, or new touch points of that frame.
// 
// Other events describing the touch point such as wl_touch.down,
// wl_touch.motion or wl_touch.orientation may be sent within the
// same wl_touch.frame. A client should treat these events as a single
// logical touch point update. The order of wl_touch.shape,
// wl_touch.orientation and wl_touch.motion is not guaranteed.
// A wl_touch.down event is guaranteed to occur before the first
// wl_touch.shape event for this touch ID but both events may occur within
// the same wl_touch.frame.
// 
// A touchpoint shape is approximated by an ellipse through the major and
// minor axis length. The major axis length describes the longer diameter
// of the ellipse, while the minor axis length describes the shorter
// diameter. Major and minor are orthogonal and both are specified in
// surface-local coordinates. The center of the ellipse is always at the
// touchpoint location as reported by wl_touch.down or wl_touch.move.
// 
// This event is only sent by the compositor if the touch device supports
// shape reports. The client has to make reasonable assumptions about the
// shape if it did not receive this event.
Wl_Touch_Shape_Event :: struct {
	target: Wl_Touch,
	// the unique ID of this touch point
	id: i32,
	// length of the major axis in surface-local coordinates
	major: Fixed,
	// length of the minor axis in surface-local coordinates
	minor: Fixed,
}
WL_TOUCH_SHAPE_EVENT_OPCODE: Event_Opcode : 5
wl_touch_shape_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Shape_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_SHAPE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.id = message_read_i32(&reader) or_return
	event.major = message_read_fixed(&reader) or_return
	event.minor = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "shape" + ":" + " " + "id" + "={}" + " " + "major" + "={}" + " " + "minor" + "={}", event.target, event.id, event.major, event.minor)
	return
}

// update orientation of touch point
//
// Sent when a touchpoint has changed its orientation.
// 
// This event does not occur on its own. It is sent before a
// wl_touch.frame event and carries the new shape information for
// any previously reported, or new touch points of that frame.
// 
// Other events describing the touch point such as wl_touch.down,
// wl_touch.motion or wl_touch.shape may be sent within the
// same wl_touch.frame. A client should treat these events as a single
// logical touch point update. The order of wl_touch.shape,
// wl_touch.orientation and wl_touch.motion is not guaranteed.
// A wl_touch.down event is guaranteed to occur before the first
// wl_touch.orientation event for this touch ID but both events may occur
// within the same wl_touch.frame.
// 
// The orientation describes the clockwise angle of a touchpoint's major
// axis to the positive surface y-axis and is normalized to the -180 to
// +180 degree range. The granularity of orientation depends on the touch
// device, some devices only support binary rotation values between 0 and
// 90 degrees.
// 
// This event is only sent by the compositor if the touch device supports
// orientation reports.
Wl_Touch_Orientation_Event :: struct {
	target: Wl_Touch,
	// the unique ID of this touch point
	id: i32,
	// angle between major axis and positive surface y-axis in degrees
	orientation: Fixed,
}
WL_TOUCH_ORIENTATION_EVENT_OPCODE: Event_Opcode : 6
wl_touch_orientation_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Touch_Orientation_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_TOUCH_ORIENTATION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.id = message_read_i32(&reader) or_return
	event.orientation = message_read_fixed(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_touch" + "@{}." + "orientation" + ":" + " " + "id" + "={}" + " " + "orientation" + "={}", event.target, event.id, event.orientation)
	return
}

// compositor output region
//
// An output describes part of the compositor geometry.  The
// compositor works in the 'compositor coordinate system' and an
// output corresponds to a rectangular area in that space that is
// actually visible.  This typically corresponds to a monitor that
// displays part of the compositor space.  This object is published
// as global during start up, or when a monitor is hotplugged.
Wl_Output :: Object_Id

// subpixel geometry information
//
// This enumeration describes how the physical
// pixels on an output are laid out.
Wl_Output_Subpixel_Enum :: enum u32 {
	// unknown geometry
	Unknown = 0,
	// no geometry
	None = 1,
	// horizontal RGB
	Horizontal_Rgb = 2,
	// horizontal BGR
	Horizontal_Bgr = 3,
	// vertical RGB
	Vertical_Rgb = 4,
	// vertical BGR
	Vertical_Bgr = 5,
}
// transform from framebuffer to output
//
// This describes the transform that a compositor will apply to a
// surface to compensate for the rotation or mirroring of an
// output device.
// 
// The flipped values correspond to an initial flip around a
// vertical axis followed by rotation.
// 
// The purpose is mainly to allow clients to render accordingly and
// tell the compositor, so that for fullscreen surfaces, the
// compositor will still be able to scan out directly from client
// surfaces.
Wl_Output_Transform_Enum :: enum u32 {
	// no transform
	Normal = 0,
	// 90 degrees counter-clockwise
	_90 = 1,
	// 180 degrees counter-clockwise
	_180 = 2,
	// 270 degrees counter-clockwise
	_270 = 3,
	// 180 degree flip around a vertical axis
	Flipped = 4,
	// flip and rotate 90 degrees counter-clockwise
	Flipped_90 = 5,
	// flip and rotate 180 degrees counter-clockwise
	Flipped_180 = 6,
	// flip and rotate 270 degrees counter-clockwise
	Flipped_270 = 7,
}
// mode information
//
// These flags describe properties of an output mode.
// They are used in the flags bitfield of the mode event.
Wl_Output_Mode_Enum :: distinct bit_set[enum u32 {
	// indicates this is the current mode
	Current /* = 1 */,
	// indicates this is the preferred mode
	Preferred /* = 2 */,
}; u32]
WL_OUTPUT_RELEASE_OPCODE: Opcode : 0
// release the output object
//
// Using this request a client can tell the server that it is not going to
// use the output object anymore.
wl_output_release :: proc(conn_: ^Connection, target_: Wl_Output, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_OUTPUT_RELEASE_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_output" + "@{}." + "release" + ":", target_)
	return
}

// properties of the output
//
// The geometry event describes geometric properties of the output.
// The event is sent when binding to the output object and whenever
// any of the properties change.
// 
// The physical size can be set to zero if it doesn't make sense for this
// output (e.g. for projectors or virtual outputs).
// 
// The geometry event will be followed by a done event (starting from
// version 2).
// 
// Note: wl_output only advertises partial information about the output
// position and identification. Some compositors, for instance those not
// implementing a desktop-style output layout or those exposing virtual
// outputs, might fake this information. Instead of using x and y, clients
// should use xdg_output.logical_position. Instead of using make and model,
// clients should use name and description.
Wl_Output_Geometry_Event :: struct {
	target: Wl_Output,
	// x position within the global compositor space
	x: i32,
	// y position within the global compositor space
	y: i32,
	// width in millimeters of the output
	physical_width: i32,
	// height in millimeters of the output
	physical_height: i32,
	// subpixel orientation of the output
	subpixel: Wl_Output_Subpixel_Enum,	// textual description of the manufacturer
	make: string,
	// textual description of the model
	model: string,
	// transform that maps framebuffer to output
	transform: Wl_Output_Transform_Enum,}
WL_OUTPUT_GEOMETRY_EVENT_OPCODE: Event_Opcode : 0
wl_output_geometry_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Output_Geometry_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_OUTPUT_GEOMETRY_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.x = message_read_i32(&reader) or_return
	event.y = message_read_i32(&reader) or_return
	event.physical_width = message_read_i32(&reader) or_return
	event.physical_height = message_read_i32(&reader) or_return
	event.subpixel = message_read_enum(&reader, Wl_Output_Subpixel_Enum) or_return
	event.make = message_read_string(&reader) or_return
	event.model = message_read_string(&reader) or_return
	event.transform = message_read_enum(&reader, Wl_Output_Transform_Enum) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_output" + "@{}." + "geometry" + ":" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "physical_width" + "={}" + " " + "physical_height" + "={}" + " " + "subpixel" + "={}" + " " + "make" + "={}" + " " + "model" + "={}" + " " + "transform" + "={}", event.target, event.x, event.y, event.physical_width, event.physical_height, event.subpixel, event.make, event.model, event.transform)
	return
}

// advertise available modes for the output
//
// The mode event describes an available mode for the output.
// 
// The event is sent when binding to the output object and there
// will always be one mode, the current mode.  The event is sent
// again if an output changes mode, for the mode that is now
// current.  In other words, the current mode is always the last
// mode that was received with the current flag set.
// 
// Non-current modes are deprecated. A compositor can decide to only
// advertise the current mode and never send other modes. Clients
// should not rely on non-current modes.
// 
// The size of a mode is given in physical hardware units of
// the output device. This is not necessarily the same as
// the output size in the global compositor space. For instance,
// the output may be scaled, as described in wl_output.scale,
// or transformed, as described in wl_output.transform. Clients
// willing to retrieve the output size in the global compositor
// space should use xdg_output.logical_size instead.
// 
// The vertical refresh rate can be set to zero if it doesn't make
// sense for this output (e.g. for virtual outputs).
// 
// The mode event will be followed by a done event (starting from
// version 2).
// 
// Clients should not use the refresh rate to schedule frames. Instead,
// they should use the wl_surface.frame event or the presentation-time
// protocol.
// 
// Note: this information is not always meaningful for all outputs. Some
// compositors, such as those exposing virtual outputs, might fake the
// refresh rate or the size.
Wl_Output_Mode_Event :: struct {
	target: Wl_Output,
	// bitfield of mode flags
	flags: Wl_Output_Mode_Enum,	// width of the mode in hardware units
	width: i32,
	// height of the mode in hardware units
	height: i32,
	// vertical refresh rate in mHz
	refresh: i32,
}
WL_OUTPUT_MODE_EVENT_OPCODE: Event_Opcode : 1
wl_output_mode_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Output_Mode_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_OUTPUT_MODE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.flags = message_read_enum(&reader, Wl_Output_Mode_Enum) or_return
	event.width = message_read_i32(&reader) or_return
	event.height = message_read_i32(&reader) or_return
	event.refresh = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_output" + "@{}." + "mode" + ":" + " " + "flags" + "={}" + " " + "width" + "={}" + " " + "height" + "={}" + " " + "refresh" + "={}", event.target, event.flags, event.width, event.height, event.refresh)
	return
}

// sent all information about output
//
// This event is sent after all other properties have been
// sent after binding to the output object and after any
// other property changes done after that. This allows
// changes to the output properties to be seen as
// atomic, even if they happen via multiple events.
Wl_Output_Done_Event :: struct {
	target: Wl_Output,
}
WL_OUTPUT_DONE_EVENT_OPCODE: Event_Opcode : 2
wl_output_done_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Output_Done_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_OUTPUT_DONE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_output" + "@{}." + "done" + ":", event.target)
	return
}

// output scaling properties
//
// This event contains scaling geometry information
// that is not in the geometry event. It may be sent after
// binding the output object or if the output scale changes
// later. If it is not sent, the client should assume a
// scale of 1.
// 
// A scale larger than 1 means that the compositor will
// automatically scale surface buffers by this amount
// when rendering. This is used for very high resolution
// displays where applications rendering at the native
// resolution would be too small to be legible.
// 
// It is intended that scaling aware clients track the
// current output of a surface, and if it is on a scaled
// output it should use wl_surface.set_buffer_scale with
// the scale of the output. That way the compositor can
// avoid scaling the surface, and the client can supply
// a higher detail image.
// 
// The scale event will be followed by a done event.
Wl_Output_Scale_Event :: struct {
	target: Wl_Output,
	// scaling factor of output
	factor: i32,
}
WL_OUTPUT_SCALE_EVENT_OPCODE: Event_Opcode : 3
wl_output_scale_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Output_Scale_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_OUTPUT_SCALE_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.factor = message_read_i32(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_output" + "@{}." + "scale" + ":" + " " + "factor" + "={}", event.target, event.factor)
	return
}

// name of this output
//
// Many compositors will assign user-friendly names to their outputs, show
// them to the user, allow the user to refer to an output, etc. The client
// may wish to know this name as well to offer the user similar behaviors.
// 
// The name is a UTF-8 string with no convention defined for its contents.
// Each name is unique among all wl_output globals. The name is only
// guaranteed to be unique for the compositor instance.
// 
// The same output name is used for all clients for a given wl_output
// global. Thus, the name can be shared across processes to refer to a
// specific wl_output global.
// 
// The name is not guaranteed to be persistent across sessions, thus cannot
// be used to reliably identify an output in e.g. configuration files.
// 
// Examples of names include 'HDMI-A-1', 'WL-1', 'X11-1', etc. However, do
// not assume that the name is a reflection of an underlying DRM connector,
// X11 connection, etc.
// 
// The name event is sent after binding the output object. This event is
// only sent once per output object, and the name does not change over the
// lifetime of the wl_output global.
// 
// Compositors may re-use the same output name if the wl_output global is
// destroyed and re-created later. Compositors should avoid re-using the
// same name if possible.
// 
// The name event will be followed by a done event.
Wl_Output_Name_Event :: struct {
	target: Wl_Output,
	// output name
	name: string,
}
WL_OUTPUT_NAME_EVENT_OPCODE: Event_Opcode : 4
wl_output_name_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Output_Name_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_OUTPUT_NAME_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.name = message_read_string(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_output" + "@{}." + "name" + ":" + " " + "name" + "={}", event.target, event.name)
	return
}

// human-readable description of this output
//
// Many compositors can produce human-readable descriptions of their
// outputs. The client may wish to know this description as well, e.g. for
// output selection purposes.
// 
// The description is a UTF-8 string with no convention defined for its
// contents. The description is not guaranteed to be unique among all
// wl_output globals. Examples might include 'Foocorp 11" Display' or
// 'Virtual X11 output via :1'.
// 
// The description event is sent after binding the output object and
// whenever the description changes. The description is optional, and may
// not be sent at all.
// 
// The description event will be followed by a done event.
Wl_Output_Description_Event :: struct {
	target: Wl_Output,
	// output description
	description: string,
}
WL_OUTPUT_DESCRIPTION_EVENT_OPCODE: Event_Opcode : 5
wl_output_description_parse :: proc(conn: ^Connection, message: Message) -> (event: Wl_Output_Description_Event, err: Conn_Error) {
	assert(message.header.target != 0)
	assert(message.header.opcode == WL_OUTPUT_DESCRIPTION_EVENT_OPCODE)
	reader: bytes.Reader
	bytes.reader_init(&reader, message.payload)
	event.target = message.header.target
	event.description = message_read_string(&reader) or_return

	if bytes.reader_length(&reader) > 0 {
	    log.error("message size mis-match: header={} parsed_size={}", message.header, reader.i)
		return {}, .Invalid_Message
	}
	log.debugf("<- " + "wl_output" + "@{}." + "description" + ":" + " " + "description" + "={}", event.target, event.description)
	return
}

// region interface
//
// A region object describes an area.
// 
// Region objects are used to describe the opaque and input
// regions of a surface.
Wl_Region :: Object_Id

WL_REGION_DESTROY_OPCODE: Opcode : 0
// destroy region
//
// Destroy the region.  This will invalidate the object ID.
wl_region_destroy :: proc(conn_: ^Connection, target_: Wl_Region, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_REGION_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_region" + "@{}." + "destroy" + ":", target_)
	return
}

WL_REGION_ADD_OPCODE: Opcode : 1
// add rectangle to region
//
// Add the specified rectangle to the region.
// - x: region-local x coordinate
// - y: region-local y coordinate
// - width: rectangle width
// - height: rectangle height
wl_region_add :: proc(conn_: ^Connection, target_: Wl_Region, x: i32, y: i32, width: i32, height: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_REGION_ADD_OPCODE, msg_size_) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	message_write(writer_, width) or_return
	message_write(writer_, height) or_return
	log.debugf("-> " + "wl_region" + "@{}." + "add" + ":" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "width" + "={}" + " " + "height" + "={}", target_, x, y, width, height)
	return
}

WL_REGION_SUBTRACT_OPCODE: Opcode : 2
// subtract rectangle from region
//
// Subtract the specified rectangle from the region.
// - x: region-local x coordinate
// - y: region-local y coordinate
// - width: rectangle width
// - height: rectangle height
wl_region_subtract :: proc(conn_: ^Connection, target_: Wl_Region, x: i32, y: i32, width: i32, height: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 16
	message_write_header(writer_, target_, WL_REGION_SUBTRACT_OPCODE, msg_size_) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	message_write(writer_, width) or_return
	message_write(writer_, height) or_return
	log.debugf("-> " + "wl_region" + "@{}." + "subtract" + ":" + " " + "x" + "={}" + " " + "y" + "={}" + " " + "width" + "={}" + " " + "height" + "={}", target_, x, y, width, height)
	return
}

// sub-surface compositing
//
// The global interface exposing sub-surface compositing capabilities.
// A wl_surface, that has sub-surfaces associated, is called the
// parent surface. Sub-surfaces can be arbitrarily nested and create
// a tree of sub-surfaces.
// 
// The root surface in a tree of sub-surfaces is the main
// surface. The main surface cannot be a sub-surface, because
// sub-surfaces must always have a parent.
// 
// A main surface with its sub-surfaces forms a (compound) window.
// For window management purposes, this set of wl_surface objects is
// to be considered as a single window, and it should also behave as
// such.
// 
// The aim of sub-surfaces is to offload some of the compositing work
// within a window from clients to the compositor. A prime example is
// a video player with decorations and video in separate wl_surface
// objects. This should allow the compositor to pass YUV video buffer
// processing to dedicated overlay hardware when possible.
Wl_Subcompositor :: Object_Id

Wl_Subcompositor_Error_Enum :: enum u32 {
	// the to-be sub-surface is invalid
	Bad_Surface = 0,
	// the to-be sub-surface parent is invalid
	Bad_Parent = 1,
}
WL_SUBCOMPOSITOR_DESTROY_OPCODE: Opcode : 0
// unbind from the subcompositor interface
//
// Informs the server that the client will not be using this
// protocol object anymore. This does not affect any other
// objects, wl_subsurface objects included.
wl_subcompositor_destroy :: proc(conn_: ^Connection, target_: Wl_Subcompositor, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SUBCOMPOSITOR_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_subcompositor" + "@{}." + "destroy" + ":", target_)
	return
}

WL_SUBCOMPOSITOR_GET_SUBSURFACE_OPCODE: Opcode : 1
// give a surface the role sub-surface
//
// Create a sub-surface interface for the given surface, and
// associate it with the given parent surface. This turns a
// plain wl_surface into a sub-surface.
// 
// The to-be sub-surface must not already have another role, and it
// must not have an existing wl_subsurface object. Otherwise the
// bad_surface protocol error is raised.
// 
// Adding sub-surfaces to a parent is a double-buffered operation on the
// parent (see wl_surface.commit). The effect of adding a sub-surface
// becomes visible on the next time the state of the parent surface is
// applied.
// 
// The parent surface must not be one of the child surface's descendants,
// and the parent must be different from the child surface, otherwise the
// bad_parent protocol error is raised.
// 
// This request modifies the behaviour of wl_surface.commit request on
// the sub-surface, see the documentation on wl_subsurface interface.
// - id: the new sub-surface object ID
// - surface: the surface to be turned into a sub-surface
// - parent: the parent surface
wl_subcompositor_get_subsurface :: proc(conn_: ^Connection, target_: Wl_Subcompositor, surface: Wl_Surface, parent: Wl_Surface, ) -> (id: Wl_Subsurface, err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 12
	message_write_header(writer_, target_, WL_SUBCOMPOSITOR_GET_SUBSURFACE_OPCODE, msg_size_) or_return
	id = connection_alloc_id(conn_) or_return
	message_write(writer_, id) or_return
	message_write(writer_, surface) or_return
	message_write(writer_, parent) or_return
	log.debugf("-> " + "wl_subcompositor" + "@{}." + "get_subsurface" + ":" + " " + "id" + "={}" + " " + "surface" + "={}" + " " + "parent" + "={}", target_, id, surface, parent)
	return
}

// sub-surface interface to a wl_surface
//
// An additional interface to a wl_surface object, which has been
// made a sub-surface. A sub-surface has one parent surface. A
// sub-surface's size and position are not limited to that of the parent.
// Particularly, a sub-surface is not automatically clipped to its
// parent's area.
// 
// A sub-surface becomes mapped, when a non-NULL wl_buffer is applied
// and the parent surface is mapped. The order of which one happens
// first is irrelevant. A sub-surface is hidden if the parent becomes
// hidden, or if a NULL wl_buffer is applied. These rules apply
// recursively through the tree of surfaces.
// 
// The behaviour of a wl_surface.commit request on a sub-surface
// depends on the sub-surface's mode. The possible modes are
// synchronized and desynchronized, see methods
// wl_subsurface.set_sync and wl_subsurface.set_desync. Synchronized
// mode caches the wl_surface state to be applied when the parent's
// state gets applied, and desynchronized mode applies the pending
// wl_surface state directly. A sub-surface is initially in the
// synchronized mode.
// 
// Sub-surfaces also have another kind of state, which is managed by
// wl_subsurface requests, as opposed to wl_surface requests. This
// state includes the sub-surface position relative to the parent
// surface (wl_subsurface.set_position), and the stacking order of
// the parent and its sub-surfaces (wl_subsurface.place_above and
// .place_below). This state is applied when the parent surface's
// wl_surface state is applied, regardless of the sub-surface's mode.
// As the exception, set_sync and set_desync are effective immediately.
// 
// The main surface can be thought to be always in desynchronized mode,
// since it does not have a parent in the sub-surfaces sense.
// 
// Even if a sub-surface is in desynchronized mode, it will behave as
// in synchronized mode, if its parent surface behaves as in
// synchronized mode. This rule is applied recursively throughout the
// tree of surfaces. This means, that one can set a sub-surface into
// synchronized mode, and then assume that all its child and grand-child
// sub-surfaces are synchronized, too, without explicitly setting them.
// 
// Destroying a sub-surface takes effect immediately. If you need to
// synchronize the removal of a sub-surface to the parent surface update,
// unmap the sub-surface first by attaching a NULL wl_buffer, update parent,
// and then destroy the sub-surface.
// 
// If the parent wl_surface object is destroyed, the sub-surface is
// unmapped.
Wl_Subsurface :: Object_Id

Wl_Subsurface_Error_Enum :: enum u32 {
	// wl_surface is not a sibling or the parent
	Bad_Surface = 0,
}
WL_SUBSURFACE_DESTROY_OPCODE: Opcode : 0
// remove sub-surface interface
//
// The sub-surface interface is removed from the wl_surface object
// that was turned into a sub-surface with a
// wl_subcompositor.get_subsurface request. The wl_surface's association
// to the parent is deleted. The wl_surface is unmapped immediately.
wl_subsurface_destroy :: proc(conn_: ^Connection, target_: Wl_Subsurface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SUBSURFACE_DESTROY_OPCODE, msg_size_) or_return
	connection_free_id(conn_, target_)
	log.debugf("-> " + "wl_subsurface" + "@{}." + "destroy" + ":", target_)
	return
}

WL_SUBSURFACE_SET_POSITION_OPCODE: Opcode : 1
// reposition the sub-surface
//
// This schedules a sub-surface position change.
// The sub-surface will be moved so that its origin (top left
// corner pixel) will be at the location x, y of the parent surface
// coordinate system. The coordinates are not restricted to the parent
// surface area. Negative values are allowed.
// 
// The scheduled coordinates will take effect whenever the state of the
// parent surface is applied. When this happens depends on whether the
// parent surface is in synchronized mode or not. See
// wl_subsurface.set_sync and wl_subsurface.set_desync for details.
// 
// If more than one set_position request is invoked by the client before
// the commit of the parent surface, the position of a new request always
// replaces the scheduled position from any previous request.
// 
// The initial position is 0, 0.
// - x: x coordinate in the parent surface
// - y: y coordinate in the parent surface
wl_subsurface_set_position :: proc(conn_: ^Connection, target_: Wl_Subsurface, x: i32, y: i32, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 8
	message_write_header(writer_, target_, WL_SUBSURFACE_SET_POSITION_OPCODE, msg_size_) or_return
	message_write(writer_, x) or_return
	message_write(writer_, y) or_return
	log.debugf("-> " + "wl_subsurface" + "@{}." + "set_position" + ":" + " " + "x" + "={}" + " " + "y" + "={}", target_, x, y)
	return
}

WL_SUBSURFACE_PLACE_ABOVE_OPCODE: Opcode : 2
// restack the sub-surface
//
// This sub-surface is taken from the stack, and put back just
// above the reference surface, changing the z-order of the sub-surfaces.
// The reference surface must be one of the sibling surfaces, or the
// parent surface. Using any other surface, including this sub-surface,
// will cause a protocol error.
// 
// The z-order is double-buffered. Requests are handled in order and
// applied immediately to a pending state. The final pending state is
// copied to the active state the next time the state of the parent
// surface is applied. When this happens depends on whether the parent
// surface is in synchronized mode or not. See wl_subsurface.set_sync and
// wl_subsurface.set_desync for details.
// 
// A new sub-surface is initially added as the top-most in the stack
// of its siblings and parent.
// - sibling: the reference surface
wl_subsurface_place_above :: proc(conn_: ^Connection, target_: Wl_Subsurface, sibling: Wl_Surface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SUBSURFACE_PLACE_ABOVE_OPCODE, msg_size_) or_return
	message_write(writer_, sibling) or_return
	log.debugf("-> " + "wl_subsurface" + "@{}." + "place_above" + ":" + " " + "sibling" + "={}", target_, sibling)
	return
}

WL_SUBSURFACE_PLACE_BELOW_OPCODE: Opcode : 3
// restack the sub-surface
//
// The sub-surface is placed just below the reference surface.
// See wl_subsurface.place_above.
// - sibling: the reference surface
wl_subsurface_place_below :: proc(conn_: ^Connection, target_: Wl_Subsurface, sibling: Wl_Surface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 4
	message_write_header(writer_, target_, WL_SUBSURFACE_PLACE_BELOW_OPCODE, msg_size_) or_return
	message_write(writer_, sibling) or_return
	log.debugf("-> " + "wl_subsurface" + "@{}." + "place_below" + ":" + " " + "sibling" + "={}", target_, sibling)
	return
}

WL_SUBSURFACE_SET_SYNC_OPCODE: Opcode : 4
// set sub-surface to synchronized mode
//
// Change the commit behaviour of the sub-surface to synchronized
// mode, also described as the parent dependent mode.
// 
// In synchronized mode, wl_surface.commit on a sub-surface will
// accumulate the committed state in a cache, but the state will
// not be applied and hence will not change the compositor output.
// The cached state is applied to the sub-surface immediately after
// the parent surface's state is applied. This ensures atomic
// updates of the parent and all its synchronized sub-surfaces.
// Applying the cached state will invalidate the cache, so further
// parent surface commits do not (re-)apply old state.
// 
// See wl_subsurface for the recursive effect of this mode.
wl_subsurface_set_sync :: proc(conn_: ^Connection, target_: Wl_Subsurface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SUBSURFACE_SET_SYNC_OPCODE, msg_size_) or_return
	log.debugf("-> " + "wl_subsurface" + "@{}." + "set_sync" + ":", target_)
	return
}

WL_SUBSURFACE_SET_DESYNC_OPCODE: Opcode : 5
// set sub-surface to desynchronized mode
//
// Change the commit behaviour of the sub-surface to desynchronized
// mode, also described as independent or freely running mode.
// 
// In desynchronized mode, wl_surface.commit on a sub-surface will
// apply the pending state directly, without caching, as happens
// normally with a wl_surface. Calling wl_surface.commit on the
// parent surface has no effect on the sub-surface's wl_surface
// state. This mode allows a sub-surface to be updated on its own.
// 
// If cached state exists when wl_surface.commit is called in
// desynchronized mode, the pending state is added to the cached
// state, and applied as a whole. This invalidates the cache.
// 
// Note: even if a sub-surface is set to desynchronized, a parent
// sub-surface may override it to behave as synchronized. For details,
// see wl_subsurface.
// 
// If a surface's parent surface behaves as desynchronized, then
// the cached state is applied on set_desync.
wl_subsurface_set_desync :: proc(conn_: ^Connection, target_: Wl_Subsurface, ) -> (err_: Conn_Error) {
	writer_ := connection_writer(conn_)
	msg_size_ :u16 = message_header_size + 0
	message_write_header(writer_, target_, WL_SUBSURFACE_SET_DESYNC_OPCODE, msg_size_) or_return
	log.debugf("-> " + "wl_subsurface" + "@{}." + "set_desync" + ":", target_)
	return
}


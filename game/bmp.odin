package game

import "base:runtime"

@(private = "file")
BMP_Header :: struct #packed {
	id: [2]u8,
	size: u32le,
	_reserved1: u16le,
	_reserved2: u16le,
	bitmap_offset: u32le,
}
#assert(size_of(BMP_Header) == 14)

@(private = "file")
DIB_Bitmap_Info_Header :: struct #packed {
	// Should be >= 40
	header_size: u32le,
	bitmap_width: i32le,
	// Positive: bottom->top
	// Negative: top->bottom
	bitmap_height: i32le,
	color_planes: u16le,
	bits_per_pixel: u16le,
	compression: Compression_Method,
	// 0 for RGB
	image_size: u32le,
	horiz_resolution: u32le,
	vert_resolution: u32le,
	colors: u32le,
	important_colors: u32le,
	// v4
	// RGBA
	masks: [4]u32le,
	cs_type: u32le,
	endpoints: [3][3]u32le,
	gamma: [3][2]u16le,
	// v5
	intent: u32le,
	profile_data: u32le,
	profile_size: u32le,
	_reserved: u32le,
}

@(private = "file")
Compression_Method :: enum u32le {
	Rgb             = 0,
	Rle8            = 1,
	Rle4            = 2,
	Bitfields       = 3,
	Jpeg            = 4,
	Png             = 5,
	Alpha_Bitfields = 6,
	Cmyk            = 11,
	Cmyk_Rle8       = 12,
	Cmyk_Rle4       = 13,
}

@(private = "file")
BMP_Format :: enum {
	Rgba8le,
	Argb8le,
	// TODO: Separate formats for non-alpha channel? Just assume alpha is 255 in
	// those cases?
}

@(private = "file")
BMP_Pixel_Rgba8le :: struct #packed {
	a, b, g, r: u8,
}
@(private = "file")
BMP_RGBA8LE_MASK :: [4]u32le{0xFF000000, 0x00FF0000, 0x0000FF00, 0x000000FF}

@(private = "file")
BMP_Pixel_Argb8le :: struct #packed {
	b, g, r, a: u8,
}
@(private = "file")
BMP_ARGB8LE_MASK :: [4]u32le{0x00FF0000, 0x0000FF00, 0x000000FF, 0xFF000000}

load_bmp :: proc(
	contents: []byte,
	allocator: runtime.Allocator = context.allocator,
) -> (
	image: Image,
	ok: bool,
) {
	if len(contents) < size_of(BMP_Header) {
		ok = false
		return
	}

	// TODO: Replace asserts with error returns + logs
	bmp_header := (^BMP_Header)(&contents[0])
	assert(bmp_header.id == "BM")
	assert(bmp_header.bitmap_offset <= bmp_header.size)

	info_header := (^DIB_Bitmap_Info_Header)(&contents[size_of(bmp_header^)])
	assert(info_header.header_size >= size_of(info_header^))
	assert(info_header.color_planes == 1)
	assert(info_header.bits_per_pixel == 32)
	assert(info_header.colors == 0)

	// Round up to nearest 32-bit chunk
	stride_bytes :=
		((u32(info_header.bits_per_pixel) * u32(info_header.bitmap_width) +
				31) &
			~u32(31)) >>
		3
	assert(
		u32(info_header.image_size) ==
		stride_bytes * u32(abs(info_header.bitmap_height)),
	)

	format: BMP_Format
	// TODO: Support more dynamic formats
	#partial switch info_header.compression {
	case .Bitfields:
		if info_header.masks.rgb == BMP_RGBA8LE_MASK.rgb {
			format = .Rgba8le
		} else if info_header.masks.rgb == BMP_ARGB8LE_MASK.rgb {
			format = .Argb8le
		} else {
			panic("unsupported bitfields format")
		}
	// case .Alpha_Bitfields:
	// 	assert(info_header.masks == BMP_RGBA8LE_MASK)
	case:
		panic("unsupported BMP format")
	}

	assert(info_header.bitmap_width >= 0)
	// TODO: support flipped order
	assert(info_header.bitmap_height >= 0)
	image.width = u32(info_header.bitmap_width)
	image.height = u32(info_header.bitmap_height)
	image.stride = image.width * size_of(Pixel)

	src_pixels := contents[bmp_header.bitmap_offset:]
	if pixel_buf, err := make([]Pixel, image.height * image.width);
	   err == nil {
		image.pixels = raw_data(pixel_buf)
	} else {
		panic("failed to allocate image pixels")
	}
	for y in 0 ..< int(image.height) {
		for x in 0 ..< int(image.width) {
			dst_pixel: Pixel
			// Index in bytes since that's how the format is structured
			src_pixel_ptr := &src_pixels[y * int(stride_bytes) + x * 4]
			switch format {
			case .Rgba8le:
				bmp_px := (^BMP_Pixel_Rgba8le)(src_pixel_ptr)
				dst_pixel = Pixel {
					r = bmp_px.r,
					g = bmp_px.g,
					b = bmp_px.b,
					a = bmp_px.a,
				}
			case .Argb8le:
				bmp_px := (^BMP_Pixel_Argb8le)(src_pixel_ptr)
				dst_pixel = Pixel {
					r = bmp_px.r,
					g = bmp_px.g,
					b = bmp_px.b,
					a = bmp_px.a,
				}
			}
			frame_buffer_set(image, x, y, dst_pixel)
		}
	}

	ok = true
	return
}

package scanner

import "core:encoding/xml"
import "core:log"
import "core:strconv"
import "core:strings"

Protocol :: struct {
	filename:   string,
	name:       string,
	copyright:  string,
	interfaces: [dynamic]Interface,

	// Keep reference to the XML document so it can be freed later
	xml_doc:    ^xml.Document `fmt:"-"`,
}

// TODO: Parse descriptions
Descrition :: struct {
	summary: string,
	body:    string,
}

Version :: u32

Interface :: struct {
	name:        string,
	name_upper:  string,
	name_snake:  string,
	name_ada:    string,
	version:     Version,
	description: Descrition,
	enums:       [dynamic]Enum,
	requests:    [dynamic]Message,
	events:      [dynamic]Message,
}

Enum :: struct {
	name:        string,
	name_ada:    string,
	description: Descrition,
	since:       Version,
	bitfield:    bool,
	entries:     [dynamic]Enum_Entry,
}

Enum_Entry :: struct {
	name:        string,
	name_ada:    string,
	value:       u32,
	description: Descrition,
}

Message_Type :: enum {
	/* doc */
	Basic = 0, /*doc*/
	/*doc*/
	// TODO: Do something with this info
	Destructor, // TODO: Do something with this info
	// TODO: Do something with this info
}

// request or event
Message :: struct {
	name:        string,
	name_upper:  string,
	name_snake:  string,
	name_ada:    string,
	type:        Message_Type,
	since:       Version,
	description: Descrition,
	args:        [dynamic]Argument,
}

Argument :: struct {
	name:        string,
	type:        Arg_Type,
	// TODO: Parse/handle allow-null
	description: Descrition,
}

Primitive_Type :: enum {
	Int,
	Uint,
	Fixed,
	String,
	Array,
	Fd,
}

Object_Type :: struct {
	interface:     string,
	interface_ada: string,
	is_new:        bool,
}

object_type_make :: proc(interface: string, is_new: bool = false) -> Object_Type {
	return {interface = interface, interface_ada = strings.to_ada_case(interface), is_new = is_new}
}

Enum_Type :: struct {
	name: string,
}

Arg_Type :: union {
	Primitive_Type,
	Object_Type,
	Enum_Type,
}

Parse_Error :: enum {
	None = 0,
	Unexpected_Tag,
	Unexpected_Attribute,
	Missing_Tag,
	Missing_Attribute,
	Invalid_Version,
	Invalid_Message_Type,
	Invalid_Enum_Value,
	Invalid_Enum_Type,
	Invalid_Bitfield_Type,
	Invalid_Arg_Type,
}

Load_Error :: union #shared_nil {
	xml.Error,
	Parse_Error,
}

protocol_destroy :: proc(proto: Protocol) {
	for iface in proto.interfaces {
		for enum_ in iface.enums {
			delete(enum_.entries)
		}
		delete(iface.enums)
		for request in iface.requests {
			delete(request.args)
		}
		delete(iface.requests)
		for event in iface.events {
			delete(event.args)
		}
		delete(iface.events)
	}
	delete(proto.interfaces)

	xml.destroy(proto.xml_doc)
}

protocol_load :: proc(filename: string) -> (Protocol, Load_Error) {
	doc, load_err := xml.load_from_file(filename)
	if load_err != .None {
		return {}, load_err
	}

	proto, parse_err := parse_protocol(doc)
	if parse_err != .None {
		protocol_destroy(proto)
		return {}, parse_err
	}
	proto.filename = filename
	return proto, nil
}

parse_protocol :: proc(doc: ^xml.Document) -> (proto: Protocol, err: Parse_Error) {
	proto.xml_doc = doc
	if doc.elements[0].ident != "protocol" {
		err = .Unexpected_Tag
		return
	}

	if name, found := xml.find_attribute_val_by_key(doc, 0, "name"); found {
		proto.name = name
	} else {
		err = .Missing_Attribute
		return
	}

	get_copyright: if copyright_el, found := xml.find_child_by_ident(doc, 0, "copyright"); found {
		if len(doc.elements[copyright_el].value) == 0 {
			break get_copyright
		}
		if body, is_string := doc.elements[copyright_el].value[0].(string); is_string {
			proto.copyright = body
		}
	}

	for nth := 0;; nth += 1 {
		if id, found := xml.find_child_by_ident(doc, 0, "interface", nth); found {
			new_iface: Interface
			new_iface, err = parse_interface(doc, id)
			if err != nil {
				return
			}
			append(&proto.interfaces, new_iface)
		} else {
			break
		}
	}
	return
}

parse_description_of :: proc(
	doc: ^xml.Document,
	elem: xml.Element_ID,
) -> (
	desc: Descrition,
	err: Parse_Error,
) {
	if desc_el, found := xml.find_child_by_ident(doc, elem, "description"); found {
		desc.summary, _ = xml.find_attribute_val_by_key(doc, desc_el, "summary")
		if len(doc.elements[desc_el].value) == 0 do return
		desc.body, _ = doc.elements[desc_el].value[0].(string)
	} else {
		// fallback to summary attribute on the element
		desc.summary, _ = xml.find_attribute_val_by_key(doc, elem, "summary")
	}
	return
}

parse_interface :: proc(
	doc: ^xml.Document,
	elem: xml.Element_ID,
) -> (
	iface: Interface,
	err: Parse_Error,
) {
	if name, found := xml.find_attribute_val_by_key(doc, elem, "name"); found {
		iface.name = name
	} else {
		err = .Missing_Attribute
		return
	}
	iface.name_upper = strings.to_upper_snake_case(iface.name)
	// Should already be snake case, but may as well ensure it
	iface.name_snake = strings.to_snake_case(iface.name)
	iface.name_ada = strings.to_ada_case(iface.name)

	iface.description = parse_description_of(doc, elem) or_return

	if version_str, found := xml.find_attribute_val_by_key(doc, elem, "version"); found {
		version, ok := strconv.parse_u64(version_str, 10)
		// TODO: Is there a constant for maximum int sizes?
		if !ok || version >= (1 << 32) {
			err = .Invalid_Version
			return
		}
		iface.version = u32(version)
	} else {
		err = .Missing_Attribute
		return
	}

	for nth := 0;; nth += 1 {
		if enum_elem, found := xml.find_child_by_ident(doc, elem, "enum", nth); found {
			new: Enum
			new, err = parse_enum(doc, enum_elem)
			if err != nil {
				return
			}
			append(&iface.enums, new)
		} else {
			break
		}
	}


	for nth := 0;; nth += 1 {
		if request_elem, found := xml.find_child_by_ident(doc, elem, "request", nth); found {
			new: Message
			new, err = parse_message(doc, request_elem)
			if err != nil {
				return
			}
			append(&iface.requests, new)
		} else {break}
	}

	for nth := 0;; nth += 1 {
		if event_elem, found := xml.find_child_by_ident(doc, elem, "event", nth); found {
			new: Message
			new, err = parse_message(doc, event_elem)
			if err != nil {
				return
			}
			append(&iface.events, new)
		} else {break}
	}

	return
}

parse_message :: proc(
	doc: ^xml.Document,
	elem: xml.Element_ID,
) -> (
	message: Message,
	err: Parse_Error,
) {
	if name, found := xml.find_attribute_val_by_key(doc, elem, "name"); found {
		message.name = name
	} else {
		err = .Missing_Attribute
		return
	}
	message.name_upper = strings.to_upper_snake_case(message.name)
	message.name_snake = strings.to_snake_case(message.name)
	message.name_ada = strings.to_ada_case(message.name)

	message.description = parse_description_of(doc, elem) or_return

	if version_str, found := xml.find_attribute_val_by_key(doc, elem, "since"); found {
		version, ok := strconv.parse_u64(version_str, 10)
		// TODO: Is there a constant for maximum int sizes?
		if !ok || version >= (1 << 32) {
			err = .Invalid_Version
			return
		}
		message.since = u32(version)
	}

	if type_str, found := xml.find_attribute_val_by_key(doc, elem, "type"); found {
		switch type_str {
		case "destructor":
			message.type = .Destructor
		case:
			err = .Invalid_Message_Type
			return
		}
	}

	for nth := 0;; nth += 1 {
		if arg_elem, found := xml.find_child_by_ident(doc, elem, "arg", nth); found {
			new := parse_arg(doc, arg_elem) or_return
			if obj_type, ok := new.type.(Object_Type);
			   ok && obj_type.is_new && obj_type.interface == "" {
				// Have to inject interface and version args in this specific case
				// (this is what wayland-scanner does)
				// TODO: Should this only happen for requests?
				append(&message.args, Argument{name = "interface", type = Primitive_Type.String})
				append(&message.args, Argument{name = "version", type = Primitive_Type.Uint})
			}
			append(&message.args, new)
		} else {
			break
		}
	}
	return
}

parse_arg :: proc(doc: ^xml.Document, elem: xml.Element_ID) -> (arg: Argument, err: Parse_Error) {
	if name, found := xml.find_attribute_val_by_key(doc, elem, "name"); found {
		arg.name = name
	} else {
		err = .Missing_Attribute
		return
	}

	arg.description = parse_description_of(doc, elem) or_return

	if type_str, found := xml.find_attribute_val_by_key(doc, elem, "type"); found {
		switch type_str {
		case "int":
			arg.type = .Int
		case "uint":
			arg.type = .Uint
		case "fixed":
			arg.type = .Fixed
		case "string":
			arg.type = .String
		case "fd":
			arg.type = .Fd
		case "array":
			arg.type = .Array
		case "object":
			interface, _ := xml.find_attribute_val_by_key(doc, elem, "interface")
			arg.type = object_type_make(interface)
		case "new_id":
			interface, _ := xml.find_attribute_val_by_key(doc, elem, "interface")
			arg.type = object_type_make(interface, is_new = true)
		case:
			err = .Invalid_Arg_Type
			return
		}
	} else {
		err = .Missing_Attribute
		return
	}

	if enum_name, found := xml.find_attribute_val_by_key(doc, elem, "enum"); found {
		allowed_type := false
		// TODO: Better way to check this?
		#partial switch arg_type in arg.type {
		case Primitive_Type:
			#partial switch arg_type {
			case .Int, .Uint:
				allowed_type = true
			}
		}
		if !allowed_type {
			log.errorf("invalid base type for argument: {}", arg.name)
			err = .Invalid_Enum_Type
			return
		}
		arg.type = Enum_Type {
			name = enum_name,
		}
	}
	return
}

parse_enum :: proc(doc: ^xml.Document, elem: xml.Element_ID) -> (enum_: Enum, err: Parse_Error) {
	if name, found := xml.find_attribute_val_by_key(doc, elem, "name"); found {
		enum_.name = name
	} else {
		err = .Missing_Attribute
		return
	}
	enum_.name_ada = strings.to_ada_case(enum_.name)

	enum_.description = parse_description_of(doc, elem) or_return

	if version_str, found := xml.find_attribute_val_by_key(doc, elem, "since"); found {
		version, ok := strconv.parse_u64(version_str, 10)
		// TODO: Is there a constant for maximum int sizes?
		if !ok || version >= (1 << 32) {
			err = .Invalid_Version
			return
		}
		enum_.since = u32(version)
	}

	if bitfield_str, found := xml.find_attribute_val_by_key(doc, elem, "bitfield"); found {
		switch bitfield_str {
		case "true":
			enum_.bitfield = true
		case "false":
			enum_.bitfield = false
		case:
			err = .Invalid_Bitfield_Type
			return
		}
	}

	for nth := 0;; nth += 1 {
		if entry_elem, found := xml.find_child_by_ident(doc, elem, "entry", nth); found {
			new: Enum_Entry
			new, err = parse_enum_entry(doc, entry_elem)
			if err != nil {
				return
			}
			append(&enum_.entries, new)
		} else {break}
	}
	return
}

parse_enum_entry :: proc(
	doc: ^xml.Document,
	elem: xml.Element_ID,
) -> (
	entry: Enum_Entry,
	err: Parse_Error,
) {
	if name, found := xml.find_attribute_val_by_key(doc, elem, "name"); found {
		entry.name = name
	} else {
		err = .Missing_Attribute
		return
	}
	entry.name_ada = strings.to_ada_case(entry.name)

	entry.description = parse_description_of(doc, elem) or_return

	if value_str, found := xml.find_attribute_val_by_key(doc, elem, "value"); found {
		value, ok := strconv.parse_u64(value_str)
		// TODO: Is there a constant for maximum int sizes?
		if !ok || value >= (1 << 32) {
			err = .Invalid_Enum_Value
			return
		}
		entry.value = u32(value)
	} else {
		err = .Missing_Tag
		return
	}
	return
}

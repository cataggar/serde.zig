//! XML serialization and deserialization.
//!
//! Serialize structs to XML with `toSlice` / `toWriter`, and deserialize
//! with `fromSlice` / `fromReader`. Supports XML attributes, custom root
//! element names, pretty-printing, and entity escaping.
//!
//! Slice fields are serialized as repeated child elements sharing the
//! field's name (no `<item>` wrapper). The deserializer collects
//! consecutive sibling elements whose name matches the field. This makes
//! shapes like `<Blobs><Blob>…</Blob><Blob>…</Blob></Blobs>` round-trip
//! when modelled as `struct { Blobs: struct { Blob: []const Blob } }`.

const std = @import("std");
const compat = @import("compat");
const serializer_mod = @import("serializer.zig");
const deserializer_mod = @import("deserializer.zig");
const scanner_mod = @import("scanner.zig");
const core_serialize = @import("../../core/serialize.zig");
const core_deserialize = @import("../../core/deserialize.zig");
const kind_mod = @import("../../core/kind.zig");
const xml_writer = @import("writer.zig");
const opt = @import("../../core/options.zig");

pub const Serializer = serializer_mod.Serializer;
pub const Deserializer = deserializer_mod.Deserializer;
pub const Options = serializer_mod.Options;
pub const Scanner = scanner_mod.Scanner;

/// Serialize a value to an XML byte slice. Caller owns the returned memory.
pub fn toSlice(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return toSliceWith(allocator, value, .{});
}

/// Serialize with explicit options.
pub fn toSliceWith(allocator: std.mem.Allocator, value: anytype, opts: Options) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try xmlSerialize(@TypeOf(value), value, &aw.writer, opts, {});
    return aw.toOwnedSlice();
}

/// Serialize a value to a writer in XML format.
pub fn toWriter(writer: *compat.Io.Writer, value: anytype) !void {
    return toWriterWith(writer, value, .{});
}

/// Serialize with explicit options to a writer.
pub fn toWriterWith(writer: *compat.Io.Writer, value: anytype, opts: Options) !void {
    try xmlSerialize(@TypeOf(value), value, writer, opts, {});
}

/// Serialize a value to a null-terminated XML byte slice. Caller owns the returned memory.
pub fn toSliceAlloc(allocator: std.mem.Allocator, value: anytype) ![:0]u8 {
    const bytes = try toSlice(allocator, value);
    defer allocator.free(bytes);
    const result = try allocator.allocSentinel(u8, bytes.len, 0);
    @memcpy(result, bytes);
    return result;
}

/// Serialize with an external schema.
pub fn toSliceSchema(allocator: std.mem.Allocator, value: anytype, comptime schema: anytype) ![]u8 {
    return toSliceWithSchema(allocator, value, .{}, schema);
}

/// Serialize with explicit options and an external schema.
pub fn toSliceWithSchema(allocator: std.mem.Allocator, value: anytype, opts: Options, comptime schema: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(allocator);
    try xmlSerialize(@TypeOf(value), value, &aw.writer, opts, schema);
    return aw.toOwnedSlice();
}

/// Serialize to a writer with an external schema.
pub fn toWriterSchema(writer: *compat.Io.Writer, value: anytype, comptime schema: anytype) !void {
    try xmlSerialize(@TypeOf(value), value, writer, .{}, schema);
}

/// Serialize with explicit options to a writer with an external schema.
pub fn toWriterWithSchema(writer: *compat.Io.Writer, value: anytype, opts: Options, comptime schema: anytype) !void {
    try xmlSerialize(@TypeOf(value), value, writer, opts, schema);
}

/// Deserialize a value of type T from an XML byte slice.
pub fn fromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return xmlDeserialize(T, allocator, input, false, {});
}

/// Deserialize with zero-copy string borrowing.
pub fn fromSliceBorrowed(comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return xmlDeserialize(T, allocator, input, true, {});
}

/// Deserialize from a reader.
pub fn fromReader(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSlice(T, allocator, buf);
}

/// Deserialize from a file path.
pub fn fromFilePath(comptime T: type, allocator: std.mem.Allocator, path: []const u8) !T {
    const content = try compat.readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(content);
    return fromSlice(T, allocator, content);
}

/// Deserialize with an external schema.
pub fn fromSliceSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    return xmlDeserialize(T, allocator, input, false, schema);
}

/// Deserialize with zero-copy borrowing and an external schema.
pub fn fromSliceBorrowedSchema(comptime T: type, allocator: std.mem.Allocator, input: []const u8, comptime schema: anytype) !T {
    return xmlDeserialize(T, allocator, input, true, schema);
}

/// Deserialize from a reader with an external schema.
pub fn fromReaderSchema(comptime T: type, allocator: std.mem.Allocator, reader: *compat.Io.Reader, comptime schema: anytype) !T {
    const buf = try readAll(allocator, reader);
    defer allocator.free(buf);
    return fromSliceSchema(T, allocator, buf, schema);
}

// XML-specific serialization: wraps values in root element, handles attributes.
fn xmlSerialize(
    comptime T: type,
    value: T,
    writer: *compat.Io.Writer,
    opts: Options,
    comptime schema: anytype,
) !void {
    if (opts.xml_declaration) {
        writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>") catch return error.WriteFailed;
        if (opts.pretty) writer.writeByte('\n') catch return error.WriteFailed;
    }

    const k = comptime kind_mod.typeKind(T);

    if (k == .@"struct") {
        const root_name = comptime resolveRootName(T, schema);
        try writeStructElement(T, value, writer, opts, root_name, schema);
    } else {
        // Non-struct: wrap in a <value> root element.
        writer.writeAll("<value>") catch return error.WriteFailed;
        var ser = serializer_mod.Serializer.init(writer, opts);
        if (@TypeOf(schema) != void) {
            try core_serialize.serializeSchema(T, value, &ser, schema, .{});
        } else {
            try core_serialize.serialize(T, value, &ser, .{});
        }
        writer.writeAll("</value>") catch return error.WriteFailed;
    }
}

fn writeStructElement(
    comptime T: type,
    value: T,
    writer: *compat.Io.Writer,
    opts: Options,
    comptime root_name: []const u8,
    comptime schema: anytype,
) !void {
    const info = @typeInfo(T).@"struct";

    // Opening tag with attributes.
    writer.writeByte('<') catch return error.WriteFailed;
    writer.writeAll(root_name) catch return error.WriteFailed;

    // Attributes: fields marked with xml_attribute.
    inline for (info.fields) |field| {
        if (comptime opt.shouldSkipFieldSchema(T, field.name, .serialize, schema)) continue;
        if (comptime isXmlAttribute(T, field.name, schema)) {
            writer.writeByte(' ') catch return error.WriteFailed;
            const wire_name = comptime opt.wireFieldNameForDir(T, field.name, schema, .serialize);
            writer.writeAll(wire_name) catch return error.WriteFailed;
            writer.writeByte('=') catch return error.WriteFailed;
            // Write attribute value.
            var buf: [64]u8 = undefined;
            const val_str = fieldToString(field.type, @field(value, field.name), &buf);
            xml_writer.writeXmlAttrEscaped(writer, val_str) catch return error.WriteFailed;
        }
    }

    writer.writeByte('>') catch return error.WriteFailed;

    // Text content: a field marked xml_text is written as the element's text.
    inline for (info.fields) |field| {
        if (comptime isXmlText(T, field.name, schema)) {
            const tv = @field(value, field.name);
            const TInfo = @typeInfo(field.type);
            if (TInfo == .optional) {
                if (tv) |inner| {
                    var tbuf: [64]u8 = undefined;
                    const s = fieldToString(TInfo.optional.child, inner, &tbuf);
                    xml_writer.writeXmlEscaped(writer, s) catch return error.WriteFailed;
                }
            } else {
                var tbuf: [64]u8 = undefined;
                const s = fieldToString(field.type, tv, &tbuf);
                xml_writer.writeXmlEscaped(writer, s) catch return error.WriteFailed;
            }
        }
    }

    // Children: non-attribute fields.
    var ser = serializer_mod.Serializer.init(writer, opts);
    if (opts.pretty) ser.depth = 1;
    var ss = try ser.beginStruct();

    inline for (info.fields) |field| {
        if (comptime opt.shouldSkipFieldSchema(T, field.name, .serialize, schema)) continue;
        if (comptime isXmlAttribute(T, field.name, schema)) continue;
        if (comptime isXmlText(T, field.name, schema)) continue;

        if (comptime opt.isFlattenedFieldSchema(T, field.name, schema)) {
            if (@typeInfo(field.type) != .@"struct")
                @compileError("Flatten requires a struct type, got " ++ @typeName(field.type));
            const nested = @field(value, field.name);
            const nested_info = @typeInfo(field.type).@"struct";
            inline for (nested_info.fields) |sf| {
                const nested_wire = comptime opt.wireFieldNameForDir(field.type, sf.name, {}, .serialize);
                try ss.serializeField(nested_wire, @field(nested, sf.name));
            }
            continue;
        }

        const wire_name = comptime opt.wireFieldNameForDir(T, field.name, schema, .serialize);
        const field_value = @field(value, field.name);

        const skip_null = comptime opt.isSkipIfNullSchema(T, field.name, schema) and @typeInfo(field.type) == .optional;
        const skip_empty = comptime opt.isSkipIfEmptySchema(T, field.name, schema) and @typeInfo(field.type) == .pointer;

        const should_skip = (skip_null and field_value == null) or
            (skip_empty and field_value.len == 0);

        if (!should_skip) {
            if (comptime opt.hasFieldWithSchema(T, field.name, schema)) {
                const WithMod = comptime opt.getFieldWithSchema(T, field.name, schema);
                try ss.serializeField(wire_name, WithMod.serialize(field_value));
            } else {
                try ss.serializeField(wire_name, field_value);
            }
        }
    }

    try ss.end();

    // Closing tag.
    if (opts.pretty) {
        writer.writeByte('\n') catch return error.WriteFailed;
    }
    writer.writeAll("</") catch return error.WriteFailed;
    writer.writeAll(root_name) catch return error.WriteFailed;
    writer.writeByte('>') catch return error.WriteFailed;
}

fn fieldToString(comptime T: type, value: T, buf: *[64]u8) []const u8 {
    const tinfo = @typeInfo(T);
    if (tinfo == .optional) {
        if (value) |inner| return fieldToString(tinfo.optional.child, inner, buf);
        return "";
    }
    const k = comptime kind_mod.typeKind(T);
    return switch (k) {
        .bool => if (value) "true" else "false",
        .int => std.fmt.bufPrint(buf, "{d}", .{value}) catch "0",
        .float => std.fmt.bufPrint(buf, "{d}", .{value}) catch "0",
        .string => value,
        .@"enum" => @tagName(value),
        else => "",
    };
}

fn resolveRootName(comptime T: type, comptime schema: anytype) []const u8 {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "xml_root"))
            return schema.xml_root;
    }
    if (opt.hasSerdeOptions(T)) {
        const serde_opts = T.serde;
        if (@hasField(@TypeOf(serde_opts), "xml_root") or @hasDecl(@TypeOf(serde_opts), "xml_root"))
            return serde_opts.xml_root;
    }
    // Derive from type name: take the last component after the dot.
    const name = @typeName(T);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse 0;
    const candidate = if (dot > 0) name[dot + 1 ..] else name;
    // Validate as XML element name (letters, digits, underscore, hyphen; must start with letter/underscore).
    if (candidate.len == 0) return "root";
    if (!isXmlNameStart(candidate[0])) return "root";
    for (candidate[1..]) |c| {
        if (!isXmlNameChar(c)) return "root";
    }
    return candidate;
}

fn isXmlNameStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_';
}

fn isXmlNameChar(c: u8) bool {
    return isXmlNameStart(c) or (c >= '0' and c <= '9') or c == '-' or c == '.';
}

fn isXmlText(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "xml_text")) {
            return std.mem.eql(u8, @tagName(schema.xml_text), field_name);
        }
    }
    if (!opt.hasSerdeOptions(T)) return false;
    const serde = T.serde;
    const SerdeTy = @TypeOf(serde);
    if (!@hasField(SerdeTy, "xml_text") and !@hasDecl(SerdeTy, "xml_text")) return false;
    return std.mem.eql(u8, @tagName(serde.xml_text), field_name);
}

fn isXmlAttribute(comptime T: type, comptime field_name: []const u8, comptime schema: anytype) bool {
    const S = @TypeOf(schema);
    if (S != void) {
        if (@hasField(S, "xml_attribute")) {
            const attrs = schema.xml_attribute;
            const attr_fields = @typeInfo(@TypeOf(attrs)).@"struct".fields;
            inline for (attr_fields) |f| {
                const val = @field(attrs, f.name);
                const tag_name = @tagName(val);
                if (std.mem.eql(u8, tag_name, field_name)) return true;
            }
            return false;
        }
    }
    if (!opt.hasSerdeOptions(T)) return false;
    const serde = T.serde;
    const SerdeTy = @TypeOf(serde);
    if (!@hasField(SerdeTy, "xml_attribute") and !@hasDecl(SerdeTy, "xml_attribute")) return false;
    const attrs = serde.xml_attribute;
    const attr_fields = @typeInfo(@TypeOf(attrs)).@"struct".fields;
    inline for (attr_fields) |f| {
        const val = @field(attrs, f.name);
        const tag_name = @tagName(val);
        if (std.mem.eql(u8, tag_name, field_name)) return true;
    }
    return false;
}

// XML-specific deserialization: handles root element, then delegates.
fn xmlDeserialize(
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    borrow: bool,
    comptime schema: anytype,
) !T {
    var scanner = scanner_mod.Scanner{ .input = input };

    const k = comptime kind_mod.typeKind(T);

    if (k == .@"struct") {
        // Expect root element.
        const tok = try scanner.next();
        switch (tok) {
            .element_open => {
                // Root element found, scanner is now past the attributes (or in in_tag state).
                // Deserialize the struct fields.
                var deser = deserializer_mod.Deserializer{
                    .scanner = scanner,
                    .borrow_strings = borrow,
                };
                if (@TypeOf(schema) != void) {
                    return core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
                } else {
                    return core_deserialize.deserialize(T, allocator, &deser, .{});
                }
            },
            .self_closing => {
                // Empty root: return struct with defaults.
                return initStructDefaults(T, schema);
            },
            else => return error.MalformedXml,
        }
    } else {
        // Non-struct: expect <value>content</value>.
        const tok = try scanner.next();
        if (tok != .element_open) return error.MalformedXml;
        var deser = deserializer_mod.Deserializer{
            .scanner = scanner,
            .borrow_strings = borrow,
        };
        if (@TypeOf(schema) != void) {
            return core_deserialize.deserializeSchema(T, allocator, &deser, schema, .{});
        } else {
            return core_deserialize.deserialize(T, allocator, &deser, .{});
        }
    }
}

fn initStructDefaults(comptime T: type, comptime schema: anytype) !T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.fields) |field| {
        if (comptime field.defaultValue()) |dv| {
            @field(result, field.name) = dv;
        } else if (comptime opt.hasSerdeDefaultSchema(T, field.name, schema)) {
            @field(result, field.name) = comptime opt.getSerdeDefaultSchema(T, field.name, schema);
        } else if (@typeInfo(field.type) == .optional) {
            @field(result, field.name) = null;
        } else {
            return error.MissingField;
        }
    }
    return result;
}

fn readAll(allocator: std.mem.Allocator, reader: *compat.Io.Reader) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    while (true) {
        const chunk = buf.addManyAsSlice(allocator, 4096) catch return error.OutOfMemory;
        const n = reader.read(chunk) catch return error.OutOfMemory;
        buf.shrinkRetainingCapacity(buf.items.len - chunk.len + n);
        if (n == 0) break;
    }
    return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

const testing = std.testing;

test "serialize simple struct" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSliceWith(testing.allocator, Point{ .x = 1, .y = 2 }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Point><x>1</x><y>2</y></Point>", bytes);
}

test "serialize with xml_root" {
    const User = struct {
        name: []const u8,
        pub const serde = .{ .xml_root = "user" };
    };
    const bytes = try toSliceWith(testing.allocator, User{ .name = "Alice" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<user><name>Alice</name></user>", bytes);
}

test "serialize with xml_attribute" {
    const User = struct {
        id: u64,
        name: []const u8,
        pub const serde = .{ .xml_attribute = .{.id}, .xml_root = "user" };
    };
    const bytes = try toSliceWith(testing.allocator, User{ .id = 42, .name = "Alice" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<user id=\"42\"><name>Alice</name></user>", bytes);
}

test "serialize with xml declaration" {
    const Point = struct { x: i32 };
    const bytes = try toSlice(testing.allocator, Point{ .x = 1 });
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
}

test "serialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const bytes = try toSliceWith(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Outer><name>test</name><inner><val>42</val></inner></Outer>", bytes);
}

test "serialize optional null" {
    const Opt = struct { val: ?i32 };
    const bytes = try toSliceWith(testing.allocator, Opt{ .val = null }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Opt><val/></Opt>", bytes);
}

test "serialize optional present" {
    const Opt = struct { val: ?i32 };
    const bytes = try toSliceWith(testing.allocator, Opt{ .val = 42 }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Opt><val>42</val></Opt>", bytes);
}

test "serialize slice" {
    const List = struct { items: []const i32 };
    const bytes = try toSliceWith(testing.allocator, List{ .items = &.{ 1, 2, 3 } }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<List><items>1</items><items>2</items><items>3</items></List>", bytes);
}

test "serialize string with entities" {
    const Msg = struct { text: []const u8 };
    const bytes = try toSliceWith(testing.allocator, Msg{ .text = "a<b&c" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Msg><text>a&lt;b&amp;c</text></Msg>", bytes);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const bytes = try toSliceWith(testing.allocator, Wrapper{ .color = .green }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Wrapper><color>green</color></Wrapper>", bytes);
}

test "serialize bool" {
    const Flags = struct { active: bool };
    const bytes = try toSliceWith(testing.allocator, Flags{ .active = true }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Flags><active>true</active></Flags>", bytes);
}

test "serialize void field" {
    const Cmd = struct { ping: void };
    const bytes = try toSliceWith(testing.allocator, Cmd{ .ping = {} }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Cmd><ping/></Cmd>", bytes);
}

test "deserialize simple struct" {
    const Point = struct { x: i32, y: i32 };
    const point = try fromSlice(Point, testing.allocator, "<Point><x>10</x><y>20</y></Point>");
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize with xml declaration" {
    const Point = struct { x: i32, y: i32 };
    const point = try fromSlice(Point, testing.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Point><x>10</x><y>20</y></Point>");
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize with attributes" {
    const User = struct { id: u64, name: []const u8 };
    const user = try fromSlice(User, testing.allocator, "<user id=\"42\"><name>Alice</name></user>");
    defer testing.allocator.free(user.name);
    try testing.expectEqual(@as(u64, 42), user.id);
    try testing.expectEqualStrings("Alice", user.name);
}

test "deserialize optional null" {
    const Opt = struct { a: i32, b: ?i32 };
    const val = try fromSlice(Opt, testing.allocator, "<Opt><a>5</a></Opt>");
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize optional present" {
    const Opt = struct { a: i32, b: ?i32 };
    const val = try fromSlice(Opt, testing.allocator, "<Opt><a>5</a><b>7</b></Opt>");
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, 7), val.b);
}

test "deserialize nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Outer, arena.allocator(), "<Outer><name>test</name><inner><val>42</val></inner></Outer>");
    try testing.expectEqualStrings("test", val.name);
    try testing.expectEqual(@as(i32, 42), val.inner.val);
}

test "deserialize enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const val = try fromSlice(Wrapper, testing.allocator, "<Wrapper><color>green</color></Wrapper>");
    try testing.expectEqual(Color.green, val.color);
}

test "deserialize string with entities" {
    const Msg = struct { text: []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Msg, arena.allocator(), "<Msg><text>a&amp;b&lt;c</text></Msg>");
    try testing.expectEqualStrings("a&b<c", val.text);
}

test "deserialize bool" {
    const Flags = struct { active: bool };
    const val = try fromSlice(Flags, testing.allocator, "<Flags><active>true</active></Flags>");
    try testing.expectEqual(true, val.active);
}

test "roundtrip simple struct" {
    const Point = struct { x: i32, y: i32 };
    const original = Point{ .x = 42, .y = -7 };
    const bytes = try toSliceWith(testing.allocator, original, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    const result = try fromSlice(Point, testing.allocator, bytes);
    try testing.expectEqualDeep(original, result);
}

test "roundtrip nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Outer{ .name = "test", .inner = .{ .val = 42 } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", result.name);
    try testing.expectEqual(@as(i32, 42), result.inner.val);
}

test "roundtrip with optional" {
    const Opt = struct { a: i32, b: ?i32 };
    const original = Opt{ .a = 5, .b = 7 };
    const bytes = try toSliceWith(testing.allocator, original, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    const result = try fromSlice(Opt, testing.allocator, bytes);
    try testing.expectEqualDeep(original, result);
}

test "roundtrip with enum" {
    const Color = enum { red, green, blue };
    const Wrapper = struct { color: Color };
    const original = Wrapper{ .color = .green };
    const bytes = try toSliceWith(testing.allocator, original, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    const result = try fromSlice(Wrapper, testing.allocator, bytes);
    try testing.expectEqualDeep(original, result);
}

test "roundtrip with string entities" {
    const Msg = struct { text: []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Msg{ .text = "a<b&c>d" };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(Msg, arena.allocator(), bytes);
    try testing.expectEqualStrings("a<b&c>d", result.text);
}

test "deserialize xml_text with optional attribute" {
    const BlobName = struct {
        encoded: ?bool = null,
        content: ?[]const u8 = null,
        pub const serde = .{
            .xml_root = "BlobName",
            .xml_attribute = .{.encoded},
            .xml_text = .content,
            .rename = .{ .encoded = "Encoded" },
        };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const val = try fromSlice(BlobName, a, "<BlobName Encoded=\"true\">my&amp;blob.txt</BlobName>");
    try testing.expectEqual(true, val.encoded.?);
    try testing.expectEqualStrings("my&blob.txt", val.content.?);
}

test "roundtrip xml_text" {
    const Named = struct {
        encoded: ?bool = null,
        content: ?[]const u8 = null,
        pub const serde = .{
            .xml_root = "Name",
            .xml_attribute = .{.encoded},
            .xml_text = .content,
            .rename = .{ .encoded = "Encoded" },
        };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = Named{ .encoded = true, .content = "hello.txt" };
    const bytes = try toSliceWith(a, original, .{ .xml_declaration = false });
    const result = try fromSlice(Named, a, bytes);
    try testing.expectEqual(true, result.encoded.?);
    try testing.expectEqualStrings("hello.txt", result.content.?);
}

test "roundtrip with xml_root and xml_attribute" {
    const User = struct {
        id: u64,
        name: []const u8,
        pub const serde = .{ .xml_attribute = .{.id}, .xml_root = "user" };
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = User{ .id = 42, .name = "Alice" };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(User, arena.allocator(), bytes);
    try testing.expectEqual(@as(u64, 42), result.id);
    try testing.expectEqualStrings("Alice", result.name);
}

test "serialize with rename" {
    const Config = struct {
        max_retries: u32,
        pub const serde = .{ .rename_all = opt.NamingConvention.camel_case };
    };
    const bytes = try toSliceWith(testing.allocator, Config{ .max_retries = 3 }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Config><maxRetries>3</maxRetries></Config>", bytes);
}

test "serialize with skip" {
    const Secret = struct {
        name: []const u8,
        token: []const u8,
        pub const serde = .{ .skip = .{ .token = opt.SkipMode.always } };
    };
    const bytes = try toSliceWith(testing.allocator, Secret{ .name = "test", .token = "secret" }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Secret><name>test</name></Secret>", bytes);
}

test "deserialize ignores unknown fields" {
    const Point = struct { x: i32 };
    const val = try fromSlice(Point, testing.allocator, "<Point><x>5</x><extra>99</extra></Point>");
    try testing.expectEqual(@as(i32, 5), val.x);
}

test "deserialize with defaults" {
    const Def = struct {
        a: i32,
        b: i32 = 99,
    };
    const val = try fromSlice(Def, testing.allocator, "<Def><a>1</a></Def>");
    try testing.expectEqual(@as(i32, 1), val.a);
    try testing.expectEqual(@as(i32, 99), val.b);
}

test "serialize pretty" {
    const Point = struct { x: i32, y: i32 };
    const bytes = try toSliceWith(testing.allocator, Point{ .x = 1, .y = 2 }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Point>\n  <x>1</x>\n  <y>2</y>\n</Point>", bytes);
}

test "serialize pretty nested struct" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    const bytes = try toSliceWith(testing.allocator, Outer{ .name = "test", .inner = .{ .val = 42 } }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<Outer>\n  <name>test</name>\n  <inner>\n    <val>42</val>\n  </inner>\n</Outer>", bytes);
}

test "serialize pretty with attributes" {
    const User = struct {
        id: u64,
        name: []const u8,
        pub const serde = .{ .xml_attribute = .{.id}, .xml_root = "user" };
    };
    const bytes = try toSliceWith(testing.allocator, User{ .id = 42, .name = "Alice" }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<user id=\"42\">\n  <name>Alice</name>\n</user>", bytes);
}

test "serialize pretty deeply nested" {
    const C = struct { z: i32 };
    const B = struct { c: C };
    const A = struct { b: B };
    const bytes = try toSliceWith(testing.allocator, A{ .b = .{ .c = .{ .z = 1 } } }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<A>\n  <b>\n    <c>\n      <z>1</z>\n    </c>\n  </b>\n</A>", bytes);
}

test "serialize pretty slice" {
    const List = struct { items: []const i32 };
    const bytes = try toSliceWith(testing.allocator, List{ .items = &.{ 1, 2 } }, .{
        .xml_declaration = false,
        .pretty = true,
        .indent = 2,
    });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<List>\n  <items>1</items>\n  <items>2</items>\n</List>", bytes);
}

test "pretty roundtrip" {
    const Inner = struct { val: i32 };
    const Outer = struct { name: []const u8, inner: Inner };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Outer{ .name = "test", .inner = .{ .val = 42 } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .pretty = true, .indent = 2 });
    const result = try fromSlice(Outer, arena.allocator(), bytes);
    try testing.expectEqualStrings("test", result.name);
    try testing.expectEqual(@as(i32, 42), result.inner.val);
}

test "deserialize slice" {
    const List = struct { items: []const i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(List, arena.allocator(), "<List><items>1</items><items>2</items><items>3</items></List>");
    try testing.expectEqual(@as(usize, 3), val.items.len);
    try testing.expectEqual(@as(i32, 1), val.items[0]);
    try testing.expectEqual(@as(i32, 2), val.items[1]);
    try testing.expectEqual(@as(i32, 3), val.items[2]);
}

test "roundtrip slice" {
    const List = struct { items: []const i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = List{ .items = &.{ 10, 20, 30 } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(List, arena.allocator(), bytes);
    try testing.expectEqualDeep(original.items, result.items);
}

test "deserialize string slice" {
    const Tags = struct { tags: []const []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(Tags, arena.allocator(), "<Tags><tags>a</tags><tags>b</tags></Tags>");
    try testing.expectEqual(@as(usize, 2), val.tags.len);
    try testing.expectEqualStrings("a", val.tags[0]);
    try testing.expectEqualStrings("b", val.tags[1]);
}

test "issue#1: no-wrapper repeated children" {
    const input = "<root><item>a</item><item>b</item></root>";
    const Root = struct { item: ?[]const []const u8 = null };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expect(r.item != null);
    try testing.expectEqual(@as(usize, 2), r.item.?.len);
    try testing.expectEqualStrings("a", r.item.?[0]);
    try testing.expectEqualStrings("b", r.item.?[1]);
}

test "issue#1: nested wrapper containing slice of strings" {
    const input = "<root><items><item>a</item><item>b</item></items></root>";
    const Items = struct { item: []const []const u8 };
    const Root = struct { items: ?Items = null };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expect(r.items != null);
    try testing.expectEqual(@as(usize, 2), r.items.?.item.len);
    try testing.expectEqualStrings("a", r.items.?.item[0]);
    try testing.expectEqualStrings("b", r.items.?.item[1]);
}

test "issue#1: Azure Blob list shape" {
    const input =
        "<EnumerationResults><Blobs>" ++
        "<Blob><Name>a</Name></Blob>" ++
        "<Blob><Name>b</Name></Blob>" ++
        "</Blobs></EnumerationResults>";
    const Blob = struct { Name: []const u8 };
    const Blobs = struct { Blob: ?[]const Blob = null };
    const Root = struct { Blobs: ?Blobs = null };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expect(r.Blobs != null);
    try testing.expect(r.Blobs.?.Blob != null);
    try testing.expectEqual(@as(usize, 2), r.Blobs.?.Blob.?.len);
    try testing.expectEqualStrings("a", r.Blobs.?.Blob.?[0].Name);
    try testing.expectEqualStrings("b", r.Blobs.?.Blob.?[1].Name);
}

test "issue#3: flat children work (control)" {
    const Blob = struct { Name: []const u8, ETag: []const u8 };
    const Blobs = struct { Blob: ?[]const Blob = null };
    const Root = struct { Blobs: ?Blobs = null };
    const input =
        "<R><Blobs>" ++
        "<Blob><Name>a</Name><ETag>e1</ETag></Blob>" ++
        "<Blob><Name>b</Name><ETag>e2</ETag></Blob>" ++
        "</Blobs></R>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expectEqual(@as(usize, 2), r.Blobs.?.Blob.?.len);
    try testing.expectEqualStrings("a", r.Blobs.?.Blob.?[0].Name);
    try testing.expectEqualStrings("e1", r.Blobs.?.Blob.?[0].ETag);
    try testing.expectEqualStrings("b", r.Blobs.?.Blob.?[1].Name);
    try testing.expectEqualStrings("e2", r.Blobs.?.Blob.?[1].ETag);
}

test "issue#3: nested struct child breaks sibling collection" {
    const Props = struct { @"Content-Type": []const u8 };
    const Blob = struct { Name: []const u8, Properties: Props };
    const Blobs = struct { Blob: ?[]const Blob = null };
    const Root = struct { Blobs: ?Blobs = null };
    const input =
        "<R><Blobs>" ++
        "<Blob><Name>a</Name><Properties><Content-Type>x</Content-Type></Properties></Blob>" ++
        "<Blob><Name>b</Name><Properties><Content-Type>y</Content-Type></Properties></Blob>" ++
        "</Blobs></R>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expectEqual(@as(usize, 2), r.Blobs.?.Blob.?.len);
    try testing.expectEqualStrings("a", r.Blobs.?.Blob.?[0].Name);
    try testing.expectEqualStrings("x", r.Blobs.?.Blob.?[0].Properties.@"Content-Type");
    try testing.expectEqualStrings("b", r.Blobs.?.Blob.?[1].Name);
    try testing.expectEqualStrings("y", r.Blobs.?.Blob.?[1].Properties.@"Content-Type");
}

test "issue#3: optional-of-struct nested field present" {
    const Props = struct { @"Content-Type": []const u8 };
    const Blob = struct { Name: []const u8, Properties: ?Props = null };
    const Blobs = struct { Blob: ?[]const Blob = null };
    const Root = struct { Blobs: ?Blobs = null };
    const input =
        "<R><Blobs>" ++
        "<Blob><Name>a</Name><Properties><Content-Type>x</Content-Type></Properties></Blob>" ++
        "<Blob><Name>b</Name><Properties><Content-Type>y</Content-Type></Properties></Blob>" ++
        "</Blobs></R>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expectEqual(@as(usize, 2), r.Blobs.?.Blob.?.len);
    try testing.expectEqualStrings("x", r.Blobs.?.Blob.?[0].Properties.?.@"Content-Type");
    try testing.expectEqualStrings("y", r.Blobs.?.Blob.?[1].Properties.?.@"Content-Type");
}

test "issue#3: two nested struct fields per element" {
    const Props = struct { @"Content-Type": []const u8 };
    const Meta = struct { Owner: []const u8 };
    const Blob = struct { Name: []const u8, Properties: Props, Metadata: Meta };
    const Blobs = struct { Blob: []const Blob };
    const Root = struct { Blobs: Blobs };
    const input =
        "<Root><Blobs>" ++
        "<Blob><Name>a</Name><Properties><Content-Type>x</Content-Type></Properties><Metadata><Owner>alice</Owner></Metadata></Blob>" ++
        "<Blob><Name>b</Name><Properties><Content-Type>y</Content-Type></Properties><Metadata><Owner>bob</Owner></Metadata></Blob>" ++
        "</Blobs></Root>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expectEqual(@as(usize, 2), r.Blobs.Blob.len);
    try testing.expectEqualStrings("alice", r.Blobs.Blob[0].Metadata.Owner);
    try testing.expectEqualStrings("bob", r.Blobs.Blob[1].Metadata.Owner);
}

test "issue#3: nested struct field before scalar field" {
    const Props = struct { @"Content-Type": []const u8 };
    const Blob = struct { Properties: Props, Name: []const u8 };
    const Blobs = struct { Blob: []const Blob };
    const Root = struct { Blobs: Blobs };
    const input =
        "<Root><Blobs>" ++
        "<Blob><Properties><Content-Type>x</Content-Type></Properties><Name>a</Name></Blob>" ++
        "<Blob><Properties><Content-Type>y</Content-Type></Properties><Name>b</Name></Blob>" ++
        "</Blobs></Root>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(Root, arena.allocator(), input);
    try testing.expectEqual(@as(usize, 2), r.Blobs.Blob.len);
    try testing.expectEqualStrings("a", r.Blobs.Blob[0].Name);
    try testing.expectEqualStrings("b", r.Blobs.Blob[1].Name);
}

test "issue#3: full Azure Blob list shape" {
    const Props = struct {
        @"Content-Type": []const u8,
        @"Content-Length": u64,
    };
    const Blob = struct {
        Name: []const u8,
        Properties: Props,
    };
    const Blobs = struct { Blob: []const Blob };
    const EnumerationResults = struct { Blobs: Blobs };
    const input =
        "<EnumerationResults><Blobs>" ++
        "<Blob><Name>file1.txt</Name><Properties><Content-Type>text/plain</Content-Type><Content-Length>42</Content-Length></Properties></Blob>" ++
        "<Blob><Name>file2.png</Name><Properties><Content-Type>image/png</Content-Type><Content-Length>1024</Content-Length></Properties></Blob>" ++
        "<Blob><Name>file3.bin</Name><Properties><Content-Type>application/octet-stream</Content-Type><Content-Length>0</Content-Length></Properties></Blob>" ++
        "</Blobs></EnumerationResults>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try fromSlice(EnumerationResults, arena.allocator(), input);
    try testing.expectEqual(@as(usize, 3), r.Blobs.Blob.len);
    try testing.expectEqualStrings("file1.txt", r.Blobs.Blob[0].Name);
    try testing.expectEqualStrings("text/plain", r.Blobs.Blob[0].Properties.@"Content-Type");
    try testing.expectEqual(@as(u64, 42), r.Blobs.Blob[0].Properties.@"Content-Length");
    try testing.expectEqualStrings("file2.png", r.Blobs.Blob[1].Name);
    try testing.expectEqual(@as(u64, 1024), r.Blobs.Blob[1].Properties.@"Content-Length");
    try testing.expectEqualStrings("file3.bin", r.Blobs.Blob[2].Name);
    try testing.expectEqual(@as(u64, 0), r.Blobs.Blob[2].Properties.@"Content-Length");
}

test "issue#3: Azure Blob list roundtrip" {
    const Props = struct {
        @"Content-Type": []const u8,
        @"Content-Length": u64,
    };
    const Blob = struct {
        Name: []const u8,
        Properties: Props,
    };
    const Blobs = struct { Blob: []const Blob };
    const EnumerationResults = struct { Blobs: Blobs };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = EnumerationResults{ .Blobs = .{ .Blob = &.{
        .{ .Name = "a", .Properties = .{ .@"Content-Type" = "text/plain", .@"Content-Length" = 1 } },
        .{ .Name = "b", .Properties = .{ .@"Content-Type" = "image/png", .@"Content-Length" = 2 } },
    } } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    const result = try fromSlice(EnumerationResults, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), result.Blobs.Blob.len);
    try testing.expectEqualStrings("a", result.Blobs.Blob[0].Name);
    try testing.expectEqualStrings("text/plain", result.Blobs.Blob[0].Properties.@"Content-Type");
    try testing.expectEqual(@as(u64, 1), result.Blobs.Blob[0].Properties.@"Content-Length");
    try testing.expectEqualStrings("b", result.Blobs.Blob[1].Name);
    try testing.expectEqual(@as(u64, 2), result.Blobs.Blob[1].Properties.@"Content-Length");
}

test "issue#3: nested-then-sibling field in same parent" {
    // Locks in that a struct child followed by another field in the same
    // parent works (previously worked by accident — at-end-of-input only).
    const Inner = struct { val: i32 };
    const Outer = struct { inner: Inner, name: []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(
        Outer,
        arena.allocator(),
        "<Outer><inner><val>42</val></inner><name>after</name></Outer>",
    );
    try testing.expectEqual(@as(i32, 42), val.inner.val);
    try testing.expectEqualStrings("after", val.name);
}

test "slice of structs roundtrip (Azure-style)" {
    const Blob = struct { Name: []const u8 };
    const Blobs = struct { Blob: []const Blob };
    const Root = struct { Blobs: Blobs };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Root{ .Blobs = .{ .Blob = &.{
        .{ .Name = "a" },
        .{ .Name = "b" },
    } } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    try testing.expectEqualStrings(
        "<Root><Blobs><Blob><Name>a</Name></Blob><Blob><Name>b</Name></Blob></Blobs></Root>",
        bytes,
    );
    const result = try fromSlice(Root, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 2), result.Blobs.Blob.len);
    try testing.expectEqualStrings("a", result.Blobs.Blob[0].Name);
    try testing.expectEqualStrings("b", result.Blobs.Blob[1].Name);
}

test "serialize empty slice emits nothing" {
    const List = struct { items: []const i32 };
    const bytes = try toSliceWith(testing.allocator, List{ .items = &.{} }, .{ .xml_declaration = false });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("<List></List>", bytes);
}

test "deserialize empty slice from absent field" {
    const List = struct { items: []const i32 = &.{} };
    const val = try fromSlice(List, testing.allocator, "<List></List>");
    try testing.expectEqual(@as(usize, 0), val.items.len);
}

test "slice of strings roundtrip" {
    const Tags = struct { tag: []const []const u8 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const original = Tags{ .tag = &.{ "alpha", "beta", "gamma" } };
    const bytes = try toSliceWith(arena.allocator(), original, .{ .xml_declaration = false });
    try testing.expectEqualStrings(
        "<Tags><tag>alpha</tag><tag>beta</tag><tag>gamma</tag></Tags>",
        bytes,
    );
    const result = try fromSlice(Tags, arena.allocator(), bytes);
    try testing.expectEqual(@as(usize, 3), result.tag.len);
    try testing.expectEqualStrings("alpha", result.tag[0]);
    try testing.expectEqualStrings("beta", result.tag[1]);
    try testing.expectEqualStrings("gamma", result.tag[2]);
}

test "single-element slice deserialize" {
    const List = struct { item: []const i32 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const val = try fromSlice(List, arena.allocator(), "<List><item>42</item></List>");
    try testing.expectEqual(@as(usize, 1), val.item.len);
    try testing.expectEqual(@as(i32, 42), val.item[0]);
}

test "schema: top-level enum rename deserializes" {
    const Mode = enum {
        read_only,
        write_only,
    };
    const schema = .{
        .rename = .{
            .read_only = "ro",
            .write_only = "wo",
        },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try fromSliceSchema(Mode, arena.allocator(), "<value>ro</value>", schema);
    try testing.expectEqual(Mode.read_only, value);
}

test "schema: top-level untagged union deserializes" {
    const Scalar = union(enum) {
        string: []const u8,
        int: i64,
    };
    const schema = .{
        .tag = opt.UnionTag.untagged,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try fromSliceSchema(Scalar, arena.allocator(), "<value>hello</value>", schema);
    try testing.expectEqualStrings("hello", value.string);
}

test "deserialize element after wrapped struct-slice" {
    // A struct field whose last member is a slice of structs (a "wrapper"
    // element containing repeated child structs), followed by a sibling
    // element. Regression: `readSliceItem` used to consume the wrapper's
    // closing tag after the last struct item, dropping the trailing sibling
    // (e.g. Azure blob listing: `<Containers>...</Containers><NextMarker>`).
    const Item = struct {
        name: []const u8,
        pub const serde = .{ .rename = .{ .name = "Name" } };
    };
    const Wrap = struct {
        item: []const Item = &.{},
        pub const serde = .{ .rename = .{ .item = "Item" } };
    };
    const Root = struct {
        wrap: Wrap = .{},
        tail: ?[]const u8 = null,
        pub const serde = .{ .rename = .{ .wrap = "Wrap", .tail = "Tail" } };
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const xml =
        "<Root><Wrap><Item><Name>a</Name></Item>" ++
        "<Item><Name>b</Name></Item></Wrap><Tail>done</Tail></Root>";
    const r = try fromSlice(Root, arena.allocator(), xml);
    try testing.expectEqual(@as(usize, 2), r.wrap.item.len);
    try testing.expectEqualStrings("a", r.wrap.item[0].name);
    try testing.expectEqualStrings("b", r.wrap.item[1].name);
    try testing.expect(r.tail != null);
    try testing.expectEqualStrings("done", r.tail.?);
}

const std = @import("std");
const reflection = @import("compat").reflection;
const scanner_mod = @import("scanner.zig");
const core_deserialize = @import("../../core/deserialize.zig");

const Scanner = scanner_mod.Scanner;
const Token = scanner_mod.Token;
const Allocator = std.mem.Allocator;

pub const DeserializeError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEof,
    UnknownField,
    MissingField,
    InvalidNumber,
    InvalidUnicode,
    InvalidEscape,
    InvalidControlCharacter,
    MaxDepthExceeded,
    TrailingData,
    WrongType,
    Overflow,
};

pub const Options = struct {
    /// When true, JSON `null` deserializes to 0 for integer/float fields.
    /// Default false; non-optional numeric fields receiving null produce error.WrongType.
    lenient_null_to_zero: bool = false,
    /// When true, unescaped control characters (U+0000..U+001F) inside strings
    /// are accepted. Default false per RFC 8259 §7.
    allow_unescaped_control_chars: bool = false,
    /// Maximum allowed nesting depth for arrays and objects. Beyond this,
    /// parsing returns error.MaxDepthExceeded. Default 256.
    max_depth: u32 = 256,
};

pub const Deserializer = struct {
    scanner: Scanner,
    borrow_strings: bool = false,
    options: Options = .{},

    pub const Error = DeserializeError;

    pub fn init(input: []const u8) Deserializer {
        return .{ .scanner = .{ .input = input } };
    }

    pub fn initWith(input: []const u8, options: Options) Deserializer {
        return .{
            .scanner = .{
                .input = input,
                .allow_unescaped_control_chars = options.allow_unescaped_control_chars,
                .max_depth = options.max_depth,
            },
            .options = options,
        };
    }

    pub fn initBorrowed(input: []const u8) Deserializer {
        return .{ .scanner = .{ .input = input }, .borrow_strings = true };
    }

    pub fn initBorrowedWith(input: []const u8, options: Options) Deserializer {
        return .{
            .scanner = .{
                .input = input,
                .allow_unescaped_control_chars = options.allow_unescaped_control_chars,
                .max_depth = options.max_depth,
            },
            .borrow_strings = true,
            .options = options,
        };
    }

    pub fn deserializeBool(self: *Deserializer) Error!bool {
        const tok = try self.scanner.next();
        return switch (tok) {
            .true_lit => true,
            .false_lit => false,
            else => error.WrongType,
        };
    }

    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        const tok = try self.scanner.next();
        switch (tok) {
            .number => |raw| return std.fmt.parseInt(T, raw, 10) catch error.InvalidNumber,
            .null_lit => if (self.options.lenient_null_to_zero) return 0 else return error.WrongType,
            else => return error.WrongType,
        }
    }

    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        const tok = try self.scanner.next();
        switch (tok) {
            .number => |raw| return std.fmt.parseFloat(T, raw) catch error.InvalidNumber,
            .null_lit => if (self.options.lenient_null_to_zero) return 0 else return error.WrongType,
            else => return error.WrongType,
        }
    }

    pub fn deserializeString(self: *Deserializer, allocator: Allocator) Error![]const u8 {
        const tok = try self.scanner.next();
        switch (tok) {
            .string => |raw| {
                if (!Scanner.stringHasEscapes(raw)) {
                    if (self.borrow_strings) return raw;
                    const copy = allocator.alloc(u8, raw.len) catch return error.OutOfMemory;
                    @memcpy(copy, raw);
                    return copy;
                }
                if (self.borrow_strings) return error.InvalidEscape;
                return try unescapeString(allocator, raw);
            },
            .null_lit => {
                if (self.borrow_strings) return "";
                const empty = allocator.alloc(u8, 0) catch return error.OutOfMemory;
                return empty;
            },
            else => return error.WrongType,
        }
    }

    /// Zero-copy: return a slice into the input buffer (only when no escapes).
    pub fn deserializeStringBorrowed(self: *Deserializer) Error![]const u8 {
        const tok = try self.scanner.next();
        switch (tok) {
            .string => |raw| {
                if (Scanner.stringHasEscapes(raw)) {
                    return error.InvalidEscape;
                }
                return raw;
            },
            else => return error.WrongType,
        }
    }

    pub fn deserializeVoid(self: *Deserializer) Error!void {
        const tok = try self.scanner.next();
        if (tok != .null_lit) return error.WrongType;
    }

    pub fn deserializeOptional(self: *Deserializer, comptime T: type, allocator: Allocator) Error!?T {
        const tok = try self.scanner.peek();
        if (tok == .null_lit) {
            _ = try self.scanner.next();
            return null;
        }
        return try core_deserialize.deserialize(T, allocator, self, .{});
    }

    pub fn deserializeEnum(self: *Deserializer, comptime T: type) Error!T {
        const tok = try self.scanner.next();
        switch (tok) {
            .string => |raw| {
                inline for (reflection.fields(@typeInfo(T).@"enum")) |field| {
                    if (std.mem.eql(u8, raw, field.name))
                        return @fromBackingInt(@intCast(field.value));
                }
                return error.UnexpectedToken;
            },
            else => return error.WrongType,
        }
    }

    pub fn deserializeUnion(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T).@"union";
        const tok = try self.scanner.peek();
        if (tok == .string) {
            const str_tok = try self.scanner.next();
            const name = str_tok.string;
            inline for (reflection.fields(info)) |field| {
                if (field.type == void and std.mem.eql(u8, name, field.name)) {
                    return @unionInit(T, field.name, {});
                }
            }
            return error.UnexpectedToken;
        }
        // External tagging: {"variant": payload}
        if (tok != .object_begin) return error.WrongType;
        _ = try self.scanner.next();
        const key_tok = try self.scanner.next();
        if (key_tok != .string) return error.WrongType;
        const variant_name = key_tok.string;
        try self.scanner.expectColon();

        inline for (reflection.fields(info)) |field| {
            if (std.mem.eql(u8, variant_name, field.name)) {
                if (field.type == void) {
                    const val_tok = try self.scanner.next();
                    if (val_tok != .null_lit) return error.WrongType;
                    const close = try self.scanner.next();
                    if (close != .object_end) return error.UnexpectedToken;
                    return @unionInit(T, field.name, {});
                } else {
                    const payload = try core_deserialize.deserialize(field.type, allocator, self, .{});
                    const close = try self.scanner.next();
                    if (close != .object_end) return error.UnexpectedToken;
                    return @unionInit(T, field.name, payload);
                }
            }
        }
        return error.UnexpectedToken;
    }

    pub fn deserializeStruct(self: *Deserializer, comptime _: type) Error!MapAccess {
        const tok = try self.scanner.next();
        if (tok != .object_begin) return error.WrongType;
        return .{ .scanner = &self.scanner, .borrow_strings = self.borrow_strings, .options = self.options };
    }

    pub fn deserializeSeq(self: *Deserializer, comptime T: type, allocator: Allocator) Error!T {
        const info = @typeInfo(T);
        if (info != .pointer or info.pointer.size != .slice)
            @compileError("deserializeSeq expects a slice type");
        const Child = info.pointer.child;

        const tok = try self.scanner.next();
        if (tok != .array_begin) return error.WrongType;

        var items: std.ArrayList(Child) = .empty;
        errdefer items.deinit(allocator);

        if (try self.scanner.isContainerEmpty(']')) {
            _ = try self.scanner.next();
            return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
        }

        while (true) {
            const elem = try core_deserialize.deserialize(Child, allocator, self, .{});
            items.append(allocator, elem) catch return error.OutOfMemory;
            switch (try self.scanner.finishContainer(']')) {
                .end => break,
                .more => {},
            }
        }

        return items.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    pub fn deserializeSeqAccess(self: *Deserializer) Error!SeqAccess {
        const tok = try self.scanner.next();
        if (tok != .array_begin) return error.WrongType;
        return .{ .scanner = &self.scanner, .options = self.options };
    }

    pub fn raiseError(_: *Deserializer, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const MapAccess = struct {
    scanner: *Scanner,
    borrow_strings: bool = false,
    options: Options = .{},
    at_start: bool = true,

    pub const Error = DeserializeError;

    pub fn nextKey(self: *MapAccess, allocator: Allocator) Error!?[]const u8 {
        if (self.at_start) {
            self.at_start = false;
            if (try self.scanner.isContainerEmpty('}')) {
                _ = try self.scanner.next();
                return null;
            }
        } else {
            switch (try self.scanner.finishContainer('}')) {
                .end => return null,
                .more => {},
            }
        }
        const key_tok = try self.scanner.next();
        switch (key_tok) {
            .string => |raw| {
                try self.scanner.expectColon();
                if (Scanner.stringHasEscapes(raw)) {
                    if (self.borrow_strings) return error.InvalidEscape;
                    return try unescapeString(allocator, raw);
                }
                return raw;
            },
            else => return error.WrongType,
        }
    }

    pub fn nextValue(self: *MapAccess, comptime T: type, allocator: Allocator) Error!T {
        var deser = Deserializer{ .scanner = self.scanner.*, .borrow_strings = self.borrow_strings, .options = self.options };
        const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
        self.scanner.* = deser.scanner;
        return result;
    }

    pub fn skipValue(self: *MapAccess) Error!void {
        try self.scanner.skipValue();
    }

    pub fn raiseError(_: *MapAccess, err: anyerror) Error {
        return errorFromAny(err);
    }
};

pub const SeqAccess = struct {
    scanner: *Scanner,
    options: Options = .{},
    at_start: bool = true,

    pub const Error = DeserializeError;

    pub fn nextElement(self: *SeqAccess, comptime T: type, allocator: Allocator) Error!?T {
        if (self.at_start) {
            self.at_start = false;
            if (try self.scanner.isContainerEmpty(']')) {
                _ = try self.scanner.next();
                return null;
            }
        } else {
            switch (try self.scanner.finishContainer(']')) {
                .end => return null,
                .more => {},
            }
        }
        var deser = Deserializer{ .scanner = self.scanner.*, .options = self.options };
        const result = try core_deserialize.deserialize(T, allocator, &deser, .{});
        self.scanner.* = deser.scanner;
        return result;
    }
};

fn errorFromAny(err: anyerror) DeserializeError {
    return switch (err) {
        error.UnknownField => error.UnknownField,
        error.MissingField => error.MissingField,
        error.UnexpectedEof => error.UnexpectedEof,
        error.OutOfMemory => error.OutOfMemory,
        else => error.WrongType,
    };
}

fn unescapeString(allocator: Allocator, raw: []const u8) DeserializeError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\') {
            i += 1;
            if (i >= raw.len) return error.UnexpectedEof;
            switch (raw[i]) {
                '"' => try appendByte(&out, allocator, '"'),
                '\\' => try appendByte(&out, allocator, '\\'),
                '/' => try appendByte(&out, allocator, '/'),
                'n' => try appendByte(&out, allocator, '\n'),
                'r' => try appendByte(&out, allocator, '\r'),
                't' => try appendByte(&out, allocator, '\t'),
                'b' => try appendByte(&out, allocator, 0x08),
                'f' => try appendByte(&out, allocator, 0x0c),
                'u' => {
                    i += 1;
                    if (i + 4 > raw.len) return error.UnexpectedEof;
                    const cp = parseHex4(raw[i..][0..4]) orelse return error.InvalidUnicode;
                    i += 4;
                    if (cp >= 0xD800 and cp <= 0xDBFF) {
                        if (i + 6 > raw.len or raw[i] != '\\' or raw[i + 1] != 'u')
                            return error.InvalidUnicode;
                        i += 2;
                        const low = parseHex4(raw[i..][0..4]) orelse return error.InvalidUnicode;
                        i += 4;
                        if (low < 0xDC00 or low > 0xDFFF)
                            return error.InvalidUnicode;
                        const full: u21 = 0x10000 + (@as(u21, cp - 0xD800) << 10) + (low - 0xDC00);
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(full, &buf) catch return error.InvalidUnicode;
                        out.appendSlice(allocator, buf[0..len]) catch return error.OutOfMemory;
                    } else {
                        if (cp >= 0xDC00 and cp <= 0xDFFF) return error.InvalidUnicode;
                        const cp21: u21 = @intCast(cp);
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp21, &buf) catch return error.InvalidUnicode;
                        out.appendSlice(allocator, buf[0..len]) catch return error.OutOfMemory;
                    }
                    continue;
                },
                else => return error.InvalidEscape,
            }
            i += 1;
        } else {
            try appendByte(&out, allocator, raw[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn appendByte(list: *std.ArrayList(u8), allocator: Allocator, byte: u8) DeserializeError!void {
    list.append(allocator, byte) catch return error.OutOfMemory;
}

fn parseHex4(hex: *const [4]u8) ?u16 {
    var result: u16 = 0;
    for (hex) |c| {
        const digit: u16 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        result = result * 16 + digit;
    }
    return result;
}

// Tests.

const testing = std.testing;

test "deserialize bool" {
    var d = Deserializer.init("true");
    try testing.expectEqual(true, try d.deserializeBool());
}

test "deserialize int" {
    var d = Deserializer.init("42");
    try testing.expectEqual(@as(i32, 42), try d.deserializeInt(i32));
}

test "deserialize negative int" {
    var d = Deserializer.init("-7");
    try testing.expectEqual(@as(i32, -7), try d.deserializeInt(i32));
}

test "deserialize float" {
    var d = Deserializer.init("3.14");
    const val = try d.deserializeFloat(f64);
    try testing.expect(@abs(val - 3.14) < 0.001);
}

test "deserialize string" {
    var d = Deserializer.init("\"hello\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "deserialize string with escapes" {
    var d = Deserializer.init("\"he\\\"llo\\nworld\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("he\"llo\nworld", s);
}

test "deserialize string borrowed" {
    var d = Deserializer.init("\"hello\"");
    const s = try d.deserializeStringBorrowed();
    try testing.expectEqualStrings("hello", s);
}

test "deserialize null optional" {
    var d = Deserializer.init("null");
    const val = try d.deserializeOptional(i32, testing.allocator);
    try testing.expectEqual(@as(?i32, null), val);
}

test "deserialize present optional" {
    var d = Deserializer.init("42");
    const val = try d.deserializeOptional(i32, testing.allocator);
    try testing.expectEqual(@as(?i32, 42), val);
}

test "deserialize enum" {
    const Color = enum { red, green, blue };
    var d = Deserializer.init("\"green\"");
    try testing.expectEqual(Color.green, try d.deserializeEnum(Color));
}

test "deserialize struct" {
    const Point = struct { x: i32, y: i32 };
    var d = Deserializer.init("{\"x\":10,\"y\":20}");
    const point = try core_deserialize.deserialize(Point, testing.allocator, &d, .{});
    try testing.expectEqual(@as(i32, 10), point.x);
    try testing.expectEqual(@as(i32, 20), point.y);
}

test "deserialize struct with optional" {
    const Opt = struct { a: i32, b: ?i32 };
    var d = Deserializer.init("{\"a\":5}");
    const val = try core_deserialize.deserialize(Opt, testing.allocator, &d, .{});
    try testing.expectEqual(@as(i32, 5), val.a);
    try testing.expectEqual(@as(?i32, null), val.b);
}

test "deserialize slice" {
    var d = Deserializer.init("[1,2,3]");
    const arr = try d.deserializeSeq([]const i32, testing.allocator);
    defer testing.allocator.free(arr);
    try testing.expectEqual(@as(usize, 3), arr.len);
    try testing.expectEqual(@as(i32, 1), arr[0]);
    try testing.expectEqual(@as(i32, 2), arr[1]);
    try testing.expectEqual(@as(i32, 3), arr[2]);
}

test "deserialize union void variant" {
    const Cmd = union(enum) { ping: void, quit: void };
    var d = Deserializer.init("\"ping\"");
    const val = try d.deserializeUnion(Cmd, testing.allocator);
    try testing.expectEqual(Cmd.ping, val);
}

test "deserialize union with payload" {
    const Cmd = union(enum) { set: i32, ping: void };
    var d = Deserializer.init("{\"set\":42}");
    const val = try d.deserializeUnion(Cmd, testing.allocator);
    try testing.expectEqual(Cmd{ .set = 42 }, val);
}

test "deserialize unicode escape" {
    var d = Deserializer.init("\"\\u0041\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("A", s);
}

test "deserialize surrogate pair" {
    var d = Deserializer.init("\"\\uD83D\\uDE00\"");
    const s = try d.deserializeString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\u{1F600}", s);
}

test "deserialize lone low surrogate is rejected" {
    var d = Deserializer.init("\"\\uDC00\"");
    try testing.expectError(error.InvalidUnicode, d.deserializeString(testing.allocator));
}

test "deserialize unpaired high surrogate is rejected" {
    var d = Deserializer.init("\"\\uD83D\"");
    try testing.expectError(error.InvalidUnicode, d.deserializeString(testing.allocator));
}

test "wrong type error" {
    var d = Deserializer.init("\"hello\"");
    try testing.expectError(error.WrongType, d.deserializeBool());
}

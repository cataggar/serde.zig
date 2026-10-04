const std = @import("std");

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,

    pub fn defaultValue(comptime self: StructField) ?self.type {
        const ptr: *const self.type = @ptrCast(@alignCast(self.default_value_ptr orelse return null));
        return ptr.*;
    }
};

pub const UnionField = struct {
    name: [:0]const u8,
    type: type,
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub inline fn typeFields(comptime T: type) switch (@typeInfo(T)) {
    .@"struct" => []const StructField,
    .@"union" => []const UnionField,
    .@"enum" => []const EnumField,
    else => @compileError("expected struct, union, or enum type"),
} {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| fields(info),
        .@"union" => |info| fields(info),
        .@"enum" => |info| fields(info),
        else => unreachable,
    };
}

pub inline fn fields(comptime info: anytype) []const switch (@TypeOf(info)) {
    std.lang.Type.Struct => StructField,
    std.lang.Type.Union => UnionField,
    std.lang.Type.Enum => EnumField,
    else => @compileError("expected struct, union, or enum reflection"),
} {
    comptime {
        const Field = switch (@TypeOf(info)) {
            std.lang.Type.Struct => StructField,
            std.lang.Type.Union => UnionField,
            std.lang.Type.Enum => EnumField,
            else => unreachable,
        };
        var result: [info.field_names.len]Field = undefined;
        for (info.field_names, 0..) |name, i| {
            result[i] = switch (@TypeOf(info)) {
                std.lang.Type.Struct => .{
                    .name = name,
                    .type = info.field_types[i],
                    .default_value_ptr = info.field_attrs[i].default_value_ptr,
                },
                std.lang.Type.Union => .{ .name = name, .type = info.field_types[i] },
                std.lang.Type.Enum => .{ .name = name, .value = info.field_values[i] },
                else => unreachable,
            };
        }
        const final = result;
        return &final;
    }
}

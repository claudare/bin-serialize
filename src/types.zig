const std = @import("std");
const mem = std.mem;
const debug = std.debug;

pub fn checkBool(T: type) void {
    if (T != bool) {
        @compileError("type " ++ @typeName(T) ++ " is not a boolean");
    }
}

pub fn checkFloat(T: type) void {
    switch (@typeInfo(T)) {
        .Float => |info| {
            _ = info;
            // For now I removed validation of specific float types
            // switch (info.bits) {
            //     16, 32, 64, 80, 128 => {},
            //     else => @compileError("float type " ++ @typeName(T) ++ " is not supported, use f16, f32, f64, f80, or f128"),
            // }
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a float"),
    }
}

pub fn checkInt(comptime T: type) void {
    switch (@typeInfo(T)) {
        .Int => |info| {
            if (T == usize or T == isize) {
                @compileError("dynamic integer type " ++ @typeName(T) ++ " is not supported, use fixed-width integers instead");
            }

            if (info.bits % 8 != 0) {
                @compileError("integer type " ++ @typeName(T) ++ " must have size divisible by 8 bits");
            }
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not an integer"),
    }
}
pub fn checkOptional(T: type) void {
    switch (@typeInfo(T)) {
        .Optional => {},
        else => @compileError("type " ++ @typeName(T) ++ " is not an optional"),
    }
}

pub fn checkEnum(T: type) void {
    switch (@typeInfo(T)) {
        .Enum => |info| {
            // Check if enum has explicit tag type
            // if (info.tag_type == null) {
            //     @compileError("enum " ++ @typeName(T) ++ " must have an explicit integer tag type (e.g., enum(u8))");
            // }

            // dont allow dynamic tag sizes
            if (info.tag_type == usize or info.tag_type == isize) {
                @compileError("enum " ++ @typeName(T) ++ " cannot use usize/isize as tag type");
            }

            // Check if tag type is multiple of 8 bits
            const tag_info = @typeInfo(info.tag_type).Int;
            if (tag_info.bits % 8 != 0) {
                @compileError("enum " ++ @typeName(T) ++ " tag type must have size divisible by 8 bits");
            }
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not an enum"),
    }
}
pub fn checkUnion(T: type) void {
    switch (@typeInfo(T)) {
        .Union => |info| {
            // Check if union is tagged
            if (info.tag_type) |TagType| {
                // Check if tag type is enum
                switch (@typeInfo(TagType)) {
                    .Enum => |tag_info| {
                        // Its not possible to check if enum has explicit tag type?
                        // if (tag_info.tag_type) {
                        //     @compileError("union " ++ @typeName(T) ++ " tag enum must have an explicit integer tag type");
                        // }

                        // Check if tag type is multiple of 8 bits
                        const tag_int_info = @typeInfo(tag_info.tag_type).Int;
                        if (tag_int_info.bits % 8 != 0) {
                            @compileError("union " ++ @typeName(T) ++ " tag type must have size divisible by 8 bits");
                        }
                    },
                    else => @compileError("union " ++ @typeName(T) ++ " tag type must be an enum"),
                }
            } else {
                @compileError("untagged union " ++ @typeName(T) ++ " is not supported");
            }
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a union"),
    }
}
pub fn checkStruct(T: type) void {
    switch (@typeInfo(T)) {
        .Struct => {}, // struct allows both packed and unpacked versions
        else => @compileError("type " ++ @typeName(T) ++ " is not a struct"),
    }
}
pub fn checkStructPacked(T: type) void {
    switch (@typeInfo(T)) {
        .Struct => |info| if (info.layout == .auto) {
            @compileError("type " ++ @typeName(T) ++ " is not a packed/external struct");
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a packed/external struct"),
    }
}
pub fn checkArray(T: type) void {
    switch (@typeInfo(T)) {
        .Array => {},
        else => @compileError("type " ++ @typeName(T) ++ " is not an array"),
    }
}
pub fn checkSlice(T: type) void {
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .Slice => {},
            else => |size| @compileError("type " ++ @typeName(T) ++ " is not a slice. Wrong size " ++ size),
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a slice"),
    }
}

// TODO: maybe allow for non-const u8 ([]u8)?
// what about all other wierd types ([:0]u8), ([*]u8)
pub fn checkString(T: type) void {
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .Slice => {
                if (info.child == u8) {
                    if (info.is_const) {
                        return;
                    }

                    @compileError("type " ++ @typeName(T) ++ " is not a string. It must have const qualifier ([]const u8)");
                }
            },
            else => |size| @compileError("type " ++ @typeName(T) ++ " is not a string. Wrong size " ++ size),
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a string"),
    }
}
pub fn checkPointerSingle(T: type) void {
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .One => {},
            else => @compileError("type " ++ @typeName(T) ++ " is not a single pointer"),
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a pointer"),
    }
}

pub const KV = struct {
    K: type,
    V: type,
    pub fn infer(comptime T: type) KV {
        const kv_struct = @typeInfo(T.KV).Struct;
        return .{
            .K = kv_struct.fields[0].type,
            .V = kv_struct.fields[1].type,
        };
    }
};

pub const RichType = union(enum) {
    Bool: void,
    Float: type,
    Int: type,
    Optional: type,
    Enum: type,
    Union: type,
    Struct: type,
    // "packed" or "external" structs automatically use a more efficient method
    StructPacked: type,
    Array: type,
    // this is a speical type to be recycled
    Slice: type,
    // special type of slice: []const u8
    String: void,
    //TODO: Vector: type,
    PointerSingle: type,

    // std types
    ArrayListUnmanaged: type,
    ArrayList: type,
    HashMapUnmanaged: KV,
    HashMap: KV,
};

pub fn getRichType(comptime T: type) RichType {
    const type_info = @typeInfo(T);

    // debug.print("type info: {any}\n", .{type_info.});
    // @compileLog("TYPEINFO IS", type_info);
    switch (type_info) {
        .Void => {
            @compileError("void type must never be used");
        },
        .Bool => return .{ .Bool = {} },
        .Float, .ComptimeFloat => {
            return .{ .Float = T };
        },
        .Int, .ComptimeInt => {
            return .{ .Int = T };
        },
        .Optional => |info| return .{ .Optional = info.child },
        .Enum => return .{ .Enum = T },
        .Union => return .{ .Union = T },
        .Array => return .{ .Array = T },
        .Vector => @compileError("type " ++ @typeName(T) ++ " was not implemented yet"),
        // pointer is the only type which is handled here exclusively.
        // this also handles the slices of dynamic size
        .Pointer => |info| {
            switch (info.size) {
                .One => {
                    // is this better for uniformity?
                    // return .{ .PointerSingle = info.child };
                    return .{ .PointerSingle = T };
                },
                .Slice => {
                    if (info.child == u8) {
                        if (info.is_const) {
                            return .{ .String = {} };
                        }
                        return .{ .Slice = info.child };
                        // @compileError("non const u8 slices ([]u8) are not implemented yet");
                    }

                    return .{ .Slice = info.child };
                },
                else => @compileError("pointers of size " ++ info.size ++ " are not implemented yet"),
            }
        },
        .Struct => |info| {
            // here complex built in type detection is performed
            if (mem.startsWith(u8, @typeName(T), "array_list")) {
                const child = @typeInfo(T.Slice).Pointer.child;
                if (mem.containsAtLeast(u8, @typeName(T), 1, "Unmanaged")) {
                    return .{ .ArrayListUnmanaged = child };
                } else {
                    return .{ .ArrayList = child };
                }
            }

            if (mem.startsWith(u8, @typeName(T), "hash_map")) {
                // really ugly way to drill in the KV types!
                const kv = KV.infer(T);

                if (mem.containsAtLeast(u8, @typeName(T), 1, "Unmanaged")) {
                    return .{ .HashMapUnmanaged = kv };
                } else {
                    return .{ .HashMap = kv };
                }
            }

            if (info.layout == .auto) {
                return .{ .Struct = T };
            } else {
                return .{ .StructPacked = T };
            }
        },
        .ErrorSet, .ErrorUnion => @compileError("type " ++ @typeName(T) ++ " was not implemented yet"),
        else => @compileError("type " ++ @typeName(T) ++ " is not supported"),
    }
}

const testing = std.testing;

test getRichType {
    try testing.expectEqual({}, getRichType(bool).Bool);
    try testing.expectEqual(f32, getRichType(f32).Float);
    try testing.expectEqual(u88, getRichType(u88).Int);
    try testing.expectEqual(u88, getRichType(?u88).Optional);

    const EnumT = enum { a, b };
    try testing.expectEqual(EnumT, getRichType(EnumT).Enum);

    const UnionT = union(enum(u0)) { a: u64 };
    try testing.expectEqual(UnionT, getRichType(UnionT).Union);

    const StructT = struct { a: u64 };
    try testing.expectEqual(StructT, getRichType(StructT).Struct);

    const StructPackedT = packed struct { a: u64 };
    try testing.expectEqual(StructPackedT, getRichType(StructPackedT).StructPacked);
    const StructExternT = extern struct { a: u64 };
    try testing.expectEqual(StructExternT, getRichType(StructExternT).StructPacked);

    const ArrayT = [3]u64;
    try testing.expectEqual(ArrayT, getRichType(ArrayT).Array);

    try testing.expectEqual(u64, getRichType([]u64).Slice);
    try testing.expectEqual(u64, getRichType(std.ArrayList(u64)).ArrayList);
    try testing.expectEqual(u64, getRichType(std.ArrayListUnmanaged(u64)).ArrayListUnmanaged);
    try testing.expectEqual({}, getRichType([]const u8).String);
    try testing.expectEqual(*u64, getRichType(*u64).PointerSingle);
    try testing.expectEqualDeep(RichType{ .HashMap = .{ .K = i32, .V = u64 } }, getRichType(std.AutoHashMap(i32, u64)));
    try testing.expectEqualDeep(RichType{ .HashMapUnmanaged = .{ .K = i32, .V = u64 } }, getRichType(std.AutoHashMapUnmanaged(i32, u64)));
}

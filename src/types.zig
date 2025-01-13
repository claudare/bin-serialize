const std = @import("std");
const mem = std.mem;
const debug = std.debug;

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

pub fn checkBool(T: type) void {
    if (T != bool) {
        @compileError("type " ++ @typeName(T) ++ " is not a boolean");
    }
}

pub fn checkFloat(T: type) void {
    if (T != f32 and T != f64 and T != f128) {
        @compileError("float type " ++ @typeName(T) ++ " is not supported, use f32, f64, or f128 instead");
    }
}

pub fn checkInt(T: type) void {
    switch (@typeInfo(T)) {
        .Int => |info| if (@rem(info.bits, 8) != 0) {
            @compileError("int type " ++ @typeName(T) ++ " must be divisible by 8");
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not an int"),
    }
}

// will be used when serializing!?
// pub fn checkOptional(T: type) void {
//     switch (@typeInfo(T)) {
//         .Optional => {},
//         else => @compileError("type " ++ @typeName(T) ++ " is not an optional"),
//     }
// }

pub fn checkEnum(T: type) void {
    switch (@typeInfo(T)) {
        .Enum => |info| {
            // FIXME: what is done if usize is defined on the struct?
            // I guess cast to u64/i64 is sufficient?
            if (info.tag_type == usize or info.tag_type == isize) {
                @compileError("FIXME: behavior for dynamic tag type of " ++ @typeName(T) ++ " has not been defined yet");
            }
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not an enum"),
    }
}
pub fn checkUnion(T: type) void {
    switch (@typeInfo(T)) {
        .Union => |info| if (info.tag_type == null) {
            @compileError("untagged union " ++ @typeName(T) ++ " is not supported");
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not an union"),
    }
}
pub fn checkStruct(T: type) void {
    switch (@typeInfo(T)) {
        .Struct => {},
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
pub fn checkString(T: type) void {
    switch (@typeInfo(T)) {
        .Pointer => |info| switch (info.size) {
            .Slice => {
                if (info.child == u8) {
                    if (info.is_const) {
                        return;
                    }

                    @compileError("type " ++ @typeName(T) ++ " is not a currently supported string type");
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
            else => |size| @compileError("type " ++ @typeName(T) ++ " is not a single pointer. It is instead " ++ size),
        },
        else => @compileError("type " ++ @typeName(T) ++ " is not a pointer"),
    }
}

// pub fn checkArrayListUnmanaged(T_FULL: type) void {

// }

pub fn getRichType(comptime T: type) RichType {
    const type_info = @typeInfo(T);

    // debug.print("type info: {any}\n", .{type_info.});
    // @compileLog("TYPEINFO IS", type_info);
    switch (type_info) {
        .Void => {
            // or instead just return the void?
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
                // i would like to handle this here,
                // but it does not seem like a good idea
                .One => {
                    return .{ .PointerSingle = T };
                },
                .Slice => {
                    if (info.child == u8) {
                        if (info.is_const) {
                            return .{ .String = void };
                        }

                        @compileError("non const u8 slices ([]u8) are not implemented yet");
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

test "types basic" {
    try testing.expectEqualDeep(RichType{ .Bool = {} }, getRichType(bool));
    try testing.expectEqual(f32, getRichType(f32).Float);
}

test "types ArrayList and Hashmap" {
    try testing.expectEqual(i32, getRichType(std.ArrayList(i32)).ArrayList);
    try testing.expectEqual(i32, getRichType(std.ArrayListUnmanaged(i32)).ArrayListUnmanaged);

    try testing.expectEqualDeep(RichType{ .HashMap = .{ .K = i32, .V = u64 } }, getRichType(std.AutoHashMap(i32, u64)));
    try testing.expectEqualDeep(RichType{ .HashMapUnmanaged = .{ .K = i32, .V = u64 } }, getRichType(std.AutoHashMapUnmanaged(i32, u64)));
}

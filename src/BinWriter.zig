const std = @import("std");
const root = @import("root.zig");
const testing = std.testing;
const debug = std.debug;
const AnyWriter = std.io.AnyWriter;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const SliceLen = root.DefaultSliceLen;
const types = @import("types.zig");

const test_endian = .little; // same as default

const BinWriter = @This();
pub const WriterConfig = struct {
    /// Provide the maximum length to be written
    /// Defaults to null: write length can be infinite
    max_len: ?usize = null,

    endian: std.builtin.Endian = .little,
};

// FIXME: AnyReader.Error is anyerror... it doesnt help at all
pub const Error = AnyWriter.Error || error{
    /// present when allocator is used
    OutOfMemory,
    /// a limit of max_len was reached
    EndOfStream,
};

allocator: Allocator,
underlying_writer: AnyWriter,
total_written: usize,
maybe_max_len: ?usize,
endian: std.builtin.Endian,

pub fn init(allocator: Allocator, underlying_writer: AnyWriter, config: WriterConfig) BinWriter {
    return .{
        .allocator = allocator,
        .underlying_writer = underlying_writer,
        .total_written = 0,
        .maybe_max_len = config.max_len,
        .endian = config.endian,
    };
}

/// a typed proxy of the `underlying_reader.read`
/// always use this function to read!
pub inline fn write(self: *BinWriter, bytes: []const u8) Error!usize {
    const write_len = bytes.len;

    if (self.maybe_max_len) |max_len| {
        if (write_len + self.total_written > max_len) {
            // TODO: use a better error name
            return error.EndOfStream;
        }
    }

    const len_written = try self.underlying_writer.write(bytes);
    self.total_written += write_len;

    return len_written;
}
/// a typed proxy of the `underlying_reader.readByte`
/// always use this function to read!
pub inline fn writeByte(self: *BinWriter, value: u8) Error!u8 {
    var result = [1]u8{value};
    const amt_written = try self.write(result[0..]);
    if (amt_written < 1) return error.EndOfStream;
    return result[0];
}
pub inline fn writeAny(self: *BinWriter, comptime T: type, value: T) Error!void {
    const rich_type = types.getRichType(T);

    return switch (rich_type) {
        .Bool => self.writeBool(value),
        .Float => self.writeFloat(T, value),
        .Int => self.writeInt(T, value),
        .Optional => |Child| self.writeOptional(Child, value),
        .Enum => self.writeEnum(T, value),
        .Union => self.writeUnion(T, value),
        .Struct => self.writeStruct(T, value),
        .StructPacked => self.writeStructPacked(T, value),
        .Array => self.writeArray(T, value),
        .Slice => |Child| self.writeSlice(Child, value),
        .String => self.writeString(value),
        .PointerSingle => self.writePointer(T, value), // TODO
        .ArrayList => |Child| self.writeArrayList(Child, value),
        .ArrayListUnmanaged => |Child| self.writeArrayListUnmanaged(Child, value),
        .HashMap => |KV| self.writeHashMap(KV.K, KV.V, value),
        .HashMapUnmanaged => |KV| self.writeHashMapUnmanaged(KV.K, KV.V, value),
    };
}

pub fn writeBool(self: *BinWriter, value: bool) Error!void {
    if (value) {
        _ = try self.writeByte(1);
    } else {
        _ = try self.writeByte(0);
    }
}

test writeBool {
    const a = testing.allocator;
    var buff: [2]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = 2 });

    try rw.seekTo(0);
    try writer.writeBool(true);
    try testing.expectEqual(1, writer.total_written);
    try writer.writeBool(false);
    try testing.expectEqual(2, writer.total_written);
    // out of bounds check!
    try testing.expectError(error.EndOfStream, writer.writeBool(false));

    try testing.expectEqual(1, buff[0]);
    try testing.expectEqual(0, buff[1]);
}

pub fn writeFloat(self: *BinWriter, T: type, value: T) Error!void {
    types.checkFloat(T);

    const IntType = switch (@bitSizeOf(T)) {
        16 => u16,
        32 => u32,
        64 => u64,
        80 => u80,
        128 => u128,
        else => unreachable,
    };

    const float_encoded: IntType = @bitCast(value);

    _ = try self.writeInt(IntType, float_encoded);
}

test writeFloat {
    const a = testing.allocator;
    var buff: [10]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try rw.seekTo(0);
    try writer.writeFloat(f64, 123.456);

    try rw.seekTo(0);
    try testing.expectEqual(123.456, @as(f64, @bitCast(try rw.reader().readInt(u64, test_endian))));
}

pub fn writeInt(self: *BinWriter, T: type, value: T) Error!void {
    types.checkInt(T);

    var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(std.math.ByteAlignedInt(T), &bytes, value, self.endian);
    _ = try self.write(&bytes);
}

test writeInt {
    const a = testing.allocator;
    var buff: [10]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try rw.seekTo(0);
    try writer.writeInt(u32, 123);

    try rw.seekTo(0);
    try testing.expectEqual(123, rw.reader().readInt(u32, test_endian));
}

pub fn writeOptional(self: *BinWriter, T: type, value: ?T) Error!void {
    if (value) |v| {
        try self.writeBool(true);
        try self.writeAny(T, v);
    } else {
        try self.writeBool(false);
    }
}

test writeOptional {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeOptional(u64, null);
    try writer.writeOptional(u64, 123);

    try rw.seekTo(0);
    try testing.expectEqual(0, rw.reader().readInt(u8, test_endian)); // null marker
    try testing.expectEqual(1, rw.reader().readInt(u8, test_endian)); // non-null marker
    try testing.expectEqual(123, rw.reader().readInt(u64, test_endian));
}

pub fn writeEnum(self: *BinWriter, T: type, value: T) Error!void {
    comptime types.checkEnum(T);

    if (std.meta.hasFn(T, "binWrite")) {
        return try value.binWrite(self);
    }

    const tag_type = @typeInfo(T).@"enum".tag_type;
    try self.writeInt(tag_type, @intFromEnum(value));
}

test "writeEnum" {
    const EnumType = enum(u8) { a, b };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeEnum(EnumType, .a);
    try writer.writeEnum(EnumType, .b);

    try rw.seekTo(0);
    try testing.expectEqual(0, rw.reader().readInt(u8, test_endian));
    try testing.expectEqual(1, rw.reader().readInt(u8, test_endian));
}

pub fn writeUnion(self: *BinWriter, T: type, value: T) Error!void {
    types.checkUnion(T);

    if (std.meta.hasFn(T, "binWrite")) {
        return try value.binWrite(self);
    }

    const union_info = @typeInfo(T).@"union";

    if (union_info.tag_type) |UnionTagType| {
        inline for (union_info.fields) |field| {
            const enum_value = @field(UnionTagType, field.name);
            if (@as(UnionTagType, value) == enum_value) {
                const EnumTagType = @typeInfo(UnionTagType).@"enum".tag_type;
                //@compileLog("EnumTagType IS ", EnumTagType);
                try self.writeInt(EnumTagType, @intFromEnum(enum_value));

                if (field.type != void) {
                    try self.writeAny(field.type, @field(value, field.name));
                }
                return;
            }
        }
        return error.UnexpectedData;
    } else {
        @compileError("Unable to serialize untagged union '" ++ @typeName(T) ++ "'");
    }
}
test writeUnion {
    const UnionType = union(enum(u16)) { a: u64, b: void };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeUnion(UnionType, UnionType{ .a = 123 });
    try writer.writeUnion(UnionType, .b);

    try rw.seekTo(0);
    try testing.expectEqual(0, rw.reader().readInt(u16, test_endian));
    try testing.expectEqual(123, rw.reader().readInt(u64, test_endian));
    try testing.expectEqual(1, rw.reader().readInt(u16, test_endian));
}

test "writeUnion explicit" {
    const UnionType = union(enum(u16)) {
        a: u64 = 40,
        b: void = 80,
    };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeUnion(UnionType, UnionType{ .a = 123 });
    try writer.writeUnion(UnionType, .b);

    try rw.seekTo(0);
    try testing.expectEqual(40, rw.reader().readInt(u16, test_endian));
    try testing.expectEqual(123, rw.reader().readInt(u64, test_endian));
    try testing.expectEqual(80, rw.reader().readInt(u16, test_endian));
}

pub fn writeStruct(self: *BinWriter, T: type, value: T) Error!void {
    types.checkStruct(T);

    if (std.meta.hasFn(T, "binWrite")) {
        // when the struct clares "self" with a pointer (self: *@This()), the following error occurs:
        // error: expected type '*e2e_tests.test.custom serialization.Custom', found '*const e2e_tests.test.custom serialization.Custom'
        return try value.binWrite(self);
    }
    // i am doing exactly the same as json
    // if (std.meta.hasFn(T, "jsonStringify")) {
    //     return value.jsonStringify(self);
    // }

    // std.json.stringify(value: anytype, options: StringifyOptions, out_stream: anytype)
    // std.json.innerParse(comptime T: type, allocator: Allocator, source: anytype, options: ParseOptions)
    const struct_info = @typeInfo(T).@"struct";

    if (struct_info.is_tuple) {
        inline for (0..struct_info.fields.len) |i| {
            try self.writeAny(struct_info.fields[i].type, value[i]);
        }
        return;
    }

    inline for (struct_info.fields) |field| {
        try self.writeAny(field.type, @field(value, field.name));
    }
}

test writeStruct {
    const StructT = struct { a: u64, b: i40 };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeStruct(StructT, .{ .a = 123, .b = -44 });

    try rw.seekTo(0);
    try testing.expectEqual(123, rw.reader().readInt(u64, test_endian));
    try testing.expectEqual(@as(i40, -44), rw.reader().readInt(i40, test_endian));
}

pub fn writeStructPacked(self: *BinWriter, T: type, value: T) Error!void {
    types.checkStructPacked(T);

    _ = try self.write(std.mem.asBytes(&value));

    // FIXME: this is broken
    // error: @byteSwap requires the number of bits to be evenly divisible by 8, but u6 has 6 bits

    // this is taken straight out of the std.io.Writer.zig -> writeStructEndian
    // const native_endian = @import("builtin").target.cpu.arch.endian();

    // // TODO: make sure this value is not a reference type
    // if (native_endian == self.ser_config.endian) {
    //     _ = try self.write(std.mem.asBytes(&value));
    // } else {
    //     var copy = value;
    //     std.mem.byteSwapAllFields(T, &copy);
    //     _ = try self.write(std.mem.asBytes(&copy));
    // }
}

test writeStructPacked {
    const StructT = packed struct { a: u6, b: enum(u2) { x, y, z } };

    const a = testing.allocator;
    var buff: [1]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeStructPacked(StructT, .{ .a = 10, .b = .z });

    try rw.seekTo(0);
    const res = try rw.reader().readStruct(StructT);
    try testing.expectEqual(10, res.a);
    try testing.expectEqual(.z, res.b);
}

pub fn writeArray(self: *BinWriter, T: type, value: T) Error!void {
    types.checkArray(T);

    const info = @typeInfo(T).array;
    for (value) |item| {
        try self.writeAny(info.child, item);
    }
}

test writeArray {
    const ArrayType = [2]u64;

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeArray(ArrayType, .{ 123, 80 });

    try rw.seekTo(0);
    try testing.expectEqual(123, rw.reader().readInt(u64, test_endian));
    try testing.expectEqual(80, rw.reader().readInt(u64, test_endian));
}

pub fn writeSlice(self: *BinWriter, T: type, items: []const T) Error!void {
    try self.writeInt(SliceLen, @intCast(items.len));
    for (items) |item| {
        try self.writeAny(T, item);
    }
}

test writeSlice {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    const slice = &[_]u16{ 123, 42 };
    try writer.writeSlice(u16, slice);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_endian));
    try testing.expectEqual(@as(u16, 123), rw.reader().readInt(u16, test_endian));
    try testing.expectEqual(@as(u16, 42), rw.reader().readInt(u16, test_endian));
}

pub fn writeString(self: *BinWriter, value: []const u8) Error!void {
    try self.writeSlice(u8, value);
}

test writeString {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    try writer.writeString("hello world");

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 11), rw.reader().readInt(SliceLen, test_endian));
    var str_buff: [11]u8 = undefined;
    _ = try rw.reader().readAll(&str_buff);
    try testing.expectEqualStrings("hello world", &str_buff);
}

pub fn writePointer(self: *BinWriter, T: type, value: T) Error!void {
    types.checkPointerSingle(T);
    const ChildType = @typeInfo(T).pointer.child;
    try self.writeAny(ChildType, value.*);
}

test writePointer {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    const value: u64 = 123;
    const ptr: *const u64 = &value;
    try writer.writePointer(*const u64, ptr);

    try rw.seekTo(0);
    try testing.expectEqual(@as(u64, 123), try rw.reader().readInt(u64, test_endian));
}

pub fn writeArrayList(self: *BinWriter, T: type, list: std.ArrayList(T)) Error!void {
    try self.writeSlice(T, list.items);
}
pub fn writeArrayListUnmanaged(self: *BinWriter, T: type, list: std.ArrayListUnmanaged(T)) Error!void {
    try self.writeSlice(T, list.items);
}

test writeArrayList {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    var list = std.ArrayList(u64).init(a);
    defer list.deinit();
    try list.append(100);
    try list.append(101);

    try writer.writeArrayList(u64, list);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_endian));
    try testing.expectEqual(@as(u64, 100), rw.reader().readInt(u64, test_endian));
    try testing.expectEqual(@as(u64, 101), rw.reader().readInt(u64, test_endian));
}

pub fn writeHashMapUnmanaged(self: *BinWriter, K: type, V: type, map: std.AutoHashMapUnmanaged(K, V)) Error!void {
    try self.writeInt(SliceLen, @intCast(map.count()));
    var it = map.iterator();
    while (it.next()) |entry| {
        try self.writeAny(K, entry.key_ptr.*);
        try self.writeAny(V, entry.value_ptr.*);
    }
}

pub fn writeHashMap(self: *BinWriter, K: type, V: type, map: std.AutoHashMap(K, V)) Error!void {
    try self.writeHashMapUnmanaged(K, V, map.unmanaged);
}

test writeHashMap {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null });

    var map = std.AutoHashMap(u32, u64).init(a);
    defer map.deinit();
    try map.put(1, 10);
    try map.put(2, 20);

    try writer.writeHashMap(u32, u64, map);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_endian));
    const k1 = try rw.reader().readInt(u32, test_endian);
    const v1 = try rw.reader().readInt(u64, test_endian);
    const k2 = try rw.reader().readInt(u32, test_endian);
    const v2 = try rw.reader().readInt(u64, test_endian);
    try testing.expectEqual(@as(u32, 1), k1);
    try testing.expectEqual(@as(u64, 10), v1);
    try testing.expectEqual(@as(u32, 2), k2);
    try testing.expectEqual(@as(u64, 20), v2);
}

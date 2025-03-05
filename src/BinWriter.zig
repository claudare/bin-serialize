const std = @import("std");
const testing = std.testing;
const debug = std.debug;
const AnyWriter = std.io.AnyWriter;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");

const SliceLen = config.SliceLen;
const ConfigSerialization = config.ConfigSerialization;
const WriterConfig = config.WriterConfig;
const types = @import("types.zig");

const BinWriter = @This();

const test_config = ConfigSerialization{
    .endian = .little,
};

// FIXME: AnyReader.Error is anyerror... it doesnt help at all
pub const WriterError = AnyWriter.Error || error{
    /// present when allocator is used
    OutOfMemory,
    /// a limit of max_len was reached
    EndOfStream,
};

allocator: Allocator,
underlying_writer: AnyWriter,
total_written: usize,
maybe_max_len: ?usize,
ser_config: ConfigSerialization,

pub fn init(allocator: Allocator, underlying_writer: AnyWriter, runtime_config: WriterConfig, comptime ser_config: ConfigSerialization) BinWriter {
    return .{
        .allocator = allocator,
        .underlying_writer = underlying_writer,
        .total_written = 0,
        .maybe_max_len = runtime_config.max_len,
        .ser_config = ser_config,
    };
}

/// a typed proxy of the `underlying_reader.read`
/// always use this function to read!
/// TODO: should this be inlined? or is this just bloat?
pub inline fn write(self: *BinWriter, dest: []const u8) WriterError!usize {
    const write_len = dest.len;

    if (self.maybe_max_len) |max_len| {
        if (write_len + self.total_written > max_len) {
            // TODO: use a better error name
            return error.EndOfStream;
        }
    }

    const len_written = try self.underlying_writer.write(dest);
    self.total_written += write_len;

    return len_written;
}

pub inline fn writeAny(self: *BinWriter, comptime T: type, value: T) WriterError!void {
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
        .PointerSingle => self.writePointer(T), // TODO
        .ArrayList => |Child| self.writeArrayList(Child, value),
        .ArrayListUnmanaged => |Child| self.writeArrayListUnmanaged(Child, value),
        .HashMap => |KV| self.writeHashMap(KV.K, KV.V, value),
        .HashMapUnmanaged => |KV| self.writeHashMapUnmanaged(KV.K, KV.V, value),
    };
}

/// a typed proxy of the `underlying_reader.readByte`
/// always use this function to read!
pub inline fn writeByte(self: *BinWriter, value: u8) WriterError!u8 {
    var result = [1]u8{value};
    const amt_written = try self.write(result[0..]);
    if (amt_written < 1) return error.EndOfStream;
    return result[0];
}

pub inline fn writeBool(self: *BinWriter, value: bool) WriterError!void {
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

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = 2 }, test_config);

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

pub inline fn writeFloat(self: *BinWriter, T: type, value: T) WriterError!void {
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

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try rw.seekTo(0);
    try writer.writeFloat(f64, 123.456);

    try rw.seekTo(0);
    try testing.expectEqual(123.456, @as(f64, @bitCast(try rw.reader().readInt(u64, test_config.endian))));
}

pub inline fn writeInt(self: *BinWriter, T: type, value: T) WriterError!void {
    types.checkInt(T);

    var bytes: [@divExact(@typeInfo(T).Int.bits, 8)]u8 = undefined;
    std.mem.writeInt(std.math.ByteAlignedInt(T), &bytes, value, self.ser_config.endian);
    _ = try self.write(&bytes);
}

test writeInt {
    const a = testing.allocator;
    var buff: [10]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try rw.seekTo(0);
    try writer.writeInt(u32, 123);

    try rw.seekTo(0);
    try testing.expectEqual(123, rw.reader().readInt(u32, test_config.endian));
}

pub inline fn writeOptional(self: *BinWriter, T: type, value: ?T) WriterError!void {
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

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeOptional(u64, null);
    try writer.writeOptional(u64, 123);

    try rw.seekTo(0);
    try testing.expectEqual(0, rw.reader().readInt(u8, test_config.endian)); // null marker
    try testing.expectEqual(1, rw.reader().readInt(u8, test_config.endian)); // non-null marker
    try testing.expectEqual(123, rw.reader().readInt(u64, test_config.endian));
}

pub inline fn writeEnum(self: *BinWriter, T: type, value: T) WriterError!void {
    comptime types.checkEnum(T);

    if (std.meta.hasFn(T, "serialize")) {
        return try value.serialize(self);
    }

    const tag_type = @typeInfo(T).Enum.tag_type;
    try self.writeInt(tag_type, @intFromEnum(value));
}

test "writeEnum" {
    const EnumType = enum(u8) { a, b };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeEnum(EnumType, .a);
    try writer.writeEnum(EnumType, .b);

    try rw.seekTo(0);
    try testing.expectEqual(0, rw.reader().readInt(u8, test_config.endian));
    try testing.expectEqual(1, rw.reader().readInt(u8, test_config.endian));
}

pub inline fn writeUnion(self: *BinWriter, T: type, value: T) WriterError!void {
    types.checkUnion(T);

    if (std.meta.hasFn(T, "serialize")) {
        return try value.serialize(self);
    }

    const info = @typeInfo(T).Union;

    const tag = std.meta.activeTag(value);

    // this is taken from the json serialization
    // not sure how to test for untagged union
    if (info.tag_type) |UnionTagType| {
        inline for (info.fields) |u_field| {
            if (value == @field(UnionTagType, u_field.name)) {
                try self.writeInt(@typeInfo(UnionTagType).Enum.tag_type, @intFromEnum(tag));

                if (u_field.type == void) {} else {
                    try self.writeAny(u_field.type, @field(value, u_field.name));
                }
                break;
            }
        } else {
            unreachable; // No active tag?
        }
        return;
    } else {
        @compileError("Unable to serialize untagged union '" ++ @typeName(T) ++ "'");
    }
}

test writeUnion {
    const UnionType = union(enum(u16)) { a: u64, b: void };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeUnion(UnionType, UnionType{ .a = 123 });
    try writer.writeUnion(UnionType, .b);

    try rw.seekTo(0);
    try testing.expectEqual(0, rw.reader().readInt(u16, test_config.endian));
    try testing.expectEqual(123, rw.reader().readInt(u64, test_config.endian));
    try testing.expectEqual(1, rw.reader().readInt(u16, test_config.endian));
}

pub inline fn writeStruct(self: *BinWriter, T: type, value: T) WriterError!void {
    types.checkStruct(T);

    if (std.meta.hasFn(T, "serialize")) {
        return try value.serialize(self);
    }

    const struct_info = @typeInfo(T).Struct;

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

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeStruct(StructT, .{ .a = 123, .b = -44 });

    try rw.seekTo(0);
    try testing.expectEqual(123, rw.reader().readInt(u64, test_config.endian));
    try testing.expectEqual(@as(i40, -44), rw.reader().readInt(i40, test_config.endian));
}

pub inline fn writeStructPacked(self: *BinWriter, T: type, value: T) WriterError!void {
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

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeStructPacked(StructT, .{ .a = 10, .b = .z });

    try rw.seekTo(0);
    const res = try rw.reader().readStruct(StructT);
    try testing.expectEqual(10, res.a);
    try testing.expectEqual(.z, res.b);
}

pub inline fn writeArray(self: *BinWriter, T: type, value: T) WriterError!void {
    types.checkArray(T);

    const info = @typeInfo(T).Array;
    for (value) |item| {
        try self.writeAny(info.child, item);
    }
}

test writeArray {
    const ArrayType = [2]u64;

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeArray(ArrayType, .{ 123, 80 });

    try rw.seekTo(0);
    try testing.expectEqual(123, rw.reader().readInt(u64, test_config.endian));
    try testing.expectEqual(80, rw.reader().readInt(u64, test_config.endian));
}

pub inline fn writeSlice(self: *BinWriter, T: type, items: []const T) WriterError!void {
    try self.writeInt(SliceLen, @intCast(items.len));
    for (items) |item| {
        try self.writeAny(T, item);
    }
}

test writeSlice {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    const slice = &[_]u16{ 123, 42 };
    try writer.writeSlice(u16, slice);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_config.endian));
    try testing.expectEqual(@as(u16, 123), rw.reader().readInt(u16, test_config.endian));
    try testing.expectEqual(@as(u16, 42), rw.reader().readInt(u16, test_config.endian));
}

pub inline fn writeString(self: *BinWriter, value: []const u8) WriterError!void {
    try self.writeSlice(u8, value);
}

test writeString {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    try writer.writeString("hello world");

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 11), rw.reader().readInt(SliceLen, test_config.endian));
    var str_buff: [11]u8 = undefined;
    _ = try rw.reader().readAll(&str_buff);
    try testing.expectEqualStrings("hello world", &str_buff);
}

pub inline fn writePointer(self: *BinWriter, T: type, value: T) WriterError!void {
    types.checkPointerSingle(T);
    const ChildType = @typeInfo(T).Pointer.child;
    try self.writeAny(ChildType, value.*);
}

test writePointer {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    const value: u64 = 123;
    const ptr: *const u64 = &value;
    try writer.writePointer(*const u64, ptr);

    try rw.seekTo(0);
    try testing.expectEqual(@as(u64, 123), try rw.reader().readInt(u64, test_config.endian));
}

pub inline fn writeArrayList(self: *BinWriter, T: type, list: std.ArrayList(T)) WriterError!void {
    try self.writeSlice(T, list.items);
}

test writeArrayList {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    var list = std.ArrayList(u64).init(a);
    defer list.deinit();
    try list.append(100);
    try list.append(101);

    try writer.writeArrayList(u64, list);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_config.endian));
    try testing.expectEqual(@as(u64, 100), rw.reader().readInt(u64, test_config.endian));
    try testing.expectEqual(@as(u64, 101), rw.reader().readInt(u64, test_config.endian));
}

pub inline fn writeArrayListUnmanaged(self: *BinWriter, T: type, list: std.ArrayListUnmanaged(T)) WriterError!void {
    try self.writeSlice(T, list.items);
}

test writeArrayListUnmanaged {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    var list = std.ArrayListUnmanaged(u64){};
    try list.append(a, 100);
    try list.append(a, 101);
    defer list.deinit(a);

    try writer.writeArrayListUnmanaged(u64, list);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_config.endian));
    try testing.expectEqual(@as(u64, 100), rw.reader().readInt(u64, test_config.endian));
    try testing.expectEqual(@as(u64, 101), rw.reader().readInt(u64, test_config.endian));
}

pub inline fn writeHashMapUnmanaged(self: *BinWriter, K: type, V: type, map: std.AutoHashMapUnmanaged(K, V)) WriterError!void {
    try self.writeInt(SliceLen, @intCast(map.count()));
    var it = map.iterator();
    while (it.next()) |entry| {
        try self.writeAny(K, entry.key_ptr.*);
        try self.writeAny(V, entry.value_ptr.*);
    }
}

pub inline fn writeHashMap(self: *BinWriter, K: type, V: type, map: std.AutoHashMap(K, V)) WriterError!void {
    try self.writeHashMapUnmanaged(K, V, map.unmanaged);
}

test writeHashMap {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    var writer = BinWriter.init(a, rw.writer().any(), .{ .max_len = null }, test_config);

    var map = std.AutoHashMap(u32, u64).init(a);
    defer map.deinit();
    try map.put(1, 10);
    try map.put(2, 20);

    try writer.writeHashMap(u32, u64, map);

    try rw.seekTo(0);
    try testing.expectEqual(@as(SliceLen, 2), rw.reader().readInt(SliceLen, test_config.endian));
    const k1 = try rw.reader().readInt(u32, test_config.endian);
    const v1 = try rw.reader().readInt(u64, test_config.endian);
    const k2 = try rw.reader().readInt(u32, test_config.endian);
    const v2 = try rw.reader().readInt(u64, test_config.endian);
    try testing.expectEqual(@as(u32, 1), k1);
    try testing.expectEqual(@as(u64, 10), v1);
    try testing.expectEqual(@as(u32, 2), k2);
    try testing.expectEqual(@as(u64, 20), v2);
}

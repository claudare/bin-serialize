const std = @import("std");
const testing = std.testing;
const debug = std.debug;
const AnyReader = std.io.AnyReader;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");

const SliceLen = config.SliceLen;
const ConfigSerialization = config.ConfigSerialization;
const ReaderConfig = config.ReaderConfig;
const types = @import("types.zig");

const BinReader = @This();

const test_config = ConfigSerialization{
    .endian = .little,
};

// FIXME: AnyReader.Error is anyerror... it doesnt help at all
pub const ReaderError = AnyReader.Error || error{
    /// present when allocator is used
    OutOfMemory,
    /// there was not enough len to read
    EndOfStream,
    /// not enough data was read. more should have been read according to ```RuntimeConfig.len```
    LengthMismatch,
    /// when reading we got something unexpected
    UnexpectedData,
};

allocator: Allocator,
underlying_reader: AnyReader,
bytes_remaining: usize,
ser_config: ConfigSerialization,

pub fn init(allocator: Allocator, underlying_reader: AnyReader, runtime_config: ReaderConfig, comptime ser_config: ConfigSerialization) BinReader {
    return .{
        .allocator = allocator,
        .underlying_reader = underlying_reader,
        .bytes_remaining = runtime_config.len,
        .ser_config = ser_config,
    };
}

/// a typed proxy of the `underlying_reader.read`
/// always use this function to read!
/// TODO: should this be inlined? or is this just bloat?
pub inline fn read(self: *BinReader, buffer: []u8) ReaderError!usize {
    const len_min = buffer.len;

    if (len_min > self.bytes_remaining) {
        return error.LengthMismatch;
    }
    const len_read = try self.underlying_reader.read(buffer);
    if (len_read > self.bytes_remaining) {
        // TODO: this can technically never happen??
        debug.print("undefined edge case triggered!\n", .{});
        return error.LengthMismatch;
    }
    self.bytes_remaining -= len_min;

    return len_read;
}

/// a typed proxy of the `underlying_reader.readByte`
/// always use this function to read!
pub inline fn readByte(self: *BinReader) ReaderError!u8 {
    var result: [1]u8 = undefined;
    const amt_read = try self.read(result[0..]);
    if (amt_read < 1) return error.EndOfStream;
    return result[0];
}

pub inline fn readAny(self: *BinReader, comptime T: type) ReaderError!T {
    const rich_type = types.getRichType(T);

    return switch (rich_type) {
        .Bool => self.readBool(),
        .Float => self.readFloat(T),
        .Int => self.readInt(T),
        .Optional => |Child| self.readOptional(Child),
        .Enum => self.readEnum(T),
        .Union => self.readUnion(T),
        .Struct => self.readStruct(T),
        .StructPacked => self.readStructPacked(T),
        .Array => self.readArray(T),
        .Slice => |Child| self.readSlice(Child),
        .String => self.readString(),
        .PointerSingle => self.readPointer(T),
        .ArrayList => |Child| self.readArrayList(Child),
        .ArrayListUnmanaged => |Child| self.readArrayListUnmanaged(Child),
        .HashMap => |KV| self.readHashMap(KV.K, KV.V),
        .HashMapUnmanaged => |KV| self.readHashMapUnmanaged(KV.K, KV.V),
        // else => @compileError("type " ++ @typeName(T) ++ " is not yet implemented"),
    };
}

/// inefficient way to use bool. Underlying data is aligned to u8
pub inline fn readBool(self: *BinReader) ReaderError!bool {
    const single: u8 = try self.readByte();

    if (single == 1) {
        return true;
    } else if (single == 0) {
        return false;
    } else {
        return error.UnexpectedData;
    }
}

test readBool {
    const a = testing.allocator;
    var buff: [3]u8 = .{ 0b0, 0b1, 0b1000 };
    var rw = std.io.fixedBufferStream(&buff);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 3 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(false, try reader.readBool());
    try testing.expectEqual(true, try reader.readBool());
    try testing.expectError(error.UnexpectedData, reader.readBool());
    // out of bounds check!
    try testing.expectError(error.LengthMismatch, reader.readBool());
}

pub inline fn readFloat(self: *BinReader, comptime T: type) ReaderError!T {
    types.checkFloat(T);

    const IntType = switch (@bitSizeOf(T)) {
        16 => u16,
        32 => u32,
        64 => u64,
        80 => u80,
        128 => u128,
        else => unreachable,
    };

    const int_value = try self.readInt(IntType);
    const result: T = @bitCast(int_value);

    return result;
}

test readFloat {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    const float_encoded: u64 = @bitCast(@as(f64, 123.456)); // bitcast to encode it!
    try rw.writer().writeInt(u64, float_encoded, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = @divExact(64, 8) }, test_config);

    try rw.seekTo(0);
    const res = try reader.readFloat(f64);
    try testing.expectEqual(@as(f64, 123.456), res);
}

// TODO: for now the size must be divisble by 8 exactly
pub inline fn readInt(self: *BinReader, comptime T: type) ReaderError!T {
    types.checkInt(T);

    const byte_count = @divExact(@typeInfo(T).Int.bits, 8);
    var buff: [byte_count]u8 = undefined;

    _ = try self.read(&buff);

    return std.mem.readInt(T, &buff, self.ser_config.endian);
}

test readInt {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u40, 123, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = @divExact(40, 8) }, test_config);

    try rw.seekTo(0);
    const res = try reader.readInt(u40);
    try testing.expectEqual(123, res);
}

pub inline fn readOptional(self: *BinReader, comptime T: type) ReaderError!?T {
    const has_value = try self.readBool();
    if (has_value) {
        return try self.readAny(T);
    }
    return null;
}

test readOptional {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 0, test_config.endian); // null value
    try rw.writer().writeInt(u8, 1, test_config.endian); // non-null value
    try rw.writer().writeInt(u64, 123, test_config.endian); // non-null value

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = @divExact(8 + 8 + 64, 8) }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(null, try reader.readOptional(u64));
    try testing.expectEqual(123, try reader.readOptional(u64));
}

pub inline fn readEnum(self: *BinReader, comptime T: type) ReaderError!T {
    comptime types.checkEnum(T);

    if (std.meta.hasFn(T, "deserialize")) {
        return try T.deserialize(self);
    }

    const t_info = @typeInfo(T).Enum;
    const int_value = try self.readInt(t_info.tag_type);

    if (t_info.is_exhaustive) {
        return std.meta.intToEnum(T, int_value) catch error.UnexpectedData;
    } else {
        return @enumFromInt(int_value);
    }
}

test "readEnum exhaustive" {
    const EnumType = enum(u8) { a, b };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 0, test_config.endian);
    try rw.writer().writeInt(u8, 1, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 2 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(EnumType.a, try reader.readEnum(EnumType));
    try testing.expectEqual(EnumType.b, try reader.readEnum(EnumType));
}

test "readEnum non-exhaustive" {
    const EnumType = enum(u8) { a, b, _ };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 0, test_config.endian);
    try rw.writer().writeInt(u8, 1, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 2 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(EnumType.a, try reader.readEnum(EnumType));
    try testing.expectEqual(EnumType.b, try reader.readEnum(EnumType));
}

test "readEnum with custom deserialize function" {
    const EnumType = enum(u8) {
        a,
        b,

        // oh boy, this is, in my humble opinion, a rough side of zig
        // its not possible to type it, and using anytype is very hard.
        // major refactor must be done soon, to use AnyReader interface...
        pub fn deserialize(reader: *BinReader) BinReader.ReaderError!@This() {
            const val = try reader.readByte();
            if (val == 100) {
                return .a;
            } else if (val == 101) {
                return .b;
            } else {
                return error.UnexpectedData;
            }
        }
    };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 100, test_config.endian);
    try rw.writer().writeInt(u8, 101, test_config.endian);
    try rw.writer().writeInt(u8, 42, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(EnumType.a, try reader.readEnum(EnumType));
    try testing.expectEqual(EnumType.b, try reader.readEnum(EnumType));
    try testing.expectError(error.UnexpectedData, reader.readEnum(EnumType));
}

pub inline fn readUnion(self: *BinReader, comptime T: type) ReaderError!T {
    types.checkUnion(T);

    if (std.meta.hasFn(T, "deserialize")) {
        return T.deserialize(self);
    }

    const union_info = @typeInfo(T).Union;

    const tag_type = union_info.tag_type.?; // its non-null from checkUnion

    const t_info = @typeInfo(tag_type).Enum;
    const size = t_info.tag_type;
    const int_value = try self.readInt(size);

    // TODO: this could be wrong if different order is used?
    inline for (union_info.fields, 0..) |field, i| {
        if (i == int_value) {
            if (field.type == void) {
                return @unionInit(T, field.name, {});
            } else {
                return @unionInit(T, field.name, try self.readAny(field.type));
            }
        }
    }

    return error.UnexpectedData;
}

test readUnion {
    const UnionType = union(enum(u16)) { a: u64, b: void };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u16, 0, test_config.endian); // enum tag
    try rw.writer().writeInt(u64, 123, test_config.endian); // enum value
    try rw.writer().writeInt(u16, 1, test_config.endian); // enum tag, no value
    try rw.writer().writeInt(u16, 4, test_config.endian); // bad enum tag

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(UnionType{ .a = 123 }, try reader.readUnion(UnionType));
    try testing.expectEqual(UnionType{ .b = {} }, try reader.readUnion(UnionType));
    try testing.expectError(error.UnexpectedData, reader.readUnion(UnionType));
}

pub inline fn readStruct(self: *BinReader, comptime T: type) ReaderError!T {
    types.checkStruct(T);

    if (std.meta.hasFn(T, "deserialize")) {
        return T.deserialize(self);
    }

    const struct_info = @typeInfo(T).Struct;

    if (struct_info.is_tuple) {
        var result: T = undefined;
        inline for (0..struct_info.fields.len) |i| {
            result[i] = try self.readAny(struct_info.fields[i].type);
        }
        return result;
    }

    var result: T = undefined;

    inline for (struct_info.fields) |field| {
        @field(result, field.name) = try self.readAny(field.type);
    }

    return result;
}

test "readStruct" {
    const StructT = struct { a: u64, b: i40 };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian); // a value
    try rw.writer().writeInt(i40, -44, test_config.endian); // b value

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readStruct(StructT);
    try testing.expectEqual(123, res.a);
    try testing.expectEqual(@as(i40, -44), res.b);
}
test "readStruct tuple" {
    const TupleType = std.meta.Tuple(&.{ u64, i40 });

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian); // a value
    try rw.writer().writeInt(i40, -44, test_config.endian); // b value

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readStruct(TupleType);
    try testing.expectEqual(123, res.@"0");
    try testing.expectEqual(@as(i40, -44), res.@"1");
}

/// TODO: check endianess here
/// like the writer: writeStructEndian
pub inline fn readStructPacked(self: *BinReader, comptime T: type) anyerror!T {
    types.checkStructPacked(T);

    var result: [1]T = undefined;

    // const packed_size = @divExact(@bitSizeOf(T), 8);
    _ = try self.read(std.mem.sliceAsBytes(result[0..]));
    return result[0];
}

test "struct packed" {
    const StructT = packed struct { a: u6, b: enum(u2) { x, y, z } };

    const a = testing.allocator;
    var buff: [1]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeStruct(StructT{ .a = 10, .b = .z });

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readStructPacked(StructT);
    try testing.expectEqual(10, res.a);
    try testing.expectEqual(.z, res.b);
}

pub inline fn readArray(self: *BinReader, comptime T: type) anyerror!T {
    const arrayInfo = @typeInfo(T).Array;

    var result: T = undefined;
    var i: usize = 0;
    while (i < arrayInfo.len) : (i += 1) {
        result[i] = try self.readAny(arrayInfo.child);
    }

    // this cant be used for some reason instead:
    // inline for (0..arrayInfo.len) |i| {
    //     result[i] == try self.readAny(arrayInfo.child);
    // }
    return result;
}

test readArray {
    const ArrayType = [2]u64;

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian); // a value
    try rw.writer().writeInt(u64, 80, test_config.endian); // b value

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readArray(ArrayType);
    try testing.expectEqual(2, res.len);
    try testing.expectEqual(123, res[0]);
    try testing.expectEqual(80, res[1]);
}

/// caller owns memory
/// Array will be deinitialized on failure
/// TODO: each item must be deinited automatically as well when error occurs
pub inline fn readSlice(self: *BinReader, comptime T: type) ReaderError![]T {
    var array_list = try self.readArrayListUnmanaged(T);
    return array_list.toOwnedSlice(self.allocator);
}

test readSlice {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(SliceLen, 2, test_config.endian);
    try rw.writer().writeInt(u16, 123, test_config.endian);
    try rw.writer().writeInt(u16, 42, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readSlice(u16);
    defer a.free(res);
    try testing.expectEqual(2, res.len);
    try testing.expectEqual(res[0], 123);
    try testing.expectEqual(res[1], 42);
}

/// Array will be deinitialized on failure
/// TODO: each item must be deinited automatically when error occurs
pub inline fn readArrayListUnmanaged(self: *BinReader, comptime T: type) ReaderError!std.ArrayListUnmanaged(T) {
    const len = try self.readInt(SliceLen);

    // it would be nice to calculate the maximum allowed size from the bytes remaining
    // this is only possible for single non-complex type
    // optionals and union(enum) make the calculation impossible

    var unmanaged = try std.ArrayListUnmanaged(T).initCapacity(self.allocator, len);
    errdefer unmanaged.deinit(self.allocator);

    for (0..len) |_| {
        const v = try self.readAny(T);
        unmanaged.appendAssumeCapacity(v);
    }

    return unmanaged;
}

test "readArrayListUnmanaged" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(SliceLen, 2, test_config.endian);
    try rw.writer().writeInt(u64, 100, test_config.endian);
    try rw.writer().writeInt(u64, 101, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    var res = try reader.readArrayListUnmanaged(u64);
    defer res.deinit(a);

    try testing.expectEqual(2, res.items.len);
    try testing.expectEqual(100, res.items[0]);
    try testing.expectEqual(101, res.items[1]);
}

pub inline fn readArrayList(self: *BinReader, comptime T: type) ReaderError!std.ArrayList(T) {
    var unmanaged = try self.readArrayListUnmanaged(T);
    return unmanaged.toManaged(self.allocator);
}

test "readArrayList" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(SliceLen, 2, test_config.endian);
    try rw.writer().writeInt(u64, 100, test_config.endian);
    try rw.writer().writeInt(u64, 101, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    var res = try reader.readArrayList(u64);
    defer res.deinit();

    try testing.expectEqual(2, res.items.len);
    try testing.expectEqual(100, res.items[0]);
    try testing.expectEqual(101, res.items[1]);
}

pub inline fn readString(self: *BinReader) ReaderError![]const u8 {
    const len = try self.readInt(SliceLen);

    var list = try std.ArrayList(u8).initCapacity(self.allocator, len);
    errdefer list.deinit();

    var read_bytes: u32 = 0;

    while (read_bytes < len) : (read_bytes += 1) {
        const v = try self.readByte();
        list.appendAssumeCapacity(v);
    }

    return list.toOwnedSlice();
}

test readString {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(SliceLen, 11, test_config.endian);
    _ = try rw.writer().write("hello world");

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readString();
    defer a.free(res);
    try testing.expectEqualStrings("hello world", res);
}

/// Reads a pointer and returns a pointer
/// Type T MUST be a pointer type, and it returns a pointer too
pub inline fn readPointer(self: *BinReader, comptime T: type) ReaderError!T {
    types.checkPointerSingle(T);

    // FIXME: this is broken...
    const ChildType = @typeInfo(T).Pointer.child;

    const result: *ChildType = try self.allocator.create(ChildType);
    result.* = try self.readAny(ChildType);
    return result;
}

test readPointer {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    const res = try reader.readPointer(*u64);
    defer a.destroy(res);

    try testing.expectEqual(@as(u64, 123), res.*);
}

pub inline fn readHashMapUnmanaged(self: *BinReader, comptime K: type, comptime V: type) ReaderError!std.AutoHashMapUnmanaged(K, V) {
    // or it gives me a hashmap and I append to it!
    // TODO: check for presence of unmanaged: Unmanaged on it. If unmanaged exists, that means the underlying structure is managed
    const len = try self.readInt(SliceLen);

    var unmanaged = std.AutoHashMapUnmanaged(K, V){};
    try unmanaged.ensureUnusedCapacity(self.allocator, len);
    // TODO: also need to deinit each value when error appears!
    // should this look for free() or deinit()? if so, presence or absence of an allocator must be detected
    // this is turning into an automagical solution, which is conventient, but its not zig!
    errdefer unmanaged.deinit(self.allocator);

    for (0..len) |_| {
        const k = try self.readAny(K);
        const v = try self.readAny(V);

        // TODO: check if NoClobber is safe
        // maybe with a config option?
        // maybe expose this here?
        unmanaged.putAssumeCapacityNoClobber(k, v);
    }

    return unmanaged;
}

test "readHashmapUnmanaged" {
    //const T = std.AutoHashMapUnmanaged(u32, u64);

    const a = testing.allocator;

    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(SliceLen, 2, test_config.endian);
    try rw.writer().writeInt(u32, 1, test_config.endian);
    try rw.writer().writeInt(u64, 10, test_config.endian);
    try rw.writer().writeInt(u32, 2, test_config.endian);
    try rw.writer().writeInt(u64, 20, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    var res = try reader.readHashMapUnmanaged(u32, u64);
    defer res.deinit(a);

    try testing.expectEqual(2, res.count());
    try testing.expectEqual(10, res.get(1).?);
    try testing.expectEqual(20, res.get(2).?);
}

/// Will return an autohashmap
/// TODO: special case must be taken when string is the key!
/// Note: this assumes that there are no duplicate keys!
pub inline fn readHashMap(self: *BinReader, comptime K: type, comptime V: type) ReaderError!std.AutoHashMap(K, V) {
    const unmanaged = try self.readHashMapUnmanaged(K, V);
    return unmanaged.promote(self.allocator);
}

test "readHashmap" {
    //const T = std.AutoHashMap(u32, u64);

    const a = testing.allocator;

    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(SliceLen, 2, test_config.endian);
    try rw.writer().writeInt(u32, 1, test_config.endian);
    try rw.writer().writeInt(u64, 10, test_config.endian);
    try rw.writer().writeInt(u32, 2, test_config.endian);
    try rw.writer().writeInt(u64, 20, test_config.endian);

    var reader = BinReader.init(a, rw.reader().any(), .{ .len = 100 }, test_config);

    try rw.seekTo(0);
    var res = try reader.readHashMap(u32, u64);
    defer res.deinit();

    try testing.expectEqual(2, res.count());
    try testing.expectEqual(10, res.get(1).?);
    try testing.expectEqual(20, res.get(2).?);
}

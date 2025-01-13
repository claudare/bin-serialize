const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const debug = std.debug;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");

pub const RuntimeConfig = struct {
    /// Provide the length of the data to be read
    /// Errors will be thrown if the serialized data data is too short or too long
    len: usize,
};

pub const SerializationConfig = struct {
    endian: std.builtin.Endian = .big,
    SliceLenType: type = u32, // limits srting size to 65k, which is a lot!
};

// custom errors
pub const DeserializeError = error{
    /// there was not enough len to read
    EndOfStream,
    /// not enough data was read. more should have been read according to ```RuntimeConfig.len```
    LengthMismatch,
    /// when reading we got something unexpected
    UnexpectedData,
};

pub fn BinReader(comptime ReaderType: type, comptime ser_config: SerializationConfig) type {
    return struct {
        allocator: Allocator,
        underlying_reader: ReaderType,
        bytes_remaining: usize,

        pub const Error = ReaderType.Error || DeserializeError;

        const Self = @This();

        /// a typed proxy of the `underlying_reader.read`
        /// always use this function to read!
        /// TODO: should this be inlined? or is this just bloat?
        pub inline fn read(self: *Self, dest: []u8) Error!usize {
            const len_min = dest.len;

            if (len_min > self.bytes_remaining) {
                return error.LengthMismatch;
            }
            const len_read = try self.underlying_reader.read(dest);
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
        pub inline fn readByte(self: *Self) Error!u8 {
            var result: [1]u8 = undefined;
            const amt_read = try self.read(result[0..]);
            if (amt_read < 1) return error.EndOfStream;
            return result[0];
        }

        // using std.json innerParse as an example for this implementation
        pub inline fn readAny(self: *Self, comptime T: type) Error!T {
            const rich_type = types.getRichType(T);

            return switch (rich_type) {
                .Bool => self.readBool(),
                .Float => self.readFloat(T),
                .Int => self.readInt(T),
                .Optional => |T2| self.readOptional(T2),
                .Enum => self.readEnum(T),
                .Union => self.readUnion(T),
                .Struct => self.readStruct(T),
                .StructPacked => self.readStructPacked(T),
                .Array => self.readArray(T),
                .Slice => |T2| self.readSlice(T2),
                .String => self.readString(),
                .PointerSingle => self.readPointer(T),
                .ArrayList => |T2| self.readArrayList(T2),
                .ArrayListUnmanaged => |T2| self.readArrayListUnmanaged(T2),
                .HashMap => |KV| self.readHashMap(KV.K, KV.V),
                .HashMapUnmanaged => |KV| self.readHashMapUnmanaged(KV.K, KV.V),
                // else => @compileError("type " ++ @typeName(T) ++ " is not yet implemented"),
            };
        }

        /// inefficient way to use bool. Underlying data is aligned to u8
        pub inline fn readBool(self: *Self) Error!bool {
            const single: u8 = try self.readByte();

            if (single == 1) {
                return true;
            } else if (single == 0) {
                return false;
            } else {
                return error.UnexpectedData;
            }
        }

        pub inline fn readFloat(self: *Self, comptime T: type) Error!T {
            types.checkFloat(T);

            const IntType = switch (@bitSizeOf(T)) {
                32 => u32,
                64 => u64,
                128 => u128,
                else => unreachable,
            };

            const int_value = try self.readInt(IntType);
            const result: T = @bitCast(int_value);

            return result;
        }

        // TODO: for now the size must be divisble by 8 exactly
        pub inline fn readInt(self: *Self, comptime T: type) Error!T {
            types.checkInt(T);

            const byte_count = @divExact(@typeInfo(T).Int.bits, 8);
            var buff: [byte_count]u8 = undefined;

            _ = try self.read(&buff);

            return mem.readInt(T, &buff, ser_config.endian);
        }

        /// This reads an optional value (nullable one)
        /// nullable values save first u8 as a bool. if its 0, it means that value is null
        /// since its saving it as bool, this is technically inefficient
        pub inline fn readOptional(self: *Self, comptime T: type) Error!?T {
            // types.checkOptional(T);

            const has_value = try self.readBool();
            if (has_value) {
                return try self.readAny(T);
            }
            return null;
        }

        pub inline fn readEnum(self: *Self, comptime T: type) Error!T {
            types.checkEnum(T);

            // ohh snap, this is not possible as this type of generic cant be typed on the struct
            // therefore anytype is required, but that defeats the whole purpose of this lib!
            if (std.meta.hasFn(T, "deserialize")) {
                return T.deserialize(self.allocator, self);
            }

            const t_info = @typeInfo(T).Enum;
            const int_value = try self.readInt(t_info.tag_type);

            if (t_info.is_exhaustive) {
                return std.meta.intToEnum(T, int_value) catch error.UnexpectedData;
            } else {
                return @enumFromInt(int_value);
            }
        }

        pub inline fn readUnion(self: *Self, comptime T: type) anyerror!T {
            types.checkUnion(T);

            // TODO: this is a wrong name
            if (std.meta.hasFn(T, "serialize")) {
                return T.serialize(self.allocator, self);
            }

            const unionInfo = @typeInfo(T).Union;
            // this check is done internally
            // if (unionInfo.tag_type == null) @compileError("Unable to parse into untagged union '" ++ @typeName(T) ++ "'");

            // read the field, its the size of the union, must be explicitly defined
            const tag_type = unionInfo.tag_type.?;

            const enumInfo = @typeInfo(tag_type).Enum;
            const size = enumInfo.tag_type;
            const int_value = try self.readInt(size);

            inline for (unionInfo.fields, 0..) |field, i| {
                if (i == int_value) {
                    if (field.type == void) {
                        return @unionInit(T, field.name, {});
                    } else {
                        return @unionInit(T, field.name, try self.readAny(field.type));
                    }
                }
            }

            return error.UnknownFieldId;
        }

        pub inline fn readStruct(self: *Self, comptime T: type) anyerror!T {
            types.checkStruct(T);

            if (std.meta.hasFn(T, "serialize")) {
                return T.serialize(self.allocator, self); // no need to pass the allocator
            }

            const structInfo = @typeInfo(T).Struct;

            if (structInfo.is_tuple) {
                // this is like a slice! TODO: TEST ME
                var r: T = undefined;
                inline for (0..structInfo.fields.len) |i| {
                    r[i] = try self.readAny(structInfo.fields[i].type);
                }
                return r;
            }

            var result: T = undefined;

            // no default values are allowed!
            // all must exist
            inline for (structInfo.fields) |field| {
                @field(result, field.name) = try self.readAny(field.type);
            }

            return result;
        }

        /// TODO: check endianess here
        /// like the writer: writeStructEndian
        pub inline fn readStructPacked(self: *Self, comptime T: type) anyerror!T {
            types.checkStructPacked(T);

            var res: [1]T = undefined;

            // const packed_size = @divExact(@bitSizeOf(T), 8);
            _ = try self.read(mem.sliceAsBytes(res[0..]));
            return res[0];
        }

        /// This is for reading of the arrays with fixed sizes
        /// pretty rare! for dynamic slices, use ArrayList
        pub inline fn readArray(self: *Self, comptime T: type) anyerror!T {
            //
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

        // this a single pointer!
        pub inline fn readPointer(self: *Self, comptime T: type) anyerror!T {
            types.checkPointerSingle(T);

            const ChildType = @typeInfo(T).Pointer.child;

            const result: *ChildType = try self.allocator.create(ChildType);
            result.* = try self.readAny(ChildType);
            return result;
        }

        /// this will cause an allocation or arbitrary size, limited by config
        /// the allocated memory should be shared. Maximum length is fixed and initialized at startup
        /// so that the Reader now becomes stateful!
        /// but max len per field is enforced
        pub inline fn readString(self: *Self) anyerror![]const u8 {
            const len = try self.readInt(ser_config.SliceLenType);

            // TODO: check length

            var list = try std.ArrayList(u8).initCapacity(self.allocator, len);
            errdefer list.deinit();

            var read_bytes: u32 = 0;

            while (read_bytes < len) : (read_bytes += 1) {
                const v = self.underlying_reader.readByte() catch {
                    return error.DataIsTooShort;
                };
                list.appendAssumeCapacity(v);
            }

            return list.toOwnedSlice();
        }

        /// caller owns memory
        /// TODO: each item be deinited as well when error occurs
        pub inline fn readSlice(self: *Self, comptime T: type) anyerror![]T {
            var array_list = try self.readArrayListUnmanaged(T);
            return array_list.toOwnedSlice();
        }

        pub inline fn readArrayListUnmanaged(self: *Self, comptime TItem: type) anyerror!std.ArrayListUnmanaged(TItem) {
            const len = try self.readInt(ser_config.SliceLenType);
            // what if I want unmanaged?
            var unmanaged = try std.ArrayListUnmanaged(TItem).initCapacity(self.allocator, len);
            errdefer unmanaged.deinit(self.allocator);

            for (0..len) |_| {
                const v = try self.readAny(TItem);
                unmanaged.appendAssumeCapacity(v);
            }

            return unmanaged;
        }
        /// This is a public function which the developer uses when manually encoding
        /// this takes in a type of item, but then we loose the ability to construct it
        /// upto the specifications
        pub inline fn readArrayList(self: *Self, comptime TItem: type) anyerror!std.ArrayList(TItem) {
            var unmanaged = try self.readArrayListUnmanaged(TItem);
            return unmanaged.toManaged(self.allocator);
        }

        pub inline fn readHashMapUnmanaged(self: *Self, comptime K: type, comptime V: type) anyerror!std.AutoHashMapUnmanaged(K, V) {
            // or it gives me a hashmap and I append to it!
            // TODO: check for presence of unmanaged: Unmanaged on it. If unmanaged exists, that means the underlying structure is managed
            const len = try self.readInt(ser_config.SliceLenType);

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
                unmanaged.putAssumeCapacityNoClobber(k, v);
            }

            return unmanaged;
        }
        /// Will return an autohashmap
        /// TODO: special case must be taken when string is the key!
        /// Note: this assumes that there are no duplicate keys!
        pub inline fn readHashMap(self: *Self, comptime K: type, comptime V: type) anyerror!std.AutoHashMap(K, V) {
            const unmanaged = try self.readHashMapUnmanaged(K, V);
            return unmanaged.promote(self.allocator);
        }
    };
}

/// must be initialized like limited reader.
/// zig's type system limitation is a good example for this!
/// no other way to instantiate this otherwise...
pub fn binReader(
    allocator: Allocator,
    underlying_reader: anytype,
    runtime_config: RuntimeConfig,
    serialization_config: SerializationConfig,
) BinReader(@TypeOf(underlying_reader), serialization_config) {
    return .{
        .allocator = allocator,
        .underlying_reader = underlying_reader,
        .bytes_remaining = runtime_config.len,
    };
}

const test_config = SerializationConfig{
    .endian = .big,
    .SliceLenType = u16,
};

test "bool" {
    const a = testing.allocator;
    var buff: [3]u8 = .{ 0b0, 0b1, 0b1000 };
    var rw = std.io.fixedBufferStream(&buff);

    var reader = binReader(a, rw.reader(), .{ .len = 3 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(false, try reader.readBool());
    try testing.expectEqual(true, try reader.readBool());
    try testing.expectError(error.UnexpectedData, reader.readBool());
    // out of bounds check!
    try testing.expectError(error.LengthMismatch, reader.readBool());
}

test "float" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    const float_encoded: u64 = @bitCast(@as(f64, 123.456)); // bitcast to encode it!
    try rw.writer().writeInt(u64, float_encoded, test_config.endian);

    var reader = binReader(a, rw.reader(), .{ .len = @divExact(64, 8) }, test_config);

    try rw.seekTo(0);
    const res = try reader.readFloat(f64);
    try testing.expectEqual(@as(f64, 123.456), res);
}

test "int" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u40, 123, test_config.endian);

    var reader = binReader(a, rw.reader(), .{ .len = @divExact(40, 8) }, test_config);

    try rw.seekTo(0);
    const res = try reader.readInt(u40);
    try testing.expectEqual(123, res);
}

test "optional" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 0, test_config.endian); // null value
    try rw.writer().writeInt(u8, 1, test_config.endian); // non-null value
    try rw.writer().writeInt(u64, 123, test_config.endian); // non-null value

    var reader = binReader(a, rw.reader(), .{ .len = @divExact(8 + 8 + 64, 8) }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(null, try reader.readOptional(u64));
    try testing.expectEqual(123, try reader.readOptional(u64));
}

test "enum exhaustive" {
    const EnumType = enum(u8) { a, b };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 0, test_config.endian);
    try rw.writer().writeInt(u8, 1, test_config.endian);

    var reader = binReader(a, rw.reader(), .{ .len = 2 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(EnumType.a, try reader.readEnum(EnumType));
    try testing.expectEqual(EnumType.b, try reader.readEnum(EnumType));
}

test "enum non-exhaustive" {
    const EnumType = enum(u8) { a, b, _ };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u8, 0, test_config.endian);
    try rw.writer().writeInt(u8, 1, test_config.endian);

    var reader = binReader(a, rw.reader(), .{ .len = 2 }, test_config);

    try rw.seekTo(0);
    try testing.expectEqual(EnumType.a, try reader.readEnum(EnumType));
    try testing.expectEqual(EnumType.b, try reader.readEnum(EnumType));
}

test "union" {
    const UnionType = union(enum(u16)) { a: u64, b: ?u32, c: void };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u16, 0, test_config.endian); // enum tag
    try rw.writer().writeInt(u64, 123, test_config.endian); // enum value

    try rw.writer().writeInt(u16, 1, test_config.endian); // enum tag
    try rw.writer().writeInt(u8, 1, test_config.endian); // optional of value
    try rw.writer().writeInt(u32, 456, test_config.endian); // value

    try rw.writer().writeInt(u16, 2, test_config.endian);

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        try testing.expectEqual(UnionType{ .a = 123 }, try reader.readUnion(UnionType));
        try testing.expectEqual(UnionType{ .b = 456 }, try reader.readUnion(UnionType));
        try testing.expectEqual(UnionType{ .c = {} }, try reader.readUnion(UnionType));
    }

    {
        try rw.seekTo(0);
        try testing.expectEqual(UnionType{ .a = 123 }, try reader.readAny(UnionType));
        try testing.expectEqual(UnionType{ .b = 456 }, try reader.readAny(UnionType));
        try testing.expectEqual(UnionType{ .c = {} }, try reader.readAny(UnionType));
    }
}

test "struct" {
    const StructT = struct { a: u64, b: i40 };

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian); // a value
    try rw.writer().writeInt(i40, -44, test_config.endian); // b value

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        const res = try reader.readStruct(StructT);
        try testing.expectEqual(123, res.a);
        try testing.expectEqual(@as(i40, -44), res.b);
    }

    {
        try rw.seekTo(0);
        const res = try reader.readAny(StructT);
        try testing.expectEqual(123, res.a);
        try testing.expectEqual(@as(i40, -44), res.b);
    }
}

test "struct packed" {
    const StructT = packed struct { a: u6, b: enum(u2) { x, y, z } };

    const a = testing.allocator;
    var buff: [1]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeStruct(StructT{ .a = 10, .b = .z });

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        const res = try reader.readStructPacked(StructT);
        try testing.expectEqual(10, res.a);
        try testing.expectEqual(.z, res.b);
    }

    {
        try rw.seekTo(0);
        const res = try reader.readAny(StructT);
        try testing.expectEqual(10, res.a);
        try testing.expectEqual(.z, res.b);
    }
}

test "array" {
    const ArrayT = [2]u64;

    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian); // a value
    try rw.writer().writeInt(u64, 80, test_config.endian); // b value

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        const res = try reader.readArray(ArrayT);
        try testing.expectEqual(2, res.len);
        try testing.expectEqual(123, res[0]);
        try testing.expectEqual(80, res[1]);
    }

    {
        try rw.seekTo(0);
        const res = try reader.readAny(ArrayT);
        try testing.expectEqual(2, res.len);
        try testing.expectEqual(123, res[0]);
        try testing.expectEqual(80, res[1]);
    }
}

test "string" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(test_config.SliceLenType, 11, test_config.endian);
    _ = try rw.writer().write("hello world");

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        const res = try reader.readString();
        defer a.free(res);
        try testing.expectEqualStrings("hello world", res);
    }
}

// TODO!!!
// test "string any detection" {
//     const a = testing.allocator;

//     var buff: [100]u8 = undefined;
//     var rw = std.io.fixedBufferStream(&buff);

//     try rw.writer().writeInt(test_config.StrLenType, 11, .big);
//     _ = try rw.writer().write("hello world");

//     var reader = binReader(a, rw.reader(), .{});

//     {
//         try rw.seekTo(0);
//         const res = try reader.readAny([]const u8);
//         defer a.free(res);

//         try testing.expectEqualStrings("hello world", res);
//     }

//     {
//         // this case runs slowly as each u8 here is read as a number, with endian conversions...
//         try rw.seekTo(0);
//         const res = try reader.readAny([]u8);
//         defer a.free(res);

//         try testing.expectEqualStrings("hello world", res);
//     }
// }

test "pointer" {
    const a = testing.allocator;
    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(u64, 123, test_config.endian);

    var reader = binReader(a, rw.reader(), test_config);

    {
        const OuterT = struct { a: *struct { b: u64 } };

        try rw.seekTo(0);
        const res = try reader.readAny(OuterT);
        defer a.destroy(res.a); // CAREFUL: pointers need to be cleaned up ?!!

        try testing.expectEqual(@as(u64, 123), res.a.b);
    }

    {
        try rw.seekTo(0);
        const res = try reader.readPointer(*u64);
        defer a.destroy(res);

        try testing.expectEqual(@as(u64, 123), res.*);
    }
}

test "arraylist" {
    const T = struct {
        arrayList: std.ArrayList(u64),
        arrayListUnmanaged: std.ArrayListUnmanaged(u64),
    };

    // lets encode it manually...
    const a = testing.allocator;

    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    try rw.writer().writeInt(test_config.SliceLenType, 2, test_config.endian);
    try rw.writer().writeInt(u64, 100, test_config.endian);
    try rw.writer().writeInt(u64, 101, test_config.endian);

    try rw.writer().writeInt(test_config.SliceLenType, 2, test_config.endian);
    try rw.writer().writeInt(u64, 200, test_config.endian);
    try rw.writer().writeInt(u64, 201, test_config.endian);

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        var res = try reader.readAny(T);
        defer res.arrayList.deinit();
        defer res.arrayListUnmanaged.deinit(a);

        try testing.expectEqual(2, res.arrayList.items.len);
        try testing.expectEqual(100, res.arrayList.items[0]);
        try testing.expectEqual(101, res.arrayList.items[1]);

        try testing.expectEqual(2, res.arrayListUnmanaged.items.len);
        try testing.expectEqual(200, res.arrayListUnmanaged.items[0]);
        try testing.expectEqual(201, res.arrayListUnmanaged.items[1]);
    }

    {
        try rw.seekTo(0);
        var res = try reader.readArrayList(u64);
        defer res.deinit();

        try testing.expectEqual(2, res.items.len);
        try testing.expectEqual(100, res.items[0]);
        try testing.expectEqual(101, res.items[1]);
    }

    {
        try rw.seekTo(0);
        var res = try reader.readArrayListUnmanaged(u64);
        defer res.deinit(a);

        try testing.expectEqual(2, res.items.len);
        try testing.expectEqual(100, res.items[0]);
        try testing.expectEqual(101, res.items[1]);
    }
}

test "hashmap" {
    const T = struct {
        managed: std.AutoHashMap(u32, u64),
        unmanaged: std.AutoHashMapUnmanaged(u32, u64),
    };

    // lets encode it manually...
    const a = testing.allocator;

    var buff: [100]u8 = undefined;
    var rw = std.io.fixedBufferStream(&buff);

    for (0..2) |_| {
        try rw.writer().writeInt(test_config.SliceLenType, 2, test_config.endian);
        try rw.writer().writeInt(u32, 1, test_config.endian);
        try rw.writer().writeInt(u64, 10, test_config.endian);
        try rw.writer().writeInt(u32, 2, test_config.endian);
        try rw.writer().writeInt(u64, 20, test_config.endian);
    }

    var reader = binReader(a, rw.reader(), test_config);

    {
        try rw.seekTo(0);
        var res = try reader.readHashMap(u32, u64);
        defer res.deinit();

        try testing.expectEqual(2, res.count());
        try testing.expectEqual(10, res.get(1).?);
        try testing.expectEqual(20, res.get(2).?);
    }

    {
        try rw.seekTo(0);
        var res = try reader.readHashMapUnmanaged(u32, u64);
        defer res.deinit(a);

        try testing.expectEqual(2, res.count());
        try testing.expectEqual(10, res.get(1).?);
        try testing.expectEqual(20, res.get(2).?);
    }

    {
        try rw.seekTo(0);
        var res = try reader.readAny(T);
        defer res.managed.deinit();
        defer res.unmanaged.deinit(a);

        try testing.expectEqual(2, res.managed.count());
        try testing.expectEqual(10, res.managed.get(1).?);
        try testing.expectEqual(20, res.managed.get(2).?);

        try testing.expectEqual(2, res.unmanaged.count());
        try testing.expectEqual(10, res.unmanaged.get(1).?);
        try testing.expectEqual(20, res.unmanaged.get(2).?);
    }
}

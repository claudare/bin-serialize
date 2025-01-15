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

const test_config = config.test_config;

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
pub inline fn write(self: *BinWriter, dest: []u8) WriterError!usize {
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

const std = @import("std");
const testing = std.testing;
const config = @import("config.zig");

// library exports
pub const ConfigSerialization = config.ConfigSerialization;
pub const SliceLen = config.SliceLen;

// reader
pub const BinReader = @import("BinReader.zig");
pub const ReaderConfig = config.ReaderConfig;
pub const ReaderError = BinReader.ReaderError;

// writer
pub const BinWriter = @import("BinWriter.zig");
pub const WriterConfig = config.WriterConfig;
pub const WriterError = BinWriter.WriterError;

test {
    _ = @import("BinReader.zig");
    _ = @import("BinWriter.zig");
    _ = @import("types.zig");
}

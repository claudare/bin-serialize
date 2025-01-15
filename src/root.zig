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

test {
    _ = @import("BinReader.zig");
    _ = @import("types.zig");
}

const std = @import("std");

// Zig build system does not allow passing "type" into library options
// therefore its hardcoded to u32
pub const SliceLen = u32;

/// configuration for initializing BinReader and BinWriter
/// sane defaults are provided
pub const ConfigSerialization = struct {
    endian: std.builtin.Endian = .big,
};

pub const ReaderConfig = struct {
    /// Provide the length of the data to be read
    /// Errors will be thrown if the serialized data data is too short or too long
    len: usize,
};

pub const WriterConfig = struct {
    /// Provide the maximum length to be written
    /// Default to null: write length can be infinite
    max_len: ?usize = null,
};

pub const test_config = ConfigSerialization{
    .endian = .big,
};

const std = @import("std");

// Zig build system does not allow passing "type" into library options
// Therefore, its impossible for library consumers to choose length size encoding,
// Even at build time in their `build.zig`.
// Because of this, its hardcoded to u32 for "automatic encodings"
// Library user can manually specify the size when manually serializing/deserializing
pub const SliceLen = u32;

/// configuration for initializing BinReader and BinWriter
/// sane defaults are provided
/// TODO: maybe merge this into the reader and writer config
pub const ConfigSerialization = struct {
    endian: std.builtin.Endian = .little,
};

pub const ReaderConfig = struct {
    /// Provide the length of the data to be read
    /// bin-serialize will make sure that data outside the defined range wont be read
    /// Reading too little must be checked manually
    len: usize,
};

pub const WriterConfig = struct {
    /// Provide the maximum length to be written
    /// Default to null: write length can be infinite
    max_len: ?usize = null,
};

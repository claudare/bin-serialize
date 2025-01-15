const std = @import("std");

pub const ConfigRuntime = struct {
    /// Provide the length of the data to be read
    /// Errors will be thrown if the serialized data data is too short or too long
    len: usize,
};

// Zig build system does not allow passing "type" into library options
// therefore its hardcoded to u32
pub const SliceLen = u32;

// these must be placed inside the configuration of the library, so they are defined at build time
// and that is a requirement just because the "type" used in encoding slices must be compiletime known...
pub const ConfigSerialization = struct {
    endian: std.builtin.Endian = .big,
};

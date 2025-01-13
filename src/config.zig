const std = @import("std");

pub const ConfigRuntime = struct {
    /// Provide the length of the data to be read
    /// Errors will be thrown if the serialized data data is too short or too long
    len: usize,
};

pub const ConfigSerialization = struct {
    endian: std.builtin.Endian = .big,
    slice_len_bitsize: u16 = 32, // by default u32 is used to serialize arrays

    pub fn SliceLenType(self: ConfigSerialization) type {
        // temprary check for now

        if (@rem(self.sliceLenSize, 8) != 0) {
            @compileError("slice encoding type must be divisible by 8. Instead got " ++ self.sliceLenSize());
        }

        return comptime @Type(.{
            .Int = .{
                .bits = self.sliceLenSize,
                .signedness = .unsigned,
            },
        });
    }
};

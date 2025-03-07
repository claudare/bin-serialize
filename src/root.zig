const std = @import("std");
const testing = std.testing;

// Zig build system does not allow passing "type" into library options
// Therefore, its impossible for library consumers to choose length size encoding,
// Even at build time in their `build.zig`.
// Because of this, its hardcoded to u32 for "automatic encodings"
// Library user, in the future, could manually specify the size when manually serializing/deserializing
// soon im going to try to override this?
// https://ziggit.dev/t/why-use-import-root/6749
pub const DefaultSliceLen = u32;

pub const BinReader = @import("BinReader.zig");
pub const BinWriter = @import("BinWriter.zig");

test {
    _ = @import("BinReader.zig");
    _ = @import("BinWriter.zig");
    _ = @import("e2e_tests.zig");

    _ = @import("types.zig");
}

# bin-serialize/

A zig serailization library which allows for simple automatic and custom serialization to readers/writers. Currently, the encoding is not super efficient or performant. Will improve in the future.

The following types are currently supported: Bool, Float, Int, Optional, Enum, Union, Struct, StructPacked, Array, Slice, ArrayList, ArrayListUnmanaged, String, Pointer, AutoHashMap, AutoHashMapUnmanaged.

This library will follow the latest stable version. Currently `0.14.0` is supported.

# Installation

Fetch it via

```bash
# specific version
zig fetch --save https://github.com/claudare/bin-serialize/archive/refs/tags/{VERSION_TAG}.tar.gz
# or use latest main branch
zig fetch --save https://github.com/claudare/bin-serialize/archive/refs/heads/main.tar.gz
```

Now add to your `build.zig`

```zig
const binser = b.dependency("bin-serialize", .{});
exe.root_module.addImport("bin-serialize", binser.module("bin-serialize"));
```

# Usage

... TODO...

## Allocator-less serialization

TODO: Figure out how to do this without an actual allocator

## Custom serialization functions

implement 2 functions:
```zig
pub fn binWrite(self: *const @This(), writer: *BinWriter) BinWriter.Error!void {
    // allocator can be accessed via writer.allocator
    try writer.writeInt(u8, self.value);
    ...
}

pub fn binRead(reader: *BinReader) BinReader.Error!@This() {
    // allocator can be accessed via reader.allocator
    const value = try reader.readInt(u8)
    ...
    return .{ .value = value };
}
```

# Limitations

`usize` and `isize` integer types are not supported. Instead use concrete sizes divisible by 8.

If non-8 sizes need serialization, then manually serialize them as `packed structs` with `writePackedStruct` and `readPackedStruct`.

All the sizes of unions and enums must be divisible by 8. For example, `const MyEnum = enum { a = void, b = u64, c = [2]u8 }`, will not compile: `error: int type u2 must be divisible by 8`. In order to fix this, make sure the tag types are in fractions of 8 (`enum(u8)`).

<!-- # ideas
[] continious writer/reader. Provide a union to reader or writer and it would serialize events into a steam. Really good for one-way messaging protocols.
[] continious rpc. Provide reader and writer on Client and Server. Provide enum for both exgress (Server to Client) and ingress (Client to Server). Good for realtime applications. -->

# TODOs
 - support no-allocator operation (for when no dynamic structures are used)
 - cleanup memory when allocator-specific functions error. This will require a custom deinit function "binFree(allocator: Allocator)"
 - reading tuples

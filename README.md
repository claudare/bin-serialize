# bin-serailize

A zig serailization library which allows for simple automatic and custom serialization to readers/writers. Currently, the encoding is not super efficient or performant. Will improve in the future.

The following types are currently supported: Bool, Float, Int, Optional, Enum, Union, Struct, StructPacked, Array, Slice, ArrayList, ArrayListUnmanaged, String, Pointer, AutoHashMap, AutoHashMapUnmanaged.

This library will follow the latest stable version. Currently `0.13.0` is supported.

# installation

Fetch it via

```bash
# specific version (TODO, this does not exist yet)
zig fetch --save https://github.com/claudare/bin-serialize/archive/refs/tags/0.0.1.tar.gz
# or main branch
zig fetch --save https://github.com/claudare/bin-serialize/archive/refs/heads/main.tar.gz
```

Now add to your `build.zig`

```zig
const binser = b.dependency("bin-serialize", .{});
exe.root_module.addImport("bin-serialize", binser.module("bin-serialize"));
```

# ideas
[] continious writer/reader. Provide a union to reader or writer and it would serialize events into a steam. Really good for one-way messaging protocols.
[] continious rpc. Provide reader and writer on Client and Server. Provide enum for both exgress (Server to Client) and ingress (Client to Server). Good for realtime applications.

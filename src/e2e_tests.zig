const std = @import("std");
const testing = std.testing;
const BinReader = @import("BinReader.zig");
const BinWriter = @import("BinWriter.zig");
const config = @import("config.zig");

const test_config = config.ConfigSerialization{
    .endian = .little,
};

fn testRoundTrip(test_allocator: std.mem.Allocator, value: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(test_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var buff: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buff);

    // Write
    var writer = BinWriter.init(allocator, fbs.writer().any(), .{}, test_config);
    try writer.writeAny(@TypeOf(value), value);

    // Read
    try fbs.seekTo(0);
    var reader = BinReader.init(allocator, fbs.reader().any(), .{ .len = writer.total_written }, test_config);
    const result = try reader.readAny(@TypeOf(value));

    // special case for slice comparison
    switch (@typeInfo(@TypeOf(value))) {
        .Pointer => |info| switch (info.size) {
            .Slice => {
                try testing.expectEqualSlices(info.child, value, result);
                return;
            },
            else => {},
        },
        else => {},
    }

    try testing.expectEqual(value, result);
}

test "e2e: primitive types" {
    const a = testing.allocator;

    // Integers
    try testRoundTrip(a, @as(u8, 123));
    try testRoundTrip(a, @as(i16, -500));
    try testRoundTrip(a, @as(u32, 1234567));
    try testRoundTrip(a, @as(i64, -9876543210));

    // Floats
    try testRoundTrip(a, @as(f32, 3.14159));
    try testRoundTrip(a, @as(f64, -123.456));

    // Bool
    try testRoundTrip(a, true);
    try testRoundTrip(a, false);
}

test "e2e: complex types" {
    const a = testing.allocator;

    // Optional
    try testRoundTrip(a, @as(?u32, null));
    try testRoundTrip(a, @as(?u32, 42));

    // Enum
    const TestEnum = enum(u8) { a, b, c };
    try testRoundTrip(a, TestEnum.b);

    // Array
    const arr = [_]u16{ 1, 2, 3, 4 };
    try testRoundTrip(a, arr);

    // Slice
    const slice = try a.dupe(u8, &[_]u8{ 10, 20, 30 });
    defer a.free(slice);
    try testRoundTrip(a, slice);
}

test "e2e: nested structures" {
    const a = testing.allocator;

    const NestedStruct = struct {
        x: u32,
        y: ?bool,
        arr: [3]f32,
    };

    const nested = NestedStruct{
        .x = 42,
        .y = true,
        .arr = .{ 1.0, 2.0, 3.0 },
    };
    try testRoundTrip(a, nested);
}

test "e2e: union types" {
    const a = testing.allocator;

    const TestUnion = union(enum(u8)) {
        int: i32,
        float: f64,
        empty: void,
    };

    try testRoundTrip(a, TestUnion{ .int = -42 });
    try testRoundTrip(a, TestUnion{ .float = 3.14 });
    try testRoundTrip(a, TestUnion{ .empty = {} });
}

// test "e2e: dynamic containers" {
//     const a = testing.allocator;

//     // these cant be really compared with expectEqual...

//     // ArrayList
//     var list = std.ArrayList(u32).init(a);
//     defer list.deinit();
//     try list.appendSlice(&[_]u32{ 1, 2, 3, 4, 5 });
//     try testRoundTrip(a, list);

//     // HashMap
//     var map = std.AutoHashMap(u32, []const u8).init(a);
//     defer map.deinit();
//     try map.put(1, "one");
//     try map.put(2, "two");
//     try map.put(3, "three");
//     try testRoundTrip(a, map);
// }

test "e2e: packed structs" {
    const a = testing.allocator;

    const PackedStruct = packed struct {
        flag: bool,
        value: u7,
    };

    const value = PackedStruct{
        .flag = true,
        .value = 127,
    };
    try testRoundTrip(a, value);
}

// TODO: make this an actual example...
// test "e2e: complex nested structure" {
//     const a = testing.allocator;

//     const Point = struct {
//         x: f32,
//         y: f32,
//     };

//     const Shape = union(enum) {
//         circle: f32,
//         rectangle: struct {
//             width: f32,
//             height: f32,
//         },
//     };

//     const ComplexStruct = struct {
//         name: []const u8,
//         points: std.ArrayList(Point),
//         properties: std.AutoHashMap([]const u8, Shape),
//         flags: ?[3]bool,
//     };

//     var points = std.ArrayList(Point).init(a);
//     defer points.deinit();
//     try points.append(.{ .x = 1, .y = 2 });
//     try points.append(.{ .x = 3, .y = 4 });

//     var properties = std.AutoHashMap([]const u8, Shape).init(a);
//     defer properties.deinit();
//     try properties.put("circle1", Shape{ .circle = 5.0 });
//     try properties.put("rect1", Shape{ .rectangle = .{ .width = 10, .height = 20 } });

//     const complex = ComplexStruct{
//         .name = "test structure",
//         .points = points,
//         .properties = properties,
//         .flags = .{ true, false, true },
//     };

//     try testRoundTrip(a, complex);
// }

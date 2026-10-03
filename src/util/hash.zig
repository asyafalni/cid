//! The content hash: BLAKE3, 256 bits, lower-case hex. Every item, manifest,
//! version file and diff is named and checked by it, on the server and in
//! the CLI alike, so it is chosen here once. (Protocols keep their own:
//! S3 signing, OpenSSH fingerprints and HMAC tokens stay SHA-256.)

const std = @import("std");

pub const Hasher = std.crypto.hash.Blake3;

/// The algorithm's name where it shows: storage keys (`items/blake3/…`),
/// `cid hash-object`, the dashboard.
pub const name = "blake3";

pub const Hex = [Hasher.digest_length * 2]u8;

pub fn init() Hasher {
    return Hasher.init(.{});
}

/// The hex of a finished hasher.
pub fn hexOf(hasher: *const Hasher) Hex {
    var digest: [Hasher.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// The hex of a whole buffer.
pub fn hex(bytes: []const u8) Hex {
    var digest: [Hasher.digest_length]u8 = undefined;
    Hasher.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Storage key of an item's bytes: items/blake3/<aa>/<bb>/<hex>.
pub fn itemKey(arena: std.mem.Allocator, hex_hash: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(arena, "items/" ++ name ++ "/{s}/{s}/{s}", .{ hex_hash[0..2], hex_hash[2..4], hex_hash });
}

test "BLAKE3 of the empty input and of a short one, as the reference gives them" {
    try std.testing.expectEqualStrings("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262", &hex(""));
    try std.testing.expectEqualStrings("6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85", &hex("abc"));
    var h = init();
    h.update("a");
    h.update("bc");
    try std.testing.expectEqualStrings(&hex("abc"), &hexOf(&h));
}

test "item key" {
    const key = try itemKey(std.testing.allocator, "abcd" ++ "0" ** 60);
    defer std.testing.allocator.free(key);
    try std.testing.expectEqualStrings("items/blake3/ab/cd/abcd" ++ "0" ** 60, key);
}

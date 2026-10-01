//! OpenSSH public-key handling shared by `cid admin add-key` and the
//! GitLab key sync: the SHA256:… fingerprint, exactly as OpenSSH prints
//! it (base64 of the SHA-256 of the decoded key blob, unpadded).

const std = @import("std");

pub fn fingerprint(arena: std.mem.Allocator, key_line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, key_line, ' ');
    _ = it.next() orelse return null; // key type
    const blob_b64 = it.next() orelse return null;
    const decoder = std.base64.standard.Decoder;
    const blob = arena.alloc(u8, decoder.calcSizeForSlice(blob_b64) catch return null) catch return null;
    decoder.decode(blob, blob_b64) catch return null;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
    const b64 = std.base64.standard_no_pad.Encoder;
    const out = arena.alloc(u8, "SHA256:".len + b64.calcSize(32)) catch return null;
    @memcpy(out[0.."SHA256:".len], "SHA256:");
    _ = b64.encode(out["SHA256:".len..], &digest);
    return out;
}

test "fingerprint matches ssh-keygen -lf" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A fixed throwaway key; the expected value is ssh-keygen's own output.
    const key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFdJMTzwHtTuz5TEIEMRoQ8hWQ8EuaJotFSs/0FCfvS4 fixture@cid";
    try std.testing.expectEqualStrings(
        "SHA256:dFtRBBCbqwbXXQkKRXzbOpi9eJQNbn/SAiaVrdWiLo0",
        fingerprint(arena, key).?,
    );
    try std.testing.expect(fingerprint(arena, "not a key") == null);
    try std.testing.expect(fingerprint(arena, "ssh-ed25519 !!!bad-base64 x") == null);
}

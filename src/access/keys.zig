//! OpenSSH public-key handling shared by `cid admin add-key`, the GitLab
//! key sync and keys added in the dashboard: reading a key line, and the
//! SHA256:… fingerprint exactly as OpenSSH prints it (base64 of the
//! SHA-256 of the decoded key blob, unpadded).

const std = @import("std");

/// A public key line, read and checked: `<type> <base64 blob> [comment]`.
pub const Key = struct {
    type: []const u8,
    /// The line as it is kept: type and blob, plus the comment if any.
    line: []const u8,
    comment: []const u8,
    fingerprint: []const u8,
};

/// The key types sshd accepts that cid accepts too. DSA is gone from
/// OpenSSH; RSA must be at least 2048 bits.
const accepted = [_][]const u8{
    "ssh-ed25519",
    "sk-ssh-ed25519@openssh.com",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "sk-ecdsa-sha2-nistp256@openssh.com",
    "ssh-rsa",
};

pub const ParseError = error{ NotAKey, UnsupportedType, TypeMismatch, WeakKey, OutOfMemory };

/// Reads a public key line as pasted (surrounding space and a trailing
/// newline are fine) and checks that the blob is what its type says.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Key {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOfAny(u8, trimmed, "\r\n") != null) return error.NotAKey;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const key_type = it.next() orelse return error.NotAKey;
    const blob_b64 = it.next() orelse return error.NotAKey;
    const comment = std.mem.trim(u8, it.rest(), " \t");
    if (!isAccepted(key_type)) {
        return if (std.mem.indexOfScalar(u8, key_type, '-') != null) error.UnsupportedType else error.NotAKey;
    }
    const decoder = std.base64.standard.Decoder;
    const blob = try arena.alloc(u8, decoder.calcSizeForSlice(blob_b64) catch return error.NotAKey);
    decoder.decode(blob, blob_b64) catch return error.NotAKey;

    // The blob names its own type first; it must be the one on the line.
    var r: Reader = .{ .bytes = blob };
    const inner_type = r.string() orelse return error.NotAKey;
    if (!std.mem.eql(u8, inner_type, key_type)) return error.TypeMismatch;
    if (std.mem.eql(u8, key_type, "ssh-rsa")) {
        _ = r.string() orelse return error.NotAKey; // e
        const n = r.string() orelse return error.NotAKey;
        if (modulusBits(n) < 2048) return error.WeakKey;
    }

    const line = if (comment.len > 0)
        try std.fmt.allocPrint(arena, "{s} {s} {s}", .{ key_type, blob_b64, comment })
    else
        try std.fmt.allocPrint(arena, "{s} {s}", .{ key_type, blob_b64 });
    return .{ .type = key_type, .line = line, .comment = comment, .fingerprint = try fingerprintOf(arena, blob) };
}

/// The fingerprint of a key line, or null when it is not one. Kept for
/// the GitLab sync and `cid admin add-key`, which take what they are given.
pub fn fingerprint(arena: std.mem.Allocator, key_line: []const u8) ?[]const u8 {
    const key = parse(arena, key_line) catch return null;
    return key.fingerprint;
}

fn fingerprintOf(arena: std.mem.Allocator, blob: []const u8) error{OutOfMemory}![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(blob, &digest, .{});
    const b64 = std.base64.standard_no_pad.Encoder;
    const out = try arena.alloc(u8, "SHA256:".len + b64.calcSize(32));
    @memcpy(out[0.."SHA256:".len], "SHA256:");
    _ = b64.encode(out["SHA256:".len..], &digest);
    return out;
}

fn isAccepted(key_type: []const u8) bool {
    for (accepted) |t| if (std.mem.eql(u8, t, key_type)) return true;
    return false;
}

/// SSH wire strings: a 32-bit big-endian length, then the bytes.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn string(self: *Reader) ?[]const u8 {
        if (self.bytes.len - self.at < 4) return null;
        const len = std.mem.readInt(u32, self.bytes[self.at..][0..4], .big);
        self.at += 4;
        if (self.bytes.len - self.at < len) return null;
        defer self.at += len;
        return self.bytes[self.at..][0..len];
    }
};

/// Bits in an mpint, leading zero bytes not counted.
fn modulusBits(n: []const u8) usize {
    var i: usize = 0;
    while (i < n.len and n[i] == 0) : (i += 1) {}
    if (i == n.len) return 0;
    return (n.len - i - 1) * 8 + (8 - @clz(n[i]));
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

test "parse: a pasted key is read and checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const blob = "AAAAC3NzaC1lZDI1NTE5AAAAIFdJMTzwHtTuz5TEIEMRoQ8hWQ8EuaJotFSs/0FCfvS4";
    const k = try parse(a, "  ssh-ed25519 " ++ blob ++ "  ada@laptop \n");
    try std.testing.expectEqualStrings("ssh-ed25519", k.type);
    try std.testing.expectEqualStrings("ada@laptop", k.comment);
    try std.testing.expectEqualStrings("ssh-ed25519 " ++ blob ++ " ada@laptop", k.line);
    try std.testing.expectEqualStrings("SHA256:dFtRBBCbqwbXXQkKRXzbOpi9eJQNbn/SAiaVrdWiLo0", k.fingerprint);

    try std.testing.expectError(error.NotAKey, parse(a, "hello"));
    try std.testing.expectError(error.NotAKey, parse(a, "ssh-ed25519 " ++ blob ++ "\nssh-ed25519 " ++ blob));
    try std.testing.expectError(error.UnsupportedType, parse(a, "ssh-dss " ++ blob));
    // The blob says ssh-ed25519; the line says otherwise.
    try std.testing.expectError(error.TypeMismatch, parse(a, "ecdsa-sha2-nistp256 " ++ blob));
    // A 1024-bit RSA modulus.
    var rsa: [4 + 7 + 4 + 3 + 4 + 129]u8 = undefined;
    var w: usize = 0;
    inline for (.{ "ssh-rsa", "\x01\x00\x01" }) |part| {
        std.mem.writeInt(u32, rsa[w..][0..4], part.len, .big);
        @memcpy(rsa[w + 4 ..][0..part.len], part);
        w += 4 + part.len;
    }
    std.mem.writeInt(u32, rsa[w..][0..4], 129, .big);
    rsa[w + 4] = 0;
    @memset(rsa[w + 5 ..][0..128], 0xC3);
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(rsa.len));
    _ = enc.encode(b64, &rsa);
    try std.testing.expectError(error.WeakKey, parse(a, try std.fmt.allocPrint(a, "ssh-rsa {s}", .{b64})));
}

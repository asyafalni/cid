//! Scoped access tokens (docs/access.md): handed out over SSH, verified
//! by the server, never stored anywhere. Stateless HMAC-SHA256 over a
//! readable payload:
//!
//!   cid1.<base64url(payload)>.<base64url(mac)>
//!   payload = "1:<expiry unix>:<level>:<dataset>:<account>"
//!   (account ids contain ':' — gitlab:<id> — so account is the tail;
//!   dataset paths never do and are checked at mint)
//!
//! Scoped to one dataset and one level, expiring in minutes (invariant:
//! SSH only authenticates; these tokens are all it hands out).

const std = @import("std");

/// Reporter reads, Developer writes (push), Maintainer maintains: tags,
/// branches, merges and the card. Each covers the ones below it.
pub const Level = enum {
    read,
    write,
    maintain,

    pub fn covers(self: Level, needed: Level) bool {
        return @intFromEnum(self) >= @intFromEnum(needed);
    }
};

pub const Claims = struct {
    expiry_unix: u64,
    level: Level,
    account: []const u8,
    dataset: []const u8,
};

pub const default_ttl_secs: u64 = 15 * 60;

const prefix = "cid1.";
const b64 = std.base64.url_safe_no_pad;

pub fn mint(
    arena: std.mem.Allocator,
    secret: []const u8,
    claims: Claims,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, claims.dataset, ':') != null) return error.BadClaims;
    const payload = try std.fmt.allocPrint(arena, "1:{d}:{t}:{s}:{s}", .{
        claims.expiry_unix, claims.level, claims.dataset, claims.account,
    });
    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, payload, secret);

    const out = try arena.alloc(u8, prefix.len + b64.Encoder.calcSize(payload.len) + 1 + b64.Encoder.calcSize(mac.len));
    @memcpy(out[0..prefix.len], prefix);
    const p_end = prefix.len + b64.Encoder.calcSize(payload.len);
    _ = b64.Encoder.encode(out[prefix.len..p_end], payload);
    out[p_end] = '.';
    _ = b64.Encoder.encode(out[p_end + 1 ..], &mac);
    return out;
}

pub const VerifyError = error{ Malformed, BadSignature, Expired, OutOfMemory };

pub fn verify(
    arena: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
    now_unix: u64,
) VerifyError!Claims {
    if (!std.mem.startsWith(u8, token, prefix)) return error.Malformed;
    const rest = token[prefix.len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return error.Malformed;
    const payload_b64 = rest[0..dot];
    const mac_b64 = rest[dot + 1 ..];

    const payload = try arena.alloc(u8, b64.Decoder.calcSizeForSlice(payload_b64) catch return error.Malformed);
    b64.Decoder.decode(payload, payload_b64) catch return error.Malformed;
    var mac_given: [32]u8 = undefined;
    if ((b64.Decoder.calcSizeForSlice(mac_b64) catch return error.Malformed) != 32) return error.Malformed;
    b64.Decoder.decode(&mac_given, mac_b64) catch return error.Malformed;

    var mac_expected: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac_expected, payload, secret);
    var diff: u8 = 0;
    for (mac_given, mac_expected) |a, b| diff |= a ^ b;
    if (diff != 0) return error.BadSignature;

    // "1:<expiry>:<level>:<dataset>:<account>" — account ids contain ':'
    // (gitlab:<id>), so account is the remainder after the fourth separator.
    var it = std.mem.splitScalar(u8, payload, ':');
    const version = it.next() orelse return error.Malformed;
    if (!std.mem.eql(u8, version, "1")) return error.Malformed;
    const expiry_text = it.next() orelse return error.Malformed;
    const level_text = it.next() orelse return error.Malformed;
    const dataset = it.next() orelse return error.Malformed;
    const account = it.rest();
    if (account.len == 0 or dataset.len == 0) return error.Malformed;

    const claims: Claims = .{
        .expiry_unix = std.fmt.parseInt(u64, expiry_text, 10) catch return error.Malformed,
        .level = std.meta.stringToEnum(Level, level_text) orelse return error.Malformed,
        .account = account,
        .dataset = dataset,
    };
    if (now_unix >= claims.expiry_unix) return error.Expired;
    return claims;
}

test "mint and verify round trip, scoped and expiring" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const secret = "test-secret-at-least-32-bytes-long!";

    const token = try mint(arena, secret, .{
        .expiry_unix = 1000,
        .level = .write,
        .account = "gitlab:42",
        .dataset = "org/datasets/calls",
    });
    try std.testing.expect(std.mem.startsWith(u8, token, "cid1."));

    const claims = try verify(arena, secret, token, 999);
    try std.testing.expectEqual(@as(u64, 1000), claims.expiry_unix);
    try std.testing.expectEqual(Level.write, claims.level);
    try std.testing.expectEqualStrings("gitlab:42", claims.account);
    try std.testing.expectEqualStrings("org/datasets/calls", claims.dataset);

    // Expired, tampered, wrong secret, malformed: all refused.
    try std.testing.expectError(error.Expired, verify(arena, secret, token, 1000));
    try std.testing.expectError(error.BadSignature, verify(arena, "other-secret", token, 999));
    var tampered = try arena.dupe(u8, token);
    tampered[8] = if (tampered[8] == 'A') 'B' else 'A';
    const tampered_result = verify(arena, secret, tampered, 999);
    try std.testing.expect(tampered_result == error.BadSignature or tampered_result == error.Malformed);
    try std.testing.expectError(error.Malformed, verify(arena, secret, "not-a-token", 999));
    try std.testing.expectError(error.Malformed, verify(arena, secret, "cid1.!!!.x", 999));
}

test "levels: each covers the ones below it, never above" {
    try std.testing.expect(Level.write.covers(.read));
    try std.testing.expect(Level.write.covers(.write));
    try std.testing.expect(Level.read.covers(.read));
    try std.testing.expect(!Level.read.covers(.write));
    try std.testing.expect(Level.maintain.covers(.write));
    try std.testing.expect(!Level.write.covers(.maintain));
    try std.testing.expect(!Level.read.covers(.maintain));
}

test "datasets with colons are refused at mint time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadClaims, mint(arena_state.allocator(), "s", .{
        .expiry_unix = 1,
        .level = .read,
        .account = "gitlab:42",
        .dataset = "evil:inject",
    }));
}

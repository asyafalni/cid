//! UUIDv7 (RFC 9562): 48-bit Unix milliseconds, then version and variant
//! bits over random data. Time-ordered, so `rev_id` and `commit_id` sort by
//! creation time — the property the data model's cutoffs rely on.

const std = @import("std");

pub const Uuid = struct {
    bytes: [16]u8,

    /// Build from a millisecond timestamp and 10 bytes of entropy.
    /// Pure, so tests can pin both.
    pub fn init(unix_ms: u64, entropy: [10]u8) Uuid {
        var b: [16]u8 = undefined;
        std.mem.writeInt(u48, b[0..6], @truncate(unix_ms), .big);
        @memcpy(b[6..16], &entropy);
        b[6] = (b[6] & 0x0f) | 0x70; // version 7
        b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
        return .{ .bytes = b };
    }

    /// Convenience for runtime use: current wall clock + io entropy.
    pub fn now(io: std.Io) Uuid {
        const ts = std.Io.Timestamp.now(io, .real);
        const ms: u64 = @intCast(@max(0, ts.toMilliseconds()));
        var entropy: [10]u8 = undefined;
        io.random(&entropy);
        return init(ms, entropy);
    }

    pub fn unixMs(self: Uuid) u64 {
        return std.mem.readInt(u48, self.bytes[0..6], .big);
    }

    /// Canonical lower-case form: 0191c2a3-…-….
    pub fn format(self: Uuid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        try w.print("{s}-{s}-{s}-{s}-{s}", .{
            hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
        });
    }

    pub fn toString(self: Uuid) [36]u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        var out: [36]u8 = undefined;
        @memcpy(out[0..8], hex[0..8]);
        out[8] = '-';
        @memcpy(out[9..13], hex[8..12]);
        out[13] = '-';
        @memcpy(out[14..18], hex[12..16]);
        out[18] = '-';
        @memcpy(out[19..23], hex[16..20]);
        out[23] = '-';
        @memcpy(out[24..36], hex[20..32]);
        return out;
    }

    pub const ParseError = error{InvalidUuid};

    pub fn parse(text: []const u8) ParseError!Uuid {
        if (text.len != 36) return error.InvalidUuid;
        if (text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-')
            return error.InvalidUuid;
        var hex: [32]u8 = undefined;
        var n: usize = 0;
        for (text) |ch| {
            if (ch == '-') continue;
            hex[n] = ch;
            n += 1;
        }
        var out: Uuid = undefined;
        _ = std.fmt.hexToBytes(&out.bytes, &hex) catch return error.InvalidUuid;
        return out;
    }

    pub fn order(a: Uuid, b: Uuid) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    /// A fresh id guaranteed to sort after `last`. Plain UUIDv7 randomness
    /// is NOT ordered within one millisecond, which would let a later
    /// revision sort under an earlier cutoff; every id sequence that
    /// cutoffs or logs depend on must come through here.
    pub fn nextAfter(io: std.Io, last: ?Uuid) Uuid {
        const candidate = now(io);
        const floor = last orelse return candidate;
        if (candidate.order(floor) == .gt) return candidate;
        return bump(floor);
    }

    /// The smallest valid UUIDv7 greater than `u`: increments the 62-bit
    /// random-b field, carrying into rand-a and then the timestamp, and
    /// keeps the version and variant bits intact.
    fn bump(u: Uuid) Uuid {
        var b = u.bytes;
        const rand_b = std.mem.readInt(u64, b[8..16], .big) & 0x3fff_ffff_ffff_ffff;
        if (rand_b != 0x3fff_ffff_ffff_ffff) {
            std.mem.writeInt(u64, b[8..16], (rand_b + 1) | 0x8000_0000_0000_0000, .big);
            return .{ .bytes = b };
        }
        std.mem.writeInt(u64, b[8..16], 0x8000_0000_0000_0000, .big);
        const rand_a: u12 = @truncate(std.mem.readInt(u16, b[6..8], .big));
        if (rand_a != 0xfff) {
            std.mem.writeInt(u16, b[6..8], @as(u16, rand_a + 1) | 0x7000, .big);
            return .{ .bytes = b };
        }
        return init(u.unixMs() + 1, @splat(0));
    }
};

test "round trip and field placement" {
    const u = Uuid.init(0x0190_1234_5678, .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try std.testing.expectEqual(@as(u64, 0x0190_1234_5678), u.unixMs());
    try std.testing.expectEqual(@as(u8, 0x7f), u.bytes[6]); // version 7 kept high nibble
    try std.testing.expectEqual(@as(u8, 0xbf), u.bytes[8]); // variant 10xx
    const s = u.toString();
    const parsed = try Uuid.parse(&s);
    try std.testing.expectEqualSlices(u8, &u.bytes, &parsed.bytes);
}

test "later timestamps order later" {
    const a = Uuid.init(1000, @splat(0xff));
    const b = Uuid.init(1001, @splat(0x00));
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
}

test "bump produces the next id, through every carry" {
    // Plain increment of rand-b.
    const a = Uuid.init(1000, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 });
    const a2 = Uuid.bump(a);
    try std.testing.expectEqual(std.math.Order.lt, a.order(a2));
    try std.testing.expectEqual(a.unixMs(), a2.unixMs());

    // rand-b saturated: carries into rand-a, stays in the same millisecond.
    var sat_b = Uuid.init(1000, @splat(0));
    @memset(sat_b.bytes[8..16], 0xff);
    sat_b.bytes[8] = 0xbf; // variant bits kept
    const carried = Uuid.bump(sat_b);
    try std.testing.expectEqual(std.math.Order.lt, sat_b.order(carried));
    try std.testing.expectEqual(sat_b.unixMs(), carried.unixMs());
    try std.testing.expectEqual(@as(u8, 0x70), carried.bytes[6] & 0xf0); // still v7
    try std.testing.expectEqual(@as(u8, 0x80), carried.bytes[8] & 0xc0); // still variant 10

    // Everything saturated: moves to the next millisecond.
    var sat_all = sat_b;
    sat_all.bytes[6] = 0x7f;
    sat_all.bytes[7] = 0xff;
    const next_ms = Uuid.bump(sat_all);
    try std.testing.expectEqual(std.math.Order.lt, sat_all.order(next_ms));
    try std.testing.expectEqual(sat_all.unixMs() + 1, next_ms.unixMs());
}

test "parse rejects malformed input" {
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("not-a-uuid"));
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("0190123456780000000000000000000000000"));
    try std.testing.expectError(error.InvalidUuid, Uuid.parse("01901234-5678-7xff-bfff-ffffffffffff"));
}

//! Media sniffing: the one sanctioned look inside a file (invariant:
//! cid never interprets file contents except to read media metadata on
//! upload and to diff tabular files). Pure over bytes: magic numbers for
//! the type, and the pixel dimensions where the header carries them.
//! Unknown stays unknown — application/octet-stream is an honest answer.

const std = @import("std");

pub const Sniffed = struct {
    media_type: []const u8,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub fn sniff(bytes: []const u8) ?Sniffed {
    if (bytes.len < 12) return null;

    // PNG: 8-byte signature, then IHDR carries width/height big-endian.
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        var out: Sniffed = .{ .media_type = "image/png" };
        if (bytes.len >= 24 and std.mem.eql(u8, bytes[12..16], "IHDR")) {
            out.width = std.mem.readInt(u32, bytes[16..20], .big);
            out.height = std.mem.readInt(u32, bytes[20..24], .big);
        }
        return out;
    }

    // JPEG: FFD8, then markers until a start-of-frame carries the size.
    if (bytes[0] == 0xff and bytes[1] == 0xd8) {
        var out: Sniffed = .{ .media_type = "image/jpeg" };
        var i: usize = 2;
        while (i + 9 < bytes.len) {
            if (bytes[i] != 0xff) break;
            const marker = bytes[i + 1];
            if (marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd9)) {
                i += 2;
                continue;
            }
            const seg_len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
            if (seg_len < 2) break;
            const is_sof = switch (marker) {
                0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => true,
                else => false,
            };
            if (is_sof and i + 9 < bytes.len) {
                out.height = std.mem.readInt(u16, bytes[i + 5 ..][0..2], .big);
                out.width = std.mem.readInt(u16, bytes[i + 7 ..][0..2], .big);
                break;
            }
            i += 2 + seg_len;
        }
        return out;
    }

    // GIF: dimensions little-endian right after the version.
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) {
        return .{
            .media_type = "image/gif",
            .width = std.mem.readInt(u16, bytes[6..8], .little),
            .height = std.mem.readInt(u16, bytes[8..10], .little),
        };
    }

    // WebP: RIFF…WEBP; VP8X extended header carries the canvas size.
    if (std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        var out: Sniffed = .{ .media_type = "image/webp" };
        if (bytes.len >= 30 and std.mem.eql(u8, bytes[12..16], "VP8X")) {
            const w: u32 = @as(u32, bytes[24]) | (@as(u32, bytes[25]) << 8) | (@as(u32, bytes[26]) << 16);
            const h: u32 = @as(u32, bytes[27]) | (@as(u32, bytes[28]) << 8) | (@as(u32, bytes[29]) << 16);
            out.width = w + 1;
            out.height = h + 1;
        }
        return out;
    }

    if (std.mem.startsWith(u8, bytes, "%PDF-")) {
        return .{ .media_type = "application/pdf" };
    }

    // ISO base media (mp4/mov): 'ftyp' at offset 4.
    if (std.mem.eql(u8, bytes[4..8], "ftyp")) {
        return .{ .media_type = "video/mp4" };
    }

    // Matroska / WebM: EBML header.
    if (std.mem.startsWith(u8, bytes, "\x1a\x45\xdf\xa3")) {
        return .{ .media_type = "video/webm" };
    }

    return null;
}

test "sniffs the usual suspects, with dimensions where headers carry them" {
    // A minimal PNG header: signature + IHDR for 640x480.
    var png: [24]u8 = undefined;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(png[8..12], "\x00\x00\x00\x0d");
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 640, .big);
    std.mem.writeInt(u32, png[20..24], 480, .big);
    const p = sniff(&png).?;
    try std.testing.expectEqualStrings("image/png", p.media_type);
    try std.testing.expectEqual(@as(?u32, 640), p.width);
    try std.testing.expectEqual(@as(?u32, 480), p.height);

    // JPEG: SOI, APP0 stub, SOF0 with 100x200.
    const jpeg = [_]u8{
        0xff, 0xd8, // SOI
        0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, // APP0, length 4
        0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0xc8, 0x00, 0x64, // SOF0: h=200 w=100
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
    };
    const j = sniff(&jpeg).?;
    try std.testing.expectEqualStrings("image/jpeg", j.media_type);
    try std.testing.expectEqual(@as(?u32, 100), j.width);
    try std.testing.expectEqual(@as(?u32, 200), j.height);

    const gif = "GIF89a" ++ "\x40\x01" ++ "\xf0\x00" ++ ("\x00" ** 8);
    const g = sniff(gif).?;
    try std.testing.expectEqualStrings("image/gif", g.media_type);
    try std.testing.expectEqual(@as(?u32, 320), g.width);
    try std.testing.expectEqual(@as(?u32, 240), g.height);

    try std.testing.expectEqualStrings("application/pdf", sniff("%PDF-1.7 and so on").?.media_type);
    try std.testing.expectEqualStrings("video/mp4", sniff("\x00\x00\x00\x20ftypisom____").?.media_type);
    try std.testing.expect(sniff("plain text, honestly nothing") == null);
}

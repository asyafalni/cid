//! `.cidkeys`: which columns identify a table's rows, declared in a file
//! committed with the data (decided 2026-11-20, docs/roadmap.md), so a row
//! diff can tell a row changed from a row replaced. One rule per line, a
//! path pattern (as `.cidignore`'s) and its key columns, comma-separated:
//!
//!     # people are identified by their id
//!     people.csv  id
//!     events/     user_id,ts
//!
//! The last rule that matches a path wins, as in `.gitattributes`. Nothing
//! is ever guessed: a table no rule names is compared by whole rows.

const std = @import("std");
const pathpattern = @import("../util/pathpattern.zig");

pub const Rule = struct { pattern: []const u8, columns: []const []const u8 };

/// The rules of a `.cidkeys` file; a line that is not a rule is skipped.
pub fn parse(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const Rule {
    var rules: std.ArrayList(Rule) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        // The pattern, then the columns: comma-separated, spaces around
        // the commas allowed; a column name holds no space.
        const gap = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const pattern = line[0..gap];
        const cols_text = std.mem.trim(u8, line[gap..], " \t");
        var columns: std.ArrayList([]const u8) = .empty;
        var cols = std.mem.splitScalar(u8, cols_text, ',');
        const ok = while (cols.next()) |c| {
            const col = std.mem.trim(u8, c, " \t");
            if (col.len == 0 or std.mem.indexOfAny(u8, col, " \t") != null) break false;
            try columns.append(arena, col);
        } else true;
        if (!ok or columns.items.len == 0) continue;
        try rules.append(arena, .{ .pattern = pattern, .columns = columns.items });
    }
    return rules.items;
}

/// The key columns for a path, or none.
pub fn keyFor(rules: []const Rule, path: []const u8) ?[]const []const u8 {
    var found: ?[]const []const u8 = null;
    for (rules) |r| if (pathpattern.matches(r.pattern, path)) {
        found = r.columns;
    };
    return found;
}

test "rules, comments, the last match wins, nothing guessed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const rules = try parse(arena,
        \\# keys
        \\*.csv        id
        \\events/      user_id, ts
        \\people.csv   person_id
        \\not a rule here
        \\lonely.csv
    );
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqualStrings("person_id", keyFor(rules, "people.csv").?[0]);
    try std.testing.expectEqualStrings("id", keyFor(rules, "data/other.csv").?[0]);
    const ev = keyFor(rules, "events/2026.parquet").?;
    try std.testing.expectEqual(@as(usize, 2), ev.len);
    try std.testing.expectEqualStrings("ts", ev[1]);
    try std.testing.expect(keyFor(rules, "notes.jsonl") == null);
}

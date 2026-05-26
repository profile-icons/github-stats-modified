// modified by Adam Ross (https://www.github.com/profile-icons/github-stats-modified), 26/05/26.
const std = @import("std");

var is_installed: ?bool = null;

pub const gh_languages_url = "https://raw.githubusercontent.com/github-linguist/linguist/master/lib/linguist/languages.yml";

pub fn isInstalled(gpa: std.mem.Allocator, io: std.Io) bool {
    if (is_installed) |v| {
        return v;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const run = std.process.run(arena.allocator(), io, .{
        .argv = &.{ "git", "--version" },
    }) catch {
        is_installed = false;
        return is_installed.?;
    };
    is_installed = switch (run.term) {
        .exited => |v| v == 0,
        else => false,
    };
    return is_installed.?;
}

pub fn currentCommit(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    if (!isInstalled(gpa, io)) return error.GitNotInstalled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const run = try std.process.run(arena.allocator(), io, .{
        .argv = &.{ "git", "rev-parse", "HEAD" },
    });
    return try gpa.dupe(u8, run.stdout[0..8]);
}

pub const LanguageDefinition = struct {
    name: []const u8,
    color: ?[]const u8 = null,
    extensions: [][]const u8 = &.{},
    filenames: [][]const u8 = &.{},

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.color) |color| gpa.free(color);
        for (self.extensions) |extension| {
            gpa.free(extension);
        }
        if (self.extensions.len > 0) {
            gpa.free(self.extensions);
        }
        for (self.filenames) |filename| {
            gpa.free(filename);
        }
        if (self.filenames.len > 0) {
            gpa.free(self.filenames);
        }
    }
};

const BuildLanguage = struct {
    name: []const u8,
    color: ?[]const u8 = null,
    extensions: std.ArrayList([]const u8) = .empty,
    filenames: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
        if (self.name.len > 0) {
            gpa.free(self.name);
        }
        if (self.color) |color| gpa.free(color);
        for (self.extensions.items) |extension| {
            gpa.free(extension);
        }
        self.extensions.deinit(gpa);
        for (self.filenames.items) |filename| {
            gpa.free(filename);
        }
        self.filenames.deinit(gpa);
    }
};

const ActiveYamlList = enum {
    none,
    extensions,
    filenames,
};

pub const GitHubRepoLanguages = struct {
    definitions: []LanguageDefinition,

    pub fn init(gpa: std.mem.Allocator, yaml: []const u8) !GitHubRepoLanguages {
        var build_languages: std.ArrayList(BuildLanguage) = .empty;
        errdefer {
            for (build_languages.items) |*language| {
                language.deinit(gpa);
            }
            build_languages.deinit(gpa);
        }

        var current_index: ?usize = null;
        var active_list: ActiveYamlList = .none;

        var lines = std.mem.splitScalar(u8, yaml, '\n');
        while (lines.next()) |raw_line| {
            const line = trimRightScalar(raw_line, '\r');
            const left_trimmed = trimLeftAny(line, " \t");
            const trimmed = std.mem.trim(u8, left_trimmed, " \t");

            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }

            const is_top_level = line.len == left_trimmed.len;
            if (is_top_level and std.mem.endsWith(u8, trimmed, ":")) {
                const name_raw = trimmed[0 .. trimmed.len - 1];
                const name = stripYamlScalar(name_raw);
                if (name.len == 0) continue;

                try build_languages.append(gpa, .{
                    .name = try gpa.dupe(u8, name),
                });
                current_index = build_languages.items.len - 1;
                active_list = .none;
                continue;
            }

            const idx = current_index orelse continue;
            const language = &build_languages.items[idx];

            if (std.mem.startsWith(u8, trimmed, "color:")) {
                const value = stripYamlScalar(trimmed["color:".len..]);
                if (value.len > 0) {
                    if (language.color) |old_color| gpa.free(old_color);
                    language.color = try gpa.dupe(u8, value);
                }
                active_list = .none;
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "extensions:")) {
                active_list = .extensions;
                try appendYamlInlineList(
                    gpa,
                    &language.extensions,
                    trimmed["extensions:".len..],
                );
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "filenames:")) {
                active_list = .filenames;
                try appendYamlInlineList(
                    gpa,
                    &language.filenames,
                    trimmed["filenames:".len..],
                );
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const value = stripYamlScalar(trimmed[2..]);
                if (value.len == 0) continue;

                switch (active_list) {
                    .extensions => try appendUniqueScalar(gpa, &language.extensions, value),
                    .filenames => try appendUniqueScalar(gpa, &language.filenames, value),
                    .none => {},
                }
                continue;
            }

            active_list = .none;
        }

        const definitions = try gpa.alloc(LanguageDefinition, build_languages.items.len);
        errdefer {
            for (definitions) |definition| {
                definition.deinit(gpa);
            }
            gpa.free(definitions);
        }

        for (build_languages.items, definitions) |*src, *dest| {
            dest.* = .{
                .name = src.name,
                .color = src.color,
                .extensions = try src.extensions.toOwnedSlice(gpa),
                .filenames = try src.filenames.toOwnedSlice(gpa),
            };

            // Ownership moved to `definitions`.
            src.name = &.{};
            src.color = null;
            src.extensions = .empty;
            src.filenames = .empty;
        }

        for (build_languages.items) |*language| {
            language.deinit(gpa);
        }
        build_languages.deinit(gpa);

        return .{ .definitions = definitions };
    }

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        for (self.definitions) |definition| {
            definition.deinit(gpa);
        }
        gpa.free(self.definitions);
    }

    pub fn findByPath(self: @This(), path: []const u8) ?*const LanguageDefinition {
        const basename = std.fs.path.basename(path);

        // Filename-based matches first, matching Linguist's separate filename metadata.
        for (self.definitions) |*definition| {
            for (definition.filenames) |filename| {
                if (std.mem.eql(u8, basename, filename)) {
                    return definition;
                }
            }
        }

        // Longest extension match wins, so `.d.ts` beats `.ts`, `.blade.php`
        // beats `.php`, etc.
        var best: ?*const LanguageDefinition = null;
        var best_extension_len: usize = 0;

        for (self.definitions) |*definition| {
            for (definition.extensions) |extension| {
                if (extension.len <= best_extension_len) continue;
                if (endsWithIgnoreCase(path, extension)) {
                    best = definition;
                    best_extension_len = extension.len;
                }
            }
        }

        return best;
    }

    pub fn getExtensionsForLanguage(
        self: @This(),
        language_name: []const u8,
    ) ?[][]const u8 {
        for (self.definitions) |definition| {
            if (std.mem.eql(u8, definition.name, language_name)) {
                return definition.extensions;
            }
        }
        return null;
    }

    pub fn getColorForLanguage(
        self: @This(),
        language_name: []const u8,
    ) ?[]const u8 {
        for (self.definitions) |definition| {
            if (std.mem.eql(u8, definition.name, language_name)) {
                return definition.color;
            }
        }
        return null;
    }
};

pub const LanguageLineStats = struct {
    name: []const u8,
    color: ?[]const u8 = null,
    extensions: [][]const u8 = &.{},
    additions: u32 = 0,
    deletions: u32 = 0,
    lines_changed: u32 = 0,

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        if (self.color) |color| {
            gpa.free(color);
        }
        for (self.extensions) |extension| {
            gpa.free(extension);
        }
        if (self.extensions.len > 0) {
            gpa.free(self.extensions);
        }
    }
};

fn appendYamlInlineList(
    gpa: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    raw_value: []const u8,
) !void {
    const value = std.mem.trim(u8, raw_value, " \t");
    if (value.len == 0 or value[0] != '[') return;

    const body = std.mem.trim(u8, value, " \t[]");
    var items = std.mem.splitScalar(u8, body, ',');
    while (items.next()) |raw_item| {
        const item = stripYamlScalar(raw_item);
        if (item.len == 0) continue;
        try appendUniqueScalar(gpa, list, item);
    }
}

fn appendUniqueScalar(
    gpa: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) {
            return;
        }
    }
    try list.append(gpa, try gpa.dupe(u8, value));
}

fn stripYamlScalar(raw: []const u8) []const u8 {
    var value = std.mem.trim(u8, raw, " \t,");

    // This intentionally does not treat `#` as a comment marker because
    // color values are normally `"#RRGGBB"`.
    if (value.len >= 2) {
        const first = value[0];
        const last = value[value.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            value = value[1 .. value.len - 1];
        }
    }

    return value;
}

fn trimLeftAny(s: []const u8, values: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and containsScalar(values, s[start])) {
        start += 1;
    }
    return s[start..];
}

fn containsScalar(values: []const u8, value: u8) bool {
    for (values) |candidate| {
        if (candidate == value) return true;
    }
    return false;
}

fn trimRightScalar(s: []const u8, value: u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == value) {
        end -= 1;
    }
    return s[0..end];
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (suffix.len > s.len) return false;
    return std.ascii.eqlIgnoreCase(s[s.len - suffix.len ..], suffix);
}

fn authorEmailMatches(email: []const u8, emails: []const []const u8) bool {
    for (emails) |candidate| {
        if (std.ascii.eqlIgnoreCase(email, candidate)) {
            return true;
        }
    }
    return false;
}

fn dupStringSlice(
    gpa: std.mem.Allocator,
    values: []const []const u8,
) ![][]const u8 {
    if (values.len == 0) {
        return &.{};
    }

    const result = try gpa.alloc([]const u8, values.len);
    errdefer gpa.free(result);

    for (values, result, 0..) |src, *dest, i| {
        errdefer {
            for (result[0..i]) |value| {
                gpa.free(value);
            }
        }
        dest.* = try gpa.dupe(u8, src);
    }

    return result;
}

fn makeLanguageLineStats(
    gpa: std.mem.Allocator,
    definition: ?*const LanguageDefinition,
) !LanguageLineStats {
    if (definition) |language| {
        return .{
            .name = try gpa.dupe(u8, language.name),
            .color = if (language.color) |color| try gpa.dupe(u8, color) else null,
            .extensions = try dupStringSlice(gpa, language.extensions),
        };
    }

    return .{
        .name = try gpa.dupe(u8, "Other"),
        .color = null,
        .extensions = &.{},
    };
}

fn getOrCreateLanguageLineStats(
    gpa: std.mem.Allocator,
    stats: *std.ArrayList(LanguageLineStats),
    definition: ?*const LanguageDefinition,
) !*LanguageLineStats {
    const name = if (definition) |language| language.name else "Other";

    for (stats.items) |*language_stats| {
        if (std.mem.eql(u8, language_stats.name, name)) {
            return language_stats;
        }
    }

    try stats.append(gpa, try makeLanguageLineStats(gpa, definition));
    return &stats.items[stats.items.len - 1];
}

pub fn getLanguageStatsByLineChanges(
    gpa: std.mem.Allocator,
    io: std.Io,
    login: []const u8,
    token: []const u8,
    repo: []const u8,
    emails: []const []const u8,
    languages: *const GitHubRepoLanguages,
) ![]LanguageLineStats {
    if (!isInstalled(gpa, io)) return error.GitNotInstalled;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const repo_path = try std.mem.replaceOwned(u8, allocator, repo, "/", "_");
    std.Io.Dir.cwd().deleteTree(io, repo_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, repo_path) catch {};

    const repo_url = try std.fmt.allocPrint(
        allocator,
        "https://{s}:{s}@github.com/{s}.git",
        .{ login, token, repo },
    );

    const clone = try std.process.run(allocator, io, .{
        .argv = &.{
            "git",
            "clone",
            "--bare",
            "--filter=blob:none",
            "--no-tags",
            repo_url,
            repo_path,
        },
    });
    switch (clone.term) {
        .exited => |v| if (v != 0) return error.CloneFailed,
        else => return error.CloneFailed,
    }

    const email_args = try allocator.alloc([]const u8, emails.len * 2);
    for (emails, 0..) |email, i| {
        email_args[i * 2] = "--author";
        email_args[i * 2 + 1] = email;
    }

    const log_args = try std.mem.concat(allocator, []const u8, &.{
        &.{
            "git",
            "-C",
            repo_path,
            "log",
            "--all",
            "--use-mailmap",
            "--no-renames",
            "--numstat",
            "--pretty=tformat:__GIT_STATS_AUTHOR__%ae",
        },
        email_args,
    });

    const log = try std.process.run(allocator, io, .{
        .argv = log_args,
    });
    switch (log.term) {
        .exited => |v| if (v != 0) return error.LogFailed,
        else => return error.LogFailed,
    }

    var stats: std.ArrayList(LanguageLineStats) = .empty;
    errdefer {
        for (stats.items) |language_stats| {
            language_stats.deinit(gpa);
        }
        stats.deinit(gpa);
    }

    var include_commit = false;
    var lines = std.mem.tokenizeScalar(u8, log.stdout, '\n');
    while (lines.next()) |raw_line| {
        const line = trimRightScalar(raw_line, '\r');
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "__GIT_STATS_AUTHOR__")) {
            const author_email = line["__GIT_STATS_AUTHOR__".len..];
            include_commit = authorEmailMatches(author_email, emails);
            continue;
        }

        if (!include_commit) continue;

        var parts = std.mem.splitScalar(u8, line, '\t');
        const additions_raw = parts.next() orelse continue;
        const deletions_raw = parts.next() orelse continue;
        const path = parts.next() orelse continue;

        // Binary files are shown as "-\t-\tpath".
        if (std.mem.eql(u8, additions_raw, "-") or
            std.mem.eql(u8, deletions_raw, "-"))
        {
            continue;
        }

        const additions = std.fmt.parseUnsigned(u32, additions_raw, 10) catch continue;
        const deletions = std.fmt.parseUnsigned(u32, deletions_raw, 10) catch continue;

        const definition = languages.findByPath(path);
        const language_stats =
            try getOrCreateLanguageLineStats(gpa, &stats, definition);

        language_stats.additions += additions;
        language_stats.deletions += deletions;
        language_stats.lines_changed += additions + deletions;
    }

    const result = try stats.toOwnedSlice(gpa);
    std.sort.pdq(LanguageLineStats, result, {}, struct {
        pub fn lessThanFn(_: void, lhs: LanguageLineStats, rhs: LanguageLineStats) bool {
            return rhs.lines_changed < lhs.lines_changed;
        }
    }.lessThanFn);

    return result;
}

pub fn getLinesChanged(
    gpa: std.mem.Allocator,
    io: std.Io,
    login: []const u8,
    token: []const u8,
    repo: []const u8,
    emails: []const []const u8,
) !u32 {
    if (!isInstalled(gpa, io)) return error.GitNotInstalled;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const repo_path = try std.mem.replaceOwned(u8, allocator, repo, "/", "_");
    const repo_url = try std.fmt.allocPrint(
        allocator,
        "https://{s}:{s}@github.com/{s}.git",
        .{ login, token, repo },
    );
    const clone = try std.process.run(allocator, io, .{
        .argv = &.{
            "git",
            "clone",
            "--bare",
            "--filter=blob:limit=1m",
            "--no-tags",
            "--single-branch",
            repo_url,
            repo_path,
        },
    });
    switch (clone.term) {
        .exited => |v| if (v != 0) return error.CloneFailed,
        else => return error.CloneFailed,
    }
    defer std.Io.Dir.cwd().deleteTree(io, repo_path) catch {};

    const email_args = try allocator.alloc([]const u8, emails.len * 2);
    for (emails, 0..) |email, i| {
        email_args[i * 2] = "--author";
        email_args[i * 2 + 1] = email;
    }
    const log_args = try std.mem.concat(allocator, []const u8, &.{
        &.{
            "git",
            "-C",
            repo_path,
            "log",
            "--numstat",
            "--pretty=tformat:",
        },
        email_args,
    });
    const log = try std.process.run(allocator, io, .{ .argv = log_args });
    switch (log.term) {
        .exited => |v| if (v != 0) return error.LogFailed,
        else => return error.LogFailed,
    }

    var lines_changed: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, log.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.tokenizeAny(u8, line, " \t");
        const additions =
            std.fmt.parseUnsigned(u32, parts.next().?, 10) catch 0;
        const deletions =
            std.fmt.parseUnsigned(u32, parts.next().?, 10) catch 0;
        lines_changed += additions + deletions;
    }
    return lines_changed;
}

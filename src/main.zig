// modified by Adam Ross (https://www.github.com/profile-icons/git-stats); 26/05/26.
const builtin = @import("builtin");
const std = @import("std");
const version = @import("options").version;

const argparse = @import("argparse.zig");
const glob = @import("glob.zig");
const templateFill = @import("template.zig").fill;

const HttpClient = @import("http_client.zig");
const Statistics = @import("statistics.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
    // Even though we change it later, this is necessary to ensure that debug
    // logs aren't stripped in release builds.
    .log_level = .debug,
};

var log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    else => .warn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const embedded_overview_template = @embedFile("templates/overview.svg");
const embedded_languages_template = @embedFile("templates/languages.svg");
const embedded_i18n_json = @embedFile("locales/i18n.json");

const I18n = struct {
    github_statistics_str: []const u8,
    stars_str: []const u8,
    forks_str: []const u8,
    all_time_contributions_str: []const u8,
    lines_of_code_changed_str: []const u8,
    repo_traffic_str: []const u8,
    repos_with_contributions_str: []const u8,
    programming_languages_str: []const u8,
    by_line_changes_str: []const u8,
    estimated_str: []const u8,
};

const Args = struct {
    access_token: ?[]const u8 = null,
    json_input_file: ?[]const u8 = null,
    json_output_file: ?[]const u8 = null,
    silent: bool = false,
    debug: bool = false,
    verbose: bool = false,
    exclude_repos: ?[]const u8 = null,
    exclude_langs: ?[]const u8 = null,
    exclude_private: bool = false,
    overview_output_file: ?[]const u8 = null,
    languages_output_file: ?[]const u8 = null,
    overview_template: ?[]const u8 = null,
    languages_template: ?[]const u8 = null,
    max_retries: ?usize = 25,
    is_local: bool = false,
    version: bool = false,
    dump_overview_template: ?[]const u8 = null,
    dump_languages_template: ?[]const u8 = null,

    const Self = @This();

    pub fn init(main_init: std.process.Init) !Self {
        return try argparse.parse(main_init, Self, struct {
            fn errorCheck(a: Self, stderr: *std.Io.Writer) !bool {
                if ((a.access_token == null or a.access_token.?.len == 0) and
                    a.json_input_file == null and !a.version)
                {
                    try stderr.print(
                        "You must pass an input file or a GitHub token.\n",
                        .{},
                    );
                    return false;
                }
                return true;
            }
        }.errorCheck);
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Self).@"struct".fields) |field| {
            switch (@typeInfo(field.type)) {
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .pointer => |pointer| switch (pointer.size) {
                            .slice => if (@field(self, field.name)) |p|
                                allocator.free(p),
                            else => comptime unreachable,
                        },
                        .bool, .int => {},
                        else => comptime unreachable,
                    }
                },
                .pointer => |p| switch (p.size) {
                    .slice => allocator.free(@field(self, field.name)),
                    else => comptime unreachable,
                },
                .bool, .int => {},
                else => comptime unreachable,
            }
        }
    }
};

fn parseI18nJson(
    allocator: std.mem.Allocator,
    data: []const u8,
) !std.json.ObjectMap {
    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        allocator,
        data,
        .{},
    );

    return switch (parsed) {
        .object => |obj| obj,
        else => error.InvalidI18nFile,
    };
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = obj.get(key) orelse return error.MissingI18nKey;
    return switch (value) {
        .string => |s| s,
        else => error.InvalidI18nValue,
    };
}

fn i18nFromJson(obj: std.json.ObjectMap) !I18n {
    return .{
        .github_statistics_str = try jsonString(obj, "github_statistics_str"),
        .stars_str = try jsonString(obj, "stars_str"),
        .forks_str = try jsonString(obj, "forks_str"),
        .all_time_contributions_str = try jsonString(obj, "all_time_contributions_str"),
        .lines_of_code_changed_str = try jsonString(obj, "lines_of_code_changed_str"),
        .repo_traffic_str = try jsonString(obj, "repo_traffic_str"),
        .repos_with_contributions_str = try jsonString(obj, "repos_with_contributions_str"),
        .programming_languages_str = try jsonString(obj, "programming_languages_str"),
        .by_line_changes_str = try jsonString(obj, "by_line_changes_str"),
        .estimated_str = try jsonString(obj, "estimated_str"),
    };
}

fn fallbackI18n(i18n_json: std.json.ObjectMap) !I18n {
    const fallback_value =
        i18n_json.get("en") orelse
        return error.MissingEnglishI18nFallback;

    const fallback_obj = switch (fallback_value) {
        .object => |obj| obj,
        else => return error.InvalidI18nLocale,
    };

    return try i18nFromJson(fallback_obj);
}

fn i18nSvgLanguagesBlock(
    allocator: std.mem.Allocator,
    system_language: ?[]const u8,
    stats: anytype,
    i18n: I18n,
    progress: []const u8,
    lang_list: []const u8,
) ![]const u8 {
    const system_language_attr =
        if (system_language) |lang|
            try std.fmt.allocPrint(
                allocator,
                " systemLanguage=\"{s}\"",
                .{lang},
            )
        else
            "";

    const languages_by_str =
        if (stats.is_local)
            i18n.by_line_changes_str
        else
            i18n.estimated_str;

    return try std.fmt.allocPrint(allocator,
        \\<foreignObject{s} x="21" y="17" width="406.3" height="176">
        \\<div xmlns="http://www.w3.org/1999/xhtml" class="ellipsis">
        \\
        \\<h2>{d} {s} ({s})</h2>
        \\
        \\<div>
        \\<span class="progress">
        \\{s}
        \\</span>
        \\</div>
        \\
        \\<ul>
        \\
        \\{s}
        \\
        \\</ul>
        \\
        \\</div>
        \\</foreignObject>
        \\
    , .{
        system_language_attr,
        stats.languages.count(),
        i18n.programming_languages_str,
        languages_by_str,
        progress,
        lang_list,
    });
}

fn i18nLanguagesBlocks(
    allocator: std.mem.Allocator,
    i18n_json: std.json.ObjectMap,
    stats: anytype,
    progress: []const u8,
    lang_list: []const u8,
) ![]const u8 {
    var blocks = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer blocks.deinit(allocator);

    var iterator = i18n_json.iterator();
    while (iterator.next()) |entry| {
        const locale = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        const locale_obj = switch (value) {
            .object => |obj| obj,
            else => continue,
        };

        const i18n = try i18nFromJson(locale_obj);

        try blocks.append(
            allocator,
            try i18nSvgLanguagesBlock(
                allocator,
                locale,
                stats,
                i18n,
                progress,
                lang_list,
            ),
        );
    }

    try blocks.append(
        allocator,
        try i18nSvgLanguagesBlock(
            allocator,
            null,
            stats,
            try fallbackI18n(i18n_json),
            progress,
            lang_list,
        ),
    );

    return try std.mem.concat(allocator, u8, blocks.items);
}

fn i18nSvgOverviewBlock(
    allocator: std.mem.Allocator,
    system_language: ?[]const u8,
    stats: anytype,
    i18n: I18n,
) ![]const u8 {
    const system_language_attr =
        if (system_language) |lang|
            try std.fmt.allocPrint(
                allocator,
                " systemLanguage=\"{s}\"",
                .{lang},
            )
        else
            "";

    return try std.fmt.allocPrint(allocator,
        \\<foreignObject{s} x="21" y="21" width="318" height="168">
        \\<div xmlns="http://www.w3.org/1999/xhtml">
        \\<table>
        \\<thead><tr style="transform: translateX(0);">
        \\<th colspan="2">{s} {s}</th>
        \\</tr></thead>
        \\<tbody>
        \\<tr><td><svg class="octicon" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" version="1.1" width="16" height="16"><path fill-rule="evenodd" d="M8 .25a.75.75 0 01.673.418l1.882 3.815 4.21.612a.75.75 0 01.416 1.279l-3.046 2.97.719 4.192a.75.75 0 01-1.088.791L8 12.347l-3.766 1.98a.75.75 0 01-1.088-.79l.72-4.194L.818 6.374a.75.75 0 01.416-1.28l4.21-.611L7.327.668A.75.75 0 018 .25zm0 2.445L6.615 5.5a.75.75 0 01-.564.41l-3.097.45 2.24 2.184a.75.75 0 01.216.664l-.528 3.084 2.769-1.456a.75.75 0 01.698 0l2.77 1.456-.53-3.084a.75.75 0 01.216-.664l2.24-2.183-3.096-.45a.75.75 0 01-.564-.41L8 2.694v.001z"></path></svg>{s}</td><td>{d}</td></tr>
        \\<tr style="animation-delay: 150ms"><td><svg class="octicon" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" version="1.1" width="16" height="16" role="img"><path fill-rule="evenodd" d="M5 3.25a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm0 2.122a2.25 2.25 0 10-1.5 0v.878A2.25 2.25 0 005.75 8.5h1.5v2.128a2.251 2.251 0 101.5 0V8.5h1.5a2.25 2.25 0 002.25-2.25v-.878a2.25 2.25 0 10-1.5 0v.878a.75.75 0 01-.75.75h-4.5A.75.75 0 015 6.25v-.878zm3.75 7.378a.75.75 0 11-1.5 0 .75.75 0 011.5 0zm3-8.75a.75.75 0 100-1.5.75.75 0 000 1.5z"></path></svg>{s}</td><td>{d}</td></tr>
        \\<tr style="animation-delay: 300ms"><td><svg class="octicon" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" version="1.1" width="16" height="16" aria-hidden="true"><path fill-rule="evenodd" d="M1 2.5A2.5 2.5 0 013.5 0h8.75a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0V1.5h-8a1 1 0 00-1 1v6.708A2.492 2.492 0 013.5 9h3.25a.75.75 0 010 1.5H3.5a1 1 0 100 2h5.75a.75.75 0 010 1.5H3.5A2.5 2.5 0 011 11.5v-9zm13.23 7.79a.75.75 0 001.06-1.06l-2.505-2.505a.75.75 0 00-1.06 0L9.22 9.229a.75.75 0 001.06 1.061l1.225-1.224v6.184a.75.75 0 001.5 0V9.066l1.224 1.224z"></path></svg>{s}</td><td>{d}</td></tr>
        \\<tr style="animation-delay: 450ms"><td><svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill-rule="evenodd" d="M8.75 1.75a.75.75 0 00-1.5 0V5H4a.75.75 0 000 1.5h3.25v3.25a.75.75 0 001.5 0V6.5H12A.75.75 0 0012 5H8.75V1.75zM4 13a.75.75 0 000 1.5h8a.75.75 0 100-1.5H4z"></path></svg>{s}</td><td>{d}</td></tr>
        \\<tr style="animation-delay: 600ms"><td><svg class="octicon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill-rule="evenodd" d="M1.679 7.932c.412-.621 1.242-1.75 2.366-2.717C5.175 4.242 6.527 3.5 8 3.5c1.473 0 2.824.742 3.955 1.715 1.124.967 1.954 2.096 2.366 2.717a.119.119 0 010 .136c-.412.621-1.242 1.75-2.366 2.717C10.825 11.758 9.473 12.5 8 12.5c-1.473 0-2.824-.742-3.955-1.715C2.92 9.818 2.09 8.69 1.679 8.068a.119.119 0 010-.136zM8 2c-1.981 0-3.67.992-4.933 2.078C1.797 5.169.88 6.423.43 7.1a1.619 1.619 0 000 1.798c.45.678 1.367 1.932 2.637 3.024C4.329 13.008 6.019 14 8 14c1.981 0 3.67-.992 4.933-2.078 1.27-1.091 2.187-2.345 2.637-3.023a1.619 1.619 0 000-1.798c-.45-.678-1.367-1.932-2.637-3.023C11.671 2.992 9.981 2 8 2zm0 8a2 2 0 100-4 2 2 0 000 4z"></path></svg>{s}</td><td>{d}</td></tr>
        \\<tr style="animation-delay: 750ms"><td><svg class="octicon" viewBox="0 0 16 16" xmlns="http://www.w3.org/2000/svg" version="1.1" width="16" height="16" aria-hidden="true"><path fill-rule="evenodd" d="M2 2.5A2.5 2.5 0 014.5 0h8.75a.75.75 0 01.75.75v12.5a.75.75 0 01-.75.75h-2.5a.75.75 0 110-1.5h1.75v-2h-8a1 1 0 00-.714 1.7.75.75 0 01-1.072 1.05A2.495 2.495 0 012 11.5v-9zm10.5-1V9h-8c-.356 0-.694.074-1 .208V2.5a1 1 0 011-1h8zM5 12.25v3.25a.25.25 0 00.4.2l1.45-1.087a.25.25 0 01.3 0L8.6 15.7a.25.25 0 00.4-.2v-3.25a.25.25 0 00-.25-.25h-3.5a.25.25 0 00-.25.25z"></path></svg>{s}</td><td>{d}</td></tr>
        \\</tbody>
        \\</table>
        \\</div>
        \\</foreignObject>
        \\
    , .{
        system_language_attr,
        i18n.github_statistics_str,
        stats.name,
        i18n.stars_str,
        stats.stars,
        i18n.forks_str,
        stats.forks,
        i18n.all_time_contributions_str,
        stats.contributions,
        i18n.lines_of_code_changed_str,
        stats.lines_changed,
        i18n.repo_traffic_str,
        stats.traffic,
        i18n.repos_with_contributions_str,
        stats.repos,
    });
}

fn i18nOverviewBlocks(
    allocator: std.mem.Allocator,
    i18n_json: std.json.ObjectMap,
    stats: anytype,
) ![]const u8 {
    var blocks = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer blocks.deinit(allocator);

    var iterator = i18n_json.iterator();
    while (iterator.next()) |entry| {
        const locale = entry.key_ptr.*;
        const value = entry.value_ptr.*;

        const locale_obj = switch (value) {
            .object => |obj| obj,
            else => continue,
        };

        const i18n = try i18nFromJson(locale_obj);

        try blocks.append(
            allocator,
            try i18nSvgOverviewBlock(
                allocator,
                locale,
                stats,
                i18n,
            ),
        );
    }

    try blocks.append(
        allocator,
        try i18nSvgOverviewBlock(
            allocator,
            null,
            stats,
            try fallbackI18n(i18n_json),
        ),
    );

    return try std.mem.concat(allocator, u8, blocks.items);
}

fn overview(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
    i18n_json: std.json.ObjectMap,
) ![]const u8 {
    const a = arena.allocator();
    return templateFill(
        a,
        template,
        struct {
            i18n_overview_blocks: []const u8,
        }{
            .i18n_overview_blocks = try i18nOverviewBlocks(
                a,
                i18n_json,
                stats,
            ),
        },
    );
}

fn languages(
    arena: *std.heap.ArenaAllocator,
    stats: anytype,
    template: []const u8,
    i18n_json: std.json.ObjectMap,
) ![]const u8 {
    const a = arena.allocator();

    const progress = try a.alloc([]const u8, stats.languages.count());
    const lang_list = try a.alloc([]const u8, stats.languages.count());

    for (
        stats.languages.keys(),
        stats.languages.values(),
        progress,
        lang_list,
        0..,
    ) |language, count, *progress_s, *lang_s, i| {
        const color = stats.language_colors.get(language);
        const percent =
            100 * if (stats.languages_total == 0)
                0.0
            else
                @as(f64, @floatFromInt(count)) /
                    @as(f64, @floatFromInt(stats.languages_total));

        progress_s.* = try std.fmt.allocPrint(a,
            \\<span style="
            \\  background-color: {s}; 
            \\  width: {d:.3}%;
            \\" class="progress-item"></span>
        , .{ color orelse "#000", percent });

        lang_s.* = try std.fmt.allocPrint(a,
            \\<li style="animation-delay: {d}ms;">
            \\  <svg 
            \\      xmlns="http://www.w3.org/2000/svg" 
            \\      class="octicon"
            \\      style="fill: {s};" 
            \\      viewBox="0 0 16 16" 
            \\      version="1.1" 
            \\      width="16" 
            \\      height="16"
            \\  ><path 
            \\      fill-rule="evenodd" 
            \\      d="M8 4a4 4 0 100 8 4 4 0 000-8z"
            \\  ></path></svg>
            \\  <span class="lang">{s}</span>
            \\  <span class="percent">{d:.2}%</span>
            \\</li>
            \\
        , .{ (i + 1) * 150, color orelse "#000", language, percent });
    }

    const progress_html = try std.mem.concat(a, u8, progress);
    const lang_list_html = try std.mem.concat(a, u8, lang_list);

    return templateFill(
        a,
        template,
        struct {
            i18n_languages_blocks: []const u8,
        }{
            .i18n_languages_blocks = try i18nLanguagesBlocks(
                a,
                i18n_json,
                stats,
                progress_html,
                lang_list_html,
            ),
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try Args.init(init);
    defer args.deinit(allocator);
    if (args.silent) {
        log_level = .err;
    } else if (args.debug) {
        log_level = .debug;
    } else if (args.verbose) {
        log_level = .info;
    }

    if (args.version) {
        const stdout = std.Io.File.stdout();
        var writer = stdout.writer(io, &.{});
        try writer.interface.print(
            \\GitHub Stats version {s}
            \\https://github.com/jstrieb/github-stats
            \\Created by Jacob Strieb
            \\
        , .{version});
        return;
    }

    if (args.dump_overview_template) |path| {
        try writeFile(io, path, embedded_overview_template);
        return;
    }

    if (args.dump_languages_template) |path| {
        try writeFile(io, path, embedded_languages_template);
        return;
    }

    const exclude_repos =
        if (args.exclude_repos) |exclude|
            try splitList(allocator, exclude, " ,\t\r\n|\"'\x00")
        else
            null;
    defer if (exclude_repos) |exclude| allocator.free(exclude);
    const exclude_langs =
        if (args.exclude_langs) |exclude|
            try splitList(allocator, exclude, ",\t\r\n|\"'\x00")
        else
            null;
    defer if (exclude_langs) |exclude| allocator.free(exclude);

    var stats: Statistics = if (args.json_input_file) |path| stats: {
        const data = try readFile(allocator, io, path);
        defer allocator.free(data);
        break :stats try Statistics.initFromJson(allocator, data);
    } else if (args.access_token) |access_token| stats: {
        std.log.info(
            "Collecting statistics from GitHub {s}",
            .{if (args.is_local) "commit logs" else "API"},
        );
        var client: HttpClient = try .init(allocator, io, access_token);
        defer client.deinit();
        break :stats try Statistics.initWithOptionalParams(
            &client,
            allocator,
            io,
            .{
                .max_retries = args.max_retries,
                .use_api_line_stats = !args.is_local,
            },
        );
    } else unreachable;
    defer stats.deinit(allocator);

    if (args.json_output_file) |path| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try writeFile(
            io,
            path,
            try std.json.Stringify.valueAlloc(
                arena.allocator(),
                stats,
                .{ .whitespace = .indent_2 },
            ),
        );
    }

    var i18n_arena = std.heap.ArenaAllocator.init(allocator);
    defer i18n_arena.deinit();

    const i18n_json = try parseI18nJson(
        i18n_arena.allocator(),
        embedded_i18n_json,
    );

    var aggregate_stats: struct {
        languages: std.array_hash_map.String(u64),
        language_colors: std.array_hash_map.String([]const u8),
        is_local: bool,
        contributions: usize,
        name: []const u8,
        languages_total: u64 = 0,
        stars: usize = 0,
        forks: usize = 0,
        lines_changed: usize = 0,
        traffic: usize = 0,
        repos: usize = 0,
    } = .{
        .is_local = args.is_local,
        .contributions = stats.repo_contributions +
            stats.issue_contributions +
            stats.commit_contributions +
            stats.pr_contributions +
            stats.review_contributions,
        .languages = try .init(allocator, &.{}, &.{}),
        .language_colors = try .init(allocator, &.{}, &.{}),
        .name = stats.name,
    };
    defer aggregate_stats.languages.deinit(allocator);
    defer aggregate_stats.language_colors.deinit(allocator);

    for (stats.repositories) |repository| {
        if (glob.matchAny(exclude_repos orelse &.{}, repository.name) or
            (args.exclude_private and repository.private))
        {
            continue;
        }
        aggregate_stats.stars += repository.stars;
        aggregate_stats.forks += repository.forks;
        aggregate_stats.lines_changed += repository.lines_changed;
        aggregate_stats.traffic += repository.traffic;
        aggregate_stats.repos += 1;
        if (repository.languages) |langs| for (langs) |language| {
            if (glob.matchAny(exclude_langs orelse &.{}, language.name)) {
                continue;
            }

            const lang_lines_changed = @as(u64, language.lines_changed);
            if (lang_lines_changed == 0) {
                continue;
            }

            if (language.color) |color| {
                try aggregate_stats.language_colors.put(
                    allocator,
                    language.name,
                    color,
                );
            }
            var total = aggregate_stats.languages.get(language.name) orelse 0;

            total += lang_lines_changed;
            try aggregate_stats.languages.put(allocator, language.name, total);
            aggregate_stats.languages_total += lang_lines_changed;
        };
    }
    aggregate_stats.languages.sort(struct {
        values: @TypeOf(aggregate_stats.languages.values()),
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            // Sort in reverse order
            return self.values[a] > self.values[b];
        }
    }{ .values = aggregate_stats.languages.values() });

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        try writeFile(
            io,
            args.overview_output_file orelse "overview.svg",
            try overview(
                &arena,
                aggregate_stats,
                if (args.overview_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_overview_template,
                i18n_json,
            ),
        );

        try writeFile(
            io,
            args.languages_output_file orelse "languages.svg",
            try languages(
                &arena,
                aggregate_stats,
                if (args.languages_template) |template|
                    try readFile(arena.allocator(), io, template)
                else
                    embedded_languages_template,
                i18n_json,
            ),
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}

fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) ![]const u8 {
    std.log.info("Reading data from '{s}'", .{path});
    const in =
        if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdin()
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
    defer if (!std.mem.eql(u8, path, "-")) in.close(io);
    var read_buffer: [64 * 1024]u8 = undefined;
    var reader = in.reader(io, &read_buffer);
    return try (&reader.interface).allocRemaining(allocator, .unlimited);
}

fn writeFile(
    io: std.Io,
    path: []const u8,
    data: []const u8,
) !void {
    std.log.info("Writing data to '{s}'", .{path});
    const out =
        if (std.mem.eql(u8, path, "-"))
            std.Io.File.stdout()
        else
            try std.Io.Dir.cwd().createFile(io, path, .{});
    defer if (!std.mem.eql(u8, path, "-")) out.close(io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &write_buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn splitList(
    allocator: std.mem.Allocator,
    original: []const u8,
    separators: []const u8,
) ![][]const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    errdefer list.deinit(allocator);
    var iterator = std.mem.tokenizeAny(u8, original, separators);
    while (iterator.next()) |pattern| {
        try list.append(allocator, std.mem.trim(u8, pattern, " "));
    }
    return try list.toOwnedSlice(allocator);
}

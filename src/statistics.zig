// modified by Adam Ross (https://www.github.com/profile-icons/git-stats); 26/05/26.
const std = @import("std");
const git = @import("git.zig");
const HttpClient = @import("http_client.zig");

repositories: []Repository,
user: []const u8,
name: []const u8,
emails: [][]const u8,
repo_contributions: u32 = 0,
issue_contributions: u32 = 0,
commit_contributions: u32 = 0,
pr_contributions: u32 = 0,
review_contributions: u32 = 0,

const Statistics = @This();

pub const InitParams = struct {
    max_retries: ?usize = null,
    use_api_line_stats: bool = true,
};

const Repository = struct {
    name: []const u8,
    stars: u32,
    forks: u32,
    languages: ?[]Language,
    lines_changed: u32,
    views: u32,
    clones: u32,
    traffic: u32,
    private: bool,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.languages) |languages| {
            for (languages) |language| {
                language.deinit(allocator);
            }
            allocator.free(languages);
        }
    }

    pub fn getLinesChanged(
        self: *@This(),
        arena: *std.heap.ArenaAllocator,
        client: *HttpClient,
        user: []const u8,
    ) !std.http.Status {
        const response = try client.rest(
            try std.mem.concat(
                arena.allocator(),
                u8,
                &.{
                    "https://api.github.com/repos/",
                    self.name,
                    "/stats/contributors",
                },
            ),
        );
        defer client.allocator.free(response.body);
        if (response.status == .ok) {
            self.lines_changed = 0;
            const authors = std.json.parseFromSliceLeaky(
                []struct {
                    author: struct { login: []const u8 },
                    weeks: []struct {
                        a: u32,
                        d: u32,
                    },
                },
                arena.allocator(),
                response.body,
                .{ .ignore_unknown_fields = true },
            ) catch {
                // TODO: Replace with proper exception propagation when GitHub
                // gets their shit together and stops breaking this endpoint
                std.log.info(
                    "Skipping lines changed by {s} in {s} due to invalid " ++
                        "response from GitHub.",
                    .{ user, self.name },
                );
                return response.status;
            };
            for (authors) |o| {
                if (!std.mem.eql(u8, o.author.login, user)) {
                    continue;
                }
                for (o.weeks) |week| {
                    self.lines_changed += week.a;
                    self.lines_changed += week.d;
                }
            }
        }
        return response.status;
    }

    fn getLanguageStatsByLineChange(self: *@This()) void {
        if (self.languages == null) {
            return;
        }
        const languages = self.languages.?;

        var total_size: u64 = 0;
        for (languages) |language| {
            total_size += language.size;
        }

        if (total_size == 0 or self.lines_changed == 0) {
            for (languages) |*language| {
                language.additions = 0;
                language.deletions = 0;
                language.lines_changed = 0;
            }
            return;
        }

        var cur_size: u64 = 0;
        var cur_lines: u64 = 0;
        var prev_lines: u64 = 0;
        for (languages) |*language| {
            cur_size += language.size;
            cur_lines = (@as(u64, self.lines_changed) * cur_size) / total_size;
            language.additions = 0;
            language.deletions = 0;
            language.lines_changed = @intCast(cur_lines - prev_lines);
            prev_lines = cur_lines;
        }
    }

    fn isLanguagesStats(self: @This()) bool {
        if (self.languages) |languages| {
            for (languages) |language| {
                if (language.lines_changed > 0 or language.additions > 0 or language.deletions > 0) {
                    return true;
                }
            }
        }
        return false;
    }

    fn repoLanguageByteShareSize(self: @This(), name: []const u8) u32 {
        if (self.languages) |languages| {
            for (languages) |language| {
                if (std.mem.eql(u8, language.name, name)) {
                    return language.size;
                }
            }
        }
        return 0;
    }

    fn repoLanguageColour(self: @This(), name: []const u8) ?[]const u8 {
        if (self.languages) |languages| {
            for (languages) |language| {
                if (std.mem.eql(u8, language.name, name)) {
                    return language.color;
                }
            }
        }
        return null;
    }

    fn freeLanguagesResource(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.languages) |languages| {
            for (languages) |language| {
                language.deinit(allocator);
            }
            allocator.free(languages);
            self.languages = null;
        }
    }

    fn getUserStatsFromCommitLogs(
        self: *@This(),
        allocator: std.mem.Allocator,
        io: std.Io,
        login: []const u8,
        token: []const u8,
        emails: [][]const u8,
        repo_languages: *const git.GitHubRepoLanguages,
    ) !void {
        const git_languages = try git.getLanguageStatsByLineChanges(
            allocator,
            io,
            login,
            token,
            self.name,
            emails,
            repo_languages,
        );
        defer {
            for (git_languages) |language| {
                language.deinit(allocator);
            }
            allocator.free(git_languages);
        }

        var languages: std.ArrayList(Language) = .empty;
        errdefer {
            for (languages.items) |language| {
                language.deinit(allocator);
            }
            languages.deinit(allocator);
        }

        var total_lines_changed: u64 = 0;
        for (git_languages) |src| {
            total_lines_changed += src.lines_changed;

            const repo_language_size = self.repoLanguageByteShareSize(src.name);
            if (repo_language_size == 0) {
                continue;
            }

            var language = Language{
                .name = try allocator.dupe(u8, src.name),
                .size = repo_language_size,
                .additions = src.additions,
                .deletions = src.deletions,
                .lines_changed = src.lines_changed,
                .color = null,
                .extensions = &.{},
            };
            var committed = false;
            errdefer if (!committed) language.deinit(allocator);

            language.color = if (self.repoLanguageColour(src.name)) |c|
                try allocator.dupe(u8, c)
            else if (src.color) |c|
                try allocator.dupe(u8, c)
            else
                null;
            language.extensions = try getFileExtensions(allocator, src.extensions);

            try languages.append(allocator, language);
            committed = true;
        }

        const languages_used = try languages.toOwnedSlice(allocator);
        self.freeLanguagesResource(allocator);
        self.languages = languages_used;
        self.lines_changed = saturatingCastU32(total_lines_changed);
    }
};

fn getLanguageStatsByRepo(self: *Statistics) void {
    for (self.repositories) |*repository| {
        if (!repository.isLanguagesStats()) {
            repository.getLanguageStatsByLineChange();
        }
    }
}

fn getUserStatsFromCommitLogs(
    self: *Statistics,
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *HttpClient,
    strict: bool,
) !void {
    const response = try client.rest(git.gh_languages_url);
    defer client.allocator.free(response.body);

    if (response.status != .ok) {
        std.log.info(
            "Failed to get GitHub language metadata ({?s})",
            .{response.status.phrase()},
        );
        return error.RequestFailed;
    }

    const repo_languages = try git.GitHubRepoLanguages.init(allocator, response.body);
    defer repo_languages.deinit(allocator);

    for (self.repositories) |*repository| {
        repository.getUserStatsFromCommitLogs(
            allocator,
            io,
            self.user,
            client.token,
            self.emails,
            &repo_languages,
        ) catch |e| {
            if (strict) return e;
            std.log.info(
                "Falling back to API-estimated language line changes ({any})",
                .{e},
            );
            repository.getLanguageStatsByLineChange();
        };
    }
}

fn getFileExtensions(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![][]const u8 {
    if (values.len == 0) {
        return &.{};
    }

    const result = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(result);

    for (values, result, 0..) |src, *dest, i| {
        errdefer {
            for (result[0..i]) |value| {
                allocator.free(value);
            }
        }
        dest.* = try allocator.dupe(u8, src);
    }

    return result;
}

const Language = struct {
    name: []const u8,
    size: u32,
    additions: u32 = 0,
    deletions: u32 = 0,
    lines_changed: u32 = 0,
    color: ?[]const u8 = null,
    extensions: [][]const u8 = &.{},

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.color) |color| allocator.free(color);

        for (self.extensions) |extension| {
            allocator.free(extension);
        }
        if (self.extensions.len > 0) {
            allocator.free(self.extensions);
        }
    }
};

pub fn init(
    client: *HttpClient,
    allocator: std.mem.Allocator,
    io: std.Io,
    max_retries: ?usize,
) !Statistics {
    return initWithOptionalParams(client, allocator, io, .{
        .max_retries = max_retries,
        .use_api_line_stats = true,
    });
}

pub fn initWithOptionalParams(
    client: *HttpClient,
    allocator: std.mem.Allocator,
    io: std.Io,
    params: InitParams,
) !Statistics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var self: Statistics = try getRepos(allocator, &arena, client);
    errdefer self.deinit(allocator);

    try self.getLineStats(
        allocator,
        &arena,
        io,
        client,
        params.max_retries,
        params.use_api_line_stats,
    );

    return self;
}

fn getLineStats(
    self: *Statistics,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    client: *HttpClient,
    max_retries: ?usize,
    use_api_line_stats: bool,
) !void {
    if (use_api_line_stats) {
        self.getLineStatsFromApi(arena, io, client, max_retries) catch |api_err| {
            std.log.info(
                "API line stats failed; falling back to commit logs ({any})",
                .{api_err},
            );
            try self.getLineStatsFromCommitLogs(allocator, io, client);
        };
    } else {
        self.getLineStatsFromCommitLogs(allocator, io, client) catch |git_err| {
            std.log.info(
                "Commit-log line stats failed; falling back to API ({any})",
                .{git_err},
            );
            try self.getLineStatsFromApi(arena, io, client, max_retries);
        };
    }
}

fn getLineStatsFromApi(
    self: *Statistics,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    client: *HttpClient,
    max_retries: ?usize,
) !void {
    try self.getLinesChanged(arena, io, client, max_retries);
    self.getLanguageStatsByRepo();
}

fn getLineStatsFromCommitLogs(
    self: *Statistics,
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *HttpClient,
) !void {
    try self.getUserStatsFromCommitLogs(allocator, io, client, true);
}

pub fn initFromJson(allocator: std.mem.Allocator, s: []const u8) !Statistics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(
        Statistics,
        arena.allocator(),
        s,
        .{ .ignore_unknown_fields = true },
    );
    var self = try deepcopy(allocator, parsed);
    self.getLanguageStatsByRepo();
    return self;
}

pub fn deinit(self: Statistics, allocator: std.mem.Allocator) void {
    for (self.repositories) |repository| {
        repository.deinit(allocator);
    }
    allocator.free(self.repositories);
    allocator.free(self.user);
    allocator.free(self.name);
    for (self.emails) |email| {
        allocator.free(email);
    }
    allocator.free(self.emails);
}

fn appendUniqueEmail(
    emails: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    email: []const u8,
) !void {
    for (emails.items) |existing| {
        if (std.ascii.eqlIgnoreCase(existing, email)) {
            return;
        }
    }
    try emails.append(allocator, email);
}

fn saturatingCastU32(n: u64) u32 {
    return if (n > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(n);
}

fn getBasicInfo(client: *HttpClient, arena: *std.heap.ArenaAllocator) !struct {
    years: []u32,
    user: []const u8,
    name: ?[]const u8,
    emails: [][]const u8,
} {
    std.log.info("Getting contribution years...", .{});
    const response = try client.graphql(
        \\query {
        \\  viewer {
        \\    login
        \\    databaseId
        \\    name
        \\    contributionsCollection {
        \\      contributionYears
        \\    }
        \\  }
        \\}
    , null);
    defer client.allocator.free(response.body);
    if (response.status != .ok) {
        std.log.err(
            "Failed to get contribution years ({?s})",
            .{response.status.phrase()},
        );
        return error.RequestFailed;
    }
    const parsed = (try std.json.parseFromSliceLeaky(
        struct {
            data: struct {
                viewer: struct {
                    login: []const u8,
                    databaseId: ?u32,
                    name: ?[]const u8,
                    contributionsCollection: struct {
                        contributionYears: []u32,
                    },
                },
            },
        },
        arena.allocator(),
        response.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    )).data.viewer;

    std.log.info("Getting contributor emails...", .{});
    const email_response =
        try client.rest("https://api.github.com/user/emails");
    defer client.allocator.free(email_response.body);

    var emails: std.ArrayList([]const u8) = .empty;
    defer emails.deinit(arena.allocator());

    if (email_response.status == .ok) {
        const parsed_emails = (try std.json.parseFromSliceLeaky(
            []struct { email: []const u8 },
            arena.allocator(),
            email_response.body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ));
        for (parsed_emails) |src| {
            try appendUniqueEmail(&emails, arena.allocator(), src.email);
        }
    } else {
        std.log.err("Failed to get user emails. " ++
            "Token may be missing `user:email` permission.", .{});
    }

    try appendUniqueEmail(
        &emails,
        arena.allocator(),
        try std.fmt.allocPrint(
            arena.allocator(),
            "{s}@users.noreply.github.com",
            .{parsed.login},
        ),
    );

    if (parsed.databaseId) |database_id| {
        try appendUniqueEmail(
            &emails,
            arena.allocator(),
            try std.fmt.allocPrint(
                arena.allocator(),
                "{d}+{s}@users.noreply.github.com",
                .{ database_id, parsed.login },
            ),
        );
    }

    return .{
        .years = parsed.contributionsCollection.contributionYears,
        .user = parsed.login,
        .name = parsed.name,
        .emails = try emails.toOwnedSlice(arena.allocator()),
    };
}

fn isRepoPushAccess(permission: []const u8) bool {
    return std.mem.eql(u8, permission, "WRITE") or std.mem.eql(u8, permission, "MAINTAIN") or std.mem.eql(u8, permission, "ADMIN");
}

fn getReposByYear(
    context: struct {
        allocator: std.mem.Allocator,
        arena: *std.heap.ArenaAllocator,
        client: *HttpClient,
        user: []const u8,
        result: *Statistics,
        seen: *std.StringHashMap(bool),
        repositories: *std.ArrayList(Repository),
    },
    year: usize,
    start_month: usize,
    months: usize,
) !void {
    std.log.info(
        "Getting {d} month{s} of data starting from {d}/{d}...",
        .{ months, if (months != 1) "s" else "", start_month + 1, year },
    );
    const response = try context.client.graphql(
        \\query ($from: DateTime, $to: DateTime) {
        \\  viewer {
        \\    contributionsCollection(from: $from, to: $to) {
        \\      totalRepositoryContributions
        \\      totalIssueContributions
        \\      totalCommitContributions
        \\      totalPullRequestContributions
        \\      totalPullRequestReviewContributions
        \\      commitContributionsByRepository(maxRepositories: 100) {
        \\        repository {
        \\          nameWithOwner
        \\          stargazerCount
        \\          forkCount
        \\          isPrivate
        \\          viewerPermission
        \\          languages(
        \\              first: 100,
        \\              orderBy: { direction: DESC, field: SIZE }
        \\          ) {
        \\            edges {
        \\              size
        \\              node {
        \\                name
        \\                color
        \\              }
        \\            }
        \\          }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ,
        .{
            .from = try std.fmt.allocPrint(
                context.arena.allocator(),
                "{d}-{d:02}-01T00:00:00Z",
                .{ year, start_month + 1 },
            ),
            .to = try std.fmt.allocPrint(
                context.arena.allocator(),
                "{d}-{d:02}-01T00:00:00Z",
                .{
                    year + (start_month + months) / 12,
                    (start_month + months) % 12 + 1,
                },
            ),
        },
    );
    defer context.client.allocator.free(response.body);
    if (response.status != .ok) {
        std.log.err(
            "Failed to get data from {d} ({?s})",
            .{ year, response.status.phrase() },
        );
        return error.RequestFailed;
    }
    const stats = (try std.json.parseFromSliceLeaky(
        struct { data: struct { viewer: struct {
            contributionsCollection: struct {
                totalRepositoryContributions: u32,
                totalIssueContributions: u32,
                totalCommitContributions: u32,
                totalPullRequestContributions: u32,
                totalPullRequestReviewContributions: u32,
                commitContributionsByRepository: []struct {
                    repository: struct {
                        nameWithOwner: []const u8,
                        stargazerCount: u32,
                        forkCount: u32,
                        isPrivate: bool,
                        viewerPermission: []const u8,
                        languages: ?struct {
                            edges: ?[]struct {
                                size: u32,
                                node: struct {
                                    name: []const u8,
                                    color: ?[]const u8,
                                },
                            },
                        },
                    },
                },
            },
        } } },
        context.arena.allocator(),
        response.body,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    )).data.viewer.contributionsCollection;
    std.log.info(
        "Parsed {d} total repositories from {d}",
        .{ stats.commitContributionsByRepository.len, year },
    );

    const limit = 100;
    // This slightly convoluted logic subdivides the months range for the
    // current call. It assumes the initial months range is 12, and subdivides
    // by increasingly large prime factors of 12. If it cannot divide by any
    // prime factors of 12, the size of the range is 1. In that case, it emits a
    // warning and proceeds with processing the data.
    if (stats.commitContributionsByRepository.len >= limit) {
        for (&[_]usize{ 2, 3 }) |factor| {
            if (months % factor == 0) {
                for (0..factor) |i| {
                    try getReposByYear(
                        context,
                        year,
                        start_month + (months / factor) * i,
                        months / factor,
                    );
                }
                return;
            }
        } else {
            std.log.warn(
                "More than {d} repos returned for {d}/{d}. " ++
                    "Some data may be omitted due to GitHub API limitations.",
                .{ limit, start_month + 1, year },
            );
        }
    }

    context.result.repo_contributions += stats.totalRepositoryContributions;
    context.result.issue_contributions += stats.totalIssueContributions;
    context.result.commit_contributions += stats.totalCommitContributions;
    context.result.pr_contributions += stats.totalPullRequestContributions;
    context.result.review_contributions +=
        stats.totalPullRequestReviewContributions;

    for (stats.commitContributionsByRepository) |x| {
        const raw_repo = x.repository;
        if (context.seen.get(raw_repo.nameWithOwner) orelse false) {
            std.log.debug(
                "Skipping {s} (seen)",
                .{raw_repo.nameWithOwner},
            );
            continue;
        }
        var repository = Repository{
            .name = try context.allocator.dupe(u8, raw_repo.nameWithOwner),
            .stars = raw_repo.stargazerCount,
            .forks = raw_repo.forkCount,
            .private = raw_repo.isPrivate,
            .languages = null,
            .views = 0,
            .clones = 0,
            .traffic = 0,
            .lines_changed = 0,
        };
        errdefer repository.deinit(context.allocator);
        if (raw_repo.languages) |repo_languages| {
            if (repo_languages.edges) |raw_languages| {
                repository.languages = try context.allocator.alloc(
                    Language,
                    raw_languages.len,
                );
                errdefer {
                    context.allocator.free(repository.languages.?);
                    repository.languages = null;
                }
                for (
                    raw_languages,
                    repository.languages.?,
                    0..,
                ) |raw, *language, i| {
                    errdefer {
                        for (0..i, repository.languages.?) |_, l| {
                            l.deinit(context.allocator);
                        }
                    }
                    language.* = .{
                        .name = try context.allocator.dupe(u8, raw.node.name),
                        .size = raw.size,
                        .additions = 0,
                        .deletions = 0,
                        .lines_changed = 0,
                        .extensions = &.{},
                    };
                    errdefer context.allocator.free(language.name);
                    if (raw.node.color) |color| {
                        language.color = try context.allocator.dupe(u8, color);
                    }
                    errdefer if (language.color) |c| context.allocator.free(c);
                }
            }
        }

        if (isRepoPushAccess(raw_repo.viewerPermission)) {
            std.log.info(
                "Getting views for {s}...",
                .{raw_repo.nameWithOwner},
            );
            const response2 = try context.client.rest(
                try std.mem.concat(
                    context.arena.allocator(),
                    u8,
                    &.{
                        "https://api.github.com/repos/",
                        raw_repo.nameWithOwner,
                        "/traffic/views",
                    },
                ),
            );
            defer context.client.allocator.free(response2.body);
            if (response2.status == .ok) {
                repository.views = (try std.json.parseFromSliceLeaky(
                    struct { count: u32 },
                    context.arena.allocator(),
                    response2.body,
                    .{ .ignore_unknown_fields = true },
                )).count;
            } else {
                std.log.info(
                    "Failed to get views for {s} ({?s})",
                    .{ raw_repo.nameWithOwner, response2.status.phrase() },
                );
            }
        }

        if (isRepoPushAccess(raw_repo.viewerPermission)) {
            std.log.info(
                "Getting clones for {s}...",
                .{raw_repo.nameWithOwner},
            );
            const response2 = try context.client.rest(
                try std.mem.concat(
                    context.arena.allocator(),
                    u8,
                    &.{
                        "https://api.github.com/repos/",
                        raw_repo.nameWithOwner,
                        "/traffic/clones",
                    },
                ),
            );
            defer context.client.allocator.free(response2.body);
            if (response2.status == .ok) {
                repository.clones = (try std.json.parseFromSliceLeaky(
                    struct { count: u32 },
                    context.arena.allocator(),
                    response2.body,
                    .{ .ignore_unknown_fields = true },
                )).count;
            } else {
                std.log.info(
                    "Failed to get clones for {s} ({?s})",
                    .{ raw_repo.nameWithOwner, response2.status.phrase() },
                );
            }
        }

        repository.traffic = repository.views + repository.clones;

        try context.seen.put(raw_repo.nameWithOwner, true);
        try context.repositories.append(context.allocator, repository);
    }
}

fn getRepos(
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    client: *HttpClient,
) !Statistics {
    var result: Statistics = .{
        .user = undefined,
        .name = undefined,
        .emails = undefined,
        .repositories = undefined,
    };
    var repositories: std.ArrayList(Repository) =
        try .initCapacity(allocator, 32);
    errdefer {
        for (repositories.items) |repo| {
            repo.deinit(allocator);
        }
        repositories.deinit(allocator);
    }
    var seen: std.StringHashMap(bool) = .init(arena.allocator());
    defer seen.deinit();

    const info = try getBasicInfo(client, arena);
    if (info.name) |n| {
        std.log.info("Getting data for {s} ({s})...", .{ n, info.user });
    } else {
        std.log.info("Getting data for user {s}...", .{info.user});
    }

    result.user = try allocator.dupe(u8, info.user);
    errdefer allocator.free(result.user);
    result.name = try allocator.dupe(u8, info.name orelse info.user);
    errdefer allocator.free(result.name);

    result.emails = try allocator.alloc([]const u8, info.emails.len);
    errdefer allocator.free(result.emails);
    for (result.emails, info.emails, 0..) |*dest, src, i| {
        errdefer {
            for (result.emails[0..i]) |email| {
                allocator.free(email);
            }
        }
        dest.* = try allocator.dupe(u8, src);
    }
    errdefer {
        for (result.emails) |email| {
            allocator.free(email);
        }
    }

    for (info.years) |year| {
        try getReposByYear(.{
            .allocator = allocator,
            .arena = arena,
            .client = client,
            .user = info.user,
            .result = &result,
            .seen = &seen,
            .repositories = &repositories,
        }, year, 0, 12);
    }

    result.repositories = try repositories.toOwnedSlice(allocator);
    errdefer {
        for (result.repositories) |repository| {
            repository.deinit(allocator);
        }
        allocator.free(result.repositories);
    }
    std.sort.pdq(Repository, result.repositories, {}, struct {
        pub fn lessThanFn(_: void, lhs: Repository, rhs: Repository) bool {
            if (rhs.traffic == lhs.traffic) {
                return rhs.stars + rhs.forks < lhs.stars + lhs.forks;
            }
            return rhs.traffic < lhs.traffic;
        }
    }.lessThanFn);

    return result;
}

fn getLinesChanged(
    self: *Statistics,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    client: *HttpClient,
    max_retries: ?usize,
) !void {
    const allocator = arena.allocator();
    const T = struct {
        repo: *Repository,
        delay: i64,
        timestamp: i64,
        retries: usize,
    };
    var q: std.PriorityQueue(T, void, struct {
        pub fn compareFn(_: void, lhs: T, rhs: T) std.math.Order {
            return std.math.order(lhs.timestamp, rhs.timestamp);
        }
    }.compareFn) = .empty;
    defer q.deinit(allocator);
    for (self.repositories) |*repo| {
        if (repo.lines_changed > 0) {
            continue;
        }
        try q.push(allocator, .{
            .repo = repo,
            .delay = 0,
            .timestamp = std.Io.Clock.real.now(io).toSeconds(),
            .retries = 0,
        });
    }
    while (q.pop()) |_item| {
        var item = _item;
        const now = std.Io.Clock.real.now(io).toSeconds();
        if (item.timestamp > now) {
            const delay = item.timestamp - now;
            std.log.debug("Sleeping for {d}s. Waiting for {d} repo{s}.", .{
                delay,
                q.count() + 1,
                if (q.count() + 1 != 0) "s" else "",
            });
            try io.sleep(.fromSeconds(delay), .real);
        }
        switch (try item.repo.getLinesChanged(arena, client, self.user)) {
            .ok => {},
            // If we're hitting rate limits on this API, just clone the repo
            // locally to compute lines changed
            // https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api?apiVersion=2026-03-10#rate-limit-errors
            .accepted, .forbidden, .too_many_requests => {
                item.timestamp =
                    std.Io.Clock.real.now(io).toSeconds() + item.delay;
                // Note: this actually works way better with a very short delay,
                // hence no exponential backoff
                const random: std.Random.IoSource = .{ .io = io };
                item.delay = random.interface().intRangeAtMost(i64, 0, 4);
                item.retries += 1;
                if (max_retries) |max| {
                    if (item.retries <= max) {
                        try q.push(allocator, item);
                    } else {
                        std.log.info(
                            "Cloning {s} to get lines changed...",
                            .{item.repo.name},
                        );
                        item.repo.lines_changed = git.getLinesChanged(
                            arena.allocator(),
                            io,
                            self.user,
                            client.token,
                            item.repo.name,
                            self.emails,
                        ) catch |e| switch (e) {
                            error.GitNotInstalled => 0,
                            else => return e,
                        };
                        std.log.info("Got {d} line{s} changed by {s} in {s}", .{
                            item.repo.lines_changed,
                            if (item.repo.lines_changed != 1) "s" else "",
                            self.user,
                            item.repo.name,
                        });
                    }
                } else {
                    try q.push(allocator, item);
                }
            },
            else => |status| {
                std.log.info(
                    "Failed to get contribution data for {s} ({?s})",
                    .{ item.repo.name, status.phrase() },
                );
                std.log.err(
                    "Request failed with response {?s}",
                    .{status.phrase()},
                );
                return error.RequestFailed;
            },
        }
    }
}

// May not correctly free memory if there are errors during copying
fn deepcopy(a: std.mem.Allocator, o: anytype) !@TypeOf(o) {
    return switch (@typeInfo(@TypeOf(o))) {
        .pointer => |p| switch (p.size) {
            .slice => v: {
                const result = try a.dupe(p.child, o);
                errdefer a.free(result);
                for (o, result) |src, *dest| {
                    dest.* = try deepcopy(a, src);
                }
                break :v result;
            },
            // Only slices in this struct
            else => comptime unreachable,
        },
        .@"struct" => |s| v: {
            var result = o;
            inline for (s.fields) |field| {
                @field(result, field.name) =
                    try deepcopy(a, @field(o, field.name));
            }
            break :v result;
        },
        .optional => if (o) |v| try deepcopy(a, v) else null,
        else => o,
    };
}

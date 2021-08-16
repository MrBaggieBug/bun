const std = @import("std");
const logger = @import("./logger.zig");
usingnamespace @import("./global.zig");
const CodepointIterator = @import("./string_immutable.zig").CodepointIterator;
const Fs = @import("./fs.zig");
const Api = @import("./api/schema.zig").Api;
const Variable = struct {
    key: string,
    value: string,
    has_nested_value: bool = false,
};

// i don't expect anyone to actually use the escape line feed character
const escLineFeed = 0x0C;
// arbitrary character that is invalid in a real text file
const implicitQuoteCharacter = 8;

// you get 4k. I hope you don't need more than that.
threadlocal var temporary_nested_value_buffer: [4096]u8 = undefined;

pub const Lexer = struct {
    source: *const logger.Source,
    iter: CodepointIterator,
    _codepoint: CodePoint = 0,
    current: usize = 0,
    start: usize = 0,
    end: usize = 0,
    has_nested_value: bool = false,
    has_newline_before: bool = true,

    pub inline fn codepoint(this: *Lexer) CodePoint {
        return this._codepoint;
    }

    pub fn step(this: *Lexer) void {
        @call(.{ .modifier = .always_inline }, CodepointIterator.nextCodepointNoReturn, .{&this.iter});
        this._codepoint = this.iter.c;
        this.current += 1;
    }

    pub fn eatNestedValue(
        lexer: *Lexer,
        comptime ContextType: type,
        ctx: *ContextType,
        comptime Writer: type,
        writer: Writer,
        variable: Variable,
        comptime getter: fn (ctx: *const ContextType, key: string) ?string,
    ) !void {
        var i: usize = 0;
        var last_flush: usize = 0;

        top: while (i < variable.value.len) {
            switch (variable.value[i]) {
                '$' => {
                    i += 1;
                    const start = i;

                    while (i < variable.value.len) {
                        switch (variable.value[i]) {
                            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {
                                i += 1;
                            },
                            else => {
                                break;
                            },
                        }
                    }

                    try writer.writeAll(variable.value[last_flush .. start - 1]);
                    last_flush = i;
                    const name = variable.value[start..i];

                    if (@call(.{ .modifier = .always_inline }, getter, .{ ctx, name })) |new_value| {
                        if (new_value.len > 0) {
                            try writer.writeAll(new_value);
                        }
                    }

                    continue :top;
                },
                '\\' => {
                    i += 1;
                    switch (variable.value[i]) {
                        '$' => {
                            i += 1;
                            continue;
                        },
                        else => {},
                    }
                },
                else => {},
            }
            i += 1;
        }

        try writer.writeAll(variable.value[last_flush..]);
    }

    pub fn eatValue(
        lexer: *Lexer,
        comptime quote: CodePoint,
    ) string {
        const start = lexer.current - 1;
        lexer.step();

        var last_non_space: usize = 0;
        while (true) {
            switch (lexer.codepoint()) {
                '\\' => {
                    lexer.step();
                    // Handle Windows CRLF
                    last_non_space += 1;

                    switch (lexer.codepoint()) {
                        '\r' => {
                            lexer.step();
                            last_non_space += 1;
                            if (lexer.codepoint() == '\n') {
                                lexer.step();
                                last_non_space += 1;
                            }
                            continue;
                        },
                        '$' => {
                            lexer.step();
                            continue;
                        },
                        else => {
                            continue;
                        },
                    }
                },
                -1 => {
                    lexer.end = lexer.current;

                    return lexer.source.contents[start..][0 .. last_non_space + 1];
                },
                '$' => {
                    lexer.has_nested_value = true;
                    last_non_space += 1;
                },

                '#' => {
                    lexer.step();
                    lexer.eatComment();

                    return lexer.source.contents[start..][0 .. last_non_space + 1];
                },

                '\n', '\r', escLineFeed => {
                    switch (comptime quote) {
                        '\'' => {
                            lexer.end = lexer.current;
                            lexer.step();
                            return lexer.source.contents[start .. lexer.end - 1];
                        },
                        implicitQuoteCharacter => {
                            lexer.end = lexer.current;
                            lexer.step();

                            return lexer.source.contents[start..][0 .. last_non_space + 1];
                        },
                        '"' => {
                            // We keep going

                        },
                        else => {},
                    }
                },
                quote => {
                    lexer.end = lexer.current;
                    lexer.step();
                    return lexer.source.contents[start..lexer.end];
                },
                ' ' => {},
                else => {
                    last_non_space += 1;
                },
            }

            lexer.step();
        }
        unreachable;
    }

    pub fn eatComment(this: *Lexer) void {
        while (true) {
            switch (this.codepoint()) {
                '\r' => {
                    this.step();
                    if (this.codepoint() == '\n') {
                        return;
                    }
                },
                '\n' => {
                    this.step();
                    return;
                },
                -1 => {
                    return;
                },
                else => {
                    this.step();
                },
            }
        }
    }

    // const NEWLINE = '\n'
    // const RE_INI_KEY_VAL = /^\s*([\w.-]+)\s*=\s*(.*)?\s*$/
    // const RE_NEWLINES = /\\n/g
    // const NEWLINES_MATCH = /\r\n|\n|\r/
    pub fn next(this: *Lexer) ?Variable {
        if (this.end == 0) this.step();

        const start = this.start;

        this.has_newline_before = this.end == 0;

        restart: while (true) {
            switch (this.codepoint()) {
                0, -1 => {
                    return null;
                },
                '#' => {
                    this.step();

                    this.eatComment();
                    continue :restart;
                },
                '\r', '\n', 0x2028, 0x2029 => {
                    this.step();
                    this.has_newline_before = true;
                    continue;
                },

                // Valid keys:
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {
                    this.start = this.current - 1;
                    this.step();
                    var last_non_space: usize = 0;
                    while (true) {
                        switch (this.codepoint()) {

                            // to match npm's "dotenv" behavior, we ignore lines that don't have an equals
                            '\r', '\n', escLineFeed => {
                                this.end = this.current;
                                this.step();
                                continue :restart;
                            },
                            0, -1 => {
                                this.end = this.current;
                                return Variable{ .key = this.source.contents[this.start..][0 .. last_non_space + 1], .value = "" };
                            },
                            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {
                                last_non_space += 1;
                            },
                            '=' => {
                                this.end = this.current;
                                const key = this.source.contents[this.start..][0 .. last_non_space + 1];
                                if (key.len == 0) return null;
                                this.step();

                                this.has_nested_value = false;
                                inner: while (true) {
                                    switch (this.codepoint()) {
                                        '"' => {
                                            const value = this.eatValue('"');
                                            return Variable{
                                                .key = key,
                                                .value = value,
                                                .has_nested_value = this.has_nested_value,
                                            };
                                        },
                                        '\'' => {
                                            const value = this.eatValue('\'');
                                            return Variable{
                                                .key = key,
                                                .value = value,
                                                .has_nested_value = this.has_nested_value,
                                            };
                                        },
                                        0, -1 => {
                                            return Variable{ .key = key, .value = "" };
                                        },
                                        '\r', '\n', escLineFeed => {
                                            this.step();
                                            return Variable{ .key = key, .value = "" };
                                        },
                                        // consume unquoted leading spaces
                                        ' ' => {
                                            this.step();
                                            continue :inner;
                                        },
                                        // we treat everything else the same as if it were wrapped in single quotes
                                        // except we don't terminate on that character
                                        else => {
                                            const value = this.eatValue(implicitQuoteCharacter);
                                            return Variable{
                                                .key = key,
                                                .value = value,
                                                .has_nested_value = this.has_nested_value,
                                            };
                                        },
                                    }
                                }
                            },
                            ' ' => {},
                            else => {
                                last_non_space += 1;
                            },
                        }
                        this.step();
                    }
                },
                else => {},
            }

            this.step();
        }
    }

    pub fn init(source: *const logger.Source) Lexer {
        return Lexer{
            .source = source,
            .iter = CodepointIterator{ .bytes = source.contents, .i = 0 },
        };
    }
};

pub const Loader = struct {
    map: *Map,
    allocator: *std.mem.Allocator,

    @".env.local": ?logger.Source = null,
    @".env.development": ?logger.Source = null,
    @".env.production": ?logger.Source = null,
    @".env": ?logger.Source = null,

    did_load_process: bool = false,

    const empty_string_value: string = "\"\"";

    pub fn copyForDefine(
        this: *Loader,
        comptime Type: type,
        to: *Type,
        framework_defaults: Api.StringMap,
        behavior: Api.DotEnvBehavior,
        prefix: string,
        allocator: *std.mem.Allocator,
    ) ![]u8 {
        var iter = this.map.iter();
        var key_count: usize = 0;
        var string_map_hashes = try allocator.alloc(u64, framework_defaults.keys.len);
        defer allocator.free(string_map_hashes);
        const invalid_hash = std.math.maxInt(u64) - 1;
        std.mem.set(u64, string_map_hashes, invalid_hash);

        var key_buf: []u8 = "";
        // Frameworks determine an allowlist of values

        for (framework_defaults.keys) |key, i| {
            if (key.len > "process.env.".len and strings.eqlComptime(key[0.."process.env.".len], "process.env.")) {
                const hashable_segment = key["process.env.".len..];
                string_map_hashes[i] = std.hash.Wyhash.hash(0, hashable_segment);
            }
        }

        // We have to copy all the keys to prepend "process.env" :/
        var key_buf_len: usize = 0;

        if (behavior != .disable) {
            if (behavior == .prefix) {
                std.debug.assert(prefix.len > 0);

                while (iter.next()) |entry| {
                    if (strings.startsWith(entry.key_ptr.*, prefix)) {
                        key_buf_len += entry.key_ptr.len;
                        key_count += 1;
                        std.debug.assert(entry.key_ptr.len > 0);
                    }
                }
            } else {
                while (iter.next()) |entry| {
                    key_buf_len += entry.key_ptr.len;
                    key_count += 1;
                    std.debug.assert(entry.key_ptr.len > 0);
                }
            }

            if (key_buf_len > 0) {
                iter.reset();
                key_buf = try allocator.alloc(u8, key_buf_len + key_count * "process.env.".len);
                errdefer allocator.free(key_buf);
                var key_fixed_allocator = std.heap.FixedBufferAllocator.init(key_buf);
                var key_allocator = &key_fixed_allocator.allocator;

                if (behavior == .prefix) {
                    while (iter.next()) |entry| {
                        const value: string = if (entry.value_ptr.*.len == 0) empty_string_value else entry.value_ptr.*;

                        if (strings.startsWith(entry.key_ptr.*, prefix)) {
                            _ = try to.getOrPutValue(
                                std.fmt.allocPrint(key_allocator, "process.env.{s}", .{entry.key_ptr.*}) catch unreachable,
                                value,
                            );
                        } else {
                            const hash = std.hash.Wyhash.hash(0, entry.key_ptr.*);

                            std.debug.assert(hash != invalid_hash);

                            if (std.mem.indexOfScalar(u64, string_map_hashes, hash)) |key_i| {
                                _ = try to.getOrPutValue(
                                    framework_defaults.keys[key_i],
                                    value,
                                );
                            }
                        }
                    }
                } else {
                    while (iter.next()) |entry| {
                        const value: string = if (entry.value_ptr.*.len == 0) empty_string_value else entry.value_ptr.*;
                        _ = try to.getOrPutValue(
                            std.fmt.allocPrint(key_allocator, "process.env.{s}", .{entry.key_ptr.*}) catch unreachable,
                            value,
                        );
                    }
                }
            }
        }

        for (framework_defaults.keys) |key, i| {
            const value = framework_defaults.values[i];

            if (value.len == 0) {
                _ = try to.getOrPutValue(key, empty_string_value);
            } else {
                _ = try to.getOrPutValue(key, value);
            }
        }

        return key_buf;
    }

    pub fn init(map: *Map, allocator: *std.mem.Allocator) Loader {
        return Loader{
            .map = map,
            .allocator = allocator,
        };
    }

    pub fn loadProcess(this: *Loader) void {
        if (this.did_load_process) return;

        // This is a little weird because it's evidently stored line-by-line
        var source = logger.Source.initPathString("process.env", "");
        for (std.os.environ) |env| {
            source.contents = std.mem.span(env);
            Parser.parse(&source, this.allocator, this.map, true);
        }
        this.did_load_process = true;
    }

    // mostly for tests
    pub fn loadFromString(this: *Loader, str: string, comptime overwrite: bool) void {
        var source = logger.Source.initPathString("test", str);
        Parser.parse(&source, this.allocator, this.map, overwrite);
        std.mem.doNotOptimizeAway(&source);
    }

    // .env.local goes first
    // Load .env.development if development
    // Load .env.production if !development
    // .env goes last
    pub fn load(
        this: *Loader,
        fs: *Fs.FileSystem.RealFS,
        dir: *Fs.FileSystem.DirEntry,
        comptime development: bool,
    ) !void {
        const start = std.time.nanoTimestamp();
        var dir_handle: std.fs.Dir = std.fs.cwd();
        var can_auto_close = false;

        if (dir.hasComptimeQuery(".env.local")) {
            try this.loadEnvFile(fs, dir_handle, ".env.local", false);
        }

        if (comptime development) {
            if (dir.hasComptimeQuery(".env.development")) {
                try this.loadEnvFile(fs, dir_handle, ".env.development", false);
            }
        } else {
            if (dir.hasComptimeQuery(".env.production")) {
                try this.loadEnvFile(fs, dir_handle, ".env.production", false);
            }
        }

        if (dir.hasComptimeQuery(".env")) {
            try this.loadEnvFile(fs, dir_handle, ".env", false);
        }

        this.printLoaded(start);
    }

    pub fn printLoaded(this: *Loader, start: i128) void {
        const count =
            @intCast(u8, @boolToInt(this.@".env.local" != null)) +
            @intCast(u8, @boolToInt(this.@".env.development" != null)) +
            @intCast(u8, @boolToInt(this.@".env.production" != null)) +
            @intCast(u8, @boolToInt(this.@".env" != null));

        if (count == 0) return;
        const elapsed = @intToFloat(f64, (std.time.nanoTimestamp() - start)) / std.time.ns_per_ms;

        const all = [_]string{
            ".env.local",
            ".env.development",
            ".env.production",
            ".env",
        };
        const loaded = [_]bool{
            this.@".env.local" != null,
            this.@".env.development" != null,
            this.@".env.production" != null,
            this.@".env" != null,
        };

        var loaded_i: u8 = 0;
        Output.printElapsed(elapsed);
        Output.prettyError(" <d>", .{});

        for (loaded) |yes, i| {
            if (yes) {
                loaded_i += 1;
                if (count == 1 or (loaded_i >= count and count > 1)) {
                    Output.prettyError("\"{s}\"", .{all[i]});
                } else {
                    Output.prettyError("\"{s}\", ", .{all[i]});
                }
            }
        }
        Output.prettyErrorln("<r>\n", .{});
        Output.flush();
    }

    pub fn loadEnvFile(this: *Loader, fs: *Fs.FileSystem.RealFS, dir: std.fs.Dir, comptime base: string, comptime override: bool) !void {
        if (@field(this, base) != null) {
            return;
        }

        var file = dir.openFile(base, .{ .read = true }) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    // prevent retrying
                    @field(this, base) = logger.Source.initPathString(base, "");
                    return;
                },
                else => {
                    return err;
                },
            }
        };
        Fs.FileSystem.setMaxFd(file.handle);

        defer {
            if (fs.needToCloseFiles()) {
                file.close();
            }
        }

        const stat = try file.stat();
        if (stat.size == 0) {
            @field(this, base) = logger.Source.initPathString(base, "");
            return;
        }

        var buf = try this.allocator.allocSentinel(u8, stat.size, 0);
        errdefer this.allocator.free(buf);
        var contents = try file.readAll(buf);
        // always sentinel
        buf.ptr[contents + 1] = 0;
        const source = logger.Source.initPathString(base, buf.ptr[0..contents]);

        Parser.parse(
            &source,
            this.allocator,
            this.map,
            override,
        );

        @field(this, base) = source;
    }
};

pub const Parser = struct {
    pub fn parse(
        source: *const logger.Source,
        allocator: *std.mem.Allocator,
        map: *Map,
        comptime override: bool,
    ) void {
        var lexer = Lexer.init(source);
        var fbs = std.io.fixedBufferStream(&temporary_nested_value_buffer);
        var writer = fbs.writer();

        while (lexer.next()) |variable| {
            if (variable.has_nested_value) {
                writer.context.reset();

                lexer.eatNestedValue(Map, map, @TypeOf(writer), writer, variable, Map.get) catch unreachable;
                const new_value = fbs.buffer[0..fbs.pos];
                if (new_value.len > 0) {
                    if (comptime override) {
                        map.put(variable.key, allocator.dupe(u8, new_value) catch unreachable) catch unreachable;
                    } else {
                        var putter = map.map.getOrPut(variable.key) catch unreachable;
                        if (!putter.found_existing) {
                            putter.value_ptr.* = allocator.dupe(u8, new_value) catch unreachable;
                        }
                    }
                }
            } else {
                if (comptime override) {
                    map.put(variable.key, variable.value) catch unreachable;
                } else {
                    map.putDefault(variable.key, variable.value) catch unreachable;
                }
            }
        }
    }
};

pub const Map = struct {
    const HashTable = std.StringArrayHashMap(string);

    map: HashTable,

    pub inline fn init(allocator: *std.mem.Allocator) Map {
        return Map{ .map = HashTable.init(allocator) };
    }

    pub inline fn iter(this: *Map) HashTable.Iterator {
        return this.map.iterator();
    }

    pub inline fn put(this: *Map, key: string, value: string) !void {
        try this.map.put(key, value);
    }

    pub fn get(
        this: *const Map,
        key: string,
    ) ?string {
        return this.map.get(key);
    }

    pub inline fn putDefault(this: *Map, key: string, value: string) !void {
        _ = try this.map.getOrPutValue(key, value);
    }

    pub inline fn getOrPut(this: *Map, key: string, value: string) !void {
        _ = try this.map.getOrPutValue(key, value);
    }
};

const expectString = std.testing.expectEqualStrings;
const expect = std.testing.expect;
test "DotEnv Loader" {
    const VALID_ENV =
        \\API_KEY=verysecure
        \\process.env.WAT=ABCDEFGHIJKLMNOPQRSTUVWXYZZ10239457123
        \\DOUBLE-QUOTED_SHOULD_PRESERVE_NEWLINES="
        \\ya
        \\"
        \\DOUBLE_QUOTES_ESCAPABLE="\"yoooo\""
        \\SINGLE_QUOTED_SHOULDNT_PRESERVE_NEWLINES='yo
        \\'
        \\
        \\SINGLE_QUOTED_PRESERVES_QUOTES='yo'
        \\
        \\# Line Comment
        \\UNQUOTED_SHOULDNT_PRESERVE_NEWLINES_AND_TRIMS_TRAILING_SPACE=yo # Inline Comment
        \\
        \\      LEADING_SPACE_IS_TRIMMED=yes
        \\
        \\LEADING_SPACE_IN_UNQUOTED_VALUE_IS_TRIMMED=        yes
        \\
        \\LINES_WITHOUT_EQUAL_ARE_IGNORED
        \\
        \\NO_VALUE_IS_EMPTY_STRING=
        \\LINES_WITHOUT_EQUAL_ARE_IGNORED
        \\
        \\IGNORING_DOESNT_BREAK_OTHER_LINES='yes'
        \\
        \\NESTED_VALUE='$API_KEY'
        \\
        \\RECURSIVE_NESTED_VALUE=$NESTED_VALUE:$API_KEY
        \\
        \\NESTED_VALUES_RESPECT_ESCAPING='\$API_KEY'
        \\
    ;
    const source = logger.Source.initPathString(".env", VALID_ENV);
    var map = Map.init(std.heap.c_allocator);
    Parser.parse(
        &source,
        std.heap.c_allocator,
        &map,
        true,
    );
    try expectString(map.get("NESTED_VALUES_RESPECT_ESCAPING").?, "'\\$API_KEY'");

    try expectString(map.get("NESTED_VALUE").?, "'verysecure'");
    try expectString(map.get("RECURSIVE_NESTED_VALUE").?, "'verysecure':verysecure");

    try expectString(map.get("API_KEY").?, "verysecure");
    try expectString(map.get("process.env.WAT").?, "ABCDEFGHIJKLMNOPQRSTUVWXYZZ10239457123");
    try expectString(map.get("DOUBLE-QUOTED_SHOULD_PRESERVE_NEWLINES").?, "\"\nya\n\"");
    try expectString(map.get("SINGLE_QUOTED_SHOULDNT_PRESERVE_NEWLINES").?, "'yo");
    try expectString(map.get("SINGLE_QUOTED_PRESERVES_QUOTES").?, "'yo'");
    try expectString(map.get("UNQUOTED_SHOULDNT_PRESERVE_NEWLINES_AND_TRIMS_TRAILING_SPACE").?, "yo");
    try expect(map.get("LINES_WITHOUT_EQUAL_ARE_IGNORED") == null);
    try expectString(map.get("LEADING_SPACE_IS_TRIMMED").?, "yes");
    try expect(map.get("NO_VALUE_IS_EMPTY_STRING").?.len == 0);
    try expectString(map.get("IGNORING_DOESNT_BREAK_OTHER_LINES").?, "'yes'");
    try expectString(map.get("LEADING_SPACE_IN_UNQUOTED_VALUE_IS_TRIMMED").?, "yes");
}

test "DotEnv Process" {
    var map = Map.init(std.heap.c_allocator);
    var process = try std.process.getEnvMap(std.heap.c_allocator);
    var loader = Loader.init(&map, std.heap.c_allocator);
    loader.loadProcess();

    try expectString(loader.map.get("TMPDIR").?, process.get("TMPDIR").?);
    try expect(loader.map.get("TMPDIR").?.len > 0);

    try expectString(loader.map.get("USER").?, process.get("USER").?);
    try expect(loader.map.get("USER").?.len > 0);
}

test "DotEnv Loader.copyForDefine" {
    const UserDefine = std.StringArrayHashMap(string);

    var map = Map.init(std.heap.c_allocator);
    var loader = Loader.init(&map, std.heap.c_allocator);
    const framework_keys = [_]string{ "process.env.BACON", "process.env.HOSTNAME" };
    const framework_values = [_]string{ "true", "\"localhost\"" };
    const framework = Api.StringMap{
        .keys = std.mem.span(&framework_keys),
        .values = std.mem.span(&framework_values),
    };

    const user_overrides: string =
        \\BACON=false
        \\HOSTNAME=example.com
        \\THIS_SHOULDNT_BE_IN_DEFINES_MAP=true
        \\
    ;

    const skip_user_overrides: string =
        \\THIS_SHOULDNT_BE_IN_DEFINES_MAP=true
        \\
    ;

    loader.loadFromString(skip_user_overrides, false);

    var user_defines = UserDefine.init(std.heap.c_allocator);
    var buf = try loader.copyForDefine(UserDefine, &user_defines, framework, .disable, "", std.heap.c_allocator);

    try expect(user_defines.get("process.env.THIS_SHOULDNT_BE_IN_DEFINES_MAP") == null);

    user_defines = UserDefine.init(std.heap.c_allocator);

    loader.loadFromString(user_overrides, true);

    buf = try loader.copyForDefine(
        UserDefine,
        &user_defines,
        framework,
        Api.DotEnvBehavior.load_all,
        "",
        std.heap.c_allocator,
    );

    try expect(user_defines.get("process.env.BACON") != null);
    try expectString(user_defines.get("process.env.BACON").?, "false");
    try expectString(user_defines.get("process.env.HOSTNAME").?, "example.com");
    try expect(user_defines.get("process.env.THIS_SHOULDNT_BE_IN_DEFINES_MAP") != null);

    user_defines = UserDefine.init(std.heap.c_allocator);

    buf = try loader.copyForDefine(UserDefine, &user_defines, framework, .prefix, "HO", std.heap.c_allocator);

    try expectString(user_defines.get("process.env.HOSTNAME").?, "example.com");
    try expect(user_defines.get("process.env.THIS_SHOULDNT_BE_IN_DEFINES_MAP") == null);
}
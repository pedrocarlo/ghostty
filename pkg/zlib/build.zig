const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("zlib", .{});

    const lib = b.addStaticLibrary(.{
        .name = "z",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.addIncludePath(upstream.path(""));
    if (target.result.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, &lib.root_module);
    }

    lib.installHeadersDirectoryOptions(.{
        .source_dir = upstream.path(""),
        .install_dir = .header,
        .install_subdir = "",
        .include_extensions = &.{".h"},
    });

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DHAVE_SYS_TYPES_H",
        "-DHAVE_STDINT_H",
        "-DHAVE_STDDEF_H",
        "-DZ_HAVE_UNISTD_H",
    });
    lib.addCSourceFiles(.{
        .dependency = upstream,
        .files = srcs,
        .flags = flags.items,
    });

    b.installArtifact(lib);
}

const srcs: []const []const u8 = &.{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "inflate.c",
    "infback.c",
    "inftrees.c",
    "inffast.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
};

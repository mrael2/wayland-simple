const std = @import("std");
const Allocator = std.mem.Allocator;

fn randomNumberGenerator() std.Random {
    var seed: u64 = undefined;
    const seed_as_bytes = std.mem.asBytes(&seed);
    std.posix.getrandom(seed_as_bytes) catch unreachable;
    var prng = std.Random.DefaultPrng.init(seed);
    const result = prng.random();
    return result;
}

const filenameSize = 16;
const FileArr = [filenameSize]u8;

fn randomMemoryFilename(prng: *std.Random) FileArr {
    var name: FileArr = undefined;
    for (&name) |*item| {
        const value = prng.intRangeAtMost(u8, 'a', 'z');
        item.* = value;
    }
    const first_element = &name[0];
    first_element.* = '/';
    std.debug.print("filename = {s}\n", .{name});
    return name;
}

pub fn createSharedMemoryFile(allocator: Allocator) !c_int {
    var prng = randomNumberGenerator();
    const name = randomMemoryFilename(&prng);
    const filename: [*:0]u8 = try allocator.dupeZ(u8, &name);
    defer allocator.free(std.mem.span(filename));
    const sh_fd = sharedMemoryFileDescriptor(filename);
    const err = std.c.shm_unlink(filename);
    std.debug.assert(err != -1);
    return sh_fd;
}

fn sharedMemoryFileDescriptor(filename: [*:0]const u8) c_int {
    const flag = std.c.O {.CREAT = true, .EXCL = true, .ACCMODE = .RDWR};
    const mode = 0o600;
    const sh_fd = std.c.shm_open(filename, @bitCast(flag), mode);
    std.debug.print("{}\n", .{sh_fd});
    if (sh_fd == -1) {
        std.posix.exit(1);
    }
    return sh_fd;
}

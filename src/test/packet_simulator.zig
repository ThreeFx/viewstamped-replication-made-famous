const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

const log = std.log.scoped(.packet_simulator);

pub const PacketSimulatorOptions = struct {
    /// Mean for the exponential distribution used to calculate forward delay.
    one_way_delay_mean: u64,
    one_way_delay_min: u64,

    packet_loss_probability: u8,
    packet_replay_probability: u8,
    packet_misdeliver_probability: u8,
    seed: u64,

    replica_count: u8,
    client_count: u8,
    node_count: u8,

    partition_mode: PartitionMode,
    partition_stability: u32,
    unpartition_stability: u32,
    partition_probability: u8,
    unpartition_probability: u8,

    /// The maximum number of in-flight packets a path can have before packets are randomly dropped.
    path_maximum_capacity: u8,

    /// Mean for the exponential distribution used to calculate how long a path is clogged for.
    path_clog_duration_mean: u64,
    path_clog_probability: u8,
};

pub const Path = struct {
    source: u8,
    target: u8,
};

pub const PartitionMode = enum {
    uniform_size,
    uniform_partition,
    isolate_single,
};

/// A fully connected network of nodes used for testing. Simulates the fault model:
/// Packets may be dropped.
/// Packets may be delayed.
/// Packets may be replayed.
pub const PacketStatistics = enum(u8) {
    dropped_due_to_partition,
    dropped_due_to_congestion,
    dropped,
    replay,
};
pub fn PacketSimulator(comptime Packet: type) type {
    return struct {
        const Self = @This();

        const Data = struct {
            expiry: u64,
            callback: fn (packet: Packet, path: Path) void,
            packet: Packet,
        };

        /// A send and receive path between each node in the network. We use the `path` function to
        /// index it.
        paths: []std.PriorityQueue(Data),

        /// We can arbitrary clog a path until a tick.
        path_clogged_till: []u64,
        ticks: u64 = 0,
        options: PacketSimulatorOptions,
        prng: std.rand.DefaultPrng,
        stats: [@typeInfo(PacketStatistics).Enum.fields.len]u32 = [_]u32{0} **
            @typeInfo(PacketStatistics).Enum.fields.len,

        is_partitioned: bool,
        partition: []bool,
        replicas: []u8,
        stability: u32,

        pub fn init(allocator: *std.mem.Allocator, options: PacketSimulatorOptions) !Self {
            assert(options.one_way_delay_mean >= options.one_way_delay_min);
            var self = Self{
                .paths = try allocator.alloc(
                    std.PriorityQueue(Data),
                    @as(usize, options.node_count) * options.node_count,
                ),
                .path_clogged_till = try allocator.alloc(
                    u64,
                    @as(usize, options.node_count) * options.node_count,
                ),
                .options = options,
                .prng = std.rand.DefaultPrng.init(options.seed),

                .is_partitioned = false,
                .stability = options.unpartition_stability,
                .partition = try allocator.alloc(bool, @as(usize, options.replica_count)),
                .replicas = try allocator.alloc(u8, @as(usize, options.replica_count)),
            };

            for (self.replicas) |_, i| {
                self.replicas[i] = @intCast(u8, i);
            }

            for (self.paths) |*queue| {
                queue.* = std.PriorityQueue(Data).init(allocator, Self.order_packets);
                try queue.ensureCapacity(options.path_maximum_capacity);
            }

            for (self.path_clogged_till) |*clogged_till| {
                clogged_till.* = 0;
            }

            return self;
        }

        pub fn deinit(self: *Self, allocator: *std.mem.Allocator) void {
            for (self.paths) |*queue| {
                while (queue.popOrNull()) |*data| data.packet.deinit();
                queue.deinit();
            }
            allocator.free(self.paths);
        }

        fn order_packets(a: Data, b: Data) math.Order {
            return math.order(a.expiry, b.expiry);
        }

        fn should_drop(self: *Self) bool {
            return self.prng.random.uintAtMost(u8, 100) < self.options.packet_loss_probability;
        }

        fn path_index(self: *Self, path: Path) usize {
            assert(path.source < self.options.node_count and path.target < self.options.node_count);

            return @as(usize, path.source) * self.options.node_count + path.target;
        }

        pub fn path_queue(self: *Self, path: Path) *std.PriorityQueue(Data) {
            var index = self.path_index(path);
            return &self.paths[@as(usize, path.source) * self.options.node_count + path.target];
        }

        fn is_clogged(self: *Self, path: Path) bool {
            return self.path_clogged_till[self.path_index(path)] > self.ticks;
        }

        fn should_clog(self: *Self, path: Path) bool {
            return self.prng.random.uintAtMost(u8, 100) < self.options.path_clog_probability;
        }

        fn clog_for(self: *Self, path: Path, ticks: u64) void {
            const clog_expiry = &self.path_clogged_till[self.path_index(path)];
            clog_expiry.* = self.ticks + ticks;
            log.debug("Path path.source={} path.target={} clogged for ticks={}", .{
                path.source,
                path.target,
                ticks,
            });
        }

        fn should_replay(self: *Self) bool {
            return self.prng.random.uintAtMost(u8, 100) < self.options.packet_replay_probability;
        }

        fn should_misdeliver(self: *Self) bool {
            return self.prng.random.uintAtMost(u8, 100) < self.options.packet_misdeliver_probability;
        }

        /// Return a value produced using an exponential distribution with
        /// the minimum and mean specified in self.options
        fn one_way_delay(self: *Self) u64 {
            const min = self.options.one_way_delay_min;
            const mean = self.options.one_way_delay_mean;
            return min + @floatToInt(u64, @intToFloat(f64, mean - min) * self.prng.random.floatExp(f64));
        }

        fn random_choice(self: *Self, probability: u8) bool {
            return self.prng.random.uintLessThan(u8, 100) < probability;
        }

        fn partition_network(
            self: *Self,
        ) void {
            self.is_partitioned = true;
            self.stability = self.options.partition_stability;

            switch (self.options.partition_mode) {
                .uniform_size => {
                    const sz = self.prng.random.uintAtMost(u8, self.options.replica_count);
                    self.prng.random.shuffle(u8, self.replicas);
                    for (self.replicas) |r, i| {
                        self.partition[r] = i < sz;
                    }
                },
                .uniform_partition => {
                    for (self.replicas) |_, i| {
                        self.partition[i] = self.random_choice(50);
                    }
                },
                .isolate_single => {
                    for (self.replicas) |_, i| {
                        self.partition[i] = false;
                    }
                    const n = self.prng.random.uintLessThan(u8, self.options.replica_count);
                    self.partition[n] = true;
                },
            }
        }

        fn unpartition_network(
            self: *Self,
        ) void {
            self.is_partitioned = false;
            self.stability = self.options.unpartition_stability;

            for (self.replicas) |_, i| {
                self.partition[i] = false;
            }
        }

        pub fn tick(self: *Self) void {
            self.ticks += 1;

            if (self.stability > 0) {
                self.stability -= 1;
            } else {
                if (self.is_partitioned) {
                    if (self.random_choice(self.options.unpartition_probability)) {
                        self.unpartition_network();
                        log.alert("unpartitioned network: partition={d}", .{self.partition});
                    }
                } else {
                    if (self.random_choice(self.options.partition_probability)) {
                        self.partition_network();
                        log.alert("partitioned network: partition={d}", .{self.partition});
                    }
                }
            }

            var from: u8 = 0;
            while (from < self.options.node_count) : (from += 1) {
                var to: u8 = 0;
                while (to < self.options.node_count) : (to += 1) {
                    var path = .{ .source = from, .target = to };
                    if (self.is_clogged(path)) continue;

                    const queue = self.path_queue(path);
                    while (queue.peek()) |*data| {
                        if (data.expiry > self.ticks) break;
                        _ = queue.remove();

                        const is_misdeliver = self.options.node_count > 1 and self.should_misdeliver();
                        var orig_to: u8 = self.options.node_count;
                        if (is_misdeliver) {
                            orig_to = to;
                            to = self.prng.random.uintLessThan(u8, self.options.node_count - 1);
                            if (to >= orig_to) to += 1;
                            assert(to < self.options.node_count and to != orig_to);

                            path.target = to;
                            log.debug("misrouting packet from={} orig_to={} new_to={}", .{ from, orig_to, to });
                        }

                        if (self.is_partitioned) {
                            if (from < self.options.replica_count and to < self.options.replica_count and self.partition[from] != self.partition[to]) {
                                self.stats[@enumToInt(PacketStatistics.dropped_due_to_partition)] += 1;
                                log.alert("dropped packet (different partitions): from={} to={}", .{ from, to });
                                data.packet.deinit(path);
                                continue;
                            }
                        }

                        if (self.should_drop()) {
                            self.stats[@enumToInt(PacketStatistics.dropped)] += 1;
                            log.alert("dropped packet from={} to={}.", .{ from, to });
                            data.packet.deinit(path);
                            continue;
                        } else if (self.should_replay()) {
                            self.submit_packet(data.packet, data.callback, path);

                            log.debug("replayed packet from={} to={}", .{ from, to });
                            self.stats[@enumToInt(PacketStatistics.replay)] += 1;

                            data.callback(data.packet, path);
                        } else {
                            log.debug("delivering packet from={} to={}", .{ from, to });
                            data.callback(data.packet, path);
                            data.packet.deinit(path);
                        }

                        if (is_misdeliver) {
                            assert(orig_to < self.options.node_count);
                            to = orig_to;
                            path.target = to;
                        }
                    }

                    const reverse_path: Path = .{ .source = to, .target = from };

                    if (self.should_clog(reverse_path)) {
                        log.debug("reverse path clogged", .{});
                        const mean = @intToFloat(f64, self.options.path_clog_duration_mean);
                        const ticks = @floatToInt(u64, mean * self.prng.random.floatExp(f64));
                        self.clog_for(reverse_path, ticks);
                    }
                }
            }
        }

        pub fn submit_packet(
            self: *Self,
            packet: Packet,
            callback: fn (packet: Packet, path: Path) void,
            path: Path,
        ) void {
            const queue = self.path_queue(path);
            var queue_length = queue.count();
            if (queue_length + 1 > queue.capacity()) {
                const index = self.prng.random.uintLessThanBiased(u64, queue_length);
                const data = queue.removeIndex(index);
                data.packet.deinit(path);
                log.alert("submit_packet: {} reached capacity, dropped packet={}", .{
                    path,
                    index,
                });
            }

            queue.add(.{
                .expiry = self.ticks + self.one_way_delay(),
                .packet = packet,
                .callback = callback,
            }) catch unreachable;
        }
    };
}

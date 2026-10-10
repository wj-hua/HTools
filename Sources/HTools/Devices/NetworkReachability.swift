import Foundation

enum NetworkReachability {
    /// 在 adb pair 之前先自己探一次 TCP 连接。
    ///
    /// adb 在配对失败时一律只报 "protocol fault (couldn't read status message)"，
    /// 网络不通、端口不对、配对码错误全是同一句，无法区分。先探一次链路，就能把
    /// 「根本连不上」和「配对本身失败」分开，给出可操作的提示。
    ///
    /// 这里刻意用 POSIX socket 而不是 Network.framework：NWConnection 会自动套用
    /// 系统代理设置，开着 SOCKS 代理时它对任何地址都会立刻返回 .ready（连 RFC 5737
    /// 的不可路由地址也一样），结果毫无意义。adb 自己用的是普通 socket，预检必须
    /// 走同一条路径，结论才能代表 adb 的实际行为。
    static func canConnect(host: String, port: UInt16, timeout: Duration) async -> Bool {
        let milliseconds = Int32(clamping: timeout.components.seconds * 1000)
        return await Task.detached(priority: .userInitiated) {
            resolveAndConnect(host: host, port: port, timeoutMilliseconds: milliseconds)
        }.value
    }

    private static func resolveAndConnect(
        host: String,
        port: UInt16,
        timeoutMilliseconds: Int32
    ) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0 else { return false }
        defer { freeaddrinfo(resolved) }

        var candidate = resolved
        while let entry = candidate {
            if connect(to: entry.pointee, timeoutMilliseconds: timeoutMilliseconds) {
                return true
            }
            candidate = entry.pointee.ai_next
        }
        return false
    }

    private static func connect(to entry: addrinfo, timeoutMilliseconds: Int32) -> Bool {
        let descriptor = socket(entry.ai_family, entry.ai_socktype, entry.ai_protocol)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // 非阻塞 connect + poll，才能自己控制超时；阻塞 connect 的默认超时长达一分钟。
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        if Darwin.connect(descriptor, entry.ai_addr, entry.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var monitored = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&monitored, 1, timeoutMilliseconds) > 0 else { return false }

        // poll 返回可写并不等于连接成功，失败时也会可写，要再查 SO_ERROR。
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return false
        }
        return socketError == 0
    }
}

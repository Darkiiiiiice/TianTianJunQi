import Darwin
import Foundation

/// 单实例锁：同一时间只允许一个客户端控制游戏窗口与鼠标（设计文档 §3.2）。
enum SingleInstanceLock {
    private static var fileDescriptor: Int32 = -1

    /// 尝试获取锁；已被其他实例持有时返回 false。进程退出（含崩溃）自动释放。
    static func acquire() -> Bool {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("TianTianJunQiAI.instance.lock")
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        fileDescriptor = fd
        return true
    }
}

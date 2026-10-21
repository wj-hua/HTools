import Foundation

extension FileManager {
    /// 数据文件读不出来（损坏、或字段变化导致解码失败）时，先把它改名留底，
    /// 否则下一次保存会用空列表覆盖掉用户原有的内容。
    /// 备份名形如 `tasks.corrupt-20261012-153000.json`，放在原文件旁边。
    func backUpUnreadableFile(at url: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(formatter.string(from: Date()))")
            .appendingPathExtension(url.pathExtension)
        try? moveItem(at: url, to: backupURL)
    }
}

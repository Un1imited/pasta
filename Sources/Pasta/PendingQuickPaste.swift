/// 搜索完成后再解析粘贴目标：回车跟随恢复的选中项，⌘数字固定槽位。
enum PendingQuickPaste {
    case selection(plain: Bool)
    case index(Int, plain: Bool)

    func resolve(selectedIndex: Int, resultCount: Int) -> (index: Int, plain: Bool)? {
        let target: (index: Int, plain: Bool)
        switch self {
        case .selection(let plain):
            target = (selectedIndex, plain)
        case .index(let index, let plain):
            target = (index, plain)
        }
        guard (0..<resultCount).contains(target.index) else { return nil }
        return target
    }
}

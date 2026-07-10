import AppKit

// 单实例守护必须先于 AppDelegate 构造：delegate 的 store 属性在构造时就会
// load()+清扫孤儿图片，第二实例哪怕随后退出，也可能已破坏第一实例的数据。
guard ClipboardStore.acquireSingleInstanceLock() else {
    let alert = NSAlert()
    alert.messageText = "Pasta 已在运行"
    alert.informativeText = "检测到另一个 Pasta 实例（App 或 swift run），本实例将退出以避免历史文件冲突。"
    alert.runModal()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标，只在菜单栏
app.run()

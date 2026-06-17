import AppKit
import Carbon

/// 注册一个系统级全局热键，用 Carbon 的 RegisterEventHotKey 实现。
/// 支持运行时改键：先 setCallback 安装回调，再用 update 注册/换绑。
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?

    func setCallback(_ action: @escaping () -> Void) {
        callback = action
        installHandlerIfNeeded()
    }

    /// 注册或换绑热键。keyCode 为虚拟键码，modifiers 为 Carbon 修饰键标志。
    func update(keyCode: UInt32, modifiers: UInt32) {
        unregisterKey()
        let hotKeyID = EventHotKeyID(signature: OSType(0x50415354) /* 'PAST' */, id: 1)
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                me.callback?()
                return noErr
            },
            1, &eventType, selfPtr, &eventHandler
        )
    }

    private func unregisterKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    deinit {
        unregisterKey()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

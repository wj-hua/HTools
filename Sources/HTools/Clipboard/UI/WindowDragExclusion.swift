import SwiftUI

/// 面板内不参与「长按拖动窗口」的区域，由控件自己按实际布局上报，
/// 避免把按钮位置写成常量后随布局漂移。
struct WindowDragExclusionPreferenceKey: PreferenceKey {
    static var defaultValue: [CGRect] { [] }

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func excludedFromWindowDrag() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: WindowDragExclusionPreferenceKey.self,
                        value: [proxy.frame(in: .named(ClipboardPanelView.panelCoordinateSpace))]
                    )
            }
        }
    }
}

// swift-tools-version:5.10
import PackageDescription

/// winpin —— macOS 菜单栏窗口置顶工具。
/// 采用 SwiftPM 可执行 Target 组织源码，xcodebuild 可直接编译本包；
/// .app Bundle 由 scripts/build_release.sh 负责组装（Info.plist + ad-hoc 签名）。
let package = Package(
    name: "winpin",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "winpin",
            path: "winpin",
            exclude: ["Resources/Info.plist"]
        )
    ]
)

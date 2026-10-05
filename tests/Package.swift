// swift-tools-version:5.10
import PackageDescription

/// winpin 单元测试包（独立 SwiftPM 包，与根目录 Package.swift / 手写 xcodeproj 主路径零干扰）。
///
/// 被测源码经 TestSources/AppSources 下的符号链接引用自 ../winpin，
/// 保证测试始终编译仓库内的真实源码。
///
/// 运行：`cd tests && swift test --disable-sandbox`
let package = Package(
    name: "winpin-tests",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(
            name: "winpinTests",
            path: "TestSources"
        )
    ]
)

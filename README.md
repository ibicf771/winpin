# winpin

macOS 菜单栏窗口置顶工具：将任意 App 的窗口一键置顶（always on top），随时取消。

- 平台：macOS 14+ / Apple Silicon（开发验证环境 macOS 26.3 Tahoe / M2）
- 技术：SwiftUI + AppKit，零三方依赖
- 置顶实现：**ScreenCaptureKit 镜像置顶**（v1.1 起）
  - 背景：macOS 26.3 上原"真置顶"方案（SkyLight 私有 API `SLSSetWindowLevel`）已被系统中性化
    ——设级与读回均返回成功，但窗口合成器不执行，视觉无效。
  - 现方案：对目标窗口建立 ScreenCaptureKit 实时流，在自有高层级浮窗
    （NSPanel, `.floating` + `canJoinAllSpaces` + `fullScreenAuxiliary`）中渲染实时画面。
    镜像可跨桌面 Space、可悬浮于全屏 App 之上——体验反而优于真置顶。
  - 原 SkyLight 引擎代码保留（`SkyLightPinningEngine`），但不再默认启用。

## 安装

1. 打开 `winpin-1.4.2-arm64.dmg`，将 `winpin.app` 拖入 `Applications`。
2. 首次启动如被 Gatekeeper 拦截：右键 App → 打开；或终端执行：
   ```bash
   xattr -d com.apple.quarantine /Applications/winpin.app
   ```
3. 按首启引导授予 **屏幕录制** 权限（必需，否则镜像无法建立）。
   辅助功能权限为可选（用于点击镜像时精准 raise 源窗口）。
4. 注意：本机 ad-hoc 签名按二进制指纹记录权限，**每次 App 更新替换后授权会失效**。
   v1.4.2 起无需终端命令：打开 winpin 后，在首启引导页或「设置 → 权限」中点击
   **「重置权限并重启 winpin」** 按钮，重启后按系统弹窗重新授权即可。
   （等价于 `tccutil reset ScreenCapture/Accessibility com.winpin.app` + 重启。）

## 使用

- 点击菜单栏图钉图标 → 面板列出「已置顶 / 全部窗口」，每行可置顶或取消。
- 快捷键（可在设置页自定义）：
  - `⌃⌥P`：切换前台 App 当前窗口的置顶状态
  - `⌃⌥⇧P`：取消所有置顶
- **镜像浮窗手势**（对齐 macOS 画中画习惯）：
  - **按住拖动**：移动浮窗到任意位置
  - **单击**：跳回原窗口（激活源 App 并 raise 源窗口，编辑请在原窗口进行）
  - **双击**：取消置顶（等价于点右上角 ✕ 按钮）
  - **右键**（v1.4）：上下文菜单——**镜像缩放**（50% / 75% / 100% / 150% / 200%，以浮窗左上角为锚点）、
    **镜像透明度**（v1.4.2，滑杆 50%~100%，拖动实时预览）与取消置顶
- 面板顶部支持**搜索过滤**（v1.4，按 App 名 / 窗口标题）。
- 设置页支持：开机自启动（SMAppService 登录项）、快捷键自定义、权限状态查看，
  以及「取消置顶时，将窗口移到镜像最后的位置」开关（v1.3，默认关闭）：
  开启后，把镜像浮窗拖到别处再取消置顶，源窗口会自动移动到浮窗所在位置（需辅助功能权限）。
- 退出 winpin 时自动销毁所有镜像浮窗。

## 从源码构建

```bash
scripts/build_release.sh   # 产出 build/Release/winpin.app（xcodebuild 主路径，swift build 兜底）
scripts/make_dmg.sh        # 产出 build/winpin-1.4.2-arm64.dmg（create-dmg 或 hdiutil 兜底）
cd tests && swift test --disable-sandbox --enable-xctest   # 运行单元测试（32 项）
```

## 已知限制

- 镜像是"实时画面"而非原窗口本体，**无法在镜像内直接输入/编辑**（事件转发不可靠，
  同类工具均放弃）；单击跳回原窗口编辑，编辑过程实时反映在镜像中。
- 源窗口移动/缩放时镜像会跟随回源窗口位置（巡检同步）。
- 全屏 Space、Stage Manager、多显示器下的行为以实测为准。
- 不做重启后恢复置顶（v1.0 设计决策）。

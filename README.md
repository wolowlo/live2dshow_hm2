# Live2DShow — 鸿蒙 Live2D 模型查看器

> 基于 HarmonyOS 原生（ArkTS / ArkUI / Stage 模型）开发的 Live2D 模型查看与互动工具。
> 支持 Cubism 2 / Cubism 3 双引擎，全部数据本地存储，无需联网。

## 功能特性

- **模型管理**：从相册导入 Live2D 模型（zip 包自动解压识别），缩略图速览、收藏 / 分类 / 版本筛选、删除管理
- **互动体验**：模型动作播放、自动轮播、沉浸模式
- **个性定制**：三套主题（粉色蜜桃 / 蜂蜜奶油 / 青瓷）、自定义背景（纯色 / 图片 / 无）
- **桌面直达**(已删除)：支持桌面卡片，快速查看模型
- **数据安全**：全部数据（模型、缩略图、背景、收藏、偏好）仅存于设备本地沙箱；支持一键导出 / 恢复备份（zip）

## 环境要求

| 项目 | 要求 |
|---|---|
| 操作系统 | macOS / Windows |
| 开发工具 | DevEco Studio 5.0+（含 SDK 6.1.1(API 24)） |
| 运行设备 | HarmonyOS 手机（API 24 及以上） |
| 构建方式 | hvigor（命令行）或 DevEco Studio 图形界面 |

## 快速开始

```bash
# 1. 解压源码包
unzip live2dview_hm2.zip -d live2dview_hm2

# 2. 安装依赖（须在 DevEco 终端或配置好 ohpm 的环境执行）
cd live2dview_hm2
ohpm install

# 3. 构建（命令行，须使用 DevEco 自带 node 并指定 SDK）
unset NODE_OPTIONS
export PATH="/Applications/DevEco-Studio.app/Contents/tools/node/bin:$PATH"
DEVECO_SDK_HOME="/Applications/DevEco-Studio.app/Contents/sdk" \
  /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw \
  assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

> 也可以直接用 DevEco Studio 打开工程：File → Open → 选择 `live2dview_hm2`，然后 Build → Build Hap(s)/APP(s)。首次打开若提示签名缺失，在 `File → Project Structure → Signing Configs` 勾选自动签名即可（会自动生成本机调试证书）。

## 工程结构

```
live2dview_hm2/
├── AppScope/                 # 应用级配置（app.json5、应用图标/启动背景）
├── entry/                    # 主模块（entry）
│   └── src/main/
│       ├── ets/
│       │   ├── entryability/   # EntryAbility（应用入口）
│       │   ├── pages/          # 页面：Index / OverviewPage / ModelsPage / SettingsPage
│       │   ├── services/       # 业务服务
│       │   │   ├── AssetServer.ets      # 本地资源服务器（127.0.0.1:17890，渲染用）
│       │   │   ├── ImportService.ets    # 相册导入 / 解压 / 迁移
│       │   │   ├── ModelScanner.ets     # 模型扫描与识别
│       │   │   ├── ModelStore.ets       # 模型元数据 RDB 数据库
│       │   │   ├── ModelRecord.ets      # 模型记录模型类
│       │   │   ├── MocParser.ets        # Cubism .moc 解析
│       │   │   ├── CharData.ets         # 模型角色数据
│       │   │   ├── ThumbnailService.ets # 缩略图生成
│       │   │   ├── BackgroundService.ets# 背景设置
│       │   │   ├── ThemeManager.ets     # 主题管理（三套主题）
│       │   │   ├── BackupService.ets    # 备份导出 / 恢复
│       │   │   └── JsonUtil.ets         # JSON 工具
│       │   └── common/                  # 公共日志 / 全局状态
│       ├── resources/
│       │   ├── base/                    # 资源（图标、颜色、字符串、页面路由）
│       │   └── rawfile/engines/         # Cubism2 / Cubism3 引擎 JS
│       └── module.json5                 # 模块配置（权限、能力声明）
├── hvigor/                   # hvigor 构建配置
├── hvigorfile.ts             # 工程构建脚本
├── oh-package.json5          # 依赖声明
├── oh-package-lock.json5     # 依赖锁文件
├── build-profile.json5       # 工程配置（签名已脱敏，占位 REPLACE_ME_*）
└── docs/                     # 文档
```

## 权限说明

| 权限 | 类型 | 用途 |
|---|---|---|
| `ohos.permission.INTERNET` | 系统授权 | 本地资源服务器（127.0.0.1）使用 |
| `ohos.permission.DETECT_GESTURE` | 系统授权 | 智感握姿感应，悬浮导航控制 |

应用**不申请任何敏感权限**（相机 / 麦克风 / 位置 / 通讯录等均无），相册导入使用系统 PhotoViewPicker（免权限）。所有数据均存于本机沙箱，无任何上传行为。

## 数据说明

| 数据类型 | 存储位置 |
|---|---|
| 模型文件 | 沙箱 `filesDir/models/` |
| 缩略图 | 沙箱 `filesDir/thumbnails/` |
| 背景图 | 沙箱 `filesDir/backgrounds/` |
| 模型元数据（收藏/分类） | RDB 数据库（S1 安全级别） |
| 主题 / 偏好设置 | Preferences（`app_settings`） |

数据保留期限：用户使用期间，卸载应用或清除数据即删除；用户可随时通过「备份导出」将数据保存至设备指定位置。

## 版本

- 当前版本：1.0.0（versionCode 1000000）
- bundleName：`com.live2dshow.app`
- 开发基线：HarmonyOS 6.1.1（API 24），Stage 模型，ArkTS 严格类型

## 常见问题

**Q1：打开工程后提示缺少签名？**
进入 `File → Project Structure → Signing Configs`，勾选自动签名生成调试证书即可（`build-profile.json5` 中的 `REPLACE_ME_*` 占位会被自动替换为本机实际签名）,如无法生成,需要连接虚拟机或者真机。

**Q2：命令行构建报 `SAFE_DELETE_BULK_CONFIRM_REQUIRED`？**
构建前 `unset NODE_OPTIONS`，并使用 DevEco 自带 node（见上方快速开始）。

**Q3：首次运行没有模型可看？**
内置示例模型在 `rawfile`，或通过「模型管理 → 导入」从相册导入 Live2D 模型包（zip，含 .model3.json / moc3 或 model.json / moc 的 Cubism 2/3 结构）。

## 模型下载

https://github.com/Eikanya/Live2d-model.git

## License

仅作个人学习与体验用途。Live2D 相关引擎与示例模型版权归各自作者所有，请勿用于商业分发。

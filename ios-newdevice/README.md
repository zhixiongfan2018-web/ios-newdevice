# NewDevice（类 AMG 一键新机）

越狱端套件：管理 App + `newdeviced` 守护进程 + Substrate/ElleKit Tweak。  
目标环境：**Dopamine rootless / iOS 15–18**（含 iOS 18.x）。

用途：本机隐私隔离、多环境测试、自动化脚本联调。请遵守当地法律与各 App 服务条款。

## 组件

| 组件 | 说明 |
|------|------|
| `NewDevice.app` | 首页一键新机、记录、目标应用、设置、参数探测 |
| `newdeviced` | `127.0.0.1:8080` HTTP API、清数据、全息备份、智能飞行 |
| `NewDevice.dylib` | 标识/机型/运营商/定位/防越狱 Hook（仅对勾选 App 生效） |

## 目录（设备上）

- 配置：`/var/jb/var/mobile/Library/Preferences/com.local.newdevice/config.plist`
- 记录：`/var/jb/var/mobile/NewDevice/Records/<name>/profile.plist`
- 全息：`.../Records/<name>/apps/<bundleId>/`
- 脚本结果：`/var/jb/var/mobile/newdeviceResult.txt`（`0` 失败 / `1` 成功 / `2` 执行中）

有根环境会自动去掉 `/var/jb` 前缀（见 `NDPaths`）。

## 编译（没有 Mac 也可以）

**Windows 本机打不出 iOS deb。** 推荐用仓库自带的 **GitHub Actions** 在云端 Mac 打包，详见：

→ [`docs/NO_MAC_BUILD.md`](docs/NO_MAC_BUILD.md)

摘要：推送到 GitHub → Actions 里跑 **Build NewDevice deb** → 下载 Artifact 里的 `.deb` → 手机 Sileo/Filza 安装 → Respring → **打开 NewDevice App**。

若你有 Mac / Linux Theos 环境，也可本地：

```bash
export THEOS=~/theos
cd ios-newdevice
make package FINALPACKAGE=1
```

安装后如需手动起守护进程：

```bash
launchctl load /var/jb/Library/LaunchDaemons/com.local.newdevice.daemon.plist
```

（脚本 API 主要靠打开 App 监听 8080，与 AMG 相同。）

## 使用流程

1. 打开 **NewDevice** → **应用**，勾选需要隔离的目标 App 并保存。  
2. **设置**中按需打开伪装定位、智能飞行、防越狱、全息备份等。  
3. 首页点 **一键新机**：生成新参数记录 → 备份/清理目标 App → 可选开关飞行模式 → 通知 Tweak 重载。  
4. 用 **探测**页或目标 App 验证 IDFA/机型等是否变化。  
5. **记录**页可切换/禁用/删除；点详情可编辑单个字段。

## 脚本 API（兼容 AMG 调用习惯）

**重要：`127.0.0.1:8080` 跑在越狱手机本机，不是 Windows 电脑。**

1. 先打开手机上的 **NewDevice** App（与 AMG 一样，API 由 App 进程监听）。
2. 在手机 Safari / 触动脚本里访问，不要在电脑浏览器直接打开。
3. 首页会显示 `API: …已监听`；也可先访问 `http://127.0.0.1:8080/` 应返回 `NewDevice API OK`。

`newRecord` 等长任务会立刻返回 `200 accepted`，真实结果写在结果文件（`0/1/2`），脚本需轮询（见 `AMG_compat.lua`）。

```
GET http://127.0.0.1:8080/                 → 健康检查
GET http://127.0.0.1:8080/cmd?fun=newRecord
GET http://127.0.0.1:8080/cmd?fun=originRecord
GET http://127.0.0.1:8080/cmd?fun=nextRecord
GET http://127.0.0.1:8080/cmd?fun=firstRecord
GET http://127.0.0.1:8080/cmd?fun=getCurrentRecordName
GET http://127.0.0.1:8080/cmd?fun=setRecord&recordName=NAME
GET http://127.0.0.1:8080/cmd?fun=deleteRecord&recordName=NAME
GET http://127.0.0.1:8080/cmd?fun=getCurrentRecordParam&saveFilePath=/path/to.plist
GET http://127.0.0.1:8080/cmd?fun=setCurrentRecordParam&filePath=/path/to.plist
```

触动示例见 [`scripts/AMG_compat.lua`](scripts/AMG_compat.lua)。

## Hook 范围（用户态）

- IDFA / IDFV / `UIDevice` 机型与系统版本（含 iPad）  
- MobileGestalt：`SerialNumber`、`UniqueDeviceID`、WiFi/BT MAC、`ProductType`、**IMEI/IMEI2** 等  
- **SSID / BSSID**（`CNCopyCurrentNetworkInfo`）  
- `CTCarrier` / ISO `us` / 无线接入类型  
- `sysctl hw.machine` / `hw.model` / **`kern.boottime`** / `uname`  
- `NSTimeZone`（按美国城市时区）  
- `CLLocationManager` 定位  
- 常见越狱路径 `stat`/`access`/`NSFileManager`；深度模式含 `dyld` 镜像名与 `fork`

## 对标 AMG 能力

| AMG 能力 | NewDevice |
|----------|-----------|
| 一键新机 / 原始 / 上下条 | ✅ |
| 全息备份 + 目标 App 清理 | ✅（含 App Group 强清） |
| 防越狱检测 | ✅ 基础/深度 |
| 智能飞行 + 公网 IP | ✅ |
| 脚本 API `8080/cmd` | ✅（含完整 `AMG.*` 兼容表） |
| Serial / UDID / MAC / IDFA | ✅ |
| **IMEI / SSID / BSSID** | ✅ 用户态 + CommCenter/IOKit/CT 邻近面（非 modem NVRAM） |
| iPad 机型池 | ✅（设置里「允许伪装 iPad」） |
| 分辨率 / 内存 / 磁盘 | ✅ UIScreen + Gestalt / sysctl / `statfs` / `NSFileSystemSize` |
| DeviceColor / DeviceClass | ✅ |
| DeviceName（用户设备名） | ✅ 与 Model 分离 |
| ifaddrs IP / MAC / DNS | ✅ 多网卡合成 + `getifaddrs` + DNS 深层 |
| Locale / 语言 | ✅ `en_US` |
| DeviceToken / OpenUDID / UUID | ✅ APNs 回调 + UserDefaults 键 |
| Battery / ICCID | ✅ UIDevice 电量 + Gestalt ICCID（非写卡） |
| canOpenURL 隐藏 | ✅ cydia/sileo/… |
| dyld 计数 / getenv | ✅ 深度防越狱 |
| 剪贴板全息 | ✅ 切换时备份/还原（可关） |
| Keychain 全息 | ✅ generic/internet/证书 DER（私钥仍可能拒） |
| 记录导入导出 | ✅ 官方 `/var/mobile/AMG_tar` + 明文 faker 导出 |
| 同时导入 Keychain | ✅ 工具页开关（默认开；AMG 官方建议非必要勿开） |
| 导入 iGrimace / AWZ | ✅ `/var/mobile/iGrimace`、`/var/mobile/importdata` |
| 瘦身（清图片/视频） | ✅ 立刻瘦身 + 导出时自动瘦身（长按切换） |
| 修复中文输入 / 国行联网 / 注销 | ✅ 工具页 |
| 美国运营商 / GPS / 时区 | ✅ |
| 结果文件 `amgResult.txt` | ✅ 同步写入 |
| `prevRecord` / `getRecordCount` | ✅ |

**边界**：modem NVRAM IMEI、Keychain 私钥；**不必也不应**去解 AMG 运行时目录里的落盘密文 `faker.plist`——正确路径是 `AMG_tar` / 脚本 `Get_Param`。

额外 API：`clearAppData` / `cleanApps`；`importAMGRecords` / `importAMGMedia` / `importIGrimace` / `importAWZ`；`exportAMGMedia`；`slimRecord`。

### 工具页（对齐 AMG）

NewDevice → **工具**：

| 项 | 默认路径 |
|---|---|
| 导入其他数据（iGrimace） | `/var/mobile/iGrimace` |
| 导入 AWZ 数据 | `/var/mobile/importdata` |
| 同时导入 Keychain | 开关，导入时还原 `keychain-full.plist`；也识别 AMG 的 `akc.plist` / `Documents/akc.plist` |
| 导入 AMG 数据 | **`/var/mobile/AMG_tar`**（官方；兼容 `Media/AMG/import`；支持 `.tar.gz`） |
| 导出 AMG 数据 | **`/var/mobile/AMG_tar`**（**明文** faker，再导入不用解密） |
| 瘦身 | 点按瘦身当前记录；长按切换「导出自动清除媒体」 |

> `/var/mobile/AMG/<记录>/faker.plist` 是 AMG **运行时落盘密文**，不是导入包。官方文档导入/导出走的是 `AMG_tar`。

### 从 AMG 导入数据

可以。真实 AMG 导出目录（例如 `+1… 2026-…/`）通常包含：

| 文件/目录 | 含义 |
|---|---|
| `faker.plist` | 身份参数；**运行时目录**里常为密文；**AMG_tar / NewDevice 导出**应为明文 |
| `selectApp.plist` | 目标 App bundle id 列表 |
| `description.plist` | 记录标题 / App 显示名 |
| `ifaddrs.plist` | 网卡/DNS 指纹 |
| `com.*` / `net.*` | App 全息沙盒 |
| `AppGroup/` | App Group 全息 |
| `Pasteboard/` | 剪贴板备份（若有） |

导入行为：

1. 在 AMG 里点 **导出 AMG 数据**，包会出现在 `/var/mobile/AMG_tar`（不要只拷 `/var/mobile/AMG`）。  
2. NewDevice → **工具** → **导入 AMG 数据**（自动解 `.tar.gz`，并兼容 `Media/AMG/import`）。  
3. 明文 `faker.plist` → 映射身份。  
4. 若是运行时密文：自动尝试 sidecar（`faker_plaintext.plist`）或本机 `getRecordParam` / `getCurrentRecordParam`（AMG 官方明文导出接口，不硬解 AES）；失败则禁用改机伪装并仍导入全息，写 `amg-import-note.txt`。  
5. 工具页提供「拉取 AMG 明文参数」。注意：若 8080 已被 NewDevice 占用，需先用 AMG/Get_Param 写出 `faker_plaintext.plist` 再导入。

脚本：`fun=importAMGMedia`（默认 `AMG_tar`）；`fun=exportAMGMedia`；`fun=slimRecord`。

**仍弱于 AMG**：modem NVRAM IMEI、Keychain 私钥；运行时密文 faker 无 AMG 密钥时无法还原（应走导出路径，而不是解密）。

## 自测清单

见 [`docs/TESTCHECKLIST.md`](docs/TESTCHECKLIST.md)。

## 工程结构

```
ios-newdevice/
  Makefile          # aggregate
  control
  shared/           # Profile / Config / RecordStore / AppData / Airplane
  app/              # UIKit 管理 App
  daemon/           # newdeviced + HTTP
  tweak/            # Logos hooks
  layout/           # LaunchDaemon + DEBIAN scripts
  scripts/          # 触动兼容脚本
```

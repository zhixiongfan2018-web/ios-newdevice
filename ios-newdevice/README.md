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
| ifaddrs IP / MAC / DNS | ✅ `getifaddrs` + `SCDynamicStore` + `res_*_getservers` |
| canOpenURL 隐藏 | ✅ cydia/sileo/… |
| dyld 计数 / getenv | ✅ 深度防越狱 |
| 剪贴板全息 | ✅ 切换时备份/还原（可关） |
| Keychain 全息 | ✅ generic/internet + accessGroup（`keychain-full.plist`） |
| 记录导入导出 | ✅ 记录页（含 AMG 全息目录） |
| 美国运营商 / GPS / 时区 | ✅ |
| 结果文件 `amgResult.txt` | ✅ 同步写入 |
| `prevRecord` / `getRecordCount` | ✅ |

**边界**：真正改写基带/modem NVRAM 的 IMEI、跨完全无关 access group 的 Keychain、密文 `faker.plist` 解密仍无法保证。证书私钥导出受系统限制。

额外 API：`clearAppData` / `cleanApps`（只清目标 App，不换身份）；`importAMGRecords`（从 `/var/mobile/AMG` 导入身份）。

### 从 AMG 导入数据

可以。真实 AMG 导出目录（例如 `+1… 2026-…/`）通常包含：

| 文件/目录 | 含义 |
|---|---|
| `faker.plist` | 身份参数（IDFA/UDID/MAC/SSID/坐标/…）；**部分版本落盘为 AES 密文** |
| `selectApp.plist` | 目标 App bundle id 列表 |
| `description.plist` | 记录标题 / App 显示名 |
| `ifaddrs.plist` | 网卡/DNS 指纹（旁路保存；`en0` MAC 由 WiFiMAC 伪造） |
| `com.*` / `net.*` | App 全息沙盒（Documents/Library） |
| `AppGroup/` | App Group 全息 |
| `Pasteboard/` | 剪贴板备份（若有） |

导入行为：

1. 把导出放到设备 `/var/mobile/AMG/`（或解压后的同级目录）。  
2. NewDevice → **记录** → **导入** → **从 AMG 目录导入**。  
3. 优先读 `faker.plist`；明文则映射 `BlueAddress`/`DiskSpace`/`SystemUptime`/`Memory` 等别名。  
4. **密文 faker**：生成随机身份，仍导入全息 App + AppGroup，并写 `amg-import-note.txt`。  
5. `selectApp.plist` 会合并进「应用」目标列表；切换记录时会还原全息与 App Group。

脚本：`http://127.0.0.1:8080/cmd?fun=importAMGRecords`（可选 `&dir=/path`）。

**仍弱于 AMG / 待优化**：modem NVRAM 级 IMEI、Keychain 私钥/证书实体重放、密文 faker 解密。

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

# NewDevice（类 AMG 一键新机）

越狱端套件：管理 App + `newdeviced` 守护进程 + Substrate/ElleKit Tweak。  
目标环境：**Dopamine rootless / iOS 15–16**。

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

- IDFA / IDFV / `UIDevice` 机型与系统版本  
- MobileGestalt：`SerialNumber`、`UniqueDeviceID`、WiFi/BT MAC、`ProductType` 等  
- `CTCarrier` / 无线接入类型  
- `sysctl hw.machine` / `uname`  
- `CLLocationManager` 定位  
- 常见越狱路径 `stat`/`access`/`NSFileManager`；深度模式含 `dyld` 镜像名与 `fork`

**边界**：基带级 IMEI、部分系统进程内标识、完整 Keychain 跨组迁移无法保证 100%。全息 Keychain 仅为可枚举 generic password 的尽力备份。

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

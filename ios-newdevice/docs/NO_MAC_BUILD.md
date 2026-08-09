# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## 推荐：GitHub Actions 云端打包（免费）

仓库已带工作流 [`.github/workflows/build-deb.yml`](../../.github/workflows/build-deb.yml)，在 GitHub 的 **macos-14** 机器上执行 Theos 打包。

### 步骤

1. 把本项目推到你的 GitHub 仓库（可用 GitHub Desktop，全程在 Windows）。
2. 打开仓库 → **Actions** → 选 **Build NewDevice deb** → **Run workflow**。
3. 等跑完（约 5–15 分钟）→ 点进本次 run → **Artifacts** → 下载 `NewDevice-deb`。
4. 解压得到 `.deb`，传到手机用 **Sileo / Filza** 安装，然后 Respring。
5. **打开 NewDevice App**，首页应显示 API 已监听；再在手机上访问  
   `http://127.0.0.1:8080/`。

### 传到手机的常用办法

- AirDrop / iCloud（若方便）
- Filza 网页上传、或电脑 `scp` 到手机
- 微信/网盘发文件到手机后用 Filza 打开安装

## 其他可选

| 方式 | 说明 |
|------|------|
| 租用云 Mac | MacinCloud 等按小时租，SSH 进去装 Theos 后 `make package` |
| Linux + Theos | 可在 Ubuntu 配 toolchain，门槛高于 Actions |
| 找有 Mac 的朋友 | 把仓库给他，跑一遍 `make package` 把 deb 发你 |

## 你仍需要的东西

- 一台 **已越狱** 的 iPhone（Dopamine / rootless，iOS 15–16 优先）
- Windows 只负责改代码 + 触发云编译 + 把 deb 装进手机

## 本地 Windows 做不到什么

- 不能在本机浏览器打开 `http://127.0.0.1:8080`（那是手机回环地址）
- 不能在本机直接 `make` 出可安装的 iOS arm64 deb（缺 Xcode/SDK）

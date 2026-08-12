# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## 推荐：raw 直链下载 deb

打包成功后，用手机浏览器打开（不进 Actions）：

https://raw.githubusercontent.com/zhixiongfan2018-web/ios-newdevice/master/downloads/NewDevice.deb

或版本化地址：

https://raw.githubusercontent.com/zhixiongfan2018-web/ios-newdevice/master/downloads/com.local.newdevice_1.0.0-13_iphoneos-arm64.deb

下载后用 **Filza / Sileo** 安装 → Respring → 打开 NewDevice。

## 云端打包

仓库工作流 [`.github/workflows/build-deb.yml`](../../.github/workflows/build-deb.yml) 在 GitHub **macos-14** 上 Theos 打包。推送到 `master` 后会：

1. 生成 `.deb`
2. 更新 `downloads/`（上面的 raw 直链）
3. 更新 apt 源索引（`repo/`）并打 release 标签，供固定源 `@latest` 拉取

### Sileo 固定源（推荐）

```
https://cdn.jsdelivr.net/gh/zhixiongfan2018-web/ios-newdevice/apt
```

不要用带 `@latest` / `@master` 的链接（Sileo 无法添加）。若刷新仍失败，用上面的 **raw 直链** 装 deb。

## 其他可选

| 方式 | 说明 |
|------|------|
| 租用云 Mac | MacinCloud 等按小时租，SSH 进去装 Theos 后 `make package` |
| Linux + Theos | 可在 Ubuntu 配 toolchain，门槛高于 Actions |

## 你仍需要的东西

- 一台 **已越狱** 的 iPhone（Dopamine / rootless）
- Windows 只负责改代码 + 触发云编译 + 把 deb 装进手机

## 本地 Windows 做不到什么

- 不能在本机浏览器打开 `http://127.0.0.1:8080`（那是手机回环地址）
- 不能在本机直接 `make` 出可安装的 iOS arm64 deb（缺 Xcode/SDK）

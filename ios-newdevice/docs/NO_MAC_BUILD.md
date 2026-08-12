# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## Sileo 固定源（推荐，无 @）

```
https://zhixiongfan2018-web.github.io/ios-newdevice
```

只用这一条。添加后刷新 → 安装/升级 NewDevice → Respring。

备用（也无 @）：

```
https://raw.githubusercontent.com/zhixiongfan2018-web/ios-newdevice/master/stable
```

> 不要用带 `@` 的 jsDelivr 地址，Sileo 无法添加。

## 云端打包

仓库工作流 [`.github/workflows/build-deb.yml`](../../.github/workflows/build-deb.yml) 在 GitHub **macos-14** 上 Theos 打包。推送后会：

1. 生成 `.deb`
2. 更新 `stable/` 源索引
3. 部署到 GitHub Pages（上面的链接）

## 其他可选

| 方式 | 说明 |
|------|------|
| 租用云 Mac | MacinCloud 等按小时租，SSH 进去装 Theos 后 `make package` |
| Linux + Theos | 可在 Ubuntu 配 toolchain，门槛高于 Actions |

## 你仍需要的东西

- 一台 **已越狱** 的 iPhone（Dopamine / rootless，含 iOS 18）
- Windows 只负责改代码 + 触发云编译 + 把 deb 装进手机

## 本地 Windows 做不到什么

- 不能在本机浏览器打开 `http://127.0.0.1:8080`（那是手机回环地址）
- 不能在本机直接 `make` 出可安装的 iOS arm64 deb（缺 Xcode/SDK）

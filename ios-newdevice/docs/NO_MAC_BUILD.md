# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## Sileo 固定源（推荐）

```
https://cdn.jsdelivr.net/gh/zhixiongfan2018-web/ios-newdevice/stable
```

只用这一条（不要加 `@`）。添加后刷新 → 安装/升级 NewDevice → Respring。

## 云端打包

仓库工作流 [`.github/workflows/build-deb.yml`](../../.github/workflows/build-deb.yml) 在 GitHub **macos-14** 上 Theos 打包。推送后会：

1. 生成 `.deb`
2. 更新 `stable/` 源索引
3. 打 GitHub Release，让上述 jsDelivr 链接（无 `@`）指向最新包

## 你仍需要的东西

- 一台 **已越狱** 的 iPhone（Dopamine / rootless，含 iOS 18）

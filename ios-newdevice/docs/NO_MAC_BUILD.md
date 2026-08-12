# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## Sileo 固定源（唯一，无 @）

```
https://cdn.jsdelivr.net/gh/zhixiongfan2018-web/ios-newdevice/stable
```

只用这一条，禁止改成 GitHub Pages 或其它地址。添加后刷新 → 安装/升级 NewDevice → Respring。

## AMG 数据格式

导入/导出使用 **`.tar`**（非 `.tar.gz`）：

- 导入：把 `.tar` 放到 `/var/mobile/Media/AMG/import/`（爱思文件管理里就是 `AMG/import`）
- 导出：工具页会写出到 `Media/AMG/export/` 与 `/var/mobile/AMG_tar/`

## 云端打包

仓库工作流会生成 `.deb`、更新 `stable/`，并打 GitHub Release（jsDelivr 无 `@` 跟最新 Release）。

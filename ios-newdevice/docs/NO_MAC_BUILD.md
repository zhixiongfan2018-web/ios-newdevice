# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## Sileo 固定源（唯一推荐，无 @）

```
https://zhixiongfan2018-web.github.io/ios-newdevice/
```

只用这一条。添加后刷新 → 安装/升级 NewDevice → Respring。

## AMG 数据格式

导入/导出使用 **`.tar`**（非 `.tar.gz`）：

- 导入：把 `.tar` 放到 `/var/mobile/Media/AMG/import/`（爱思文件管理里就是 `AMG/import`）
- 导出：工具页会写出到 `Media/AMG/export/` 与 `/var/mobile/AMG_tar/`

## 云端打包

仓库工作流会生成 `.deb` 并更新 GitHub Pages 源（上面的链接）。

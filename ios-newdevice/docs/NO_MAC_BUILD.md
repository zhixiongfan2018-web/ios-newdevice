# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## Sileo 固定源（唯一，无 @）

```
https://zhixiongfan.top/stable
```

只用这一条。服务器反代见仓库 `deploy/nginx-zhixiongfan.top-stable.conf`。添加后刷新 → 安装/升级 NewDevice → Respring。

## AMG 数据格式

导入/导出使用 **`.tar`**（非 `.tar.gz`）：

- 导入：把 `.tar` 放到 `/var/mobile/Media/NewDevice/import/` 或 `Media/AMG/import/`
- 导出：工具页写出到 `Media/NewDevice/export/`

## 云端打包

仓库工作流会生成 `.deb` 并更新 `stable/`（GitHub `master`）。`zhixiongfan.top/stable` 反代到该目录。

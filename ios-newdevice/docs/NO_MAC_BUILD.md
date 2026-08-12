# 没有 Mac 怎么编译 / 安装

本项目是 **越狱 iPhone 上的 deb**，不能在 Windows 上直接运行，也不需要你买一台 Mac。

## Sileo 固定源（可直接添加，无 @）

```
https://zhixiongfan2018-web.github.io/ios-newdevice
```

只用这一条。添加后刷新 → 安装/升级 NewDevice → Respring。

### 关于 zhixiongfan.top

`https://zhixiongfan.top/stable` **当前不能当 Sileo 源**：服务器会把请求 302 到 Dial 页面，Sileo 会超时、无法添加。

要启用域名源，先在服务器加入 `deploy/nginx-zhixiongfan.top-stable.conf`，再执行 `nginx -t && systemctl reload nginx`，并用下面命令确认返回的是 Packages 而不是 HTML：

```bash
curl -sSI https://zhixiongfan.top/stable/Packages
curl -sS https://zhixiongfan.top/stable/Packages | head
```

## AMG 数据格式

导入/导出使用 **`.tar`**：

- 导入：`/var/mobile/Media/NewDevice/import/` 或 `Media/AMG/import/`
- 导出：`Media/NewDevice/export/`

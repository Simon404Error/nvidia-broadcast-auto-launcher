# NVIDIA Broadcast 自动启动

开机 5 秒后检查 NVIDIA 独立显卡，并根据状态自动处理 NVIDIA Broadcast。

## 功能

- 独显存在且运行：最小化启动 NVIDIA Broadcast
- 独显不存在：弹窗提示“独显不存在”
- 独显已连接但未运行：弹窗提示“请检查独显状态”

## 新电脑部署

1. 安装 NVIDIA Broadcast
2. 复制本文件夹到新电脑
3. 双击 `deploy.bat`，UAC 弹窗点击“是”
4. 自动查找路径并注册开机 5 秒后触发的计划任务

## 手动运行

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-NvidiaBroadcast.ps1
```

## 主要文件

- `deploy.bat`：一键部署
- `Deploy.ps1`：自动提权、配置路径、注册开机任务
- `Start-NvidiaBroadcast.ps1`：检测独显并启动/弹窗
- `Install-AutoStart.ps1`：注册计划任务
- `launch.bat`：手动运行入口

# 安装与开发 / Setup

目前是 Windows 源码预览，无可独立安装的公开发行版。不要从 issue、评论或未知网站下载所谓官方安装包。

## 环境

- Windows 10/11 x64、Windows PowerShell 5.1、.NET/WPF。
- 当前候选使用 Electron 43.0.0 与 koffi 3.3.3；保持已验证版本，升级应重新验证原生窗口和渲染行为。
- Live2D Cubism Core、模型文件、纹理和原应用素材：单独准备，先确认适用许可。仓库不附带这些二进制依赖。
- Codex 本机数据接入目前只接受已核验的 CLI 版本 `0.162.0-alpha.17.2` 和 `0.163.0-alpha.10.2`；桌面后端独立更新时，可能显示未连接，而不是猜测任务状态。

## 组装开发目录

有完整且有权使用的 Lumi 素材/依赖目录时，在仓库根目录运行：

```powershell
.\scripts\New-DevelopmentBundle.ps1 -AssetBundlePath 'C:\MyAssets\LumiBundle' -Destination 'C:\Projects\lumi-dev-bundle'
```

必须使用不存在的新目标目录。脚本仅复制明确列出的素材/依赖与仓库源码，不复制原包 `local_state`、凭据、账号档案、日志、会话或项目绑定；也不会退出或启动应用。它不是通用的任意 Live2D 模型导入器。

## 配置本地路径

`GPT_QUOTA_PET_CODEX_HOME` 优先，其次 `CODEX_HOME`，否则使用 `%USERPROFILE%\.codex`。仅设置本次 PowerShell 会话即可，不必修改系统设置：

```powershell
$env:GPT_QUOTA_PET_CODEX_HOME = Join-Path $env:USERPROFILE '.codex'
```

只在确实要观察某个聊天时，将 `renderer/PROJECT_TASK_BINDING.example.json` 复制为 `PROJECT_TASK_BINDING.json`，填入自己的绝对路径、聊天 ID 和准确的后端版本。该文件已加入忽略规则。配置必须指向所选项目的 rollout，校验不通过时保持任务未知。当前任务目录还会只读索引该 Codex Home 中近期非归档聊天，以便通知其他任务；不能把未知状态当作完成。

```powershell
Set-Location 'C:\Projects\lumi-dev-bundle'
.\pet.ps1
```

启动会读取你的本地额度与账号环境并运行桌宠。首次验证建议准备隔离测试环境。真正切号会退出/重开 Codex，只能在任务结束并确认后操作。不要用真实重置卡做自动化测试。

## 检查源码，不启动桌宠

```powershell
node .\tests\site.test.cjs
```

GitHub Actions 还会解析 PowerShell 文件，但不会登录、切号或消耗卡片。CI 不下载 Cubism Core，不运行 GPU 动画，不代表可安装包验收。

English: this repository is a Windows source preview. A licensed complete asset/runtime bundle is required. Assemble into a new folder, configure your own Codex Home and explicit task binding, then launch `pet.ps1` deliberately. Never publish your binding, auth files or local diagnostics.

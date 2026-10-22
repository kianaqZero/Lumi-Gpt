<div align="center">

# Lumi · Codex Desktop Companion

**让 Codex 的工作进度，变成桌面上看得见的陪伴。**

![Status: work in progress](https://img.shields.io/badge/status-work_in_progress-9468be)
![Platform: Windows](https://img.shields.io/badge/platform-Windows_10%2F11-0078d4)
![Languages](https://img.shields.io/badge/UI-中文%20%7C%20EN%20%7C%20日本語%20%7C%20한국어-66539a)

[English](README.en.md) · [日本語](docs/README.ja.md) · [한국어](docs/README.ko.md) · [使用与开发](docs/SETUP.md) · [路线图](docs/ROADMAP.md)

**仍在制作中 · 本仓库是开发源码预览，尚未发布可独立安装的公开版本。**

![Lumi 四语言候选：英文额度气泡与全身角色，数值均为演示](docs/images/lumi-preview.png)

</div>

Lumi 是一个独立运行在 Windows 桌面的角色助手：在气泡中查看 Codex 任务、token 使用量、账号额度和重置公告，让思考、工作、待机与睡眠状态对应实际使用场景。适合一边使用 Codex、一边关注任务与额度的用户。它不是 OpenAI 官方产品，也不属于 ChatGPT 内置 Pets。

## 可以做什么

| 功能 | 当前行为与边界 |
| --- | --- |
| 任务气泡 | 展示近期任务、项目名称、公开回复与本轮 token；大数字缩写，悬停看精确值。依赖本地 Codex 数据格式和连接状态。 |
| 主动通知 | 新进展在对话气泡中出现；点击跳到对应任务或账号，处理后移除消息。 |
| 额度面板 | 查看小时/周额度及重置时间，区分登录账号与正在查看的账号。 |
| 账号管理 | 本地保存与切换账号，具备空闲检查、恢复记录；切换可能重启 Codex，必须先结束任务并明确确认。 |
| 重置卡 | 读取数量、到期时间和可用状态；消耗前单独确认具体账号与卡片。真实消费流程仍待补充验收。 |
| 重置公告 | 接入 [Codex Reset](https://codex-reset.com/) 公开数据：社区记录、24/48 小时概率、置信度、更新时间和近期时间线分开呈现。预测不代表账号已恢复。 |
| 四种语言 | 中文、English、日本語、한국어即时切换并记住选择；保留用户任务原文、项目名与账号名称。翻译仍持续校对。 |
| 角色与窗口 | Q 版/全身候选、状态过渡、置顶、托盘、全屏避让与恢复；长期运行稳定性继续收集反馈。 |

目前以功能与使用体验优化为主。全身 Live2D 制作暂缓；所有动画、美术和状态效果均仍在迭代。

## 界面预览

![重置公告英文界面，合成账号与固定测试时钟](docs/images/announcement-en.png)

截图来自实际渲染器/WPF 候选界面；账号、额度和公告测试时钟为演示数据，不是实时重置预测或个人账号记录。

## 如何开始

**首次访问：先阅读 [安装与开发说明](docs/SETUP.md)。** 当前没有公开安装包；仅克隆仓库不能直接运行完整桌宠。仓库包含应用源码、四语言词条、数据校验和开发脚本。Electron 运行时、Live2D Cubism Core 与角色模型/纹理由开发者自行准备，遵守各自许可；没有将个人试用包伪装成可公开分发的正式版本。

已有合法完整素材包的开发者，可用 `scripts/New-DevelopmentBundle.ps1` 在新目录合并源码与依赖。该脚本不会复制账号、会话、日志或私人项目绑定，不会自动启动软件。配置完成后在 Windows PowerShell 中运行 `pet.ps1`。具体步骤、版本条件与验证限制见 [SETUP](docs/SETUP.md)。

## 隐私与数据

任务与 token 信息从本机读取。账号凭据留在本机，切换与重置卡属于需要用户确认的独立操作。公告使用 Codex Reset 的无需登录公开 GET 接口，正常约每 5 分钟检查，限制手动重查频率并遵守限流回退。此版本没有开发者遥测上传模块；账号查询仍会与其正常服务交互。

公开仓库不包含 `auth.json`、账号档案、真实任务记录、私人绑定、sqlite 数据库或本机运行日志。提交 issue 前也请先检查截图和日志是否含敏感内容。更多说明见 [安全与隐私](SECURITY.md)。

## 开发进度与反馈

R10 候选在现有 R9 修正基础上增加网站预测/时间线和四语言界面。已做数据校验、离屏真实界面与隔离渲染器验证；这不等于长期使用验收。真实切号、真实卡片消费、不同显卡/全屏游戏以及不同 Codex 版本仍需继续测试。

欢迎通过 [Issues](https://github.com/kianaqZero/Lumi-Gpt/issues) 提交可复现问题或功能建议。请附 Windows/Codex/Lumi 版本、复现步骤和脱敏截图。路线图与待验证项目见 [ROADMAP](docs/ROADMAP.md)，开发规范见 [CONTRIBUTING](CONTRIBUTING.md)。

## 致谢与权利说明

感谢 [Codex Reset](https://codex-reset.com/developers) 提供公开公告、时间线与实验性概率接口。Lumi 不隶属于该网站、OpenAI 或 Live2D。源码公开不等同于已授予所有代码、美术、模型和第三方组件的统一开源许可；目前请参阅 [权利与第三方组件说明](docs/RIGHTS.md)。

关键词：Codex desktop pet · Windows desktop companion · Live2D · token usage · quota monitor · reset notifications · 桌宠 · 额度监控 · 多语言。

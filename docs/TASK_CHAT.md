# 独立任务聊天 / Task conversations

任务气泡里的「展开」会打开对应聊天的独立窗口。可以阅读完整报告、加载更早消息、输入要求，也可以在 Codex 客户端打开同一聊天。不会因展开而创建新聊天。

## 使用

1. 点击任务 → 展开，核对顶部的项目与聊天标题。
2. 读报告或滚动查看历史，Aa 调整字号，◐ 切换深浅色。
3. 输入要求，点击发送到 Codex，或 Ctrl + Enter。Enter 只换行，输入法候选确认不发送。
4. 已排队表示消息已进入 Codex 原生队列；只有实际读取到相同消息后，才从待处理样式变为历史记录。随后读取同一聊天中的 Codex 回复。

发送失败保留草稿。若提示结果待核对，请刷新或在 Codex 中打开检查，避免重复发送。关闭窗口前自行保存未发送草稿；目前没有跨应用重启的草稿恢复承诺。

## 本地路径与版本

使用已配置的 PROJECT_TASK_BINDING.json 中的 sessions_root，核对同一 Codex Home 的 state_5.sqlite 记录、聊天 ID、项目路径与 rollout。归档、越界路径、未知任务会拒绝，不能通过 UI 输入任意本地文件路径。

报告历史来自 CLI app-server 的 thread/read 和 thread/items/list。发送使用 thread/queue/list、thread/queue/add，再交给桌面客户端的原生聊天唤醒入口。助手不 thread/resume、不 turn/start、不代替用户批准权限请求。只有报告窗口存在时才保持自身助手进程，关闭最后一个窗口后结束它；窗口隐藏时停止轮询。

聊天回传按本机 Codex CLI **0.163.0-alpha.11** 验证，涉及实验接口与桌面客户端入口；Codex 升级后可能变化，需要重新验证。任务状态观察器另有自己的版本白名单，见 [SETUP](SETUP.md)，不能把某一模块兼容视为所有模块兼容。

## 阅读与隐私

- 消息按固定聊天 ID 隔离，原文与项目名称不翻译；界面提供中 / 英 / 日 / 韩。
- 有限 Markdown 支持标题、加粗、代码、列表、引用和简单表格，原始 HTML 不执行；不加载远程报告素材。
- 聊天页面使用独立内存 session，只加载准确列出的本地 HTML / CSS / JS；桌宠原来的资源拦截规则保持。
- 深浅色 / 字号在当前聊天 session 内保留。没有开发者服务接收聊天内容，但发送后由正常 Codex 任务处理输入。
- 维护者已确认 R11.2 本机双向同步、R12 外观。自动化回归使用模拟发送，不能当作其他设备或长时间运行已验收。

上游：[Codex app server](https://learn.chatgpt.com/docs/app-server)、[Electron session](https://www.electronjs.org/docs/latest/api/session)。实现字段以本机 CLI 生成的 schema 核验，非长期稳定 API 承诺。

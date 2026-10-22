# 安全与隐私 / Security and privacy

不要在公开 issue、PR 或附件中提交 auth.json、OAuth token、cookies、账号备份、sqlite 数据库、会话 JSONL、真实任务回复或包含私人路径的诊断包。请先制作最小脱敏复现。

本仓库不存放用户凭据与运行状态。任务读取在本机进行，公开 reset API 不需要账号登录。账号/额度查询会与正常服务交互；账号切换和重置卡使用应有具体目标、确认和可恢复路径。

目前未建立专用私密漏洞收件渠道。若发现会泄漏凭据的问题，请勿公开细节、可利用载荷或秘密；先以不含细节的 issue 请求私密联系渠道。维护者确认渠道后再披露。

This is an unfinished local desktop application. Review source and dependencies before running it with access to a real Codex account. Public issues are not a safe place for secrets.

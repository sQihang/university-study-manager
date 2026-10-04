# University Study Manager

一个面向 Windows 本地 Agent 的大学学业管理 skill，帮助整理学业资料、跟踪课程与成绩、依据学校文件理解规则、制作规则自测题和学期看板。它会区分原文依据、个人记录、计算结果与未知项，不把 AI 分析当作学校的正式资格结论。

## 安装

发布到 GitHub 后，可以在 Codex 中调用 `$skill-installer`，并提供本仓库地址和 `skills/university-study-manager` 目录；也可以下载该目录，放入用户技能目录 `%USERPROFILE%\.agents\skills\university-study-manager`，然后重新打开 Codex。

安装后可用 `$university-study-manager` 显式调用。skill 会根据任务需要读取参考说明并运行随包脚本。

## 环境与可选工具

- 需要 Windows PowerShell 5.1 或 PowerShell 7。
- PDF 文字提取和页面光栅化可配置 Poppler；Poppler 程序不包含在本仓库中。
- OCR 可按需配置 MinerU Token。Token 应由用户保存在工作区 `.private/mineru.json`，不要提交到仓库或发进聊天。
- 使用 MinerU OCR 时，获准处理的文件会上传到 MinerU 云端。上传前应确认服务商、具体文件和处理范围；本地读取授权不代表同意上传。

缺少可选工具时，skill 会说明当前缺项并提供配置选择；不会把凭据或工作区文件打包进本仓库。

## 目录

- `skills/university-study-manager/SKILL.md`：触发条件、工作流程和安全边界。
- `references/`：课程、归档、政策解读、看板、OCR 与隐私处理说明。
- `scripts/`：Windows 本地处理与看板脚本。
- `assets/`：离线看板和答题模板。
- `agents/openai.yaml`：Codex 界面显示信息。

本仓库不含测试资料、个人工作区、`.private` 配置或 API Token。请勿将自己的成绩单、学号、学校账号信息或学校内部资料提交到公开仓库。

## 许可证

本仓库当前没有附带开源许可证。公开仓库可供查看和 fork，但这不等同于授予任意复制、修改或再分发权利。若需要将本 skill 用于其他项目，请先联系作者取得许可。

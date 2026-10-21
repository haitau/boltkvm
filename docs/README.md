# 文档索引

| 目录 | 内容 |
|---|---|
| [`design/`](design/) | 目标、约束、已验证事实、方案空间与里程碑；入口是 [project-charter.md](design/project-charter.md) |
| [`plans/`](plans/) | 可复现的验证与实施计划，例如 [M0 前置验证](plans/m0-verification.md) |
| [`adr/`](adr/) | 架构决策记录，一次决策一篇 |
| [`reports/`](reports/) | 验证报告：命令、原始输出、结论 |
| `_scratch/` | 本地草稿与 agent 运行产物，已加入 `.gitignore`，不入库 |

## 写作约定

- 公开文档写给贡献者看：不写个人语气、内部代号、机器地址、密钥或安全配置细节。
- 一次决策一条 ADR；原始讨论与对话日志不入库。
- 验证报告必须包含可复跑的命令与原始输出；结论区分【事实】【推断】【未经核实】。

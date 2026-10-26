# 文档索引

| 目录 | 内容 |
|---|---|
| [`design/`](design/) | 目标、约束、已验证事实、方案空间与里程碑；入口是 [project-charter.md](design/project-charter.md) |
| [`plans/`](plans/) | 可复现的验证与实施计划，例如 [M0 前置验证](plans/m0-verification.md) |
| [`adr/`](adr/) | 架构决策记录，一次决策一篇；入口是 [ADR 索引](adr/README.md) |
| [`reports/`](reports/) | 验证报告：命令、原始输出、结论；入口是 [报告索引](reports/README.md) |
| `_scratch/` | 本地草稿与 agent 运行产物，已加入 `.gitignore`，不入库 |

根目录与相邻入口：

- [README.md](../README.md)：面向使用者的安装、配置与已知限制；英文版 [README_EN.md](../README_EN.md)
- [releasing.md](releasing.md)：发布流程、CI、签名限制与工具链注意事项
- [AGENTS.md](../AGENTS.md)：贡献与提交约定
- [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)：第三方代码许可

## 写作约定

- 公开文档写给贡献者看：不写个人语气、内部代号、机器地址、密钥或安全配置细节。
- 一次决策一条 ADR；原始讨论与对话日志不入库。
- 验证报告必须包含可复跑的命令与原始输出；结论区分【事实】【推断】【未经核实】。
- 2026-10-26 之前的历史报告在文档审计中补了「证据分级」；原始日志未入库的项标为【未经核实】，不补写无法复跑的命令。

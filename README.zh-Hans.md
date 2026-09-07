<p align="right"><a href="README.md">English</a> · <b>简体中文</b></p>

<p align="center"><img src="assets/icon.png" width="128" alt="羊毛计图标"></p>

<h1 align="center">羊毛计</h1>

<p align="center">一个 macOS 菜单栏应用，按公开 API 单价折算你的 Codex 和 Claude Code 用量。<br><b>你不需要这个应用。</b>谁都不需要。</p>

<p align="center">
  <a href="https://github.com/donalddellapietra/meter-beater/actions/workflows/verify.yml"><img alt="构建状态" src="https://github.com/donalddellapietra/meter-beater/actions/workflows/verify.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="MIT 许可证" src="https://img.shields.io/badge/license-MIT-2e8b44"></a>
  <img alt="需要 macOS 15 或更高版本" src="https://img.shields.io/badge/macOS-15%2B-33302c">
</p>

![羊毛计](assets/shot-zh-hero.png)

## 它做什么

- 以只读方式打开你本地的 Codex（`~/.codex`）和 Claude Code（`~/.claude`）数据。
- 把每个 token 按公开 API 单价折算，总数常驻菜单栏。**不是账单**——是这些用量「本来会花多少钱」。
- 按大厂自家公布的毛利，反推伺候你大概烧掉了多少成本。
- 十级羊毛段位，按每一块钱订阅费薅回的价值来评。点击段位领取 Minecraft 风格成就。低段位不是夸你。
- 深浅色皆可，中英双语界面。

## 「Claude Code 不是已经有了吗？」

羊毛计把两个工具的本地用量汇总成一个菜单栏总数，按公开 API 单价折算。无需连接账号或提供 API 密钥。它提供跨服务商的美元等价比较，不是订阅剩余额度的读数。

## 安装

1. 从 [meter-beater.app.space](https://meter-beater.app.space/) 或 [Releases](../../releases/latest) 下载 **v1.1.4**。
2. 解压，把 **Meter Beater.app** 拖进「应用程序」。
3. 打开它，在菜单栏找 ✂️——要是没看到，那是菜单栏太挤、图标被刘海吞了，请驱逐一个你没那么爱的图标，给羊腾个位置。

退出方法：打开面板，点 `⋯` 菜单里的「退出」。和所有菜单栏应用一样，图标没法用 ⌘ 拖掉——这是 macOS 的规矩，不怪羊。

需要 macOS 15 及以上。通用二进制（Apple 芯片 + Intel），已由 Apple 签名并公证。

校验下载：

```sh
shasum -a 256 -c SHA256SUMS
```

## 从源码构建

完整应用、计费引擎、测试、基准工具、发布脚本和营销图片渲染器均在本仓库中，采用 MIT 许可证。构建需要 macOS 15 或更高版本，以及支持 Swift 6 的 Xcode 或 Command Line Tools。

```sh
scripts/test.sh
swift run AIUsageTracker
scripts/package-app.sh
```

打包脚本会生成供本地测试的临时签名通用应用和 ZIP。正式下载版本使用 Developer ID 签名并经过 Apple 公证；详见 [`docs/RELEASING.md`](docs/RELEASING.md)。

计数和定价规则见 [`docs/ACCOUNTING.md`](docs/ACCOUNTING.md)。

v1.1.4 将日期筛选分为「滚动」和「日历」两种模式，新增精确的「近 24 小时」，并在无需重新扫描记录的情况下移除窗口外的旧用量。包含 Astra、Fable 5.1 和 Mythos 5.1 定价。关闭菜单栏面板时，装饰动画停止运行，但后台用量刷新仍然保留。详情见[发布说明](RELEASE_NOTES.md)。

## 隐私

它见过你凌晨三点的会话。它不会作证。

长版本：这个应用没有任何网络代码。没有账号，不发送遥测，也不做统计。它就地读取本地数据，在你的 Mac 上算数，只写自己的汇总缓存。数据不会离开这台机器——因为它根本无处可去。

Codex 访问仅限记录目录和 `state_*.sqlite` 中的只读会话/模型元数据；羊毛计绝不会打开 `~/.codex/auth.json`。Claude 账号归属使用本地 Claude 遥测和会话元数据。应用不会修改服务商数据目录，手动选择的文件夹也只会获得明确的只读安全书签。

## 贡献与安全

欢迎贡献，详情见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。安全漏洞请按 [`SECURITY.md`](SECURITY.md) 私下报告；请勿在 issue 中附上真实记录文件或凭据。

## 许可证

羊毛计采用 [MIT 许可证](LICENSE) 开源。

## 免责声明

显示的美元数字是公开 API 价目表的等价折算，不是发票、订阅扣费或经审计的成本。服务成本为基于公开分析师毛利研究的方向性估算。羊毛计是独立项目，与 OpenAI、Anthropic 均无隶属、认可或赞助关系。

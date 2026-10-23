# Keyward

[English](README.md) · **中文**

给「自己会更新的桌面应用」保管发布签名密钥的本地保险库。

[![CI](https://github.com/turinglambdaai/keyward/actions/workflows/ci.yml/badge.svg)](https://github.com/turinglambdaai/keyward/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/turinglambdaai/keyward)](https://github.com/turinglambdaai/keyward/releases)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

凡是走网络自我更新的应用，最终都依赖同一套信任模型：**私钥签更新清单**，
**装进应用里的公钥**验签。Sparkle、Tauri updater、electron-updater、
WinSparkle、Google Omaha——方案都是这一套，而没人替你解决的，从来都是
私钥这一半的日常托管：它存在哪、怎么进 CI、何时轮换，以及怎么在一份
流浪副本抢先*轮换掉你*之前发现它。

> 📖 **第一次接触更新签名？** 阅读双语手册——
> **[使用手册 / Handbook](https://keyward.jrtx.site/guide.html)**（中文原文，
> 附地道英文翻译，可按语言切换）——
> 或[源 markdown](docs/GUIDE.zh-CN.md)：安装、连接保险库、每一项日常操作、
> 接入 CI、发布更新、密钥轮换，为零基础读者写就。

Keyward 是一个守护这些密钥的小型桌面应用。建在家族 Rivet 线上
（Racket 引擎 + 原生宿主），库文件就放在你自己的同步盘里，并往上补足
明文存储缺的那份纪律：

- **永不显示，只进剪贴板。** 密钥值只通过显式的「复制到剪贴板」动作返回。
- **防丢失。** 每次改动先对存储做快照（同步盘内、只追加）；写入原子化，
  权限收紧。
- **深度校验。** 解析每把密钥（Ed25519 / RSA PKCS#8、base64-DER、
  base64-PEM 或裸 PEM），推导公钥半边，计算指纹，并与存储的公开材料
  配对——过去要靠一堆手工 openssl 命令完成的审计，现在一条命令。
- **收集，不散落。** 应用内生成密钥对直接写入保险库；PEM 导入落成
  单行 base64 值。流浪密钥文件一分钟都不会存在。
- **孤儿检测。** 粘贴坏掉产生的多行残留，打开保险库的瞬间就以行号形式现形。

保险库格式是纯 INI（`[product]` 小节、`NAME = value`、注释保留），
始终是唯一事实来源——Keyward 是它之上的纪律层，不是锁定。

## 开始使用

AGPL-3.0 许可的免费发布基础设施工具，不接商业激活。 提供 macOS、Windows、Linux 桌面预览。连接真实发布凭据前，先使用可丢弃的合成密钥库。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 状态

**v0.2.0 已发布**——三个桌面的安装包都在
[Releases 页](https://github.com/turinglambdaai/keyward/releases/latest)：
macOS（arm64 / x64，DMG + zip）、Windows（x64，MSI + zip）、
Linux（x64 / arm64，deb + rpm + AppImage + tar.gz + zip），每个都带
SHA-256 sidecar。Windows（WinUI 3）与 Linux（GTK4）宿主已构建并有
CI 覆盖。路线图：轮换流程（generate-next → promote，按两阶段 runbook）、
工作区流浪密钥扫描器、Sparkle/Tauri 密钥格式导入导出。

## 安全模型

保险库**有意**保持明文——它活在你自己可信设备间的私有同步里，预算花在
每台设备的全盘加密上。Keyward 从不把密钥发往任何地方：引擎里没有
网络代码。操作守则见 `AGENTS.md`（永不打印值、永不提交保险库、
流浪件立即收集）。

## 开发

```bash
raco rivet dev        # 构建后端 + macOS 宿主并运行应用
raco test tests/      # 引擎测试（存储 + 密钥元数据）
raco rivet package    # 分发产物
```

- 共享引擎：`app/backend.rkt` + `app/core/`（RVT1 契约——所有未来宿主
  共享的线上接口）
- macOS UI：`macos-host/Sources/RivetHost/`
- Windows UI：`windows/` · Linux UI：`linux/`

## License

AGPL-3.0

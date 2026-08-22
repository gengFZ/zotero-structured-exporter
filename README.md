# Zotero 结构化导出器

一个面向 Windows 的轻量脚本，把 Zotero 收藏夹导出成可以直接浏览、压缩和分享的普通文件夹。无需安装 PowerShell 模块，也不会登录或上传 Zotero 账号数据。

## 导出结构

```text
Zotero结构化导出/
└─ 收藏夹/
   └─ 作者-年份-标题/
      ├─ PDF原文/
      │  └─ 作者-年份-标题.pdf
      ├─ 笔记/
      │  ├─ 阅读笔记.html
      │  └─ images/
      ├─ 网页快照/
      ├─ 附件/
      └─ 文献信息.html
```

`文献信息.html` 包含标题、作者、日期、期刊、卷期、页码、DOI、网址、标签和 Zotero 条目键，不显示摘要。笔记以独立 HTML 保存，内嵌图片会复制到相邻的 `images` 文件夹，并附带纯文本完整备份。

## 环境要求

- Windows 10 或 Windows 11
- Zotero 桌面版
- Windows PowerShell 5.1 或更高版本
- `curl.exe`（现代 Windows 通常自带）

## 使用

1. 点击 GitHub 页面右上角 **Code → Download ZIP**，解压全部文件。
2. 确保 `运行Zotero导出器.cmd` 与 `Export-ZoteroCollection.ps1` 位于同一目录。
3. 双击 `运行Zotero导出器.cmd`。
4. 输入收藏夹名称或终端中列出的 8 位收藏夹键。
5. 导出结果默认保存在桌面的 `Zotero结构化导出` 文件夹中。

脚本会尝试自动启动 Zotero。如果仍无法连接，请在 Zotero 的 **设置 → 高级 → API** 中启用本地 API，然后重试。

### 命令行参数

```powershell
.\Export-ZoteroCollection.ps1 `
  -Collection "收藏夹名称或8位键" `
  -OutputDirectory "D:\导出目录" `
  -AnnotatedPdfDirectory "D:\带批注PDF"
```

- `-Collection`：收藏夹名称或 8 位键；省略时交互选择。
- `-OutputDirectory`：输出根目录；省略时使用桌面。
- `-AnnotatedPdfDirectory`：Zotero 预先导出的带批注 PDF 目录，可省略。
- `-Overwrite`：允许复用输出根目录；为避免同名文献相互覆盖，条目目录仍可能追加 Zotero 键。

## PDF 高亮和批注

Zotero 本地 API 提供的是原始附件文件，数据库中的高亮和批注不会自动写入 PDF。要保留它们：

1. 在 Zotero 中选择需要分享的文献。
2. 使用 **文件 → 导出 PDF**，勾选包含批注，导出到临时文件夹。
3. 运行本工具时输入该临时文件夹路径。

工具按原 PDF 文件名匹配，并优先复制带批注版本。若存在多个同名 PDF，请在分享前人工核对。

## 安全与隐私

- 工具只访问 `127.0.0.1:23119` 上的 Zotero 本地 API，不向第三方服务上传数据。
- 导出的笔记 HTML 会移除脚本、嵌入框架、表单、事件处理器和危险 URL 协议，以便分享后更安全地打开。
- 导出内容可能包含受版权保护的 PDF、个人笔记和其他附件；公开发布或转发前，请检查授权和隐私。
- 网页快照本身可能引用外部资源，离线时不保证完整还原。

## 已知限制

- 仅在 Windows 上设计和测试。
- PDF 批注需要先由 Zotero 导出，脚本无法直接“烘焙”数据库中的批注。
- 依赖文件名匹配带批注 PDF；同名附件可能需要手工确认。
- Zotero 或本地 API 行为变化后，脚本可能需要更新。

## 许可证

[MIT License](LICENSE)


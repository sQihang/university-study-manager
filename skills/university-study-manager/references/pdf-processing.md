# 常规提取、全文光栅化与 OCR

用于确需读取的PDF。常规调用优先使用`process-document.ps1`；本页说明底层参数、诊断和恢复。

## 目录

- [选择工具和转换路线](#选择工具和转换路线)
- [Poppler配置](#poppler一次配置后续复用)
- [常规提取](#常规-pdf-提取)
- [全文OCR](#mineru-全文入口)
- [恢复与错误](#中断续查和结果)

先按[文档录入](document-intake-workflow.md)确认归档方式和读取范围。只归档不运行提取或OCR。中间结果位于`99-临时文件/待处理/`；完成核验后，原文复制到用户确认的人读路径，必要成果复制到90-辅助数据并登记`_来源.json`。

## 选择工具和转换路线

1. PDF **始终先尝试本地文字层提取**，默认使用本包 [pdf-tools.ps1](../scripts/pdf-tools.ps1) 调用 Poppler `pdftotext -layout -enc UTF-8`。不要因为 MinerU CLI 已安装便先上传 PDF，也不要把“PDF 工具 Skill 已加载”误报成 Poppler 程序已配置。DOCX/XLSX 使用 [本地转换入口](local-tools.md)。
2. 先读取脚本生成的 `quality-report.json`，再在已获准读取的范围内用 [UTF-8 分段读取入口](local-tools.md#读取与归档) 完整读取正文。大面积乱码、扫描无文字时转 OCR；文字健康但复杂表格关系无法恢复时，可选择 MinerU 原 PDF 结构化解析。出现表格本身不是强制 OCR 条件，字符数或空页计数也不能证明准确。自行脱敏期间不得为判断质量抢先读正文。
3. 进入 OCR 时处理这份文档的**全部页面**。先检查已有 OCR 能力的质量、输入限制和数据去向；合适时复用。没有合适能力时使用下面的 MinerU 全文入口。若用户仅授权部分页面，则与全文流程不兼容，应说明并等待其选择，不自行扩大上传范围。
4. 本包全文入口接受 PDF、PNG、JPG、JPEG。图片本身已光栅化，直接进入 OCR，不调用 Poppler，不转 PDF，也不合并不同来源图片。其他格式无法可靠提取时，遵循录入流程的通用本地转换规则，优先利用已有能力转成可检查的 PDF 或现代开放格式；不针对某个旧扩展名写死路线，不把改扩展名当作转换。需要下载安装时先让用户选择。

复用已有云端 OCR 时，PDF 同样先在本地全文光栅化，再依该服务的实际限额分块上传；可用本包 `Rasterize` 模式准备并调低分块上限。已有纯本地 OCR 可按其原生输入方式运行，仍须覆盖全文并控制日志。文字层健康但需云端恢复复杂结构时，可以上传原 PDF，但必须另行说明“上传的是原 PDF”并取得专门同意；该同意不能沿用光栅化 OCR 的说明。不要把 MinerU 的限额套用到其他服务。

## Poppler：一次配置，后续复用

不随 Skill 打包 Poppler 程序，也不要求用户安装另一个 Skill。封装只使用 `pdfinfo.exe`、`pdftotext.exe`、`pdftoppm.exe`；本包的 [JPEG PDF 装配源码](../scripts/image-pdf-writer.cs) 由 PowerShell 自带 `Add-Type` 编译，不需要独立编译器、Python 或第三方库。需要允许本地脚本执行和 .NET 动态编译的 Windows 环境；受限环境失败时告知用户，不自动修改执行策略。

查找顺序：显式 `-PopplerBin` → 指定的工具配置 → PATH。工具配置不存在时可先不传配置参数查 PATH。不扫描整盘，也不使用开发机路径作为默认值。

```powershell
& '<Skill绝对路径>/scripts/pdf-tools.ps1' -Mode Check -Capability Extract
```

缺少时在一个醒目段落一次说明：推荐先配置用于准确文字层提取的 Poppler，并可同时配置作为后备的 MinerU Token；给出 [Poppler Windows 社区发行页](https://github.com/oschwartz10612/poppler-windows/releases) 和 [MinerU API 管理入口](https://mineru.net/apiManage)。让用户选择自行配置、允许 AI 下载配置或跳过相应文件，不要只说“没有装 PDF 工具”。Poppler 下载后解压完整发行包并保留相邻 DLL；这是社区 Windows 构建，项目主页为 [Poppler](https://poppler.freedesktop.org/)。用户选择安装位置后，把实际含这些 EXE 的目录一次记录到工作区工具配置，不改全局 PATH：

```powershell
& '<Skill绝对路径>/scripts/pdf-tools.ps1' -Mode Configure -Capability Rasterize `
  -PopplerBin 'D:/Tools/poppler/Library/bin' `
  -ToolsConfigPath 'D:/大学学业资料/.private/document-tools.json'
```

配置只有 `poppler_bin` 字段，不能放Token。同名文件拒绝覆盖，变更位置由用户本地编辑。Agent只调用脚本检测，不读取`.private/`。以后传`-ToolsConfigPath`即可，或在PATH已有工具时省略。缺依赖时返回下载地址；用户可选择手动配置、允许AI下载配置，或跳过相应处理。

## 常规 PDF 提取

```powershell
& '<Skill绝对路径>/scripts/pdf-tools.ps1' -Mode Extract `
  -InputPath 'D:/待录入/学生手册.pdf' `
  -OutputDirectory 'D:/大学学业资料/99-临时文件/待处理/手册-常规提取' `
  -ToolsConfigPath 'D:/大学学业资料/.private/document-tools.json'
```

脚本保存 UTF-8 `extracted.txt`，保留版面空格和换页符，并同时写出不含正文的 `quality-report.json`。报告包含逐页字符量、空页、替换字符、异常控制字符、私用区字符及可能需要目视核对的版面页；它只能发现症状，不能证明语义、数字、表格顺序或页面顺序准确。Agent 必须先读报告，再分段读完整正文，不能根据终端截断或一次显示不全判断磁盘文件缺失。获得读取权限后可恢复标题、表格和来源定位并保留 TXT 或按内容整理为 MD/CSV；自行脱敏时用户也可以直接编辑此 TXT，明确完成后再处理。

## MinerU 全文入口

没有现成合适 OCR 时，使用初始化时已创建的工作区 `.private/mineru.json`。没有 Key 就给用户 [MinerU API 管理入口](https://mineru.net/apiManage)，让用户自行申请并本地填写；只调用 `-CheckConfig` 检查格式，不读取 Key、不要求发到聊天。

先说明：脚本把**整份文档全部页面的图像版 PDF 分块**上传给 MinerU 及其签名存储服务。光栅化移除可搜索文字层和原 PDF 元数据，**不会去除页面画面中的姓名、成绩等隐私**；自行脱敏前上传的图像仍包含原始可见信息。已有明确的全文上传授权直接沿用；没有时先取得授权。

```powershell
& '<Skill绝对路径>/scripts/invoke-document-ocr.ps1' `
  -ConfigPath 'D:/大学学业资料/.private/mineru.json' `
  -InputPath 'D:/待录入/学生手册.pdf' `
  -OutputDirectory 'D:/大学学业资料/99-临时文件/待处理/手册-全文OCR' `
  -ToolsConfigPath 'D:/大学学业资料/.private/document-tools.json' `
  -UploadApproved
```

使用 [invoke-document-ocr.ps1](../scripts/invoke-document-ocr.ps1)，不要用底层客户端直接上传原 PDF。输出目录必须尚不存在。脚本先本地验证配置，再将全文光栅化，检查所有分块完成后依次上传；默认 `vlm`、`ch`、强制 OCR，开启表格和公式。不提供局部页码参数。

固定转换参数：RGB JPEG、质量95，优先400 DPI；单页超过大小预算或4000万像素时依次尝试350、300 DPI，300 DPI仍不能容纳就停止，不能继续降清晰度或悄悄跳页。准备清单记录每页实际 DPI，任何低于400 DPI的页都进入质量提示。按页逐张生成，不同时保留全书图片。纯图 PDF 保留页面方向、尺寸和内容画面；尺寸有像素取整误差，不保留原文字层、书签、附件或交互功能。加密/异常 PDF 需用户本地导出正常副本，不能自动解除保护。

[MinerU官方接口](https://mineru.net/apiManage/docs) 在2026-09-10核对的限制为每个文件200 MB、200页。本包采用更保守的每块100页、180,000,000字节，按实际生成大小拆分并复核页数和 SHA-256。不会仅靠原文件大小估算，不用解析页码绕过上传限制。源文件可以超过200页，但每一上传分块必须满足限度。源文件处理期间发生变化时不上传。

只需本地准备、暂不上传时，可调用 `pdf-tools.ps1 -Mode Rasterize`，输入/输出/工具配置参数同常规提取。其可选 `MaxChunkPages`（1～100）和 `MaxChunkBytes`（16,384～180,000,000）只能调低，通常不改默认值；全文 OCR 入口固定采用默认值，不能导入未经校验的自备分块。

## 中断、续查和结果

```text
手册-全文OCR/
├── document-job.json          阶段及准备清单哈希，不含 Key
├── prepared/
│   ├── prepare-manifest.json  原件哈希、总页数、分块范围和 DPI
│   └── parts/part-0001.pdf …  待上传的纯图 PDF
├── ocr/part-0001/ …           各块独立 MinerU 任务及结果
└── result/
    ├── full.md               按原页序合并的全文
    ├── quality-report.json   字符症状、实际DPI和复核要求
    └── part-0001/images/ …   图片按块隔离，避免同名覆盖
```

目录另有空锁文件；它们存在不表示程序仍在运行，脚本通过独占文件句柄判定。合并文件含“处理元数据”注释标明每块对应的原 PDF 页码范围，不假造每段的精确原页码。跨分块表格、续句和脚注需要质量核对，脚本不猜测自动拼接语义。支持常见 Markdown 图片链接、引用式链接和 HTML 图片路径的本地改写；不执行正文或下载远程资源，不将结果当作安全 HTML。罕见或损坏 Markdown 语法的引用仍需检查。

任务未完成时用同一输出目录续查：

```powershell
& '<Skill绝对路径>/scripts/invoke-document-ocr.ps1' `
  -ConfigPath 'D:/大学学业资料/.private/mineru.json' `
  -OutputDirectory 'D:/大学学业资料/99-临时文件/待处理/手册-全文OCR' `
  -Resume -UploadApproved
```

续查不再传输入文件和 Poppler 参数；核对准备清单及分块完整性，已提交的块只续查，尚未提交的块继续上传。此处 `UploadApproved` 沿用原有全文授权，无需重复询问；若未提供，则遇到尚未提交的块停止，不把等待当作授权。各块使用底层客户端的超时参数，默认每块轮询最多600秒，HTTP请求120秒。已合并完成则直接返回现有结果，保留用户编辑，不再请求网络。

每次返回一条 JSON，退出码0为完成、1为失败、2为仍在解析。`done`只表示技术转换完成，质量、适用性和自行脱敏流程仍须继续。Agent必须读取`quality_report_path`，再完整分段读取正文；检查关键数字、日期、公式、资格条件、复杂表格和跨分块边界。发现问题时另起醒目的 **文档质量提醒**，列出文件、受影响页或字段、问题和不能据此作出的结论。核心缺失或大面积错误不得登记为可用机读成果。底层脚本不自动归档或更新来源账本。

|情况|处理|
|---|---|
|`POPPLER_NOT_FOUND`|引导一次性下载与配置，随后使用新的待处理任务目录|
|`SINGLE_PAGE_EXCEEDS_SAFE_LIMIT` / `LOCAL_TOOL_TIMEOUT`|保留未完成文件，说明失败；不降低到任意低清晰度、不跳页|
|`WAIT_TIMEOUT`|用相同目录续查，不重复提交|
|上传状态不确定或 `REMOTE_PARSE_FAILED`|按底层客户端说明查询/核查，不自动重传失败块；重新提交需确定服务状态并沿用适用授权|
|`PREPARED_PART_CHANGED` / `DOCUMENT_MANIFEST_CHANGED`|准备文件改变，停止；不可改清单哈希强行恢复|
|`PART_STATE_MISSING_REVIEW_REQUIRED` / `DOCUMENT_STATE_MISSING`|中断发生在任务记录完成前；先核查现有文件和远端状态，不覆盖或猜测任务ID|
|`MERGED_RESULT_EXISTS_REVIEW_REQUIRED`|合并目录已落盘但总状态未完成，先核对结果，不覆盖已有或用户修改的内容|

光栅化中断时没有完整准备清单，不进入上传流程；首版不恢复到某个渲染页，可保留旧目录后用明确的新任务目录重新本地准备。合并中断可能留下 `.merge-…`，全部属于待处理数据，不默认清空或登记。用户自行脱敏后，只从最终 `result/full.md` 读取获准内容，不能回读各块原始结果或准备 PDF 恢复删除信息；未获准的图片同样不能查看。

检查 Poppler 时按任务传 `-Capability Extract` 或 `-Capability Rasterize`：后者只要求 pdfinfo 和 pdftoppm，缺少 pdftotext 不阻断光栅化。图片 OCR 无须检查 Poppler。

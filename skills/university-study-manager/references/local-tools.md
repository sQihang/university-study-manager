# 固定本地工具入口

正常调用脚本时无需读取源码。所有路径使用绝对路径；`<Skill>`是当前加载Skill的根目录。

## 目录

- [初始化](#初始化)
- [统一文档处理](#统一文档处理)
- [读取与归档](#读取与归档)
- [底层诊断](#底层诊断)

## 初始化

```powershell
& '<Skill>/scripts/initialize-workspace.ps1' -WorkspacePath '<工作区>'
```

新工作区位置由用户指定。非空目录需显式使用`-AllowNonEmpty`。脚本创建最小目录、`工作区.yaml`、`00-待整理`、`归档说明.md`、`90-辅助数据/_来源.json`、离线答题页和`.private/mineru.json`，不预建学期、不覆盖已有工作区。已有工作区重复运行时补建缺少的待整理目录和说明文档，不迁移旧结构。

## 统一文档处理

```powershell
& '<Skill>/scripts/process-document.ps1' -WorkspacePath '<工作区>' -InputPath '<源文件>' -OutputDirectory '<工作区>/99-临时文件/待处理/<唯一任务>' -Mode Auto
```

模式：

- `Auto`：可读文本直接返回；PDF先文字提取，完全没有可靠文字层时在已有上传授权下转OCR；DOCX/XLSX使用内置本地转换。
- `Text`：只做本地文字提取或转换，不自动上传。
- `Ocr`：PDF全文光栅化后OCR，图片直接OCR。
- `ComplexTable`：使用支持版面和表格结构的路径，目标为静态HTML；非PDF Office等输入由本机MinerU CLI实际能力决定。

已有空输出目录可以使用；普通非空目录拒绝覆盖。若目录含固定OCR状态，统一入口优先恢复已下载或进行中的任务；也可显式传`-Resume`。只有已经取得具体外部上传授权时才传`-UploadApproved`。返回值包含失败阶段、实际方法、耗时、输出、质量和底层错误码。`needs_action`表示需要授权、配置或适合工具，不等于处理失败。

PDF文字层出现表格诊断只表示需要检查；确认是复杂表格后改用`ComplexTable`或相应OCR路径。质量报告不能替代内容核查。

## 读取与归档

严格读取UTF-8文本：

```powershell
& '<Skill>/scripts/read-text-chunks.ps1' -InputPath '<文件>' -StartLine 1 -LineCount 200
```

继续读取直到所需范围结束；各段SHA-256必须一致。不要用终端整文件输出读取用户正文。

只归档：

```powershell
& '<Skill>/scripts/archive-document.ps1' -WorkspacePath '<工作区>' -SourcePath '<工作区>/00-待整理/通知.pdf' -DestinationRelativePath '01-资料库/03-学期资料/2026-2027-1/02-校园生活/通知.pdf' -Mode ArchiveOnly -MoveInboxSource
```

关联已有可读源文件：

```powershell
& '<Skill>/scripts/archive-document.ps1' -WorkspacePath '<工作区>' -SourcePath '<源文件.md>' -DestinationRelativePath '01-资料库/01-学校资料/某政策.md' -Mode ReadableSource -ArtifactKind policy_full -ReadScope Public
```

归档原文并登记处理结果：

```powershell
& '<Skill>/scripts/archive-document.ps1' -WorkspacePath '<工作区>' -SourcePath '<源文件>' -DestinationRelativePath '01-资料库/01-学校资料/某办法.pdf' -Mode Processed -ProcessedPaths @('<已检查全文>','<已核验提要>') -ArtifactRelativePaths @('90-辅助数据/学校资料/某办法--全文.md','90-辅助数据/学校资料/某办法--规则提要.md') -ArtifactKind policy -ProcessingMethod 'Poppler文字提取' -QualityStatus Pass -ReadScope Public -VersionLabel '2026' -VersionStatus Current
```

处理路径和成果路径一一对应。目标必须由用户在计划中确认，脚本不会替用户分类。目标存在时停止，默认不覆盖。三种模式均在复制全部成功后更新 `_来源.json` 的 `archives`；后两种模式另外更新 `artifacts`。`-MoveInboxSource` 只可用于 `00-待整理` 内来源，成功复制并写账本后移走；显式指定的其他来源不传此开关，只复制。完整替代需传`RelationType Replacement`、`SupersedesArtifact`和可定位的`SupersessionEvidence`。

同一原文的机读成果因乱码、缺页等原因重新处理并已核验时，使用修复入口：

```powershell
& '<Skill>/scripts/repair-artifact.ps1' -WorkspacePath '<工作区>' -ArtifactRelativePath '90-辅助数据/学校资料/某办法--全文.md' -ReplacementPath '<99-临时文件中的已核验新结果>' -ProcessingMethod '<本次实际方法>' -QualityStatus Pass -ReviewNote '<核验范围与改变的处理条件>'
```

脚本原子替换成果和来源记录，保留原始来源、读取范围和政策版本状态，并写入修复前后指纹。新结果未核验、来源不同或政策本身换版时不要使用该入口。

## 底层诊断

统一入口报告现有方法不可用时，才按需调用底层脚本：`pdf-tools.ps1`、`text-convert.ps1`、`mineru-cli.ps1`、`invoke-document-ocr.ps1`。先使用工作区`.private/document-tools.json`中的Poppler路径，再检查PATH；已有方法可完成任务时不推荐其他工具。

MinerU CLI支持范围以本机版本帮助为准：

```powershell
& '<Skill>/scripts/mineru-cli.ps1' -Mode Inspect
```

需要下载安装时先让用户选择。缺MinerU Token时指向`<工作区>/.private/mineru.json`和[申请入口](https://mineru.net/apiManage)，不得读取配置正文。

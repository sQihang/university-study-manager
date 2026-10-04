#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$WorkspacePath,[switch]$AllowNonEmpty)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Utf8NoBom=[Text.UTF8Encoding]::new($false)
function U([int[]]$p){return -join($p|ForEach-Object{[char]$_})}
function Done([string]$status,[string]$code,[string]$path,[int]$exitCode){[ordered]@{status=$status;code=$code;path=$path}|ConvertTo-Json -Compress|Write-Output;exit $exitCode}
function NoLinks([string]$p){$cursor=$p;while($cursor){if(Test-Path -LiteralPath $cursor){$i=Get-Item -LiteralPath $cursor -Force;if(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'REPARSE_PATH_NOT_ALLOWED'}};$parent=[IO.Directory]::GetParent($cursor);if($null-eq$parent){break};$cursor=$parent.FullName}}
function EnsureMineruConfig([string]$root){$private=[IO.Path]::Combine($root,'.private');$target=[IO.Path]::Combine($private,'mineru.json');if([IO.Directory]::Exists($target)){throw 'CONFIG_PATH_CONFLICT'};if(-not[IO.File]::Exists($target)){. ([IO.Path]::Combine($PSScriptRoot,'mineru-ocr.ps1'));$r=Invoke-MineruOcr -InitializeConfig -ConfigPath $target;if($r.status-ne'configured'){throw 'CONFIG_INITIALIZATION_FAILED'}}}
function EnsureIntake([string]$root,$layout){
    $inbox=[IO.Path]::Combine($root,$layout.Inbox);$guide=[IO.Path]::Combine($root,$layout.Guide)
    if([IO.File]::Exists($inbox)-or[IO.Directory]::Exists($guide)){throw 'INTAKE_PATH_CONFLICT'}
    [IO.Directory]::CreateDirectory($inbox)|Out-Null
    if(-not[IO.File]::Exists($guide)){
        $body=@'
# 归档说明

本文件记录适用于今后归档的一般规则和我的特殊要求。每批归档前先阅读；新规则经我确认后写在这里。单份文件的原路径、目标路径及指纹记录在辅助数据的 `_来源.json`，不要写进本文件。

## 默认分类

- 学校长期适用的制度、通知和培养方案：`{{SCHOOL}}`。
- 我的长期学业资料：`{{PERSONAL}}`。
- 明确属于某学期的课程与校园材料：`{{SEMESTER}}`，按学期和用途归类。
- 不确定归属时先列为待确认，不猜测学期、版本或用途。

## 我的特殊归档要求

（暂无。可告诉助手“以后遇到……放到……”，从以后批次开始执行。）

## 最近更新

- 初始化：创建本说明。每批归档后如分类规则有变化，在此概括更新，并提醒我阅读。
'@
        $body=$body.Replace('{{SCHOOL}}',($layout.Human+'/'+$layout.School)).Replace('{{PERSONAL}}',($layout.Human+'/'+$layout.Personal)).Replace('{{SEMESTER}}',($layout.Human+'/'+$layout.Semester))
        [IO.File]::WriteAllText($guide,$body.TrimStart()+"`n",$Utf8NoBom)
    }
}
$resolved=$WorkspacePath
try{
    if($WorkspacePath-notmatch'^[A-Za-z]:[\\/]'-or$WorkspacePath.Substring(2).Contains(':')){Done 'error' 'ABSOLUTE_LOCAL_PATH_REQUIRED' $WorkspacePath 1}
    $resolved=[IO.Path]::GetFullPath($WorkspacePath).TrimEnd('\','/');NoLinks $resolved
    if($resolved-eq[IO.Path]::GetPathRoot($resolved).TrimEnd('\','/')){Done 'error' 'DRIVE_ROOT_NOT_ALLOWED' $resolved 1}
    if([IO.File]::Exists($resolved)){Done 'error' 'PATH_IS_FILE' $resolved 1}
    $workspaceName=(U @(0x5DE5,0x4F5C,0x533A))+'.yaml';$workspaceFile=[IO.Path]::Combine($resolved,$workspaceName)
    if([IO.File]::Exists($workspaceFile)){. ([IO.Path]::Combine($PSScriptRoot,'workspace-layout.ps1'));$existing=Get-WorkspaceLayout $resolved;EnsureIntake $resolved $existing;EnsureMineruConfig $resolved;Done 'already_initialized' 'WORKSPACE_EXISTS' $resolved 0}
    if([IO.Directory]::Exists($resolved)-and@(Get-ChildItem -LiteralPath $resolved -Force|Select-Object -First 1).Count-and-not$AllowNonEmpty){Done 'error' 'NONEMPTY_REQUIRES_ALLOW' $resolved 1}
    $human='01-资料库';$machine='90-辅助数据';$quiz='02-自测'
    $relative=@('00-待整理',$human,"$human/01-学校资料","$human/02-个人档案","$human/03-学期资料",$machine,"$machine/学校资料","$machine/个人学业","$machine/学期",$quiz,"$quiz/01-题库","$quiz/02-记录",'99-临时文件','.private')
    foreach($r in $relative){$p=[IO.Path]::Combine($resolved,$r.Replace('/','\'));NoLinks $p;if([IO.File]::Exists($p)){throw 'REQUIRED_DIRECTORY_IS_FILE'}}
    [IO.Directory]::CreateDirectory($resolved)|Out-Null;foreach($r in $relative){[IO.Directory]::CreateDirectory([IO.Path]::Combine($resolved,$r.Replace('/','\')))|Out-Null}
    $config=[ordered]@{};$config[(U @(0x7ED3,0x6784,0x7248,0x672C))]=2;$config[(U @(0x5F53,0x524D,0x5B66,0x671F))]=$null;$config[(U @(0x57FA,0x672C,0x4FE1,0x606F))]=[ordered]@{}
    [IO.File]::WriteAllText($workspaceFile,(($config|ConvertTo-Json -Depth 4)+"`n"),$Utf8NoBom)
    $ledger=[IO.Path]::Combine($resolved,$machine,'_'+(U @(0x6765,0x6E90))+'.json');[IO.File]::WriteAllText($ledger,"{`n  `"schemaVersion`": 2,`n  `"artifacts`": [],`n  `"archives`": []`n}`n",$Utf8NoBom)
    $playerSource=[IO.Path]::Combine([IO.Path]::GetDirectoryName($PSScriptRoot),'assets','quiz-player.html');$player=[IO.Path]::Combine($resolved,$quiz,(U @(0x7B54,0x9898))+'.html');[IO.File]::Copy($playerSource,$player,$false)
    . ([IO.Path]::Combine($PSScriptRoot,'workspace-layout.ps1'));$layout=Get-WorkspaceLayout $resolved;EnsureIntake $resolved $layout
    EnsureMineruConfig $resolved;Done 'created' 'WORKSPACE_CREATED' $resolved 0
}catch{$code=$_.Exception.Message;if($code-notmatch'^[A-Z0-9_]+$'){$code='INITIALIZATION_FAILED'};Done 'error' $code $resolved 1}

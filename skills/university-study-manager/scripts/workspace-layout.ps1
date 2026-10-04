function Get-WorkspaceLayout([string]$WorkspacePath) {
    $configPath = [IO.Path]::Combine($WorkspacePath, '工作区.yaml')
    if (-not [IO.File]::Exists($configPath)) { throw 'WORKSPACE_NOT_INITIALIZED' }
    try {
        $config = [IO.File]::ReadAllText($configPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
        $version = [int]$config.结构版本
    } catch { throw 'WORKSPACE_CONFIG_INVALID' }
    switch ($version) {
        1 { return [pscustomobject]@{ Version=1; Inbox='00-待整理'; Guide='归档说明.md'; Human='人读资料'; School='全局'; Personal='个人档案'; Semester='学期'; Course='课程'; Campus='校园生活'; Machine='机读资料'; MachineGlobal='全局'; MachinePersonal='个人学业'; MachineSemester='学期'; Quiz='自测'; QuizBanks='题库'; QuizRecords='记录'; Temp='Temp' } }
        2 { return [pscustomobject]@{ Version=2; Inbox='00-待整理'; Guide='归档说明.md'; Human='01-资料库'; School='01-学校资料'; Personal='02-个人档案'; Semester='03-学期资料'; Course='01-课程'; Campus='02-校园生活'; Machine='90-辅助数据'; MachineGlobal='学校资料'; MachinePersonal='个人学业'; MachineSemester='学期'; Quiz='02-自测'; QuizBanks='01-题库'; QuizRecords='02-记录'; Temp='99-临时文件' } }
        default { throw 'UNSUPPORTED_WORKSPACE_VERSION' }
    }
}

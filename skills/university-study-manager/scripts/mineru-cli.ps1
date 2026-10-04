#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Inspect','Precision','Flash')][string]$Mode='Inspect',
    [string]$InputPath,
    [string]$OutputDirectory,
    [string]$ConfigPath,
    [string]$CliPath,
    [ValidateSet('md','html','latex','docx')][string]$Format='md',
    [ValidateSet('auto','vlm','pipeline','html')][string]$Model='auto',
    [string]$Language='ch',
    [switch]$Ocr,
    [switch]$UploadApproved,
    [switch]$OriginalPdfCloudApproved,
    [ValidateRange(30,7200)][int]$TimeoutSeconds=600
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function FullPath([string]$Path,[string]$Code) {
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw $Code }
    return [IO.Path]::GetFullPath($Path)
}
function ResolveCli {
    if ($CliPath) {
        $candidate=FullPath $CliPath 'CLI_PATH_INVALID'
        if (![IO.File]::Exists($candidate)) { throw 'CLI_NOT_FOUND' }
        return $candidate
    }
    $command=Get-Command 'mineru-open-api' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw 'CLI_NOT_FOUND' }
    return $command.Source
}
function InvokeCli([string]$Exe,[string[]]$Arguments,[string]$Stdout,[string]$Stderr) {
    $savedPreference=$ErrorActionPreference
    try {
        $ErrorActionPreference='Continue'
        & $Exe @Arguments 1> $Stdout 2> $Stderr
        return $LASTEXITCODE
    } finally { $ErrorActionPreference=$savedPreference }
}
function ReadHelp([string]$Exe,[string[]]$Arguments) {
    $out=[IO.Path]::GetTempFileName(); $err=[IO.Path]::GetTempFileName()
    try {
        $code=InvokeCli $Exe $Arguments $out $err
        $text=([IO.File]::ReadAllText($out)+"`n"+[IO.File]::ReadAllText($err)).Trim()
        return [ordered]@{exitCode=$code;text=$text}
    } finally { Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue }
}

$result=$null; $stdout=$null; $stderr=$null
try {
    $cli=ResolveCli
    if ($Mode -eq 'Inspect') {
        $version=ReadHelp $cli @('--version')
        $precision=ReadHelp $cli @('extract','--help')
        $flash=ReadHelp $cli @('flash-extract','--help')
        $result=[ordered]@{
            status='inspected'; cli=$cli; version=$version.text
            precisionHelp=$precision.text; flashHelp=$flash.text
            note='Treat these runtime help texts as the installed CLI capability source.'
        }
    } else {
        if (!$UploadApproved) { throw 'UPLOAD_APPROVAL_REQUIRED' }
        $input=FullPath $InputPath 'INPUT_PATH_INVALID'
        if (![IO.File]::Exists($input)) { throw 'INPUT_FILE_REQUIRED' }
        $isPdf=[IO.Path]::GetExtension($input) -ieq '.pdf'
        if ($isPdf -and $Ocr) { throw 'PDF_OCR_USE_RASTERIZED_ENTRY' }
        if ($isPdf -and !$OriginalPdfCloudApproved) { throw 'ORIGINAL_PDF_CLOUD_APPROVAL_REQUIRED' }
        $output=FullPath $OutputDirectory 'OUTPUT_PATH_INVALID'
        if ([IO.Directory]::Exists($output) -or [IO.File]::Exists($output)) { throw 'OUTPUT_MUST_NOT_EXIST' }
        $arguments=@($(if ($Mode -eq 'Precision') {'extract'} else {'flash-extract'}),$input,'--output',$output,'--language',$Language,'--timeout',[string]$TimeoutSeconds)
        if ($Ocr) { $arguments+='--ocr' }
        if ($Mode -eq 'Precision') {
            $config=FullPath $ConfigPath 'CONFIG_PATH_INVALID'
            if (![IO.File]::Exists($config)) { throw 'CONFIG_MISSING' }
            try { $settings=ConvertFrom-Json ([IO.File]::ReadAllText($config,[Text.UTF8Encoding]::new($false,$true))) } catch { throw 'CONFIG_INVALID' }
            if ($null -eq $settings -or $settings.PSObject.Properties.Name -notcontains 'token' -or [string]::IsNullOrWhiteSpace([string]$settings.token) -or [string]$settings.token -eq '<YOUR_KEY>') { throw 'TOKEN_MISSING' }
            $arguments+=@('--format',$Format)
            if ($Model -ne 'auto') { $arguments+=@('--model',$Model) }
            [IO.Directory]::CreateDirectory($output)|Out-Null
            $stdout=[IO.Path]::Combine($output,'.cli-stdout.log'); $stderr=[IO.Path]::Combine($output,'.cli-stderr.log')
            $oldToken=$env:MINERU_TOKEN
            try {
                $env:MINERU_TOKEN=[string]$settings.token
                $exitCode=InvokeCli $cli $arguments $stdout $stderr
            } finally { $env:MINERU_TOKEN=$oldToken }
        } else {
            [IO.Directory]::CreateDirectory($output)|Out-Null
            $stdout=[IO.Path]::Combine($output,'.cli-stdout.log'); $stderr=[IO.Path]::Combine($output,'.cli-stderr.log')
            $exitCode=InvokeCli $cli $arguments $stdout $stderr
        }
        if ($exitCode -ne 0) { throw 'CLI_EXTRACTION_FAILED' }
        Remove-Item -LiteralPath $stdout,$stderr -Force -ErrorAction SilentlyContinue
        $files=@(Get-ChildItem -LiteralPath $output -File -Recurse | ForEach-Object {$_.FullName})
        if (!$files.Count) { throw 'CLI_OUTPUT_MISSING' }
        $result=[ordered]@{status='done';mode=$Mode;outputDirectory=$output;fileCount=$files.Count;paths=$files;reviewRequired=$true}
    }
} catch {
    foreach ($log in @($stdout,$stderr)) { if ($log) { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue } }
    $code=$_.Exception.Message
    if ($code -notmatch '^[A-Z_]+$') { $code='CLI_FAILED' }
    $result=[ordered]@{status='error';code=$code}
    if ($code -eq 'TOKEN_MISSING') { $result['helpUrl']='https://mineru.net/apiManage' }
}
$result|ConvertTo-Json -Depth 8 -Compress
if ($result.status -eq 'error') { exit 1 }

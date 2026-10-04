#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkspacePath,
    [Parameter(Mandatory=$true)][string]$ArtifactRelativePath,
    [Parameter(Mandatory=$true)][string]$ReplacementPath,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$ProcessingMethod,
    [Parameter(Mandatory=$true)][ValidateSet('Pass','Doubtful')][string]$QualityStatus,
    [string[]]$QualityIssues=@(),
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$ReviewNote
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Utf8NoBom=[Text.UTF8Encoding]::new($false)
function U([int[]]$p){return -join($p|ForEach-Object{[char]$_})}
function Emit([string]$status,[string]$code,$detail=$null){$r=[ordered]@{status=$status;code=$code};if($detail){foreach($p in $detail.GetEnumerator()){$r[$p.Key]=$p.Value}};$r|ConvertTo-Json -Depth 10 -Compress|Write-Output;if($status-ne'repaired'){exit 1}}
function Full([string]$p,[string]$code){if([string]::IsNullOrWhiteSpace($p)-or$p-notmatch'^[A-Za-z]:[\\/]'-or$p.Substring(2).Contains(':')){throw $code};return [IO.Path]::GetFullPath($p).TrimEnd('\','/')}
function NoLinks([string]$p){$cursor=$p;while($cursor){if(Test-Path -LiteralPath $cursor){$i=Get-Item -LiteralPath $cursor -Force;if(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'REPARSE_PATH_NOT_ALLOWED'}};$parent=[IO.Directory]::GetParent($cursor);if($null-eq$parent){break};$cursor=$parent.FullName}}
function Hash([string]$p){$sha=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($p);try{return([BitConverter]::ToString($sha.ComputeHash($s))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose();$sha.Dispose()}}
function ReadJson([string]$p){try{return [IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json}catch{throw 'SOURCE_LEDGER_INVALID'}}

$lock=$null;$artifactTmp=$null;$ledgerTmp=$null;$artifactBackup=$null;$ledgerBackup=$null;$artifactReplaced=$false
try{
    $root=Full $WorkspacePath 'ABSOLUTE_WORKSPACE_REQUIRED';NoLinks $root;if(-not[IO.Directory]::Exists($root)){throw 'WORKSPACE_NOT_FOUND'}
    . ([IO.Path]::Combine($PSScriptRoot,'workspace-layout.ps1'));$layout=Get-WorkspaceLayout $root
    $machineRoot=[IO.Path]::Combine($root,$layout.Machine)
    if([IO.Path]::IsPathRooted($ArtifactRelativePath)-or$ArtifactRelativePath.Contains(':')-or$ArtifactRelativePath-match'(^|[\\/])\.\.([\\/]|$)'){throw 'INVALID_ARTIFACT_PATH'}
    $artifact=[IO.Path]::GetFullPath([IO.Path]::Combine($root,$ArtifactRelativePath));NoLinks $artifact
    if(-not$artifact.StartsWith($machineRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'MACHINE_ARTIFACT_REQUIRED'};if(-not[IO.File]::Exists($artifact)){throw 'ARTIFACT_NOT_FOUND'}
    $replacement=Full $ReplacementPath 'ABSOLUTE_REPLACEMENT_REQUIRED';NoLinks $replacement;if(-not[IO.File]::Exists($replacement)){throw 'REPLACEMENT_NOT_FOUND'};if($replacement-eq$artifact){throw 'REPLACEMENT_MUST_BE_SEPARATE_FILE'};if($replacement-match'(^|[\\/])\.private([\\/]|$)'){throw 'PRIVATE_REPLACEMENT_FORBIDDEN'}
    if($QualityStatus-eq'Doubtful'-and$QualityIssues.Count-eq0){throw 'QUALITY_ISSUES_REQUIRED'};if($QualityStatus-eq'Pass'-and$QualityIssues.Count){throw 'QUALITY_STATUS_CONFLICT'}
    $relative=$artifact.Substring($root.Length+1).Replace('\','/');$ledgerPath=[IO.Path]::Combine($machineRoot,'_'+(U @(0x6765,0x6E90))+'.json');NoLinks $ledgerPath;if(-not[IO.File]::Exists($ledgerPath)){throw 'SOURCE_LEDGER_MISSING'}
    $lockPath=[IO.Path]::Combine($root,'.archive-document.lock');$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $ledger=ReadJson $ledgerPath;if([int]$ledger.schemaVersion-notin@(1,2)-or$null-eq$ledger.artifacts){throw 'SOURCE_LEDGER_INVALID'};if([int]$ledger.schemaVersion-eq2-and$null-eq$ledger.archives){throw 'SOURCE_LEDGER_INVALID'}
    $matches=@($ledger.artifacts|Where-Object{@($_.paths)-contains$relative});if($matches.Count-ne1){throw 'ARTIFACT_RECORD_NOT_UNIQUE'};$record=$matches[0]
    $oldHash=Hash $artifact;$newHash=Hash $replacement;if($oldHash-eq$newHash){throw 'REPLACEMENT_CONTENT_UNCHANGED'}
    $id=[guid]::NewGuid().ToString('N');$artifactTmp=$artifact+'.'+$id+'.tmp';$ledgerTmp=$ledgerPath+'.'+$id+'.tmp';$artifactBackup=$artifact+'.'+$id+'.bak';$ledgerBackup=$ledgerPath+'.'+$id+'.bak'
    [IO.File]::Copy($replacement,$artifactTmp,$false);if((Hash $artifactTmp)-ne$newHash){throw 'REPLACEMENT_COPY_VALIDATION_FAILED'}
    $record|Add-Member -NotePropertyName processingMethod -NotePropertyValue $ProcessingMethod -Force;$record|Add-Member -NotePropertyName quality -NotePropertyValue $QualityStatus -Force;$record|Add-Member -NotePropertyName qualityIssues -NotePropertyValue @($QualityIssues) -Force
    $repairs=@();if($record.PSObject.Properties['repairs']){$repairs=@($record.repairs)};$repairs+=,[pscustomobject][ordered]@{repairedAt=[DateTime]::Now.ToString('s');artifact=$relative;previousSha256=$oldHash;newSha256=$newHash;reviewNote=$ReviewNote};$record|Add-Member -NotePropertyName repairs -NotePropertyValue $repairs -Force
    $hashes=[ordered]@{};if($record.PSObject.Properties['artifactHashes']){foreach($p in $record.artifactHashes.PSObject.Properties){$hashes[$p.Name]=$p.Value}};$hashes[$relative]=$newHash;$record|Add-Member -NotePropertyName artifactHashes -NotePropertyValue ([pscustomobject]$hashes) -Force
    [IO.File]::WriteAllText($ledgerTmp,(($ledger|ConvertTo-Json -Depth 30)+"`n"),$Utf8NoBom)
    $check=ReadJson $ledgerTmp;if([int]$check.schemaVersion-notin@(1,2)){throw 'UPDATED_LEDGER_INVALID'}
    [IO.File]::Replace($artifactTmp,$artifact,$artifactBackup,$true);$artifactReplaced=$true
    try{[IO.File]::Replace($ledgerTmp,$ledgerPath,$ledgerBackup,$true)}catch{if($artifactReplaced-and[IO.File]::Exists($artifactBackup)){[IO.File]::Replace($artifactBackup,$artifact,[System.Management.Automation.Language.NullString]::Value,$true);$artifactReplaced=$false};throw}
    foreach($p in @($artifactBackup,$ledgerBackup)){if($p-and[IO.File]::Exists($p)){[IO.File]::Delete($p)}}
    Emit 'repaired' 'ARTIFACT_REPAIRED' ([ordered]@{artifact=$relative;previous_sha256=$oldHash;new_sha256=$newHash;ledger=$ledgerPath})
}catch{
    foreach($p in @($artifactTmp,$ledgerTmp)){if($p-and[IO.File]::Exists($p)){[IO.File]::Delete($p)}}
    $code=$_.Exception.Message;if($code-notmatch'^[A-Z0-9_]+$'){$code='ARTIFACT_REPAIR_FAILED'};Emit 'error' $code
}finally{if($null-ne$lock){$lock.Dispose()}}

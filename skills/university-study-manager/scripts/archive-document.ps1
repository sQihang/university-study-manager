#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkspacePath,
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [Parameter(Mandatory=$true)][string]$DestinationRelativePath,
    [ValidateSet('ArchiveOnly','ReadableSource','Processed')][string]$Mode='ArchiveOnly',
    [string[]]$ProcessedPaths=@(), [string[]]$ArtifactRelativePaths=@(),
    [string]$ArtifactKind, [string]$ProcessingMethod,
    [ValidateSet('Pass','Doubtful')][string]$QualityStatus, [string[]]$QualityIssues=@(),
    [ValidateSet('Public','LocalApproved','Restricted')][string]$ReadScope='Restricted',
    [switch]$MoveInboxSource,
    [string]$VersionLabel, [ValidateSet('Current','Historical','Uncertain')][string]$VersionStatus='Uncertain',
    [ValidateSet('Primary','Implementation','Supplement','Replacement','Parallel','Uncertain')][string]$RelationType,
    [string]$RelatedArtifact, [string]$SupersedesArtifact, [string]$SupersessionEvidence
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Utf8NoBom=[Text.UTF8Encoding]::new($false)
function U([int[]]$p){return -join($p|ForEach-Object{[char]$_})}
function Result([string]$status,[string]$code,$extra=$null){$r=[ordered]@{status=$status;code=$code};if($extra){foreach($p in $extra.GetEnumerator()){$r[$p.Key]=$p.Value}};$r|ConvertTo-Json -Depth 12 -Compress|Write-Output;if($status-ne'archived'){exit 1}}
function Full([string]$p,[string]$code){if([string]::IsNullOrWhiteSpace($p)-or$p-notmatch'^[A-Za-z]:[\\/]'-or$p.Substring(2).Contains(':')){throw $code};return [IO.Path]::GetFullPath($p).TrimEnd('\','/')}
function NoLinks([string]$p){$cursor=$p;while($cursor){if(Test-Path -LiteralPath $cursor){$i=Get-Item -LiteralPath $cursor -Force;if(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'REPARSE_PATH_NOT_ALLOWED'}};$parent=[IO.Directory]::GetParent($cursor);if($null-eq$parent){break};$cursor=$parent.FullName}}
function NoTreeLinks([string]$p){if([IO.Directory]::Exists($p)){foreach($i in Get-ChildItem -LiteralPath $p -Recurse -Force){if(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne0){throw 'REPARSE_PATH_NOT_ALLOWED'}}}}
function Within([string]$relative){if([string]::IsNullOrWhiteSpace($relative)-or[IO.Path]::IsPathRooted($relative)-or$relative.Contains(':')-or$relative-match'(^|[\\/])\.\.([\\/]|$)'){throw 'INVALID_RELATIVE_PATH'};$p=[IO.Path]::GetFullPath([IO.Path]::Combine($script:root,$relative));if(-not$p.StartsWith($script:root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'PATH_OUTSIDE_WORKSPACE'};NoLinks $p;return $p}
function Rel([string]$p){return $p.Substring($script:root.Length+1).Replace('\','/')}
function HashFile([string]$p){$sha=[Security.Cryptography.SHA256]::Create();$s=[IO.File]::OpenRead($p);try{return([BitConverter]::ToString($sha.ComputeHash($s))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose();$sha.Dispose()}}
function HashPath([string]$p){if([IO.File]::Exists($p)){return HashFile $p};if(-not[IO.Directory]::Exists($p)){throw 'SOURCE_NOT_FOUND'};$lines=@(Get-ChildItem -LiteralPath $p -Recurse -File -Force|Sort-Object FullName|ForEach-Object{$_.FullName.Substring($p.Length+1).Replace('\','/')+':'+(HashFile $_.FullName)});$sha=[Security.Cryptography.SHA256]::Create();try{return([BitConverter]::ToString($sha.ComputeHash($Utf8NoBom.GetBytes(($lines-join"`n"))))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function CopyNew([string]$src,[string]$dst){
    if(Test-Path -LiteralPath $dst){throw 'DESTINATION_EXISTS'}
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))|Out-Null
    $tmp=$dst+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        if([IO.File]::Exists($src)){[IO.File]::Copy($src,$tmp,$false)}else{Copy-Item -LiteralPath $src -Destination $tmp -Recurse -Force}
        if((HashPath $src)-ne(HashPath $tmp)){throw 'COPY_VALIDATION_FAILED'}
        if([IO.File]::Exists($src)){[IO.File]::Move($tmp,$dst)}else{[IO.Directory]::Move($tmp,$dst)}
        $script:created.Add($dst)|Out-Null
    }finally{
        if([IO.File]::Exists($tmp)){[IO.File]::Delete($tmp)}elseif([IO.Directory]::Exists($tmp)){Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue}
    }
}
function ReadLedger([string]$p){if(-not[IO.File]::Exists($p)){throw 'SOURCE_LEDGER_MISSING'};try{$o=[IO.File]::ReadAllText($p,[Text.UTF8Encoding]::new($false,$true))|ConvertFrom-Json}catch{throw 'SOURCE_LEDGER_INVALID'};if($null-eq$o-or$null-eq$o.artifacts-or[int]$o.schemaVersion-notin@(1,2)){throw 'SOURCE_LEDGER_INVALID'};if([int]$o.schemaVersion-eq2-and$null-eq$o.archives){throw 'SOURCE_LEDGER_INVALID'};if([int]$o.schemaVersion-eq1){$o|Add-Member -NotePropertyName archives -NotePropertyValue @() -Force;$o.schemaVersion=2};return $o}
function WriteLedger([string]$p,$o){$tmp=$p+'.'+[guid]::NewGuid().ToString('N')+'.tmp';[IO.File]::WriteAllText($tmp,(($o|ConvertTo-Json -Depth 30)+"`n"),$Utf8NoBom);if([IO.File]::Exists($p)){[IO.File]::Replace($tmp,$p,[System.Management.Automation.Language.NullString]::Value,$true)}else{[IO.File]::Move($tmp,$p)}}

$lock=$null;$created=[Collections.Generic.List[string]]::new()
try{
    $root=Full $WorkspacePath 'ABSOLUTE_WORKSPACE_REQUIRED';NoLinks $root
    if(-not[IO.Directory]::Exists($root)){throw 'WORKSPACE_NOT_FOUND'}
    if(-not[IO.File]::Exists([IO.Path]::Combine($root,(U @(0x5DE5,0x4F5C,0x533A))+'.yaml'))){throw 'WORKSPACE_NOT_INITIALIZED'}
    $source=Full $SourcePath 'ABSOLUTE_SOURCE_REQUIRED';NoLinks $source;if(-not(Test-Path -LiteralPath $source)){throw 'SOURCE_NOT_FOUND'};NoTreeLinks $source
    if($source-match'(^|[\\/])\.private([\\/]|$)'){throw 'PRIVATE_SOURCE_FORBIDDEN'}
    . ([IO.Path]::Combine($PSScriptRoot,'workspace-layout.ps1'));$layout=Get-WorkspaceLayout $root
    $humanRoot=[IO.Path]::Combine($root,$layout.Human);$machineRoot=[IO.Path]::Combine($root,$layout.Machine)
    $inboxRoot=[IO.Path]::Combine($root,$layout.Inbox)
    if($MoveInboxSource-and(-not$source.StartsWith($inboxRoot+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'INBOX_SOURCE_REQUIRED'}
    $destination=Within $DestinationRelativePath
    if(-not($destination-eq$humanRoot-or$destination.StartsWith($humanRoot+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'HUMAN_DESTINATION_REQUIRED'}
    if($Mode-eq'ArchiveOnly'-and($ProcessedPaths.Count-or$ArtifactRelativePaths.Count-or$ArtifactKind-or$ProcessingMethod-or$PSBoundParameters.ContainsKey('QualityStatus')-or$QualityIssues.Count)){throw 'ARCHIVE_ONLY_HAS_PROCESSING_METADATA'}
    if($Mode-eq'ReadableSource'-and($ProcessedPaths.Count-or$ArtifactRelativePaths.Count)){throw 'READABLE_SOURCE_HAS_OUTPUTS'}
    if($Mode-eq'Processed'-and($ProcessedPaths.Count-eq0-or$ProcessedPaths.Count-ne$ArtifactRelativePaths.Count)){throw 'PROCESSED_OUTPUTS_REQUIRED'}
    if($Mode-ne'ArchiveOnly'-and[string]::IsNullOrWhiteSpace($ArtifactKind)){throw 'ARTIFACT_KIND_REQUIRED'}
    if($QualityStatus-eq'Doubtful'-and$QualityIssues.Count-eq0){throw 'QUALITY_ISSUES_REQUIRED'};if($QualityStatus-eq'Pass'-and$QualityIssues.Count){throw 'QUALITY_STATUS_CONFLICT'}
    $ledgerPath=[IO.Path]::Combine($machineRoot,'_'+(U @(0x6765,0x6E90))+'.json');$lockPath=[IO.Path]::Combine($root,'.archive-document.lock');NoLinks $lockPath
    $lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $sourceHash=HashPath $source;$ledger=ReadLedger $ledgerPath
    $archiveRelative=Rel $destination
    $prior=@($ledger.archives|Where-Object{$_.sourcePath-eq$source-and$_.archivedPath-eq$archiveRelative-and$_.sha256-eq$sourceHash-and$_.mode-eq$Mode})
    if($prior.Count-gt1){throw 'ARCHIVE_RECORD_NOT_UNIQUE'}
    $retry=$prior.Count-eq1-and(Test-Path -LiteralPath $destination)-and((HashPath $destination)-eq$sourceHash)
    if($prior.Count-eq1-and-not$retry){throw 'ARCHIVE_RECORD_CONFLICT'}
    $reuse=$false
    if(-not$retry-and$Mode-eq'ArchiveOnly'-and(Test-Path -LiteralPath $destination)-and((HashPath $destination)-eq$sourceHash)){
        $reuse=@($ledger.archives|Where-Object{$_.archivedPath-eq$archiveRelative-and$_.sha256-eq$sourceHash}).Count-gt0
    }
    if(-not$retry-and-not$reuse-and$source-ne$destination){CopyNew $source $destination}elseif(-not(Test-Path -LiteralPath $destination)){throw 'SOURCE_NOT_FOUND'}
    $artifactPaths=@()
    if($Mode-eq'ReadableSource'){$artifactPaths=@((Rel $destination))}
    elseif($Mode-eq'Processed'){for($i=0;$i-lt$ProcessedPaths.Count;$i++){$p=Full $ProcessedPaths[$i] 'ABSOLUTE_PROCESSED_PATH_REQUIRED';NoLinks $p;if(-not[IO.File]::Exists($p)){throw 'PROCESSED_FILE_REQUIRED'};$a=Within $ArtifactRelativePaths[$i];if(-not$a.StartsWith($machineRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'MACHINE_DESTINATION_REQUIRED'};if($retry){if(-not[IO.File]::Exists($a)-or(HashPath $a)-ne(HashPath $p)){throw 'ARCHIVE_RECORD_CONFLICT'}}else{CopyNew $p $a};$artifactPaths+=Rel $a}}
    if($Mode-ne'ArchiveOnly'-and-not$retry){
        $entries=@($ledger.artifacts)
        foreach($path in $artifactPaths){if(@($entries|Where-Object{$_.paths-contains$path}).Count){throw 'ARTIFACT_ALREADY_RECORDED'}}
        if($SupersedesArtifact){$old=@($entries|Where-Object{$_.paths-contains$SupersedesArtifact});if($old.Count-ne1-or$RelationType-ne'Replacement'-or[string]::IsNullOrWhiteSpace($SupersessionEvidence)){throw 'INVALID_REPLACEMENT'};$old[0].versionStatus='Historical';$old[0]|Add-Member supersededBy $artifactPaths[0] -Force}
        $record=[ordered]@{kind=$ArtifactKind;paths=@($artifactPaths);source=[ordered]@{path=(Rel $destination);sha256=$sourceHash};readScope=$ReadScope;createdAt=[DateTime]::Now.ToString('s');versionStatus=$VersionStatus}
        if($ProcessingMethod){$record.processingMethod=$ProcessingMethod};if($PSBoundParameters.ContainsKey('QualityStatus')){$record.quality=$QualityStatus};if($QualityIssues.Count){$record.qualityIssues=@($QualityIssues)}
        if($VersionLabel){$record.versionLabel=$VersionLabel};if($RelationType){$record.relationType=$RelationType};if($RelatedArtifact){$record.relatedArtifact=$RelatedArtifact};if($SupersessionEvidence){$record.supersessionEvidence=$SupersessionEvidence}
        $ledger.artifacts=@($entries+$record)
    }
    if(-not$retry){
        $disposition=if($MoveInboxSource){'pendingMove'}elseif($source-eq$destination){'alreadyArchived'}else{'copied'}
        $archive=[ordered]@{sourcePath=$source;archivedPath=$archiveRelative;sha256=$sourceHash;mode=$Mode;archivedAt=[DateTime]::Now.ToString('s');sourceDisposition=$disposition}
        $ledger.archives=@(@($ledger.archives)+$archive)
        WriteLedger $ledgerPath $ledger
    }
    $created.Clear()
    $disposition=if($retry){$prior[0].sourceDisposition}else{$disposition}
    if($MoveInboxSource-and$disposition-ne'moved'){
        try{
            if([IO.File]::Exists($source)){[IO.File]::Delete($source)}else{Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction Stop}
            $disposition='moved'
            $entry=@($ledger.archives|Where-Object{$_.sourcePath-eq$source-and$_.archivedPath-eq$archiveRelative-and$_.sha256-eq$sourceHash})[0]
            $entry.sourceDisposition='moved';WriteLedger $ledgerPath $ledger
        }catch{
            if(-not(Test-Path -LiteralPath $source)){try{if([IO.File]::Exists($destination)){[IO.File]::Copy($destination,$source,$false)}else{Copy-Item -LiteralPath $destination -Destination $source -Recurse -Force}}catch{}}
            $disposition=if(Test-Path -LiteralPath $source){'retained'}else{'pendingMove'}
            $entry=@($ledger.archives|Where-Object{$_.sourcePath-eq$source-and$_.archivedPath-eq$archiveRelative-and$_.sha256-eq$sourceHash})[0];$entry.sourceDisposition=$disposition;try{WriteLedger $ledgerPath $ledger}catch{}
        }
    }
    Result 'archived' 'ARCHIVE_COMPLETE' ([ordered]@{source=$archiveRelative;artifacts=@($artifactPaths);ledger=(Rel $ledgerPath);sourceDisposition=$disposition})
}catch{
    for($i=$created.Count-1;$i-ge0;$i--){$p=$created[$i];if([IO.File]::Exists($p)){[IO.File]::Delete($p)}elseif([IO.Directory]::Exists($p)){Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue}}
    $code=$_.Exception.Message;if($code-notmatch'^[A-Z0-9_]+$'){$code='ARCHIVE_FAILED'};Result 'error' $code
}finally{if($null-ne$lock){$lock.Dispose()}}

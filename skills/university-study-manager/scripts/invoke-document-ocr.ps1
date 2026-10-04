#requires -Version 5.1
# Full-document rasterization and resumable MinerU orchestration. Never prints content.
[CmdletBinding()]
param([string]$ConfigPath,[string]$InputPath,[string]$OutputDirectory,
      [string]$PopplerBin,[string]$ToolsConfigPath,[switch]$UploadApproved,[switch]$Resume,
      [int]$PollIntervalSeconds=5,[int]$WaitTimeoutSeconds=600,[int]$RequestTimeoutSeconds=120)
$studyOcrInvocationArguments=@{} + $PSBoundParameters
. ([IO.Path]::Combine($PSScriptRoot,'pdf-tools.ps1'))

function Read-StudyJson {
    param([string]$Path)
    $safe=Get-MineruLocalPath $Path
    if (![IO.File]::Exists($safe)) {Stop-Mineru 'DOCUMENT_STATE_MISSING'}
    if ((Get-Item -LiteralPath $safe).Length -gt 16777216) {Stop-Mineru 'DOCUMENT_STATE_INVALID'}
    try {return ([IO.File]::ReadAllText($safe,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json)} catch {Stop-Mineru 'DOCUMENT_STATE_INVALID'}
}

function Assert-StudyManifest {
    param([string]$Prepared,$Manifest)
    if ($Manifest.version -ne 1 -or $Manifest.source_page_count -lt 1 -or
        $Manifest.max_chunk_pages -lt 1 -or $Manifest.max_chunk_pages -gt 100 -or
        $Manifest.max_chunk_bytes -lt 16384 -or $Manifest.max_chunk_bytes -gt 180000000) {Stop-Mineru 'DOCUMENT_MANIFEST_INVALID'}
    $nextPage=1;$number=0
    foreach($part in @($Manifest.parts)) {
        $number++;$expected='parts/part-{0:D4}.pdf' -f $number
        if ($part.file -cne $expected -or $part.first_page -ne $nextPage -or
            $part.page_count -ne ($part.last_page-$part.first_page+1) -or
            $part.page_count -lt 1 -or $part.page_count -gt $Manifest.max_chunk_pages) {Stop-Mineru 'DOCUMENT_MANIFEST_INVALID'}
        $path=Get-MineruLocalPath ([IO.Path]::Combine($Prepared,$expected))
        if (![IO.File]::Exists($path)) {Stop-Mineru 'PREPARED_PART_MISSING'}
        $size=(Get-Item -LiteralPath $path).Length
        if ($size -ne $part.size_bytes -or $size -gt $Manifest.max_chunk_bytes -or
            (Get-StudyHash $path) -cne $part.sha256) {Stop-Mineru 'PREPARED_PART_CHANGED'}
        $nextPage=$part.last_page+1
    }
    if ($number -lt 1 -or $nextPage -ne $Manifest.source_page_count+1) {Stop-Mineru 'DOCUMENT_MANIFEST_INVALID'}
}

function Convert-StudyLinks {
    param([string]$Body,[string]$PartName)
    # MinerU inline Markdown images, reference destinations, and HTML table images.
    # Fenced code stays verbatim. No link is opened or image rendered here.
    $lines=[regex]::Split($Body,'\r?\n');$fence='';$fenceLength=0
    $definitions=@{}
    foreach($line in $lines) {
        if ($line -match '^ {0,3}(`{3,}|~{3,})') {
            $marker=$Matches[1]
            if (!$fence) {$fence=$marker.Substring(0,1);$fenceLength=$marker.Length}
            elseif ($marker.StartsWith($fence) -and $marker.Length -ge $fenceLength) {$fence=''}
            continue
        }
        if (!$fence -and $line -match '^ {0,3}\[([^\]]+)\]:') {$definitions[$Matches[1]]=$true}
    }
    $fence='';$output=[Collections.Generic.List[string]]::new()
    foreach($line in $lines) {
        if ($line -match '^ {0,3}(`{3,}|~{3,})') {
            $marker=$Matches[1]
            if (!$fence) {$fence=$marker.Substring(0,1);$fenceLength=$marker.Length}
            elseif ($marker.StartsWith($fence) -and $marker.Length -ge $fenceLength) {$fence=''}
            $output.Add($line);continue
        }
        if ($fence) {$output.Add($line);continue}
        # Isolate inline code as well as fenced code from link edits.
        $segments=[regex]::Split($line,'(`+[^`]*`+)')
        for($i=0;$i -lt $segments.Length;$i+=2) {
            $piece=$segments[$i]
            $pattern='(?i)(\]\(\s*<?|\b(?:src|href)\s*=\s*["'']|^\s{0,3}\[[^\]]+\]:\s*<?)(?:\./)?images/'
            $piece=[regex]::Replace($piece,$pattern,([Text.RegularExpressions.MatchEvaluator]{param($m) $m.Groups[1].Value+$PartName+'/images/'}))
            foreach($label in @($definitions.Keys)) {
                $escaped=[regex]::Escape($label)
                $replacement='['+$PartName+'-'+$label+']'
                $piece=[regex]::Replace($piece,'(?i)(^ {0,3})\['+$escaped+'\](?=:)',([Text.RegularExpressions.MatchEvaluator]{param($m) $m.Groups[1].Value+$replacement}))
                $piece=[regex]::Replace($piece,'(?i)(?<=\])\['+$escaped+'\]',([Text.RegularExpressions.MatchEvaluator]{param($m) $replacement}))
                $piece=[regex]::Replace($piece,'(?i)(\['+$escaped+'\])\[\]',([Text.RegularExpressions.MatchEvaluator]{param($m) $m.Groups[1].Value+$replacement}))
                $piece=[regex]::Replace($piece,'(?i)(?<!\])\['+$escaped+'\](?![:(\[])',([Text.RegularExpressions.MatchEvaluator]{param($m) $m.Value+$replacement}))
            }
            $segments[$i]=$piece
        }
        $output.Add(($segments -join ''))
    }
    return ($output -join "`n")
}

function Merge-StudyResults {
    param([string]$Root,$Manifest)
    $destination=Get-MineruLocalPath ([IO.Path]::Combine($Root,'result'))
    if (Test-Path -LiteralPath $destination) {Stop-Mineru 'MERGED_RESULT_EXISTS_REVIEW_REQUIRED'}
    $staging=[IO.Path]::Combine($Root,'.merge-'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging)|Out-Null
    $writer=[IO.StreamWriter]::new([IO.Path]::Combine($staging,'full.md'),$false,[Text.UTF8Encoding]::new($false))
    try {
        foreach($part in @($Manifest.parts)) {
            $name=[IO.Path]::GetFileNameWithoutExtension($part.file)
            $partResult=Get-MineruLocalPath ([IO.Path]::Combine($Root,'ocr',$name,'result'))
            $md=Get-MineruLocalPath ([IO.Path]::Combine($partResult,'full.md'))
            if (![IO.File]::Exists($md) -or (Get-Item -LiteralPath $md).Length -gt 67108864) {Stop-Mineru 'PART_MARKDOWN_MISSING_OR_TOO_LARGE'}
            $body=[IO.File]::ReadAllText($md,[Text.UTF8Encoding]::new($false,$true))
            $writer.WriteLine(('<!-- Processing metadata: source PDF pages {0}-{1}; {2}. Not original document text. -->' -f $part.first_page,$part.last_page,$name))
            $writer.WriteLine();$writer.WriteLine((Convert-StudyLinks $body $name));$writer.WriteLine()
            $body=$null
            $images=Get-MineruLocalPath ([IO.Path]::Combine($partResult,'images'))
            if ([IO.Directory]::Exists($images)) {
                # Validate every node before descending, rather than following junctions.
                $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($images)
                while($queue.Count -gt 0) {
                    $dir=$queue.Dequeue()
                    foreach($entry in Get-ChildItem -LiteralPath $dir -Force) {
                        $safe=Get-MineruLocalPath $entry.FullName
                        if ($entry.PSIsContainer) {$queue.Enqueue($safe);continue}
                        if ($entry.Extension.ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp','.gif','.bmp','.jp2')) {Stop-Mineru 'UNEXPECTED_RESULT_ASSET'}
                        $relative=$safe.Substring($partResult.Length).TrimStart([char[]]'\/')
                        $target=[IO.Path]::Combine($staging,$name,$relative)
                        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
                        [IO.File]::Copy($safe,$target,$false)
                    }
                }
            }
        }
    } finally {$writer.Dispose()}
    [IO.Directory]::Move($staging,$destination)
    return [IO.Path]::Combine($destination,'full.md')
}

function New-StudyOcrQualityReport {
    param([string]$MarkdownPath,$Manifest,[string]$ReportPath,[string]$Method='mineru-forced-ocr-on-rasterized-pdf')
    $body=[IO.File]::ReadAllText($MarkdownPath,[Text.UTF8Encoding]::new($false,$true))
    $nonWhitespace=[regex]::Replace($body,'\s','').Length
    $replacement=[regex]::Matches($body,[string][char]0xFFFD).Count
    $private=[regex]::Matches($body,'[\uE000-\uF8FF]').Count
    $control=0
    foreach($character in $body.ToCharArray()) {
        if ([char]::IsControl($character) -and $character -notin @([char]9,[char]10,[char]13)) {$control++}
    }
    $lowerDpi=@()
    if ($Manifest.PSObject.Properties.Name -contains 'lower_dpi_pages') {$lowerDpi=@($Manifest.lower_dpi_pages)}
    $issues=[Collections.Generic.List[string]]::new()
    if($nonWhitespace -lt [math]::Max(200,$Manifest.source_page_count*20)){$issues.Add('SUSPICIOUSLY_LITTLE_OCR_TEXT')}
    if($replacement+$private+$control -gt 0){$issues.Add('SUSPECT_OCR_CHARACTERS')}
    if($lowerDpi.Count -gt 0){$issues.Add('SOME_PAGES_RASTERIZED_BELOW_PREFERRED_DPI')}
    if(@($Manifest.parts).Count -gt 1){$issues.Add('CROSS_PART_BOUNDARIES_REQUIRE_REVIEW')}
    $status=if($nonWhitespace -eq 0){'failed'}elseif($issues.Count -gt 0){'warning'}else{'pass'}
    $report=[ordered]@{
        version=1;method=$Method;status=$status
        source_page_count=$Manifest.source_page_count;part_count=@($Manifest.parts).Count
        non_whitespace_characters=$nonWhitespace;replacement_characters=$replacement
        unexpected_controls=$control;private_use_characters=$private;lower_dpi_pages=$lowerDpi
        issues=@($issues.ToArray())
        required_review=@('Read the complete result in bounded UTF-8 segments.','Compare critical numbers, dates, formulas, eligibility conditions, and complex tables with rendered source pages.','Report poor quality in a separate prominent document-quality warning; do not register a critically damaged result as formally usable.')
        note='Automated checks detect symptoms only and cannot certify OCR, table, formula, semantic, or applicability accuracy.'
    }
    [IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    $body=$null
    return $report
}

function Invoke-StudyDocumentOcr {
    [CmdletBinding()]
    param([string]$ConfigPath,[string]$InputPath,[string]$OutputDirectory,
          [string]$PopplerBin,[string]$ToolsConfigPath,[switch]$UploadApproved,[switch]$Resume,
          [int]$PollIntervalSeconds=5,[int]$WaitTimeoutSeconds=600,[int]$RequestTimeoutSeconds=120)
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$lock=$null;$stage='preflight'
    $result=[ordered]@{status='error';code='DOCUMENT_PROCESSING_FAILED';stage=$stage}
    try {
        $root=Get-MineruLocalPath $OutputDirectory
        $jobPath=Get-MineruLocalPath ([IO.Path]::Combine($root,'document-job.json'))
        $prepared=Get-MineruLocalPath ([IO.Path]::Combine($root,'prepared'))
        $manifestPath=Get-MineruLocalPath ([IO.Path]::Combine($prepared,'prepare-manifest.json'))
        if ($Resume -and ($InputPath -or $PopplerBin -or $ToolsConfigPath)) {Stop-Mineru 'RESUME_OPTIONS_NOT_ALLOWED'}
        if ($PollIntervalSeconds -lt 1 -or $PollIntervalSeconds -gt 60 -or $WaitTimeoutSeconds -lt 1 -or $WaitTimeoutSeconds -gt 7200 -or $RequestTimeoutSeconds -lt 1 -or $RequestTimeoutSeconds -gt 600) {Stop-Mineru 'INVALID_TIMEOUT'}
        if (!$Resume) {
            if (!$UploadApproved) {Stop-Mineru 'UPLOAD_APPROVAL_REQUIRED'}
            if (Test-Path -LiteralPath $root) {Stop-Mineru 'OUTPUT_ALREADY_EXISTS'}
        } elseif (![IO.Directory]::Exists($root)) {Stop-Mineru 'DOCUMENT_STATE_MISSING'}
        # Images use the native client's durable job and upload their original bytes.
        # Two state formats in one root are ambiguous and must never select a route.
        $nativeJob=Get-MineruLocalPath ([IO.Path]::Combine($root,'.mineru-job.json'))
        $imageRoute=(!$Resume -and [IO.Path]::GetExtension($InputPath).ToLowerInvariant() -in @('.png','.jpg','.jpeg'))
        if ($Resume -and [IO.File]::Exists($nativeJob)) {
            if ([IO.File]::Exists($jobPath)) {Stop-Mineru 'AMBIGUOUS_DOCUMENT_STATE'}
            $nativeState=Read-StudyJson $nativeJob
            if ((Get-MineruProperty $nativeState 'upload_name') -notmatch '^document\.(png|jpg|jpeg)$') {Stop-Mineru 'DOCUMENT_STATE_INVALID'}
            $imageRoute=$true
        }
        if ($imageRoute) {
            $stage='image-service'
            $imageArgs=@{ConfigPath=$ConfigPath;OutputDirectory=$root;PollIntervalSeconds=$PollIntervalSeconds;WaitTimeoutSeconds=$WaitTimeoutSeconds;RequestTimeoutSeconds=$RequestTimeoutSeconds}
            if ($Resume) {$imageArgs['Resume']=$true}
            else {$imageArgs['InputPath']=$InputPath;$imageArgs['ForceOcr']=$true;$imageArgs['UploadApproved']=$true}
            $imageAnswer=Invoke-MineruOcr @imageArgs
            if ($imageAnswer.status -ne 'done') {if($null-eq(Get-MineruProperty $imageAnswer 'stage')){$imageAnswer|Add-Member -NotePropertyName stage -NotePropertyValue $stage};return $imageAnswer}
            $stage='image-result'
            $imageMarkdown=Get-MineruLocalPath $imageAnswer.markdown_path
            $imageQualityPath=Get-MineruLocalPath ([IO.Path]::Combine($root,'result','quality-report.json'))
            if ([IO.File]::Exists($imageQualityPath)) {$imageQuality=Read-StudyJson $imageQualityPath}
            else {
                $imageManifest=[pscustomobject]@{source_page_count=1;parts=@([pscustomobject]@{file='document-image'});lower_dpi_pages=@()}
                $imageQuality=New-StudyOcrQualityReport $imageMarkdown $imageManifest $imageQualityPath 'mineru-forced-ocr-on-original-image'
            }
            $imageResult=[ordered]@{status='done';code=$imageAnswer.code;stage='complete';markdown_path=$imageMarkdown;quality_report_path=$imageQualityPath;quality_status=$imageQuality.status;quality_issues=@($imageQuality.issues);review_required=$true}
            $assetCount=Get-MineruProperty $imageAnswer 'asset_count';if($null-eq$assetCount){$assetCount=Get-MineruProperty $imageAnswer 'image_count'};if($null-ne$assetCount){$imageResult.asset_count=$assetCount}
            return $imageResult
        }
        # Local key validation before rasterization, with no credential sent to the model.
        $config=Get-MineruLocalPath $ConfigPath
        $null=Read-MineruToken $config
        if (!$Resume) {
            [IO.Directory]::CreateDirectory($root)|Out-Null
        }
        $lockPath=Get-MineruLocalPath ([IO.Path]::Combine($root,'.document-lock'))
        try {$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)} catch {Stop-Mineru 'DOCUMENT_BUSY'}
        $result['output_directory']=$root
        if ($Resume) {
            $stage='resume-state'
            $job=Read-StudyJson $jobPath
            if ($job.version -ne 1 -or $job.phase -notin @('prepared','complete')) {Stop-Mineru 'DOCUMENT_STATE_INVALID'}
            if ($job.phase -eq 'complete') {
                $md=Get-MineruLocalPath ([IO.Path]::Combine($root,'result','full.md'))
                if (![IO.File]::Exists($md)) {Stop-Mineru 'COMPLETED_OUTPUT_MISSING'}
                $qualityPath=Get-MineruLocalPath ([IO.Path]::Combine($root,'result','quality-report.json'))
                if (![IO.File]::Exists($qualityPath)) {Stop-Mineru 'COMPLETED_QUALITY_REPORT_MISSING'}
                $quality=Read-StudyJson $qualityPath
                return [ordered]@{status='done';code='ALREADY_MERGED';stage='complete';markdown_path=$md;quality_report_path=$qualityPath;quality_status=$quality.status;quality_issues=@($quality.issues);review_required=$true}
            }
        } else {
            $stage='local-rasterization'
            $prepare=Invoke-StudyPdf -Mode Rasterize -InputPath $InputPath -OutputDirectory $prepared -PopplerBin $PopplerBin -ToolsConfigPath $ToolsConfigPath
            if ($prepare.status -ne 'prepared') {return $prepare}
            $job=[pscustomobject]@{version=1;phase='prepared';manifest_sha256=(Get-StudyHash $manifestPath)}
            Save-MineruJob $jobPath $job
        }
        if ((Get-StudyHash $manifestPath) -cne $job.manifest_sha256) {Stop-Mineru 'DOCUMENT_MANIFEST_CHANGED'}
        $manifest=Read-StudyJson $manifestPath
        Assert-StudyManifest $prepared $manifest
        if (Test-Path -LiteralPath ([IO.Path]::Combine($root,'result'))) {Stop-Mineru 'MERGED_RESULT_EXISTS_REVIEW_REQUIRED'}
        $number=0
        foreach($part in @($manifest.parts)) {
            $stage='part-service'
            $number++;$name=[IO.Path]::GetFileNameWithoutExtension($part.file)
            $partOut=Get-MineruLocalPath ([IO.Path]::Combine($root,'ocr',$name))
            $args=@{ConfigPath=$config;OutputDirectory=$partOut;PollIntervalSeconds=$PollIntervalSeconds;WaitTimeoutSeconds=$WaitTimeoutSeconds;RequestTimeoutSeconds=$RequestTimeoutSeconds}
            if (Test-Path -LiteralPath $partOut) {
                if (![IO.File]::Exists((Get-MineruLocalPath ([IO.Path]::Combine($partOut,'.mineru-job.json'))))) {Stop-Mineru 'PART_STATE_MISSING_REVIEW_REQUIRED'}
                $args['Resume']=$true
            } else {
                if (!$UploadApproved) {Stop-Mineru 'UPLOAD_APPROVAL_REQUIRED_FOR_REMAINING_PARTS'}
                $args['InputPath']=Get-MineruLocalPath ([IO.Path]::Combine($prepared,$part.file))
                $args['ForceOcr']=$true;$args['UploadApproved']=$true
            }
            $answer=Invoke-MineruOcr @args
            if ($answer.status -ne 'done') {
                return [ordered]@{status=$answer.status;code=$answer.code;stage=$stage;part_number=$number;part_count=@($manifest.parts).Count;output_directory=$root;resume_available=$true}
            }
        }
        $stage='local-merge'
        $md=Merge-StudyResults $root $manifest
        $qualityPath=Get-MineruLocalPath ([IO.Path]::Combine($root,'result','quality-report.json'))
        $quality=New-StudyOcrQualityReport $md $manifest $qualityPath
        $job.phase='complete';Save-MineruJob $jobPath $job
        return [ordered]@{status='done';code='FULL_DOCUMENT_MERGED';stage='complete';markdown_path=$md;quality_report_path=$qualityPath;quality_status=$quality.status;quality_issues=@($quality.issues);page_count=$manifest.source_page_count;part_count=@($manifest.parts).Count;review_required=$true}
    } catch {
        $exception=$_.Exception
        while($null -ne $exception.InnerException -and !$exception.Data.Contains('mineru_code')){$exception=$exception.InnerException}
        if($exception.Data.Contains('mineru_code')){$result.code=$exception.Data['mineru_code']};$result.stage=$stage
        return $result
    } finally {if($null -ne $lock){$lock.Dispose()}}
}

if($MyInvocation.InvocationName -ne '.') {
    $answer=Invoke-StudyDocumentOcr @studyOcrInvocationArguments
    $answer | ConvertTo-Json -Depth 6 -Compress | Write-Output
    if($answer.status -eq 'error'){exit 1};if($answer.status -eq 'pending'){exit 2};exit 0
}

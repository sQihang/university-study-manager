#requires -Version 5.1
# Local Poppler wrapper. No installation, document text or raw tool logs on stdout.
[CmdletBinding()]
param([string]$Mode='Check',[ValidateSet('All','Extract','Rasterize')][string]$Capability='All',[string]$InputPath,[string]$OutputDirectory,
      [string]$PopplerBin,[string]$ToolsConfigPath,[int]$MaxChunkPages=100,
      [long]$MaxChunkBytes=180000000,[int]$ToolTimeoutSeconds=120)
$studyPdfInvocationArguments = @{} + $PSBoundParameters
. ([IO.Path]::Combine($PSScriptRoot,'mineru-ocr.ps1'))
$script:StudyPdfScriptDirectory = $PSScriptRoot

function Get-StudyHash {
    param([string]$Path)
    $hash=[Security.Cryptography.SHA256]::Create()
    $stream=[IO.File]::OpenRead($Path)
    try {return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','').ToLowerInvariant()}
    finally {$stream.Dispose();$hash.Dispose()}
}

function Quote-StudyArgument {
    param([string]$Value)
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-StudyProcess {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$Executable
    $start.Arguments=($Arguments | ForEach-Object { Quote-StudyArgument $_ }) -join ' '
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8
    $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    $start.EnvironmentVariables['LC_ALL']='C'
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        try {$null=$process.Start()} catch {Stop-Mineru 'LOCAL_TOOL_START_FAILED'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds*1000)) {
            try {$process.Kill();$process.WaitForExit()} catch {}
            Stop-Mineru 'LOCAL_TOOL_TIMEOUT'
        }
        $rawOut=$stdout.GetAwaiter().GetResult();$rawError=$stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {Stop-Mineru 'LOCAL_TOOL_FAILED'}
        $rawError=$null
        return $rawOut
    } finally {$process.Dispose()}
}

function Resolve-StudyPoppler {
    param([string]$Bin,[string]$Config,[string]$Capability='All')
    if (!$Bin -and $Config) {
        $path=Get-MineruLocalPath $Config
        if (![IO.File]::Exists($path)) {Stop-Mineru 'TOOLS_CONFIG_NOT_FOUND'}
        if ((Get-Item -LiteralPath $path).Length -gt 16384) {Stop-Mineru 'TOOLS_CONFIG_INVALID'}
        try {$settings=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true)) | ConvertFrom-Json} catch {Stop-Mineru 'TOOLS_CONFIG_INVALID'}
        $Bin=Get-MineruProperty $settings 'poppler_bin'
        if (!$Bin) {Stop-Mineru 'TOOLS_CONFIG_INVALID'}
    }
    $paths=@{}
    $required=@('pdfinfo','pdftotext','pdftoppm')
    if ($Capability -eq 'Extract') {$required=@('pdfinfo','pdftotext')}
    if ($Capability -eq 'Rasterize') {$required=@('pdfinfo','pdftoppm')}
    foreach ($name in $required) {
        if ($Bin) {$candidate=[IO.Path]::Combine((Get-MineruLocalPath $Bin),$name+'.exe')}
        else {
            $command=Get-Command ($name+'.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -eq $command) {Stop-Mineru ('POPPLER_MISSING_'+$name.ToUpperInvariant())}
            $candidate=$command.Source
        }
        $candidate=Get-MineruLocalPath $candidate
        if (![IO.File]::Exists($candidate)) {Stop-Mineru ('POPPLER_MISSING_'+$name.ToUpperInvariant())}
        $paths[$name]=$candidate
    }
    return $paths
}

function Get-StudyPdfInfo {
    param([string]$InputFile,$Tools,[int]$TimeoutSeconds)
    $raw=Invoke-StudyProcess $Tools.pdfinfo @($InputFile) $TimeoutSeconds
    if ($raw -match '(?m)^Encrypted:\s+yes') {Stop-Mineru 'ENCRYPTED_PDF_REQUIRES_LOCAL_EXPORT'}
    if ($raw -notmatch '(?m)^Pages:\s+(\d+)\s*$') {Stop-Mineru 'PDF_INFO_INVALID'}
    $count=[int]$Matches[1]
    if ($count -le 0) {Stop-Mineru 'PDF_HAS_NO_PAGES'}
    $raw=Invoke-StudyProcess $Tools.pdfinfo @('-f','1','-l',[string]$count,$InputFile) $TimeoutSeconds
    $dimensions=@{}
    foreach ($match in [regex]::Matches($raw,'(?m)^Page\s+(\d+)\s+size:\s+([0-9.]+)\s+x\s+([0-9.]+)\s+pts')) {
        $w=[double]::Parse($match.Groups[2].Value,[Globalization.CultureInfo]::InvariantCulture)
        $h=[double]::Parse($match.Groups[3].Value,[Globalization.CultureInfo]::InvariantCulture)
        $dimensions[[int]$match.Groups[1].Value]=@($w,$h)
    }
    if ($dimensions.Count -ne $count) {Stop-Mineru 'PDF_PAGE_SIZES_UNAVAILABLE'}
    return @{page_count=$count;dimensions=$dimensions}
}

function Complete-StudyPart {
    param($Writer,[string]$Path,[int]$FirstPage,[int]$LastPage,$PageProfiles,$Tools,[int]$Timeout,[long]$Limit)
    $Writer.Finish();$Writer.Dispose()
    $size=(Get-Item -LiteralPath $Path).Length
    if ($size -gt $Limit) {Stop-Mineru 'GENERATED_PART_TOO_LARGE'}
    $info=Get-StudyPdfInfo $Path $Tools $Timeout
    if ($info.page_count -ne ($LastPage-$FirstPage+1)) {Stop-Mineru 'GENERATED_PAGE_COUNT_MISMATCH'}
    return [pscustomobject]@{file='parts/'+[IO.Path]::GetFileName($Path);first_page=$FirstPage;last_page=$LastPage;page_count=$info.page_count;size_bytes=$size;sha256=(Get-StudyHash $Path);pages=@($PageProfiles.ToArray())}
}

function New-StudyTextQualityReport {
    param([string]$Text,[int]$ExpectedPages,[string]$ReportPath,[string]$Method='pdftotext-layout')
    $pageBodies=$Text.Split([char]12)
    $pages=[Collections.Generic.List[object]]::new()
    $empty=[Collections.Generic.List[int]]::new()
    $suspect=[Collections.Generic.List[int]]::new()
    $tableReview=[Collections.Generic.List[int]]::new()
    $replacementTotal=0;$controlTotal=0;$privateTotal=0
    for($i=0;$i -lt $ExpectedPages;$i++) {
        $body=if($i -lt $pageBodies.Count){$pageBodies[$i]}else{''}
        $nonWhitespace=[regex]::Replace($body,'\s','').Length
        $lettersAndNumbers=[regex]::Matches($body,'[\p{L}\p{N}]').Count
        $replacement=[regex]::Matches($body,[string][char]0xFFFD).Count
        $private=[regex]::Matches($body,'[\uE000-\uF8FF]').Count
        $control=0
        foreach($character in $body.ToCharArray()) {
            if ([char]::IsControl($character) -and $character -notin @([char]9,[char]10,[char]12,[char]13)) {$control++}
        }
        $alignedLines=[regex]::Matches($body,'(?m)^.*\S\s{2,}\S.*$').Count
        $ratio=if($nonWhitespace -gt 0){[math]::Round($lettersAndNumbers/$nonWhitespace,4)}else{0}
        $isEmpty=$nonWhitespace -eq 0
        $isSuspect=($replacement+$private+$control -gt 0) -or ($nonWhitespace -ge 40 -and $ratio -lt 0.30)
        if($isEmpty){$empty.Add($i+1)}
        if($isSuspect){$suspect.Add($i+1)}
        if($alignedLines -ge 3){$tableReview.Add($i+1)}
        $replacementTotal+=$replacement;$controlTotal+=$control;$privateTotal+=$private
        $pages.Add([pscustomobject]@{page=$i+1;non_whitespace_characters=$nonWhitespace;letter_number_ratio=$ratio;replacement_characters=$replacement;unexpected_controls=$control;private_use_characters=$private;aligned_layout_lines=$alignedLines})
    }
    $issues=[Collections.Generic.List[string]]::new()
    if($empty.Count -eq $ExpectedPages){$issues.Add('NO_TEXT_LAYER_DETECTED')}
    elseif($empty.Count -gt 0){$issues.Add('EMPTY_TEXT_PAGES')}
    if($suspect.Count -gt 0){$issues.Add('SUSPECT_TEXT_ENCODING_OR_GLYPHS')}
    if($tableReview.Count -gt 0){$issues.Add('LAYOUT_OR_TABLE_REQUIRES_VISUAL_REVIEW')}
    $status=if($empty.Count -eq $ExpectedPages){'failed'}elseif($issues.Count -gt 0){'warning'}else{'pass'}
    $report=[ordered]@{
        version=1;method=$Method;status=$status;expected_page_count=$ExpectedPages
        empty_pages=@($empty.ToArray());suspect_pages=@($suspect.ToArray());layout_review_pages=@($tableReview.ToArray())
        replacement_characters=$replacementTotal;unexpected_controls=$controlTotal;private_use_characters=$privateTotal
        issues=@($issues.ToArray());pages=@($pages.ToArray())
        note='This report detects extraction symptoms only. It does not prove semantic, numeric, table, or page-order accuracy.'
    }
    [IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    return $report
}

function Invoke-StudyPdf {
    [CmdletBinding()]
    param([string]$Mode='Check',[ValidateSet('All','Extract','Rasterize')][string]$Capability='All',[string]$InputPath,[string]$OutputDirectory,
          [string]$PopplerBin,[string]$ToolsConfigPath,[int]$MaxChunkPages=100,
          [long]$MaxChunkBytes=180000000,[int]$ToolTimeoutSeconds=120)
    Set-StrictMode -Version Latest
    $ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
    $writer=$null;$directoryLock=$null;$result=[ordered]@{status='error';code='LOCAL_PROCESSING_FAILED'}
    try {
        if ($Mode -notin @('Check','Configure','Extract','Rasterize')) {Stop-Mineru 'INVALID_MODE'}
        if ($ToolTimeoutSeconds -lt 1 -or $ToolTimeoutSeconds -gt 600) {Stop-Mineru 'INVALID_TIMEOUT'}
        if ($MaxChunkPages -lt 1 -or $MaxChunkPages -gt 100 -or $MaxChunkBytes -lt 16384 -or $MaxChunkBytes -gt 180000000) {Stop-Mineru 'INVALID_CHUNK_LIMIT'}
        $requiredCapability=$Capability;if ($Mode -in @('Extract','Rasterize')) {$requiredCapability=$Mode}
        $tools=Resolve-StudyPoppler $PopplerBin $ToolsConfigPath $requiredCapability
        if ($Mode -eq 'Check' -or $Mode -eq 'Configure') {
            foreach($exe in $tools.Values){$null=Invoke-StudyProcess $exe @('-v') $ToolTimeoutSeconds}
            if ($Mode -eq 'Configure') {
                if (!$PopplerBin -or !$ToolsConfigPath) {Stop-Mineru 'CONFIGURE_REQUIRES_PATHS'}
                $config=Get-MineruLocalPath $ToolsConfigPath
                if (Test-Path -LiteralPath $config) {Stop-Mineru 'TOOLS_CONFIG_ALREADY_EXISTS'}
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config)) | Out-Null
                [IO.File]::WriteAllText($config,(@{poppler_bin=[IO.Path]::GetDirectoryName($tools.pdfinfo)} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
                return [ordered]@{status='configured';code='TOOLS_CONFIG_CREATED';config_path=$config}
            }
            return [ordered]@{status='ready';code='POPPLER_READY';capability=$requiredCapability;required_tools=@($tools.Keys | Sort-Object);poppler_bin=[IO.Path]::GetDirectoryName($tools.pdfinfo)}
        }
        $source=Get-MineruLocalPath $InputPath
        if (![IO.File]::Exists($source)) {Stop-Mineru 'INPUT_NOT_FOUND'}
        if ([IO.Path]::GetExtension($source) -ine '.pdf') {Stop-Mineru 'PDF_REQUIRED_EXPORT_WORD_FIRST'}
        $out=Get-MineruLocalPath $OutputDirectory
        if (Test-Path -LiteralPath $out) {Stop-Mineru 'OUTPUT_ALREADY_EXISTS'}
        $info=Get-StudyPdfInfo $source $tools $ToolTimeoutSeconds
        $sourceHash=Get-StudyHash $source
        [IO.Directory]::CreateDirectory($out) | Out-Null
        try {$directoryLock=[IO.File]::Open([IO.Path]::Combine($out,'.pdf-lock'),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)} catch {Stop-Mineru 'OUTPUT_ALREADY_EXISTS'}
        $result['output_directory']=$out
        if ($Mode -eq 'Extract') {
            $textPath=[IO.Path]::Combine($out,'extracted.txt')
            $null=Invoke-StudyProcess $tools.pdftotext @('-layout','-enc','UTF-8',$source,$textPath) $ToolTimeoutSeconds
            $body=[IO.File]::ReadAllText($textPath,[Text.UTF8Encoding]::new($false,$true))
            $characters=$body.Length
            $qualityPath=[IO.Path]::Combine($out,'quality-report.json')
            $quality=New-StudyTextQualityReport $body $info.page_count $qualityPath
            $body=$null
            if ((Get-StudyHash $source) -ne $sourceHash) {Stop-Mineru 'SOURCE_CHANGED'}
            return [ordered]@{status='extracted';code='TEXT_EXTRACTED_NOT_VALIDATED';text_path=$textPath;quality_report_path=$qualityPath;quality_status=$quality.status;quality_issues=@($quality.issues);page_count=$info.page_count;character_count=$characters;empty_pages=@($quality.empty_pages);format='plain_text';quality_requires_review=$true}
        }
        if (!('StudyDocuments.ImagePdfWriter' -as [type])) {
            Add-Type -Path ([IO.Path]::Combine($script:StudyPdfScriptDirectory,'image-pdf-writer.cs'))
        }
        $partsDir=[IO.Path]::Combine($out,'parts');[IO.Directory]::CreateDirectory($partsDir)|Out-Null
        $parts=[Collections.Generic.List[object]]::new()
        $profiles=[Collections.Generic.List[object]]::new()
        $first=1;$partNumber=1;$partPath=[IO.Path]::Combine($partsDir,('part-{0:D4}.pdf' -f $partNumber))
        $writer=[StudyDocuments.ImagePdfWriter]::new($partPath)
        for($page=1;$page -le $info.page_count;$page++) {
            $imageRoot=[IO.Path]::Combine($out,'.render-page')
            $jpeg=$imageRoot+'.jpg'
            if (Test-Path -LiteralPath $jpeg) {Stop-Mineru 'PARTIAL_RENDER_EXISTS'}
            $accepted=$false;$selectedDpi=0
            foreach($dpi in @(400,350,300)) {
                $dims=$info.dimensions[$page]
                if (($dims[0]*$dpi/72)*($dims[1]*$dpi/72) -gt 40000000) {continue}
                $null=Invoke-StudyProcess $tools.pdftoppm @('-f',[string]$page,'-l',[string]$page,'-singlefile','-r',[string]$dpi,'-jpeg','-jpegopt','quality=95,optimize=y',$source,$imageRoot) $ToolTimeoutSeconds
                if (![IO.File]::Exists($jpeg)) {Stop-Mineru 'RASTER_IMAGE_MISSING'}
                $length=(Get-Item -LiteralPath $jpeg).Length
                if ($length+16384 -le $MaxChunkBytes) {$accepted=$true;$selectedDpi=$dpi;break}
                [IO.File]::Delete($jpeg)
            }
            if (!$accepted) {Stop-Mineru 'SINGLE_PAGE_EXCEEDS_SAFE_LIMIT'}
            if ($writer.PageCount -gt 0 -and ($writer.PageCount -ge $MaxChunkPages -or $writer.EstimatedSizeAfter($length) -gt $MaxChunkBytes)) {
                $part=Complete-StudyPart $writer $partPath $first ($page-1) $profiles $tools $ToolTimeoutSeconds $MaxChunkBytes
                $writer=$null;$parts.Add($part);$profiles.Clear();$first=$page;$partNumber++
                $partPath=[IO.Path]::Combine($partsDir,('part-{0:D4}.pdf' -f $partNumber))
                $writer=[StudyDocuments.ImagePdfWriter]::new($partPath)
            }
            $writer.AddPage($jpeg,$selectedDpi)
            $profiles.Add([pscustomobject]@{source_page=$page;dpi=$selectedDpi})
            [IO.File]::Delete($jpeg)
        }
        $part=Complete-StudyPart $writer $partPath $first $info.page_count $profiles $tools $ToolTimeoutSeconds $MaxChunkBytes
        $writer=$null;$parts.Add($part)
        if ((Get-StudyHash $source) -ne $sourceHash) {Stop-Mineru 'SOURCE_CHANGED'}
        $lowerDpiPages=@($parts | ForEach-Object {$_.pages} | Where-Object {$_.dpi -lt 400} | ForEach-Object {$_.source_page})
        $manifest=[ordered]@{version=1;source_sha256=$sourceHash;source_page_count=$info.page_count;profile='rgb-jpeg-q95-dpi400-fallback350-300';preferred_dpi=400;minimum_dpi=300;lower_dpi_pages=$lowerDpiPages;max_chunk_pages=$MaxChunkPages;max_chunk_bytes=$MaxChunkBytes;parts=@($parts.ToArray())}
        $manifestPath=[IO.Path]::Combine($out,'prepare-manifest.json')
        [IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 7),[Text.UTF8Encoding]::new($false))
        return [ordered]@{status='prepared';code='FULL_DOCUMENT_RASTERIZED';manifest_path=$manifestPath;page_count=$info.page_count;part_count=$parts.Count;lower_dpi_pages=$lowerDpiPages;quality_requires_review=($lowerDpiPages.Count -gt 0);output_directory=$out}
    } catch {
        $exception=$_.Exception
        while($null -ne $exception.InnerException -and !$exception.Data.Contains('mineru_code')){$exception=$exception.InnerException}
        if($exception.Data.Contains('mineru_code')){$result.code=$exception.Data['mineru_code']}
        if($result.code -like 'POPPLER_MISSING_*'){$result['download_url']='https://github.com/oschwartz10612/poppler-windows/releases'}
        return $result
    } finally {if($null -ne $writer){$writer.Dispose()};if($null -ne $directoryLock){$directoryLock.Dispose()}}
}

if($MyInvocation.InvocationName -ne '.') {
    $answer=Invoke-StudyPdf @studyPdfInvocationArguments
    $answer | ConvertTo-Json -Depth 6 -Compress | Write-Output
    if($answer.status -eq 'error'){exit 1};exit 0
}

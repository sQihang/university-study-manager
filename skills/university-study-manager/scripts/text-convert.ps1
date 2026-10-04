#requires -Version 5.1
# Local, bounded OOXML text conversion. ASCII source supports Windows PowerShell.
[CmdletBinding()]
param([string]$InputPath, [string]$OutputDirectory, [string]$Mode = 'auto')
$savedTextArgs = @{ InputPath=$InputPath; OutputDirectory=$OutputDirectory; Mode=$Mode }
. "$PSScriptRoot/mineru-ocr.ps1"

function Read-TextPart($Zip, [string]$Name) {
    $entry = $Zip.GetEntry($Name)
    if (!$entry) { throw 'MISSING_PART' }
    if ($entry.Length -gt 67108864) { throw 'PART_TOO_LARGE' }
    $stream = $entry.Open()
    try {
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 67108864
        $reader = [Xml.XmlReader]::Create($stream, $settings)
        try { $doc = [Xml.XmlDocument]::new(); $doc.XmlResolver=$null; $doc.Load($reader); return ,$doc } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
function Get-TextRuns($Node) {
    $b = [Text.StringBuilder]::new()
    foreach ($n in $Node.SelectNodes('.//*[local-name()="t" or local-name()="tab" or local-name()="br" or local-name()="cr"]')) {
        if ($n.LocalName -eq 't') { [void]$b.Append($n.InnerText) }
        elseif ($n.LocalName -eq 'tab') { [void]$b.Append("`t") }
        else { [void]$b.Append("`n") }
    }
    return $b.ToString()
}
function Write-TextNew([string]$Path, [string]$Content) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($Content); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
function Invoke-TextConvert {
    param([string]$InputPath, [string]$OutputDirectory, [string]$Mode='auto')
    $ErrorActionPreference='Stop'
    $zip=$null
    $paths=[Collections.Generic.List[string]]::new()
    $warnings=[Collections.Generic.HashSet[string]]::new()
    try {
        $source=Get-MineruLocalPath $InputPath
        $dest=Get-MineruLocalPath $OutputDirectory
        if (![IO.File]::Exists($source)) { throw 'INPUT_NOT_FOUND' }
        $ext=[IO.Path]::GetExtension($source).ToLowerInvariant()
        if ($Mode -notin @('auto','xlsx','docx')) { throw 'UNSUPPORTED_MODE' }
        if ($ext -notin @('.xlsx','.docx')) { throw 'SOURCE_FORMAT_REQUIRES_LOCAL_CONVERSION' }
        if ($Mode -ne 'auto' -and $ext -ne ".$Mode") { throw 'FORMAT_MODE_MISMATCH' }
        if ([IO.Directory]::Exists($dest) -or [IO.File]::Exists($dest)) { throw 'OUTPUT_ALREADY_EXISTS' }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.IO.Compression
        $zip=[IO.Compression.ZipFile]::OpenRead($source)
        if ($zip.Entries.Count -gt 10000) { throw 'PACKAGE_TOO_LARGE' }
        # Prepare all text before creating output. Numbered filenames avoid unsafe sheet names.
        $files=[ordered]@{}
        if ($ext -eq '.docx') {
            $doc=Read-TextPart $zip 'word/document.xml'
            $lines=[Collections.Generic.List[string]]::new()
            [void]$warnings.Add('DOCX_TEXT_ONLY_LAYOUT_NOT_PRESERVED')
            if ($doc.SelectNodes('//*[local-name()="drawing" or local-name()="pict" or local-name()="object"]').Count) { [void]$warnings.Add('IMAGES_OR_EMBEDDED_OBJECTS_NOT_EXTRACTED') }
            if ($doc.SelectNodes('//*[local-name()="numPr" or local-name()="fldChar" or local-name()="ins" or local-name()="del" or local-name()="altChunk"]').Count) { [void]$warnings.Add('LIST_FIELDS_REVISIONS_OR_ALTERNATE_CONTENT_SIMPLIFIED') }
            if (@($zip.Entries | Where-Object { $_.FullName -match '^word/(header|footer|footnotes|endnotes|comments)' }).Count) { [void]$warnings.Add('HEADERS_FOOTERS_NOTES_COMMENTS_NOT_EXTRACTED') }
            foreach ($n in $doc.SelectSingleNode('//*[local-name()="body"]').ChildNodes) {
                if ($n.LocalName -eq 'p') {
                    $s=Get-TextRuns $n
                    $style=$n.SelectSingleNode('./*[local-name()="pPr"]/*[local-name()="pStyle"]')
                    if ($style) { $v=$style.GetAttribute('val',$style.NamespaceURI); if ($v -match '^Heading([1-6])$') { $s=('#' * [int]$Matches[1])+' '+$s } }
                    $lines.Add($s); $lines.Add('')
                } elseif ($n.LocalName -eq 'tbl') {
                    [void]$warnings.Add('TABLES_SIMPLIFIED_TO_MARKDOWN_CELL_TEXT')
                    $rows=@($n.SelectNodes('./*[local-name()="tr"]'))
                    $first=$true
                    foreach ($row in $rows) {
                        $cells=@($row.SelectNodes('./*[local-name()="tc"]') | ForEach-Object { ((@($_.SelectNodes('./*[local-name()="p"]') | ForEach-Object { Get-TextRuns $_ }) -join '<br>') -replace '\|','\|' -replace "`r?`n",'<br>') })
                        $lines.Add('| '+($cells -join ' | ')+' |')
                        if ($first) { $lines.Add('| '+((@($cells | ForEach-Object { '---' })) -join ' | ')+' |'); $first=$false }
                    }
                    $lines.Add('')
                } elseif ($n.LocalName -ne 'sectPr') { [void]$warnings.Add('UNSUPPORTED_BODY_CONTENT_NOT_EXTRACTED') }
            }
            $files['document.md']=$lines -join "`r`n"
        } else {
            $book=Read-TextPart $zip 'xl/workbook.xml'
            $notes=[Collections.Generic.List[string]]::new()
            $notes.Add('# Workbook conversion notes')
            $notes.Add('')
            $pr=$book.SelectSingleNode('//*[local-name()="workbookPr"]')
            $dateSystem='1900'; if ($pr -and $pr.GetAttribute('date1904') -in @('1','true')) { $dateSystem='1904' }
            $notes.Add('Date system: '+$dateSystem+'. Date/time styled cells retain raw serial values and require verification against the original workbook; custom format detection is heuristic.')
            $notes.Add('Formula results are cached values and were not recalculated. Missing caches are exported empty and listed below. Merged ranges are not filled. Names are JSON-escaped inside indented text.')
            $rels=Read-TextPart $zip 'xl/_rels/workbook.xml.rels'
            $shared=@()
            if ($zip.GetEntry('xl/sharedStrings.xml')) { $ss=Read-TextPart $zip 'xl/sharedStrings.xml'; $shared=@($ss.SelectNodes('//*[local-name()="si"]') | ForEach-Object { Get-TextRuns $_ }) }
            $dateStyles=@{}
            if ($zip.GetEntry('xl/styles.xml')) {
                $styles=Read-TextPart $zip 'xl/styles.xml'; $formats=@{}
                foreach ($fmt in $styles.SelectNodes('//*[local-name()="numFmt"]')) { $formats[$fmt.GetAttribute('numFmtId')]=$fmt.GetAttribute('formatCode') }
                $i=0
                foreach ($xf in $styles.SelectNodes('//*[local-name()="cellXfs"]/*[local-name()="xf"]')) {
                    $id=$xf.GetAttribute('numFmtId'); $code=$formats[$id]
                    if (([int]$id -ge 14 -and [int]$id -le 22) -or ([int]$id -ge 27 -and [int]$id -le 36) -or ([int]$id -ge 45 -and [int]$id -le 58) -or ($code -and (($code -replace '"[^"]*"|\\.','') -match '[ymdhs]'))) { $dateStyles[$i]=$true }
                    $i++
                }
            }
            $sheetNodes=@($book.SelectNodes('//*[local-name()="sheets"]/*[local-name()="sheet"]'))
            $idx=0; $needsNotes=($sheetNodes.Count -gt 1)
            foreach ($sheet in $sheetNodes) {
                $idx++; if ($sheet.GetAttribute('state') -in @('hidden','veryHidden')) { [void]$warnings.Add('HIDDEN_SHEETS_INCLUDED'); $needsNotes=$true }
                $filename=if ($sheetNodes.Count -eq 1) {'table.csv'} else {('sheet-{0:D3}.csv' -f $idx)}
                $state=$sheet.GetAttribute('state'); if (!$state) { $state='visible' }
                $notes.Add(''); $notes.Add('## '+$filename)
                $notes.Add(''); $notes.Add('    Original sheet name: '+(ConvertTo-Json -InputObject $sheet.GetAttribute('name') -Compress))
                $notes.Add('    Visibility: '+(ConvertTo-Json -InputObject $state -Compress))
                $rid=''; foreach ($attribute in $sheet.Attributes) { if ($attribute.LocalName -eq 'id') { $rid=$attribute.Value } }
                $rel=@($rels.DocumentElement.ChildNodes | Where-Object { $_.GetAttribute('Id') -eq $rid })
                if ($rel.Count -ne 1 -or $rel[0].GetAttribute('TargetMode') -eq 'External') { throw 'INVALID_SHEET_RELATIONSHIP' }
                $uri=[Uri]::new([Uri]'https://package.invalid/xl/workbook.xml',$rel[0].GetAttribute('Target'))
                if ($uri.Host -ne 'package.invalid') { throw 'INVALID_SHEET_RELATIONSHIP' }
                $xml=Read-TextPart $zip $uri.AbsolutePath.TrimStart('/')
                if ($xml.DocumentElement.LocalName -ne 'worksheet') { throw 'UNSUPPORTED_SHEET_TYPE' }
                if ($xml.SelectNodes('//*[local-name()="mergeCell"]').Count) { [void]$warnings.Add('MERGED_CELLS_ONLY_STORED_VALUES_EXPORTED'); $needsNotes=$true }
                foreach ($merged in $xml.SelectNodes('//*[local-name()="mergeCell"]')) { $notes.Add('    Merged range (stored values only): '+(ConvertTo-Json -InputObject $merged.GetAttribute('ref') -Compress)) }
                $values=@{}; $maxRow=0; $maxCol=0
                foreach ($cell in $xml.SelectNodes('//*[local-name()="sheetData"]/*[local-name()="row"]/*[local-name()="c"]')) {
                    $ref=$cell.GetAttribute('r'); if ($ref -notmatch '^([A-Z]{1,3})([1-9][0-9]*)$') { throw 'INVALID_CELL_REFERENCE' }
                    $col=0; foreach ($c in $Matches[1].ToCharArray()) { $col=$col*26+([int]$c-64) }; $row=[int]$Matches[2]
                    if ($row -gt 1048576 -or $col -gt 16384) { throw 'INVALID_CELL_REFERENCE' }
                    $maxRow=[Math]::Max($maxRow,$row); $maxCol=[Math]::Max($maxCol,$col)
                    if ([long]$maxRow*$maxCol -gt 2000000) { throw 'SHEET_GRID_TOO_LARGE' }
                    $v=$cell.SelectSingleNode('./*[local-name()="v"]'); $s=''; if ($v) { $s=$v.InnerText }
                    if ($cell.SelectSingleNode('./*[local-name()="f"]')) { [void]$warnings.Add('FORMULAS_USE_CACHED_VALUES_NOT_RECALCULATED'); $needsNotes=$true; if (!$v) { [void]$warnings.Add('FORMULA_CACHE_MISSING_EXPORTED_EMPTY'); $notes.Add('    Missing formula cache (empty output; review required): '+$ref) } }
                    switch ($cell.GetAttribute('t')) {
                        's' { $number=0; if (![int]::TryParse($s,[ref]$number) -or $number -lt 0 -or $number -ge $shared.Count) { throw 'INVALID_SHARED_STRING' }; $s=$shared[$number] }
                        'inlineStr' { $s=Get-TextRuns $cell }
                        'b' { if ($s -eq '1') { $s='TRUE' } elseif ($s -eq '0') { $s='FALSE' } }
                    }
                    # Keep the exact numeric serial: custom formats and elapsed times are ambiguous.
                    if ($cell.HasAttribute('s') -and $dateStyles.ContainsKey([int]$cell.GetAttribute('s'))) { [void]$warnings.Add('DATE_TIME_FORMATTED_CELLS_KEEP_RAW_SERIAL_SEE_WORKBOOK_DATE_SYSTEM'); $needsNotes=$true; $notes.Add('    Date/time styled cell (raw serial; review required): '+$ref+'; style index '+$cell.GetAttribute('s')) }
                    $values[$ref]=$s
                }
                $pr=$book.SelectSingleNode('//*[local-name()="workbookPr"]'); if ($pr -and $pr.GetAttribute('date1904') -in @('1','true')) { [void]$warnings.Add('WORKBOOK_DATE_SYSTEM_1904'); $needsNotes=$true }
                $out=[Text.StringBuilder]::new()
                for ($r=1; $r -le $maxRow; $r++) {
                    $fields=for ($c=1; $c -le $maxCol; $c++) { $n=$c; $letters=''; while ($n -gt 0) { $n--; $letters=[string][char](65+($n%26))+$letters; $n=[int][Math]::Floor($n/26) }; '"'+([string]$values["$letters$r"]).Replace('"','""')+'"' }
                    [void]$out.AppendLine(($fields -join ','))
                }
                $files[$filename]=$out.ToString()
            }
            if ($needsNotes) { $files['conversion-notes.md']=$notes -join "`r`n"; [void]$warnings.Add('REVIEW_LOCATIONS_IN_CONVERSION_NOTES') }
            [void]$warnings.Add('CSV_RAW_VALUES_FORMATTING_CHARTS_AND_OTHER_OBJECTS_NOT_PRESERVED')
        }
        [void][IO.Directory]::CreateDirectory($dest)
        foreach ($name in $files.Keys) { $path=Get-MineruLocalPath ([IO.Path]::Combine($dest,$name)); Write-TextNew $path $files[$name]; $paths.Add($path) }
        return [ordered]@{status='ok';paths=@($paths.ToArray());warnings=@($warnings | Sort-Object);review_required=($warnings.Count -gt 0)}
    } catch {
        $code='CONVERSION_FAILED'
        if ($_.Exception.Message -match '^[A-Z][A-Z0-9_]+$') { $code=$_.Exception.Message }
        if ($_.Exception.Data['mineru_code']) { $code=$_.Exception.Data['mineru_code'] }
        return [ordered]@{status='error';code=$code;paths=@($paths.ToArray());warnings=@($warnings | Sort-Object);review_required=$true}
    } finally { if ($zip) { $zip.Dispose() } }
}
if ($MyInvocation.InvocationName -ne '.') {
    $result=Invoke-TextConvert @savedTextArgs
    $result | ConvertTo-Json -Depth 6 -Compress
    if ($result.status -ne 'ok') { exit 1 }
    exit 0
}

#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$InputPath,
    [ValidateRange(1,2147483647)][int]$StartLine=1,
    [ValidateRange(1,500)][int]$LineCount=200,
    [ValidateRange(1024,268435456)][long]$MaxBytes=134217728
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Text.UTF8Encoding]::new($false)
$result=$null
try {
    if($InputPath -notmatch '^[A-Za-z]:[\\/]' -or $InputPath.Substring(2).Contains(':')){throw 'INPUT_PATH_INVALID'}
    $path=[IO.Path]::GetFullPath($InputPath)
    if(-not [IO.File]::Exists($path)){throw 'INPUT_NOT_FOUND'}
    $length=([IO.FileInfo]$path).Length
    if($length -gt $MaxBytes){throw 'INPUT_TOO_LARGE'}
    if([IO.Path]::GetExtension($path).ToLowerInvariant() -notin @('.md','.txt','.csv','.html','.htm')){throw 'UNSUPPORTED_TEXT_FORMAT'}
    try{$text=[IO.File]::ReadAllText($path,[Text.UTF8Encoding]::new($false,$true))}catch{throw 'INVALID_UTF8'}
    if($text.IndexOf([char]0) -ge 0){throw 'NUL_CHARACTER_FOUND'}
    $lines=[regex]::Split($text,'\r\n|\n|\r')
    $first=$StartLine-1;$selected=[Collections.Generic.List[string]]::new()
    if($first -lt $lines.Count){
        $last=[math]::Min($lines.Count,$first+$LineCount)
        for($i=$first;$i -lt $last;$i++){$selected.Add(('{0:D6}: {1}' -f ($i+1),$lines[$i]))}
    }
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($hash.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($text))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
    $endLine=if($selected.Count){$first+$selected.Count}else{0}
    $result=[ordered]@{status='read';path=$path;sha256=$digest;total_lines=$lines.Count;start_line=$StartLine;end_line=$endLine;truncated=($endLine -lt $lines.Count);lines=@($selected.ToArray())}
}catch{
    $code='READ_FAILED';$known=@('INPUT_PATH_INVALID','INPUT_NOT_FOUND','INPUT_TOO_LARGE','UNSUPPORTED_TEXT_FORMAT','INVALID_UTF8','NUL_CHARACTER_FOUND')
    $exception=$_.Exception
    while($null -ne $exception){
        foreach($candidate in $known){if($exception.Message -match ('(^|[^A-Z_])'+[regex]::Escape($candidate)+'($|[^A-Z_])')){$code=$candidate;break}}
        if($code-ne'READ_FAILED'){break};$exception=$exception.InnerException
    }
    $result=[ordered]@{status='error';code=$code}
}
$result|ConvertTo-Json -Depth 4 -Compress
if($result.status -eq 'error'){exit 1}

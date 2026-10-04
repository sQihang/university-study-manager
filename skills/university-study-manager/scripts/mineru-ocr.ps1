#requires -Version 5.1
<#
MinerU v4 local-file client. ASCII source for Windows PowerShell 5.1.
The caller must authorize cloud upload before setting -UploadApproved.
No document content, tokens, signed URLs, or raw server errors are printed.
Dot-source only for local testing; normal execution prints one JSON result.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$InputPath,
    [string]$OutputDirectory,
    [string]$PageRanges,
    [string]$ModelVersion = 'vlm',
    [string]$Language = 'ch',
    [switch]$ForceOcr,
    [switch]$DisableFormula,
    [switch]$DisableTable,
    [switch]$UploadApproved,
    [switch]$Resume,
    [switch]$InitializeConfig,
    [switch]$CheckConfig,
    [int]$PollIntervalSeconds = 5,
    [int]$WaitTimeoutSeconds = 600,
    [int]$RequestTimeoutSeconds = 120
)

function Stop-Mineru {
    param([string]$Code, [int]$HttpStatus = 0, [string]$ApiCode = '')
    $exception = [Exception]::new('MinerU operation stopped.')
    $exception.Data['mineru_code'] = $Code
    if ($HttpStatus) { $exception.Data['http_status'] = $HttpStatus }
    if ($ApiCode) { $exception.Data['api_code'] = $ApiCode }
    throw $exception
}

function Get-MineruProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-MineruLocalPath {
    param([string]$Value)
    if (!$Value -or $Value -notmatch '^[A-Za-z]:[\\/]' -or $Value.Substring(2).Contains(':')) {
        Stop-Mineru 'ABSOLUTE_LOCAL_PATH_REQUIRED'
    }
    try { $full = [IO.Path]::GetFullPath($Value) } catch { Stop-Mineru 'INVALID_PATH' }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Stop-Mineru 'REPARSE_PATH_NOT_ALLOWED' }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    return $full
}

function Read-MineruToken {
    param([string]$Path)
    if (![IO.File]::Exists($Path)) { Stop-Mineru 'CONFIG_NOT_FOUND' }
    if ((Get-Item -LiteralPath $Path).Length -gt 16384) { Stop-Mineru 'CONFIG_INVALID' }
    try { $config = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json } catch { Stop-Mineru 'CONFIG_INVALID' }
    $value = Get-MineruProperty $config 'token'
    if ($value -isnot [string] -or !$value -or $value -notmatch '^[\x21-\x7E]+$' -or $value -match '^Bearer' -or $value -eq '<YOUR_KEY>') {
        Stop-Mineru 'CONFIG_TOKEN_INVALID'
    }
    return $value
}

function Assert-MineruRemoteUrl {
    param([string]$Value, [switch]$Api)
    $uri = $null
    if (![Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { Stop-Mineru 'UNTRUSTED_REMOTE_URL' }
    if ($uri.Scheme -ne 'https' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment) { Stop-Mineru 'UNTRUSTED_REMOTE_URL' }
    $hostName = $uri.DnsSafeHost.ToLowerInvariant()
    if ($Api) {
        if ($hostName -ne 'mineru.net' -or !$uri.AbsolutePath.StartsWith('/api/v4/')) { Stop-Mineru 'UNTRUSTED_REMOTE_URL' }
    } else {
        $allowed = $hostName -eq 'mineru.net' -or $hostName.EndsWith('.mineru.net') -or
            $hostName.EndsWith('.openxlab.org.cn') -or $hostName.EndsWith('.aliyuncs.com')
        if (!$allowed) { Stop-Mineru 'UNTRUSTED_REMOTE_URL' }
    }
}

function Invoke-MineruHttp {
    param([string]$Method, [string]$Url, [string]$Token, [string]$JsonBody,
          [string]$UploadPath, [string]$DownloadPath, [int]$TimeoutSeconds)
    Assert-MineruRemoteUrl $Url -Api:([bool]$Token)
    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $client.MaxResponseContentBufferSize = 2MB
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url)
    $response = $null
    $fileStream = $null
    $cts = [Threading.CancellationTokenSource]::new()
    $cts.CancelAfter([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        if ($Token) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token) }
        if ($JsonBody) { $request.Content = [Net.Http.StringContent]::new($JsonBody, [Text.Encoding]::UTF8, 'application/json') }
        if ($UploadPath) {
            $fileStream = [IO.File]::Open($UploadPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $request.Content = [Net.Http.StreamContent]::new($fileStream)
            $request.Content.Headers.ContentLength = $fileStream.Length
            # No API Authorization or Content-Type is attached to signed PUT URLs.
        }
        $mode = [Net.Http.HttpCompletionOption]::ResponseContentRead
        if ($DownloadPath) { $mode = [Net.Http.HttpCompletionOption]::ResponseHeadersRead }
        try { $response = $client.SendAsync($request, $mode, $cts.Token).GetAwaiter().GetResult() } catch { Stop-Mineru 'NETWORK_OR_REQUEST_TIMEOUT' }
        $status = [int]$response.StatusCode
        if ($status -lt 200 -or $status -ge 300) { Stop-Mineru 'HTTP_ERROR' $status }
        if ($DownloadPath) {
            if ($response.Content.Headers.ContentLength -gt 268435456) { Stop-Mineru 'RESULT_TOO_LARGE' }
            $source = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $target = [IO.File]::Open($DownloadPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $buffer = [byte[]]::new(65536)
                [long]$total = 0
                while (($count = $source.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()) -gt 0) {
                    $total += $count
                    if ($total -gt 268435456) { Stop-Mineru 'RESULT_TOO_LARGE' }
                    $target.Write($buffer, 0, $count)
                }
            } finally { $target.Dispose(); $source.Dispose() }
            return $null
        }
        if ($Token) {
            try { return ($response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json) } catch { Stop-Mineru 'API_RESPONSE_INVALID' }
        }
        return $null
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose()
        if ($null -ne $fileStream) { $fileStream.Dispose() }
        $client.Dispose(); $cts.Dispose()
    }
}

function Get-MineruApiData {
    param([string]$Method, [string]$Url, [string]$Token, [string]$Body, [int]$TimeoutSeconds)
    $reply = Invoke-MineruHttp -Method $Method -Url $Url -Token $Token -JsonBody $Body -TimeoutSeconds $TimeoutSeconds
    $code = Get-MineruProperty $reply 'code'
    if ($null -eq $code) { Stop-Mineru 'API_RESPONSE_INVALID' }
    if ([string]$code -ne '0') {
        $safe = ''
        if ([string]$code -match '^(A0202|A0211|-500|-1000[12]|-600(0[1-9]|1[0-9]|2[0-2]))$') { $safe = [string]$code }
        Stop-Mineru 'API_REJECTED' 0 $safe
    }
    $data = Get-MineruProperty $reply 'data'
    if ($null -eq $data) { Stop-Mineru 'API_RESPONSE_INVALID' }
    return $data
}

function Save-MineruJob {
    param([string]$Path, $Job)
    $temporary = $Path + '.new'
    if (Test-Path -LiteralPath $temporary) { Stop-Mineru 'PARTIAL_STATE_EXISTS' }
    [IO.File]::WriteAllText($temporary, ($Job | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $Path) }
}

function Expand-MineruResult {
    param([string]$ZipPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Destination) { Stop-Mineru 'RESULT_DIRECTORY_EXISTS' }
    $zip = $null
    try {
        try { $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath) } catch { Stop-Mineru 'RESULT_ZIP_INVALID' }
        if ($zip.Entries.Count -gt 10000) { Stop-Mineru 'RESULT_TOO_LARGE' }
        $seen = @{}
        [long]$size = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name -match '(^/|\\|:|(^|/)\.\.?(/|$))' -or $name.Contains([char]0)) { Stop-Mineru 'UNSAFE_ZIP_PATH' }
            foreach ($segment in $name.Split('/')) {
                if ($segment -match '[<>"|?*\x00-\x1F]|[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { Stop-Mineru 'UNSAFE_ZIP_PATH' }
            }
            if ($seen.ContainsKey($name)) { Stop-Mineru 'DUPLICATE_ZIP_PATH' }
            $seen[$name] = $true
            $kind = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($kind -eq 0xA000) { Stop-Mineru 'UNSAFE_ZIP_PATH' }
            $size += $entry.Length
            if ($size -gt 536870912) { Stop-Mineru 'RESULT_TOO_LARGE' }
        }
        $markdown = @($zip.Entries | Where-Object { $_.Name -ceq 'full.md' })
        if ($markdown.Count -ne 1 -or $markdown[0].Length -le 0 -or $markdown[0].Length -gt 67108864) { Stop-Mineru 'MARKDOWN_MISSING_OR_AMBIGUOUS' }
        $prefix = $markdown[0].FullName.Substring(0, $markdown[0].FullName.Length - 7)
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        $reader = [IO.StreamReader]::new($markdown[0].Open(), [Text.UTF8Encoding]::new($false, $true), $true)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        [IO.File]::WriteAllText([IO.Path]::Combine($Destination, 'full.md'), $text, [Text.UTF8Encoding]::new($false))
        $text = $null
        $assetCount = 0
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.StartsWith($prefix + 'images/', [StringComparison]::Ordinal) -and
                $entry.Name -match '\.(png|jpg|jpeg|jp2|webp|gif|bmp)$') {
                $relative = $entry.FullName.Substring($prefix.Length)
                $target = [IO.Path]::GetFullPath([IO.Path]::Combine($Destination, $relative))
                if (!$target.StartsWith($Destination.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Stop-Mineru 'UNSAFE_ZIP_PATH' }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                $source = $entry.Open()
                $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew)
                try { $source.CopyTo($output) } finally { $source.Dispose(); $output.Dispose() }
                $assetCount++
            }
        }
        return $assetCount
    } finally { if ($null -ne $zip) { $zip.Dispose() } }
}

function Invoke-MineruOcr {
    [CmdletBinding()]
    param([string]$ConfigPath, [string]$InputPath, [string]$OutputDirectory, [string]$PageRanges,
          [string]$ModelVersion = 'vlm', [string]$Language = 'ch', [switch]$ForceOcr,
          [switch]$DisableFormula, [switch]$DisableTable, [switch]$UploadApproved, [switch]$Resume,
          [switch]$InitializeConfig, [switch]$CheckConfig, [int]$PollIntervalSeconds = 5,
          [int]$WaitTimeoutSeconds = 600, [int]$RequestTimeoutSeconds = 120)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $lock = $null
    $token = $null
    $job = $null
    $safeBatchId = $null
    $stage = 'preflight'
    $result = [ordered]@{ status = 'error'; code = 'UNEXPECTED_ERROR' }
    try {
        if (($InitializeConfig -and $CheckConfig) -or (($InitializeConfig -or $CheckConfig) -and ($Resume -or $InputPath -or $OutputDirectory))) { Stop-Mineru 'INCOMPATIBLE_OPTIONS' }
        $config = Get-MineruLocalPath $ConfigPath
        if ($InitializeConfig) {
            if (Test-Path -LiteralPath $config) { Stop-Mineru 'CONFIG_ALREADY_EXISTS' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($config)) | Out-Null
            $file = [IO.File]::Open($config, [IO.FileMode]::CreateNew)
            try { $bytes = [Text.UTF8Encoding]::new($false).GetBytes("{`n  `"token`": `"`"`n}`n"); $file.Write($bytes, 0, $bytes.Length) } finally { $file.Dispose() }
            $acl = [Security.AccessControl.FileSecurity]::new()
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            # Keep the filesystem-assigned owner; setting owner can require an extra
            # privilege on workspace drives. Restrict access using the DACL only.
            $acl.SetAccessRuleProtection($true, $false)
            $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', 'Allow')
            $acl.AddAccessRule($rule)
            # Avoid module discovery differences when PS5 inherits PS7's PSModulePath.
            $configFile = [IO.FileInfo]::new($config)
            if ($PSVersionTable.PSVersion.Major -le 5) { $configFile.SetAccessControl($acl) }
            else { [IO.FileSystemAclExtensions]::SetAccessControl($configFile, $acl) }
            return [ordered]@{ status = 'configured'; code = 'EMPTY_CONFIG_CREATED'; config_path = $config }
        }
        $token = Read-MineruToken $config
        if ($CheckConfig) { return [ordered]@{ status = 'ok'; code = 'CONFIG_VALID_LOCALLY' } }
        if ($PollIntervalSeconds -lt 1 -or $PollIntervalSeconds -gt 60 -or $WaitTimeoutSeconds -lt 1 -or $WaitTimeoutSeconds -gt 7200 -or $RequestTimeoutSeconds -lt 1 -or $RequestTimeoutSeconds -gt 600) { Stop-Mineru 'INVALID_TIMEOUT' }
        $out = Get-MineruLocalPath $OutputDirectory
        $jobPath = [IO.Path]::Combine($out, '.mineru-job.json')
        $destination = [IO.Path]::Combine($out, 'result')
        if (!$Resume) {
            if (!$UploadApproved) { Stop-Mineru 'UPLOAD_APPROVAL_REQUIRED' }
            if (Test-Path -LiteralPath $out) { Stop-Mineru 'OUTPUT_ALREADY_EXISTS' }
            if ($ModelVersion -notin @('vlm','pipeline') -or $Language -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,31}$') { Stop-Mineru 'INVALID_PARSE_OPTIONS' }
            if ($PageRanges) {
                foreach ($range in $PageRanges.Split(',')) {
                    if ($range -notmatch '^([1-9][0-9]*)(?:-(-?[1-9][0-9]*))?$') { Stop-Mineru 'INVALID_PAGE_RANGES' }
                    $start = [long]$Matches[1]
                    if ($Matches[2]) { $end = [long]$Matches[2]; if ($end -gt 0 -and $start -gt $end) { Stop-Mineru 'INVALID_PAGE_RANGES' } }
                }
            }
            $inputFile = Get-MineruLocalPath $InputPath
            if ([string]::Equals($inputFile, $config, [StringComparison]::OrdinalIgnoreCase)) { Stop-Mineru 'INPUT_IS_CONFIG' }
            if (![IO.File]::Exists($inputFile)) { Stop-Mineru 'INPUT_NOT_FOUND' }
            $extension = [IO.Path]::GetExtension($inputFile).ToLowerInvariant()
            if ($extension -notin @('.pdf','.png','.jpg','.jpeg','.jp2','.webp','.gif','.bmp','.doc','.docx','.ppt','.pptx','.xls','.xlsx')) { Stop-Mineru 'UNSUPPORTED_FILE_TYPE' }
            $length = (Get-Item -LiteralPath $inputFile).Length
            if ($length -eq 0) { Stop-Mineru 'INPUT_EMPTY' }
            if ($length -gt 200000000) { Stop-Mineru 'INPUT_TOO_LARGE' }
            [IO.Directory]::CreateDirectory($out) | Out-Null
        } else {
            if ($InputPath -or $PageRanges -or $ForceOcr -or $DisableFormula -or $DisableTable -or $PSBoundParameters.ContainsKey('ModelVersion') -or $PSBoundParameters.ContainsKey('Language')) { Stop-Mineru 'RESUME_CANNOT_CHANGE_INPUT' }
            $null = Get-MineruLocalPath $jobPath
            if (![IO.File]::Exists($jobPath)) { Stop-Mineru 'RESUME_STATE_NOT_FOUND' }
        }
        $lockPath = [IO.Path]::Combine($out, '.mineru-lock')
        $null = Get-MineruLocalPath $lockPath
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) } catch { Stop-Mineru 'OUTPUT_BUSY' }
        $result['output_directory'] = $out
        if (!$Resume -and ((Test-Path -LiteralPath $jobPath) -or (Test-Path -LiteralPath $destination))) { Stop-Mineru 'OUTPUT_ALREADY_EXISTS' }
        if ($Resume) {
            if ((Get-Item -LiteralPath $jobPath).Length -gt 16384) { Stop-Mineru 'RESUME_STATE_INVALID' }
            try { $job = [IO.File]::ReadAllText($jobPath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json } catch { Stop-Mineru 'RESUME_STATE_INVALID' }
            foreach ($key in @('batch_id','data_id')) {
                if ((Get-MineruProperty $job $key) -notmatch '^[a-zA-Z0-9_-]{8,128}$') { Stop-Mineru 'RESUME_STATE_INVALID' }
            }
            if ((Get-MineruProperty $job 'version') -ne 1 -or (Get-MineruProperty $job 'upload_name') -notmatch '^document\.[a-z0-9]+$' -or (Get-MineruProperty $job 'phase') -notin @('allocated','uploaded','done')) { Stop-Mineru 'RESUME_STATE_INVALID' }
            $safeBatchId = $job.batch_id
            if ($job.phase -eq 'done') {
                $md = Get-MineruLocalPath ([IO.Path]::Combine($destination, 'full.md'))
                if (![IO.File]::Exists($md)) { Stop-Mineru 'COMPLETED_OUTPUT_MISSING' }
                return [ordered]@{ status = 'done'; code = 'ALREADY_DOWNLOADED'; markdown_path = $md; output_directory = $out; review_required = $true }
            }
        } else {
            $stage = 'allocate'
            $dataId = [Guid]::NewGuid().ToString('N')
            $uploadName = 'document' + $extension
            $fileSpec = @{ name = $uploadName; data_id = $dataId; is_ocr = [bool]$ForceOcr }
            if ($PageRanges) { $fileSpec['page_ranges'] = $PageRanges }
            $body = @{ files = @($fileSpec); model_version = $ModelVersion; language = $Language; enable_formula = !$DisableFormula; enable_table = !$DisableTable } | ConvertTo-Json -Depth 5 -Compress
            $data = Get-MineruApiData 'POST' 'https://mineru.net/api/v4/file-urls/batch' $token $body $RequestTimeoutSeconds
            $batch = Get-MineruProperty $data 'batch_id'
            $urls = @(Get-MineruProperty $data 'file_urls')
            if ($batch -notmatch '^[a-zA-Z0-9_-]{8,128}$' -or $urls.Count -ne 1 -or $urls[0] -isnot [string]) { Stop-Mineru 'API_RESPONSE_INVALID' }
            Assert-MineruRemoteUrl $urls[0]
            $job = [pscustomobject]@{ version = 1; batch_id = $batch; data_id = $dataId; upload_name = $uploadName; phase = 'allocated' }
            $safeBatchId = $batch
            Save-MineruJob $jobPath $job
            $stage = 'upload'
            $null = Invoke-MineruHttp -Method 'PUT' -Url $urls[0] -UploadPath $inputFile -TimeoutSeconds $RequestTimeoutSeconds
            $job.phase = 'uploaded'
            Save-MineruJob $jobPath $job
            $urls = $null
        }
        $result['batch_id'] = $job.batch_id
        $stage = 'poll'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $downloadUrl = $null
        $state = 'pending'
        while ($watch.Elapsed.TotalSeconds -lt $WaitTimeoutSeconds) {
            $remaining = [Math]::Max(1, [Math]::Ceiling($WaitTimeoutSeconds - $watch.Elapsed.TotalSeconds))
            $budget = [int][Math]::Min($RequestTimeoutSeconds, $remaining)
            $data = Get-MineruApiData 'GET' ('https://mineru.net/api/v4/extract-results/batch/' + $job.batch_id) $token '' $budget
            if ((Get-MineruProperty $data 'batch_id') -ne $job.batch_id) { Stop-Mineru 'API_RESPONSE_INVALID' }
            $items = @(Get-MineruProperty $data 'extract_result')
            if ($items.Count -ne 1 -or $null -eq $items[0]) { Stop-Mineru 'API_RESPONSE_INVALID' }
            $item = $items[0]
            $returnedId = Get-MineruProperty $item 'data_id'
            if ($returnedId) { if ($returnedId -ne $job.data_id) { Stop-Mineru 'RESULT_ID_MISMATCH' } }
            elseif ((Get-MineruProperty $item 'file_name') -ne $job.upload_name) { Stop-Mineru 'RESULT_ID_MISMATCH' }
            $state = Get-MineruProperty $item 'state'
            if ($state -eq 'failed') { Stop-Mineru 'REMOTE_PARSE_FAILED' }
            if ($state -eq 'done') { $downloadUrl = Get-MineruProperty $item 'full_zip_url'; Assert-MineruRemoteUrl $downloadUrl; break }
            if ($state -notin @('waiting-file','pending','running','converting')) { Stop-Mineru 'UNKNOWN_REMOTE_STATE' }
            $pause = [Math]::Min($PollIntervalSeconds, [Math]::Max(0, $WaitTimeoutSeconds - $watch.Elapsed.TotalSeconds))
            if ($pause -gt 0) { Start-Sleep -Milliseconds ([int]($pause * 1000)) }
        }
        if (!$downloadUrl) {
            return [ordered]@{ status = 'pending'; code = 'WAIT_TIMEOUT'; batch_id = $job.batch_id; remote_state = $state; output_directory = $out; resumable = $true }
        }
        $stage = 'download'
        $null = Get-MineruLocalPath $destination
        if (Test-Path -LiteralPath $destination) { Stop-Mineru 'RESULT_DIRECTORY_EXISTS' }
        $temporary = [IO.Path]::Combine($out, '.download-' + [Guid]::NewGuid().ToString('N') + '.zip')
        $null = Invoke-MineruHttp -Method 'GET' -Url $downloadUrl -DownloadPath $temporary -TimeoutSeconds $RequestTimeoutSeconds
        $stage = 'extract'
        $staging = [IO.Path]::Combine($out, '.extract-' + [Guid]::NewGuid().ToString('N'))
        $assets = Expand-MineruResult $temporary $staging
        [IO.Directory]::Move($staging, $destination)
        [IO.File]::Delete($temporary)
        $job.phase = 'done'
        Save-MineruJob $jobPath $job
        return [ordered]@{ status = 'done'; code = 'DOWNLOADED'; batch_id = $job.batch_id; output_directory = $out; markdown_path = [IO.Path]::Combine($destination,'full.md'); asset_count = $assets; review_required = $true }
    } catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException -and !$exception.Data.Contains('mineru_code')) { $exception = $exception.InnerException }
        if ($exception.Data.Contains('mineru_code')) { $result.code = $exception.Data['mineru_code'] }
        foreach ($key in @('http_status','api_code')) { if ($exception.Data.Contains($key)) { $result[$key] = $exception.Data[$key] } }
        if ($result.code -in @('CONFIG_NOT_FOUND','CONFIG_INVALID','CONFIG_TOKEN_INVALID')) {
            $result['config_path'] = $config
            $result['help_url'] = 'https://mineru.net/apiManage/docs'
            $result['required_field'] = 'token'
        }
        $result['stage'] = $stage
        if ($safeBatchId) { $result['batch_id'] = $safeBatchId; $result['resumable'] = $true }
        return $result
    } finally {
        $token = $null
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $answer = Invoke-MineruOcr @PSBoundParameters
    $answer | ConvertTo-Json -Depth 5 -Compress | Write-Output
    if ($answer.status -eq 'error') { exit 1 }
    if ($answer.status -eq 'pending') { exit 2 }
    exit 0
}

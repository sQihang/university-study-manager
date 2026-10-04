#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkspacePath,
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [ValidateSet('Auto','Text','Ocr','ComplexTable')][string]$Mode='Auto',
    [switch]$UploadApproved,[switch]$Resume,
    [int]$WaitTimeoutSeconds=600,[int]$RequestTimeoutSeconds=120
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$watch=[Diagnostics.Stopwatch]::StartNew()
function Emit([string]$status,[string]$code,[string]$stage,[string]$method,$detail=$null){$r=[ordered]@{status=$status;code=$code;stage=$stage;method=$method;elapsed_seconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)};if($detail){foreach($p in $detail.GetEnumerator()){$r[$p.Key]=$p.Value}};$r|ConvertTo-Json -Depth 8 -Compress|Write-Output;if($status-eq'error'){exit 1};if($status-eq'pending'){exit 2};exit 0}
function Full([string]$p){if($p-notmatch'^[A-Za-z]:[\\/]'-or$p.Substring(2).Contains(':')){throw 'ABSOLUTE_PATH_REQUIRED'};return [IO.Path]::GetFullPath($p).TrimEnd('\','/')}
function P($o,[string]$name,$default=$null){if($null-eq$o){return $default};$p=$o.PSObject.Properties[$name];if($null-eq$p){return $default};return $p.Value}
try{
    $root=Full $WorkspacePath;$input=Full $InputPath;$out=Full $OutputDirectory
    if(-not[IO.Directory]::Exists($root)){throw 'WORKSPACE_NOT_FOUND'};if(-not[IO.File]::Exists($input)){throw 'INPUT_NOT_FOUND'}
    $prefix=$root+'\';if(-not$out.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'OUTPUT_OUTSIDE_WORKSPACE'}
    if($out-match'(^|[\\/])\.private([\\/]|$)'){throw 'PRIVATE_OUTPUT_FORBIDDEN'}
    $config=[IO.Path]::Combine($root,'.private','mineru.json');$tools=[IO.Path]::Combine($root,'.private','document-tools.json');$ext=[IO.Path]::GetExtension($input).ToLowerInvariant()
    if($Resume){. ([IO.Path]::Combine($PSScriptRoot,'invoke-document-ocr.ps1'));$a=Invoke-StudyDocumentOcr -ConfigPath $config -OutputDirectory $out -Resume -WaitTimeoutSeconds $WaitTimeoutSeconds -RequestTimeoutSeconds $RequestTimeoutSeconds;Emit $a.status $a.code ([string](P $a 'stage' 'resume')) 'mineru-api-resume' $a}
    if(Test-Path -LiteralPath $out){
        if(-not (Get-Item -LiteralPath $out -Force).PSIsContainer){throw 'OUTPUT_NOT_DIRECTORY'}
        if(@(Get-ChildItem -LiteralPath $out -Force|Select-Object -First 1).Count){
            $resumeRoot=$null;foreach($candidate in @($out,[IO.Path]::Combine($out,'ocr'))){if([IO.File]::Exists([IO.Path]::Combine($candidate,'.mineru-job.json'))-or[IO.File]::Exists([IO.Path]::Combine($candidate,'document-job.json'))){$resumeRoot=$candidate;break}}
            if($resumeRoot){. ([IO.Path]::Combine($PSScriptRoot,'invoke-document-ocr.ps1'));$a=Invoke-StudyDocumentOcr -ConfigPath $config -OutputDirectory $resumeRoot -Resume -WaitTimeoutSeconds $WaitTimeoutSeconds -RequestTimeoutSeconds $RequestTimeoutSeconds;Emit $a.status $a.code ([string](P $a 'stage' 'resume')) 'mineru-api-resume-existing' $a}
            throw 'OUTPUT_NOT_EMPTY'
        }
        [IO.Directory]::Delete($out)
    }
    if($ext-in@('.md','.txt','.csv','.json','.html','.htm')-and$Mode-in@('Auto','Text')){Emit 'ready' 'SOURCE_DIRECTLY_READABLE' 'inspect' 'none' ([ordered]@{paths=@($input);review_required=$true})}
    if($ext-eq'.pdf'-and$Mode-in@('Auto','Text')){
        . ([IO.Path]::Combine($PSScriptRoot,'pdf-tools.ps1'));$direct=[IO.Path]::Combine($out,'direct');$pdfArgs=@{Mode='Extract';Capability='Extract';InputPath=$input;OutputDirectory=$direct};if([IO.File]::Exists($tools)){$pdfArgs.ToolsConfigPath=$tools}
        $a=Invoke-StudyPdf @pdfArgs
        if($a.status-ne'extracted'){Emit 'error' $a.code 'text-extraction' 'poppler-pdftotext' $a}
        if($Mode-eq'Text'-or$a.quality_status-ne'failed'){Emit 'done' $a.code 'quality-review' 'poppler-pdftotext' $a}
        if(-not$UploadApproved){Emit 'needs_action' 'OCR_REQUIRED_UPLOAD_NOT_APPROVED' 'quality-review' 'poppler-pdftotext' ([ordered]@{direct_result=$a;ocr_available=[IO.File]::Exists($config)})}
        . ([IO.Path]::Combine($PSScriptRoot,'invoke-document-ocr.ps1'));$ocr=[IO.Path]::Combine($out,'ocr');$ocrArgs=@{ConfigPath=$config;InputPath=$input;OutputDirectory=$ocr;UploadApproved=$true;WaitTimeoutSeconds=$WaitTimeoutSeconds;RequestTimeoutSeconds=$RequestTimeoutSeconds};if([IO.File]::Exists($tools)){$ocrArgs.ToolsConfigPath=$tools}
        $b=Invoke-StudyDocumentOcr @ocrArgs
        Emit $b.status $b.code ([string](P $b 'stage' 'ocr')) 'poppler-rasterize+mineru-api' ([ordered]@{direct_result=$a;ocr_result=$b})
    }
    if($ext-eq'.pdf'-or$ext-in@('.png','.jpg','.jpeg')){
        if(-not$UploadApproved){Emit 'needs_action' 'UPLOAD_APPROVAL_REQUIRED' 'ocr' 'mineru-api' ([ordered]@{config_path=$config;help_url='https://mineru.net/apiManage'})}
        . ([IO.Path]::Combine($PSScriptRoot,'invoke-document-ocr.ps1'))
        $ocrArgs=@{ConfigPath=$config;InputPath=$input;OutputDirectory=$out;UploadApproved=$true;WaitTimeoutSeconds=$WaitTimeoutSeconds;RequestTimeoutSeconds=$RequestTimeoutSeconds};if([IO.File]::Exists($tools)){$ocrArgs.ToolsConfigPath=$tools};$a=Invoke-StudyDocumentOcr @ocrArgs
        $method=if($ext-eq'.pdf'){'poppler-rasterize+mineru-api'}else{'mineru-api-image-ocr'};Emit $a.status $a.code ([string](P $a 'stage' 'ocr')) $method $a
    }
    if($Mode-eq'ComplexTable'){
        if(-not$UploadApproved){Emit 'needs_action' 'UPLOAD_APPROVAL_REQUIRED' 'structured-extraction' 'mineru-cli' ([ordered]@{config_path=$config;help_url='https://mineru.net/apiManage'})}
        $cliOut=[IO.Path]::Combine($out,'structured');$hostExe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$cliScript=[IO.Path]::Combine($PSScriptRoot,'mineru-cli.ps1')
        $raw=& $hostExe -NoProfile -NonInteractive -File $cliScript -Mode Precision -InputPath $input -OutputDirectory $cliOut -ConfigPath $config -Format html -Model vlm -Ocr -UploadApproved 2>$null
        try{$a=$raw|ConvertFrom-Json}catch{throw 'CLI_RESPONSE_INVALID'}
        Emit $a.status $a.code 'structured-extraction' 'mineru-cli-vlm-html' $a
    }
    if($ext-in@('.docx','.xlsx')-and$Mode-in@('Auto','Text')){. ([IO.Path]::Combine($PSScriptRoot,'text-convert.ps1'));$a=Invoke-TextConvert -InputPath $input -OutputDirectory $out -Mode auto;Emit $(if($a.status-eq'ok'){'done'}else{'error'}) $(if($a.status-eq'ok'){'LOCAL_CONVERSION_COMPLETE'}else{$a.code}) 'local-conversion' 'builtin-ooxml' $a}
    Emit 'needs_action' 'FORMAT_REQUIRES_AVAILABLE_TOOL' 'tool-selection' 'none' ([ordered]@{extension=$ext;inspect_cli=$true})
}catch{$code=$_.Exception.Message;if($code-notmatch'^[A-Z0-9_]+$'){$code='DOCUMENT_PROCESSING_FAILED'};Emit 'error' $code 'preflight' 'none'}

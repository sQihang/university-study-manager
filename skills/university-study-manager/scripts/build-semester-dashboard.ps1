#requires -Version 5.1
<#
Builds a deterministic, offline semester dashboard from a temporary JSON file.
The source is ASCII so Windows PowerShell 5.1 does not depend on its code page.
Input and output text are always UTF-8 without BOM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$WorkspacePath,
    [Parameter(Mandatory=$true)][ValidatePattern('^\d{4}-\d{4}-[12]$')][string]$Semester,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$InputJson,
    [string]$TemplatePath,
    [switch]$ValidateOnly,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Utf8NoBom=[Text.UTF8Encoding]::new($false)

function U([int[]]$p){return -join($p|ForEach-Object{[char]$_})}
function Encode-Html($v){if($null -eq $v){return ''};return [Net.WebUtility]::HtmlEncode([string]$v)}
function A($v){return (Encode-Html $v)}
function Get-P($o,[string]$n,$d=$null){
    if($null -eq $o){return $d};$p=$o.PSObject.Properties[$n];if($null -eq $p){return $d};return $p.Value
}
function As-Array($v){if($null -eq $v){return @()};return @($v)}
function Full([string]$p){return [IO.Path]::GetFullPath($p)}
function Assert-Within([string]$root,[string]$candidate){
    $r=(Full $root).TrimEnd('\')+'\';$c=Full $candidate
    if(-not $c.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){throw 'PATH_OUTSIDE_WORKSPACE'}
    $cursor=$c
    while($cursor -and $cursor.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)){
        if(Test-Path -LiteralPath $cursor){$i=Get-Item -LiteralPath $cursor -Force;if(($i.Attributes-band[IO.FileAttributes]::ReparsePoint)-ne 0){throw 'REPARSE_PATH_NOT_ALLOWED'}}
        $parent=[IO.Directory]::GetParent($cursor);if($null -eq $parent){break};$cursor=$parent.FullName
    }
}
function Is-Within([string]$root,[string]$candidate){
    $r=(Full $root).TrimEnd('\')+'\';$c=Full $candidate
    return $c.StartsWith($r,[StringComparison]::OrdinalIgnoreCase)
}
function Fail([string]$code,[string]$field=''){$r=[ordered]@{status='error';code=$code};if($field){$r.field=$field};$r|ConvertTo-Json -Compress|Write-Output;exit 1}
function Is-Active($e,[int]$w){
    $s=[int](Get-P $e 'startWeek' 1);$t=[int](Get-P $e 'endWeek' $s)
    if($w-lt$s-or$w-gt$t){return $false};$p=[string](Get-P $e 'parity' 'all')
    if($p-eq'odd'){return ($w%2)-eq 1};if($p-eq'even'){return ($w%2)-eq 0};return $true
}
function Entry-Name($e){$n=Get-P $e 'courseName' '';if($n){return [string]$n};$id=[string](Get-P $e 'courseId' '');$c=$CoursesById[$id];if($null-ne$c){return [string](Get-P $c 'name' '')};return ''}
function Entry-Focus($e){$v=Get-P $e 'displayType' '';if($v){return ([string]$v)-eq'focus'};$id=[string](Get-P $e 'courseId' '');$c=$CoursesById[$id];return $null-ne$c-and([string](Get-P $c 'displayType' 'normal'))-eq'focus'}
function Slot-Label([int]$slot){$p=$SlotLabels.PSObject.Properties[[string]$slot];if($null-ne$p){return [string]$p.Value};return ('#'+$slot)}
function Stable-Key([string]$s){$b=[Text.Encoding]::UTF8.GetBytes($s);$sha=[Security.Cryptography.SHA256]::Create();try{$x=$sha.ComputeHash($b)}finally{$sha.Dispose()};return 'c'+(-join($x[0..3]|ForEach-Object{$_.ToString('x2')}))}

try{
    $root=Full $WorkspacePath;if(-not[IO.Directory]::Exists($root)){Fail 'WORKSPACE_NOT_FOUND'}
    $input=Full $InputJson;Assert-Within $root $input;if(-not[IO.File]::Exists($input)){Fail 'INPUT_NOT_FOUND'}
    . ([IO.Path]::Combine($PSScriptRoot,'workspace-layout.ps1'));$layout=Get-WorkspaceLayout $root
    $pendingRoot=[IO.Path]::Combine($root,$layout.Temp,(U @(0x5F85,0x5904,0x7406)))
    $machineRoot=[IO.Path]::Combine($root,$layout.Machine)
    if(-not(Is-Within $pendingRoot $input)-and-not(Is-Within $machineRoot $input)){Fail 'INPUT_MUST_BE_TEMP_OR_MACHINE_JSON'}
    if(-not$TemplatePath){$TemplatePath=[IO.Path]::Combine([IO.Path]::GetDirectoryName($PSScriptRoot),'assets','semester-plan-template.html')}
    $templateFile=Full $TemplatePath;if(-not[IO.File]::Exists($templateFile)){Fail 'TEMPLATE_NOT_FOUND'}
    $data=[IO.File]::ReadAllText($input,$Utf8NoBom)|ConvertFrom-Json
    if([int](Get-P $data 'schemaVersion' 0)-ne 2){Fail 'UNSUPPORTED_SCHEMA_VERSION'}
    if([string](Get-P $data 'semester' '')-ne$Semester){Fail 'SEMESTER_MISMATCH'}
    $TotalWeeks=[int](Get-P $data 'totalWeeks' 0);if($TotalWeeks-lt 1-or$TotalWeeks-gt 30){Fail 'INVALID_TOTAL_WEEKS'}
    $modules=@(As-Array (Get-P $data 'modules' @())|ForEach-Object{([string]$_).ToUpperInvariant()}|Select-Object -Unique)
    foreach($m in $modules){if($m-notin @('A','B','C','D','E','F','G')){Fail 'INVALID_MODULE'}}
    if($modules-notcontains'A'){Fail 'MODULE_A_REQUIRED'};if($modules-notcontains'B'-and$modules-contains'G'){Fail 'MODULE_G_REQUIRES_B'}
    $Courses=@(As-Array (Get-P $data 'courses' @()));$Schedule=@(As-Array (Get-P $data 'schedule' @()));$SlotLabels=Get-P $data 'slotLabels' ([pscustomobject]@{});$CoverageComplete=[bool](Get-P $data 'scheduleCoverageComplete' $false);$SchedulePendingItems=@(As-Array (Get-P $data 'schedulePendingItems' @()))
    for($pendingIndex=0;$pendingIndex-lt$SchedulePendingItems.Count;$pendingIndex++){if($SchedulePendingItems[$pendingIndex]-isnot[string]-or[string]::IsNullOrWhiteSpace([string]$SchedulePendingItems[$pendingIndex])){Fail 'INVALID_SCHEDULE_PENDING_ITEM' ('schedulePendingItems['+$pendingIndex+']')}}
    $durationUnit=[string](Get-P $data 'durationUnit' 'periods');if($durationUnit-notin@('periods','minutes')){Fail 'INVALID_DURATION_UNIT'}
    $script:CoursesById=@{};foreach($c in $Courses){$id=[string](Get-P $c 'id' '');$display=[string](Get-P $c 'displayType' 'normal');if(-not$id-or$CoursesById.ContainsKey($id)-or$display-notin@('normal','focus')){Fail 'INVALID_COURSE_ID'};$CoursesById[$id]=$c}
    $occupied=@{};$scheduleIndex=-1
    foreach($e in $Schedule){
        $scheduleIndex++;$field='schedule['+$scheduleIndex+']'
        $day=[int](Get-P $e 'day' 0);$slot=[int](Get-P $e 'slot' 0);$blockSpan=[int](Get-P $e 'blockSpan' 0);$periodCount=[int](Get-P $e 'periodCount' 0);$start=[int](Get-P $e 'startWeek' 0);$end=[int](Get-P $e 'endWeek' 0);$parity=[string](Get-P $e 'parity' 'all');$band=[string](Get-P $e 'band' '')
        if($day-lt1-or$day-gt7){Fail 'INVALID_SCHEDULE_DAY' ($field+'.day')};if($slot-lt1){Fail 'INVALID_SCHEDULE_SLOT' ($field+'.slot')};if($blockSpan-lt1){Fail 'INVALID_BLOCK_SPAN' ($field+'.blockSpan')};if($periodCount-lt1){Fail 'INVALID_PERIOD_COUNT' ($field+'.periodCount')}
        if($start-lt1-or$end-lt$start-or$end-gt$TotalWeeks){Fail 'INVALID_SCHEDULE_WEEKS' ($field+'.startWeek/endWeek')};if($parity-notin@('all','odd','even')){Fail 'INVALID_PARITY' ($field+'.parity')};if($band-notin@('morning','afternoon','evening')){Fail 'INVALID_BAND' ($field+'.band')}
        $courseId=[string](Get-P $e 'courseId' '')
        if($courseId-and-not$CoursesById.ContainsKey($courseId)){Fail 'UNKNOWN_SCHEDULE_COURSE_ID' ($field+'.courseId')}
        if(-not(Entry-Name $e)){Fail 'SCHEDULE_COURSE_NAME_REQUIRED' ($field+'.courseName')}
        if([string]::IsNullOrWhiteSpace([string](Get-P $e 'location' ''))){Fail 'SCHEDULE_LOCATION_REQUIRED' ($field+'.location')}
        if($durationUnit-eq'minutes'-and($modules-contains'C')-and[double](Get-P $e 'durationMinutes' 0)-le0){Fail 'DURATION_MINUTES_REQUIRED' ($field+'.durationMinutes')}
        for($w=$start;$w-le$end;$w++){if(-not(Is-Active $e $w)){continue};for($s=$slot;$s-lt$slot+$blockSpan;$s++){$key="$w/$day/$s";if($occupied.ContainsKey($key)){Fail 'SCHEDULE_OVERLAP' $field};$occupied[$key]=$true}}
    }
    if(($modules-contains'B'-or$modules-contains'C')-and$Schedule.Count-eq0){Fail 'SCHEDULE_DATA_REQUIRED'}
    if(($modules-contains'D')-and$Courses.Count-eq0){Fail 'COURSE_DATA_REQUIRED'}
    if(($modules-contains'E')-and@(As-Array (Get-P $data 'milestones' @())).Count-eq0){Fail 'MILESTONE_DATA_REQUIRED'}
    if(($modules-contains'F')-and@(As-Array (Get-P $data 'progress' @())).Count-eq0){Fail 'PROGRESS_DATA_REQUIRED'}
    if(@(As-Array (Get-P $data 'sources' @())).Count-eq0){Fail 'SOURCE_DISPLAY_REQUIRED'}
    $template=[IO.File]::ReadAllText($templateFile,$Utf8NoBom)
    $generated=[string](Get-P $data 'generatedAt' ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm')))
    $template=$template.Replace('{{SEMESTER}}',(Encode-Html $Semester)).Replace('{{TOTAL_WEEKS}}',[string]$TotalWeeks).Replace('{{SUBTITLE}}',(Encode-Html (Get-P $data 'subtitle' ''))).Replace('{{GENERATED_AT}}',(Encode-Html $generated)).Replace('{{COVERAGE}}',(Encode-Html (Get-P $data 'coverage' '')))

    $metricHtml='';foreach($x in As-Array (Get-P $data 'metrics' @())){$metricHtml+='<div class="metric"><span>'+(Encode-Html (Get-P $x 'label' ''))+'</span><strong>'+(Encode-Html (Get-P $x 'value' ''))+'</strong><small>'+(Encode-Html (Get-P $x 'note' ''))+'</small></div>'};$template=$template.Replace('{{METRICS_HTML}}',$metricHtml)

    $controls='<button class="week-button" type="button" data-timetable-week-button="all" aria-pressed="true">&#23398;&#26399;&#24635;&#35272;</button>'
    for($w=1;$w-le$TotalWeeks;$w++){$controls+='<button class="week-button" type="button" data-timetable-week-button="'+$w+'" aria-pressed="false">&#31532;'+$w+'&#21608;</button>'}
    $template=$template.Replace('{{TIMETABLE_WEEK_CONTROLS_HTML}}',$controls)
    $maxSlot=1;foreach($e in $Schedule){$last=[int](Get-P $e 'slot' 1)+[int](Get-P $e 'blockSpan' 1)-1;if($last-gt$maxSlot){$maxSlot=$last}}
    $days=@('&#21608;&#19968;','&#21608;&#20108;','&#21608;&#19977;','&#21608;&#22235;','&#21608;&#20116;','&#21608;&#20845;','&#21608;&#26085;')
    $colon=U @(0xFF1A);$unknownText=U @(0x672A,0x77E5);$timesText=U @(0x6B21);$weekTotalText=U @(0x5468,0x5408,0x8BA1);$smallPeriodText=U @(0x5C0F,0x8282);$openParen=U @(0xFF08);$closeParen=U @(0xFF09)
    function Week-Range($e){
        $label='W'+[int](Get-P $e 'startWeek' 1)+'-'+[int](Get-P $e 'endWeek' 1);$parity=[string](Get-P $e 'parity' 'all')
        if($parity-eq'odd'){$label+=' &#183; &#21333;&#21608;'}elseif($parity-eq'even'){$label+=' &#183; &#21452;&#21608;'};return $label
    }
    function Build-Table($week){
        $caption=if($week-eq'all'){'&#23398;&#26399;&#24635;&#35272;'}else{'&#31532;'+$week+'&#21608;'}
        $items=if($week-eq'all'){@($Schedule)}else{@($Schedule|Where-Object{Is-Active $_ ([int]$week)})}
        $render=[Collections.Generic.List[object]]::new()
        for($day=1;$day-le7;$day++){
            $dayItems=@($items|Where-Object{[int](Get-P $_ 'day' 0)-eq$day}|Sort-Object @{Expression={[int](Get-P $_ 'slot' 0)}},@{Expression={[int](Get-P $_ 'blockSpan' 1)};Descending=$true},@{Expression={[int](Get-P $_ 'startWeek' 1)}})
            $laneEnds=[Collections.Generic.List[int]]::new()
            foreach($e in $dayItems){$start=[int](Get-P $e 'slot' 1);$finish=$start+[int](Get-P $e 'blockSpan' 1)-1;$lane=-1;for($i=0;$i-lt$laneEnds.Count;$i++){if($laneEnds[$i]-lt$start){$lane=$i;break}};if($lane-lt0){$lane=$laneEnds.Count;$laneEnds.Add($finish)}else{$laneEnds[$lane]=$finish};$render.Add([pscustomobject]@{entry=$e;lane=$lane;laneCount=1})}
            $count=[Math]::Max(1,$laneEnds.Count);foreach($r in $render){if([int](Get-P $r.entry 'day' 0)-eq$day){$r.laneCount=$count}}
        }
        $s='<div class="week-view" data-timetable-week-view="'+$week+'"'+$(if($week-ne'all'){' hidden'}else{''})+'><div class="table-scroll" tabindex="0"><div class="schedule-caption">'+$caption+'</div><div class="schedule-grid" style="--slot-count:'+$maxSlot+'"><div class="schedule-head" style="grid-column:1;grid-row:1">&#33410;&#27425;</div>'
        for($day=1;$day-le7;$day++){$s+='<div class="schedule-head" style="grid-column:'+($day+1)+';grid-row:1">'+$days[$day-1]+'</div>'}
        for($slot=1;$slot-le$maxSlot;$slot++){$s+='<div class="schedule-time" style="grid-column:1;grid-row:'+($slot+1)+'">'+(Encode-Html (Slot-Label $slot))+'</div>';for($day=1;$day-le7;$day++){$s+='<div class="schedule-cell" aria-hidden="true" style="grid-column:'+($day+1)+';grid-row:'+($slot+1)+'"></div>'}}
        foreach($r in $render){$e=$r.entry;$name=Entry-Name $e;$id=[string](Get-P $e 'courseId' '');$key=if($id){Stable-Key $id}else{Stable-Key $name};$title='<strong title="'+(A $name)+'">'+(Encode-Html $name)+'</strong>';if($modules-contains'D'-and$id-and$CoursesById.ContainsKey($id)){$title='<a href="#course-'+$key+'">'+$title+'</a>'};$range=if($week-eq'all'){'<span class="week-range">'+(Week-Range $e)+'</span>'}else{''};$s+='<article class="lesson'+$(if(Entry-Focus $e){' focus'}else{''})+'" style="grid-column:'+([int](Get-P $e 'day' 1)+1)+';grid-row:'+([int](Get-P $e 'slot' 1)+1)+' / span '+[int](Get-P $e 'blockSpan' 1)+';--lane:'+$r.lane+';--lane-count:'+$r.laneCount+'">'+$range+$title+'<span>'+(Encode-Html (Get-P $e 'location' ''))+'</span></article>'}
        return $s+'</div></div></div>'
    }
    $views=Build-Table 'all';for($w=1;$w-le$TotalWeeks;$w++){$views+=Build-Table $w};$template=$template.Replace('{{TIMETABLE_VIEWS_HTML}}',$views)

    $mobile='';for($w=1;$w-le$TotalWeeks;$w++){foreach($e in $Schedule){if(-not(Is-Active $e $w)){continue};$name=Entry-Name $e;$id=[string](Get-P $e 'courseId' '');$key=if($id){Stable-Key $id}else{Stable-Key $name};$timeLabel=Slot-Label ([int](Get-P $e 'slot' 1));$mobile+='<div data-mobile-entry data-week="'+$w+'" data-day="'+[int](Get-P $e 'day' 1)+'" data-slot="'+[int](Get-P $e 'slot' 1)+'" data-span="'+[int](Get-P $e 'blockSpan' 1)+'" data-periods="'+[int](Get-P $e 'periodCount' 1)+'" data-band="'+(A (Get-P $e 'band' 'morning'))+'" data-course-key="'+$key+'"><span class="mobile-course-name">'+(Encode-Html $name)+'</span><span class="mobile-time-label">'+(Encode-Html $timeLabel)+'</span><span class="mobile-location">'+(Encode-Html (Get-P $e 'location' ''))+'</span></div>'}}
    $template=$template.Replace('{{MOBILE_SCHEDULE_DATA_HTML}}',$mobile)

    $nav='<nav class="course-nav" aria-label="&#35838;&#31243;&#24555;&#36895;&#23548;&#33322;">';$courseHtml=''
    foreach($c in $Courses){$id=[string](Get-P $c 'id' '');$key=Stable-Key $id;$name=[string](Get-P $c 'name' '');$nav+='<a href="#course-'+$key+'">'+(Encode-Html $name)+'</a>';$courseHtml+='<article class="course" id="course-'+$key+'"><div class="course-head"><h3>'+(Encode-Html $name)+'</h3><span class="tag'+$(if(([string](Get-P $c 'displayType' 'normal'))-eq'focus'){' focus'}else{''})+'">'+$(if(([string](Get-P $c 'displayType' 'normal'))-eq'focus'){'&#37325;&#28857;&#35838;&#31243;'}else{'&#26222;&#36890;&#35838;&#31243;'})+'</span></div><p>'+(Encode-Html (Get-P $c 'summary' ''))+'</p><dl>';foreach($d in As-Array (Get-P $c 'details' @())){$courseHtml+='<dt>'+(Encode-Html (Get-P $d 'label' ''))+'</dt><dd>'+(Encode-Html (Get-P $d 'value' ''))+'</dd>'};$courseHtml+='</dl><p class="source">'+(Encode-Html (Get-P $c 'source' ''))+'</p></article>'};$nav+='</nav>'
    $template=$template.Replace('{{COURSE_NAV_HTML}}',$nav).Replace('{{COURSES_HTML}}',$courseHtml)

    $events='';foreach($e in As-Array (Get-P $data 'milestones' @())){$pending=[bool](Get-P $e 'pending' $false);$events+='<li class="event'+$(if($pending){' pending'}else{''})+'"><div class="event-time">'+(Encode-Html (Get-P $e 'when' ''))+'</div><div><h3>'+(Encode-Html (Get-P $e 'title' ''))+'</h3><p>'+(Encode-Html (Get-P $e 'detail' ''))+'</p></div></li>'};$template=$template.Replace('{{MILESTONES_HTML}}',$events)

    $weeklyCounts=@{};$weeklyPeriods=@{};$dailyCounts=@{};$lastScheduledWeek=0
    for($w=1;$w-le$TotalWeeks;$w++){$weeklyCounts[$w]=0;$weeklyPeriods[$w]=0;for($day=1;$day-le7;$day++){$dayEntries=@($Schedule|Where-Object{[int](Get-P $_ 'day' 0)-eq$day-and(Is-Active $_ $w)});$dailyCounts["$w/$day"]=$dayEntries.Count;$weeklyCounts[$w]+=$dayEntries.Count;foreach($e in $dayEntries){$weeklyPeriods[$w]+=[int](Get-P $e 'periodCount' 1)};if($dayEntries.Count){$lastScheduledWeek=[Math]::Max($lastScheduledWeek,$w)}}}
    $maxWeeklyCount=($weeklyCounts.Values|Measure-Object -Maximum).Maximum;if($null-eq$maxWeeklyCount){$maxWeeklyCount=0};$scheduleCompleteForZeros=$CoverageComplete-and$SchedulePendingItems.Count-eq0
    $heat='<table class="heatmap"><thead><tr><th>&#26085;</th>';for($w=1;$w-le$TotalWeeks;$w++){$heat+='<th>'+$w+'</th>'};$heat+='</tr></thead><tbody>'
    for($day=1;$day-le7;$day++){$heat+='<tr data-day="'+$day+'"><th>'+$days[$day-1]+'</th>';for($w=1;$w-le$TotalWeeks;$w++){$count=[int]$dailyCounts["$w/$day"];$unknown=$count-eq0-and-not$scheduleCompleteForZeros;$level=if($unknown){'unknown'}else{[string][Math]::Min(4,$count)};$label=if($unknown){'W'+$w+' '+[Net.WebUtility]::HtmlDecode($days[$day-1])+$colon+$unknownText}else{'W'+$w+' '+[Net.WebUtility]::HtmlDecode($days[$day-1])+$colon+$count+$timesText};$heat+='<td data-week="'+$w+'"><span class="heat-square heat-'+$level+'" role="img" title="'+(A $label)+'" aria-label="'+(A $label)+'"><span class="sr-only">'+(Encode-Html $label)+'</span></span></td>'};$heat+='</tr>'}
    $heat+='<tr class="week-total"><th>&#21608;&#21512;&#35745;</th>';for($w=1;$w-le$TotalWeeks;$w++){$count=[int]$weeklyCounts[$w];$unknown=$count-eq0-and-not$scheduleCompleteForZeros;$level=if($unknown){'unknown'}elseif($count-eq0-or$maxWeeklyCount-eq0){'0'}else{[string][Math]::Max(1,[Math]::Ceiling(4*$count/$maxWeeklyCount))};$label=if($unknown){'W'+$w+' '+$weekTotalText+$colon+$unknownText}else{'W'+$w+' '+$weekTotalText+$colon+$count+$timesText};$heat+='<td data-week="'+$w+'"><span class="heat-square heat-'+$level+'" role="img" title="'+(A $label)+'" aria-label="'+(A $label)+'"><span class="sr-only">'+(Encode-Html $label)+'</span></span></td>'};$heat+='</tr></tbody></table><div class="heat-legend"><span>&#23569;</span><i class="heat-square heat-0"></i><i class="heat-square heat-1"></i><i class="heat-square heat-2"></i><i class="heat-square heat-3"></i><i class="heat-square heat-4"></i><span>&#22810;</span><i class="heat-square heat-unknown"></i><span>&#26410;&#30693;</span></div>';$template=$template.Replace('{{HEATMAP_HTML}}',$heat)
    function Stat-Card([string]$label,[string[]]$values,[string]$note){$first=if($values.Count){$values[0]}else{U @(0x65E0,0x5DF2,0x77E5,0x6570,0x636E)};$more='';if($values.Count-gt1){$more='<details><summary>&#26597;&#30475;&#20840;&#37096; '+$values.Count+' &#39033;</summary>'+(($values|ForEach-Object{Encode-Html $_})-join'<br>')+'</details>'};return '<div class="heat-stat"><span>'+$label+'</span><strong>'+(Encode-Html $first)+'</strong>'+$(if($note){'<small>'+$note+'</small>'}else{''})+$more+'</div>'}
    $maxPeriods=($weeklyPeriods.Values|Measure-Object -Maximum).Maximum;$busyWeeks=@();for($w=1;$w-le$TotalWeeks;$w++){if([int]$weeklyPeriods[$w]-eq[int]$maxPeriods){$busyWeeks+=('W'+$w+$openParen+$weeklyPeriods[$w]+$smallPeriodText+' / '+$weeklyCounts[$w]+$timesText+$closeParen)}}
    $maxDaily=($dailyCounts.Values|Measure-Object -Maximum).Maximum;$busyDays=@();for($w=1;$w-le$TotalWeeks;$w++){for($day=1;$day-le7;$day++){if([int]$dailyCounts["$w/$day"]-eq[int]$maxDaily){$busyDays+=('W'+$w+' '+[Net.WebUtility]::HtmlDecode($days[$day-1])+$openParen+$maxDaily+$timesText+$closeParen)}}}
    if($CoverageComplete-and$SchedulePendingItems.Count-eq0){$lastText=if($lastScheduledWeek-lt$TotalWeeks){'W'+($lastScheduledWeek+1)+(U @(0x8D77,0x65E0,0x5DF2,0x6392,0x8BFE,0x7A0B))}else{(U @(0x8BFE,0x7A0B,0x5DF2,0x6392,0x81F3))+'W'+$lastScheduledWeek};$lastNote=U @(0x8BFE,0x8868,0x6807,0x8BB0,0x4E3A,0x5B8C,0x6574,0xFF0C,0x4E14,0x6CA1,0x6709,0x672A,0x5B9A,0x4F4D,0x6392,0x8BFE,0x4E8B,0x9879)}else{$lastText=(U @(0x5F53,0x524D,0x8D44,0x6599,0x6700,0x540E,0x6392,0x8BFE,0x81F3))+'W'+$lastScheduledWeek+(U @(0xFF0C,0x540E,0x7EED,0x5F85,0x786E,0x8BA4));$lastNote=if($SchedulePendingItems.Count){(U @(0x53E6,0x6709))+$SchedulePendingItems.Count+(U @(0x9879,0x672A,0x5B9A,0x4F4D,0x6392,0x8BFE,0x4E8B,0x9879))}else{U @(0x8BFE,0x8868,0x8986,0x76D6,0x8303,0x56F4,0x672A,0x6807,0x8BB0,0x4E3A,0x5B8C,0x6574)}}
    $heatStats=(Stat-Card '&#35838;&#26102;&#26368;&#22810;&#30340;&#21608;' $busyWeeks '&#25353;&#23454;&#38469;&#23567;&#33410;&#25968;&#35745;&#31639;')+(Stat-Card '&#35838;&#31243;&#27425;&#25968;&#26368;&#22810;&#30340;&#19968;&#22825;' $busyDays '&#36830;&#22530;&#35745;&#19968;&#27425;')+(Stat-Card '&#26368;&#21518;&#24050;&#25490;&#35838;&#21608;' @($lastText) $lastNote);$template=$template.Replace('{{HEATMAP_STATS_HTML}}',$heatStats)
    $durationControls='';$durationCharts='';$unit=$durationUnit;$weeks=@{};$globalMax=0
    for($w=1;$w-le$TotalWeeks;$w++){$vals=@();for($day=1;$day-le7;$day++){$normal=0;$focus=0;foreach($e in $Schedule){if([int](Get-P $e 'day' 0)-ne$day-or-not(Is-Active $e $w)){continue};$v=if($unit-eq'minutes'){[double](Get-P $e 'durationMinutes' 0)}else{[double](Get-P $e 'periodCount' 1)};if(Entry-Focus $e){$focus+=$v}else{$normal+=$v}};$total=$normal+$focus;if($total-gt$globalMax){$globalMax=$total};$vals+=,[pscustomobject]@{normal=$normal;focus=$focus;total=$total}};$weeks[$w]=$vals}
    if($globalMax-le0){$globalMax=1}
    for($w=1;$w-le$TotalWeeks;$w++){$durationControls+='<button class="week-button" type="button" data-duration-week-button="'+$w+'" aria-pressed="'+$(if($w-eq1){'true'}else{'false'})+'">'+$w+'</button>';$durationCharts+='<div class="duration-view" data-duration-week-view="'+$w+'"'+$(if($w-ne1){' hidden'}else{''})+'>';for($day=1;$day-le7;$day++){$v=$weeks[$w][$day-1];$durationCharts+='<div class="day-bar"><span>'+$days[$day-1]+'</span><div class="bar-track"><i class="bar normal" style="width:'+([Math]::Round(100*$v.normal/$globalMax,2))+'%"></i><i class="bar focus" style="width:'+([Math]::Round(100*$v.focus/$globalMax,2))+'%"></i></div><strong>'+(Encode-Html $v.total)+' '+$(if($unit-eq'minutes'){'min'}else{'&#23567;&#33410;'})+'</strong></div>'};$durationCharts+='</div>'};$template=$template.Replace('{{DURATION_WEEK_CONTROLS_HTML}}',$durationControls).Replace('{{DURATION_CHART_HTML}}',$durationCharts).Replace('{{DURATION_SCALE_NOTE}}',('&#20840;&#23398;&#26399;&#26368;&#22823;&#26085;&#35838;&#31243;&#37327;&#65306;'+$globalMax+' '+$(if($unit-eq'minutes'){'min'}else{'&#23567;&#33410;'})))

    $progress='';foreach($p in As-Array (Get-P $data 'progress' @())){$progress+='<article class="progress-item"><span>'+(Encode-Html (Get-P $p 'label' ''))+'</span><strong>'+(Encode-Html (Get-P $p 'value' ''))+'</strong><p>'+(Encode-Html (Get-P $p 'note' ''))+'</p></article>'};$template=$template.Replace('{{PROGRESS_HTML}}',$progress)
    $sources='<ol>';foreach($s in As-Array (Get-P $data 'sources' @())){$sources+='<li><strong>'+(Encode-Html (Get-P $s 'file' ''))+'</strong> '+(Encode-Html (Get-P $s 'location' ''))+'<br>'+(Encode-Html (Get-P $s 'note' ''))+'</li>'};$sources+='</ol><p>'+(Encode-Html (Get-P $data 'gaps' ''))+'</p>';$template=$template.Replace('{{SOURCES_HTML}}',$sources)

    if($modules-notcontains'B'){$template=[regex]::Replace($template,'(?s)<!--MODULE_B_START-->.*?<!--MODULE_B_END-->','')}
    elseif($modules-notcontains'G'){$template=[regex]::Replace($template,'(?s)<!--MODULE_G_START-->.*?<!--MODULE_G_END-->','')}
    if($modules-notcontains'C'){$template=[regex]::Replace($template,'(?s)<!--MODULE_C_START-->.*?<!--MODULE_C_END-->','')}
    if($modules-notcontains'D'){$template=[regex]::Replace($template,'(?s)<!--MODULE_D_START-->.*?<!--MODULE_D_END-->','')}
    if($modules-notcontains'E'){$template=[regex]::Replace($template,'(?s)<!--MODULE_E_START-->.*?<!--MODULE_E_END-->','')}
    if($modules-notcontains'F'){$template=[regex]::Replace($template,'(?s)<!--MODULE_F_START-->.*?<!--MODULE_F_END-->','')}
    if($template-match'\{\{[A-Z0-9_]+\}\}'){Fail 'UNRESOLVED_TEMPLATE_TOKEN'}
    $humanFolder=$layout.Human;$semesterFolder=$layout.Semester;$dashboardName=(U @(0x5B66,0x671F,0x89C4,0x5212))+'.html'
    $semesterDir=[IO.Path]::Combine($root,$humanFolder,$semesterFolder,$Semester);$out=[IO.Path]::Combine($semesterDir,$dashboardName)
    Assert-Within $root $out
    if($ValidateOnly){[ordered]@{status='valid';schemaVersion=2;semester=$Semester;modules=$modules;courses=$Courses.Count;scheduleEntries=$Schedule.Count}|ConvertTo-Json -Compress|Write-Output;exit 0}
    if([IO.File]::Exists($out)-and-not$Overwrite){Fail 'OUTPUT_EXISTS'}
    [IO.Directory]::CreateDirectory($semesterDir)|Out-Null;$tmpOut=$out+'.tmp';$backupOut=$out+'.bak';$outExisted=[IO.File]::Exists($out)
    foreach($stale in @($tmpOut,$backupOut)){if([IO.File]::Exists($stale)){[IO.File]::Delete($stale)}}
    [IO.File]::WriteAllText($tmpOut,$template,$Utf8NoBom)
    try{
        if($outExisted){[IO.File]::Replace($tmpOut,$out,$backupOut,$true)}else{[IO.File]::Move($tmpOut,$out)}
    }catch{
        if([IO.File]::Exists($backupOut)){[IO.File]::Copy($backupOut,$out,$true)}elseif(-not$outExisted-and[IO.File]::Exists($out)){[IO.File]::Delete($out)}
        throw
    }finally{foreach($stale in @($tmpOut,$backupOut)){if([IO.File]::Exists($stale)){[IO.File]::Delete($stale)}}}
    [ordered]@{status='created';output=$out;modules=$modules}|ConvertTo-Json -Compress|Write-Output
}catch{$code=$_.Exception.Message;if($code-match'^[A-Z0-9_]+$'){Fail $code};Fail 'DASHBOARD_BUILD_FAILED'}

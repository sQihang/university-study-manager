# 学期看板输入协议

常规生成只需读取本文件和最小示例，不读取生成器源码。输入采用UTF-8 JSON，`schemaVersion`固定为2。

## 目录

- [顶层字段](#顶层字段)
- [课表字段](#课表字段)
- [校验规则](#校验规则)

## 顶层字段

|字段|要求|
|---|---|
|`schemaVersion`|必须为2|
|`semester`|`YYYY-YYYY-1`或`YYYY-YYYY-2`，与命令参数一致|
|`totalWeeks`|1至30|
|`modules`|A至G；A必选，G要求B|
|`scheduleCoverageComplete`|课表是否完整；不完整时空白格显示未知|
|`schedulePendingItems`|可选的非空字符串数组；记录已知存在但尚未定位到星期和大节的课程、补课等；数组非空时空白格也显示未知|
|`durationUnit`|`periods`或`minutes`|
|`slotLabels`|大节编号到统一时间标题的映射|
|`courses`、`schedule`|课程和课表；使用B、C、D、G时按模块提供|
|`milestones`、`progress`|模块E、F的数据|
|`sources`、`gaps`|页面展示的来源与缺口|

`metrics`、`subtitle`、`coverage`、`generatedAt`为可选展示字段。用户文本始终作为字符串传入，生成器负责HTML转义。

## 课表字段

每条`schedule`必须包含：

```json
{
  "courseId": "BIOCHEM",
  "day": 2,
  "slot": 2,
  "blockSpan": 1,
  "periodCount": 2,
  "durationMinutes": 100,
  "band": "morning",
  "location": "九教南305",
  "startWeek": 1,
  "endWeek": 16,
  "parity": "all"
}
```

- `day`为1至7；`slot`是开始大节。
- `blockSpan`是占用的大节数。普通两小节课程通常为1，连续四小节通常为2。
- `periodCount`是实际小节数，用于按小节统计。
- `durationMinutes`只在`durationUnit=minutes`且使用模块C时必填。
- `band`为`morning`、`afternoon`或`evening`。
- `location`必须有值；未知时使用明显占位文本，不静默留空。
- `parity`为`all`、`odd`或`even`。
- 课程名称由对应`courses[].name`取得；无`courseId`时可直接提供`courseName`。

## 校验规则

同一周、星期和大节不能有重叠课程。周次必须在总周数内；课程ID必须存在；所选模块的依赖数据不能为空。课程格不传重复时间文字，时间只由`slotLabels`显示。只有`scheduleCoverageComplete=true`且`schedulePendingItems`为空时，页面才会把最后排课周之后显示为“无已排课程”；否则统一标为待确认。

`-ValidateOnly`成功后才正式生成。错误码指出缺失或冲突类型；不要通过删除数据绕开校验。输出固定为`01-资料库/03-学期资料/<学期>/学期规划.html`。

`-ValidateOnly`检查字段要求、周次范围、课程关联及排课冲突等输入约束，不读取原课表来核对课程、周次、节次或地点是否抄写正确，也不证明首次提取准确。填充数据须依据选定来源；交付时按入口规则提示用户核对原件，如实说明已完成的检查。沿用本协议，不为核验提示增加 schema 字段。

$p='C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\parsed\us_threads_shredded.json'
$doc = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
"doc type: $($doc.GetType().FullName)"
"doc count: $($doc.Count)"
$hasRows = [bool]$doc.rows
"doc.rows truthy: $hasRows"
$rowsRaw = if ($doc.rows) { $doc.rows } else { $doc }
"rowsRaw count: $($rowsRaw.Count)"
$r0 = $rowsRaw[0]
"r0 type: $($r0.GetType().FullName)"
"r0.id = [$($r0.id)]  r0.thread_id=[$($r0.thread_id)]"
"r0.stack len = $($r0.stack.Length)"

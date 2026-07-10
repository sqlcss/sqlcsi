$txt = 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_dump_overall\txt_detail\2607030030000843_us.txt'
$heads = Select-String -Path $txt -Pattern '^\s*(\d+)\s+thread(s)?\s+\[stats\]:' | ForEach-Object { $_.Line }
$totalDeclared = ($heads | ForEach-Object { [int]([regex]::Match($_, '^\s*(\d+)\s+thread').Groups[1].Value) } | Measure-Object -Sum).Sum
$allIds = (Select-String -Path $txt -Pattern '(\d+)\s*\[!mex\.t' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value }
$uniqIds = $allIds | Sort-Object {[int]$_} -Unique
"groups=$($heads.Count)  declared_thread_sum=$totalDeclared  id_tokens=$($allIds.Count)  unique_ids=$($uniqIds.Count)"
"top group sizes:"
$heads | ForEach-Object { [int]([regex]::Match($_,'^\s*(\d+)').Groups[1].Value) } | Sort-Object -Descending | Select-Object -First 5

---
name: sqlinsight-analysis
description: 使用 SqlScriptRepl.exe + 自研 SqlInsightBridge.dll 在 SQL Server dump 上跑 SQLInsight 分析器 (LatchTimeout 等)。绕过 DumpViewer.exe GUI，允许 headless 脚本化执行与自定义 C# 分析代码注入。当用户说 "跑 sqlinsight"、"用 SqlScriptRepl 分析 dump"、"运行 LatchTimeout"、"headless dump viewer"、"注入自己的分析器" 时使用。
---

# SQLInsight 分析 (SqlScriptRepl 桥接)

## 定位

**这是一条"跑 SQLInsight 分析器"的通道**，用于对 SQL Server dump 执行 `CsDebugScript.DumpViewer.*` 里的分析器（如 `LatchTimeout.Analyze`、`NonYieldStallAnalysis`、`SummaryPage`），或注入我们自己的 C# 分析代码 —— 全部 headless、可脚本化。

**为什么不用 DumpViewer.exe GUI**：
- 无法脚本化 / 无输出捕获
- 遇到 bug (如 `latch.LatchBase is null`) 时无法插桩、无法回退

**为什么用 SqlScriptRepl.exe 而非自己写 launcher**：
- SqlScriptRepl 已经完成了所有繁重的初始化：dbgeng 加载、符号加载、SqlCsScripts 发现、debug client 生命周期管理
- 我们只需要写一个 **200 行的桥接 DLL** 就能注入任意 C# 代码

## 工作原理

```
   ┌──────────────────────────────────────────────────────┐
   │  SqlScriptRepl.exe                                   │
   │    ├─ 加载 dump + 符号                                │
   │    ├─ 从 -scripts <bridge.dll> 载入我们的 DLL         │
   │    ├─ 用 [Script] attribute 扫描并发现类              │
   │    ├─ REPL 循环: "Class.Method" -> 调用无参静态方法     │
   │    └─ Bridge 类内部再调用真正带参的分析器              │
   └──────────────────────────────────────────────────────┘
```

**关键约束**（IL 反编译得到）：
- `CsScriptExecutor.ExecuteScript(class, method)` 只能调用 **无参 public static** 方法
- 类必须带 `[CsDebugScript.Common.ScriptAttribute(...)]`
- Mini-dump 必须使用支持 mini-dump 的 attribute 构造函数（例如 `[Script(true /*allowMiniDump*/)]`）
- REPL 用 **简单类名** 匹配（不是 FullName）

**桥接机制** (`SqlInsightBridge.dll`)：
- 每个包装类都是 `[Script(true)]` 装饰的 `public static class`，只有 `public static void 方法名()`
- 方法内部读环境变量 `SQLINSIGHT_OUT`（报告目录）
- 首次调用时 `BridgeLoader.Hydrate()` 从 `SQLINSIGHT_MIRROR` 目录 `Assembly.LoadFrom` 加载 `SqlCsScripts.dll` + `SqlDebugTypes.dll`（DumpViewer 分析器运行时的依赖）

## 一次性准备

### 1. 建立 mirror 目录（放置 SqlCsScripts.dll + SqlDebugTypes.dll）

```powershell
pwsh -File .github/skills/sqlinsight-analysis/scripts/Setup-Mirror.ps1
# 默认目标: C:\Users\lduan\sqlcsi-archive\mirror
```

### 2. 构建桥接 DLL

```powershell
pwsh -File .github/skills/sqlinsight-analysis/bridge/build.ps1
# 生成: .github/skills/sqlinsight-analysis/bridge/SqlInsightBridge.dll
```

前提：
- 已安装 .NET SDK（`dotnet` 命令可用）
- `C:\Users\lduan\tools\DumpViewer\` 存在 `DumpViewer.exe` + `CsDebugScript.*.dll`
- 如果 DumpViewer 目录不同，加参数 `-DumpViewerDir <path>`

## 使用（对一个 dump 跑 Latch 分析）

```powershell
pwsh -File .github/skills/sqlinsight-analysis/scripts/Invoke-SqlInsight.ps1 `
    -Dump   'C:\Temp\2607030030000843\SQLDump0001.mdmp' `
    -OutDir 'C:\Users\lduan\sqlcsi-archive\reports\2607030030000843_latch_timeout\sqlinsight'
```

默认执行 `Bridge.Ping` + `Latch.Analyze`，然后 `exit`。日志写到 `<OutDir>\sqlscriptrepl.out`，Latch 报告写到 `<OutDir>\Reports\LatchTimeout\`。

**运行自定义命令列表**：

```powershell
pwsh -File .github/skills/sqlinsight-analysis/scripts/Invoke-SqlInsight.ps1 `
    -Dump 'C:\path\dump.mdmp' -OutDir 'C:\reports\case1' `
    -Commands @('Bridge.Ping','Latch.Analyze','Tasks.Enumerate')
```

## 输出解读

成功时日志包含：

```
[REPL] Loaded C:\...\SqlInsightBridge.dll
[INFO] Discovered N scripts.              <- N ≥ 桥接类数量
mirror> [INFO] Found Bridge.Ping, Invoking ...
[Bridge] Loaded SqlDebugTypes             <- Hydrate() 成功
[Bridge] Loaded SqlCsScripts
[Bridge.Ping] Hello from SqlInsightBridge.dll
mirror> [INFO] Found Latch.Analyze, Invoking ...
[Bridge.Latch] outDir=C:\...
[INFO] Analyzing latch timeout ...
[Bridge.Latch] OK
```

## 已知问题 & 回退方案

### Mini-dump 触发 `latch.LatchBase is null`

`CsDebugScript.DumpViewer.LatchTimeout.AddLatch(StackFrame)` 在 mini-dump 上会命中：

```
System.Exception: latch.LatchBase is null
   at CsDebugScript.DumpViewer.LatchTimeout.AddLatch(StackFrame frame)
   at CsDebugScript.DumpViewer.LatchTimeout.PickupLatchFromThreadLocal()
```

我们的桥接的 `Latch.Analyze` 内部 try/catch，所以 REPL 会记录 `[Bridge.Latch] OK` 但报告不完整。**回退**：调用现有的 [latch-timeout-analysis](../latch-timeout-analysis/SKILL.md) 技能，该技能使用 cdb dscript sweep 直接从线程栈提取 latch 状态。

### `-scripts` 只接受单一 DLL

真实的 `SqlCsScripts.dll` 里有 35 个 `[Script]` 类型（Tasks / SOSRingBuffers / Contexts 等）。若你想直接用它们，把 `SqlCsScripts.dll` 传给 `-scripts` 即可（前提是它同目录有 `SqlDebugTypes.dll`）：

```powershell
& $repl -f $dump -o $out -scripts 'C:\...\mirror\SqlCsScripts.dll'
```

**桥接与真实脚本不能同时通过 `-scripts` 加载**（只能给一个路径）。当前架构采用的策略：`-scripts` 给桥接，桥接 `Hydrate()` 时把真实 SqlCsScripts 拉入 AppDomain —— 这样 `Latch.Analyze` 里调用 `LatchTimeout.Analyze` 时它对 SqlCsScripts 类型的依赖能被解析，但**真实 SqlCsScripts 的 35 个类型不会出现在 `Discovered N scripts` 的可执行列表里**（因为 REPL 只扫描 `-scripts` 指定的那一个 assembly）。

如果要执行真实 SqlCsScripts 的脚本（如 `Tasks.Enumerate`），换成传 `SqlCsScripts.dll` 给 `-scripts` 即可 —— 但那样就无法调用 `LatchTimeout.Analyze` 之类需要参数的分析器。**两种模式互斥，按需选择**。

## 扩展：添加新的桥接类

在 `bridge/SqlInsightBridge.cs` 里加一个类：

```csharp
[Script(true /*allowMiniDump*/)]
public static class NonYieldStall
{
    public static void Analyze()
    {
        BridgeLoader.Hydrate();
        var outDir = BridgeCommon.ResolveOutDir();
        Console.WriteLine("[Bridge.NonYieldStall] outDir=" + outDir);
        try
        {
            // NonYieldStallAnalysis 构造函数需要 (string, NonYieldingOutput, string)
            // — 具体参数装配见 SQLInsight 源码
            // new NonYieldStallAnalysis(outDir, output, "…").Run();
        }
        catch (Exception ex) { Console.WriteLine("[Bridge.NonYieldStall] FAILED " + ex); }
    }
}
```

重新 `bridge\build.ps1`，重新跑 `Invoke-SqlInsight.ps1` 时加上 `-Commands @('NonYieldStall.Analyze')`。

## 关键事实（IL 反编译得来，将来别再重新推导）

| 事实 | 来源 |
|------|------|
| Discovery attribute = `CsDebugScript.Common.ScriptAttribute` | `SqlCsScripts.dll` 里 117 个 class 携带此 attribute |
| Discovery delegate = `CsDebugScript.Common.ScriptDiscovery.DiscoverRunnableScripts(Assembly, bool)` | Reflection on `CsDebugScript.Common.dll` |
| `CsScriptExecutor.ExecuteScript(cls, method)` 只调用 **无参 public static** 方法 | `DiscoverScripts` / `ExecuteScript` IL |
| REPL "Class.Method" 里 Class 是**简单名**（非 FullName） | ExecuteScript IL：`Type.Name` 比较 |
| `-scripts <path>` **替代**（而非追加）自动检测的 SqlCsScripts | Program.Main IL |
| SqlScriptRepl 不需要管理员权限 | 无 Win32 manifest；registry 警告非致命 |
| `SqlDebugTypes.dll` 必须与 `SqlCsScripts.dll` 同目录（无论哪个被 `-scripts` 指定） | 观测：不同目录 → `Could not load file or assembly 'SqlDebugTypes'` |
| `[Script(true)]` = allowMiniDump=true | ScriptAttribute 构造函数列表 |

## 相关技能

- [latch-timeout-analysis](../latch-timeout-analysis/SKILL.md) — 当 `Latch.Analyze` 因 `latch.LatchBase is null` 无法产生完整报告时的 cdb 回退
- [dump-analysis](../dump-analysis/SKILL.md) — 通用 dump 分析（cdb + SqlCsScripts/Mirrors 直接查询）

## 报告输出目录

按 `.github/copilot-instructions.md` 约定：`C:\Users\lduan\sqlcsi-archive\reports\<case_id>_<brief>\sqlinsight\`

using System;
using System.IO;
using System.Reflection;
using CsDebugScript.Common;
using CsDebugScript.DumpViewer;

// SqlInsightBridge — no-arg [Script]-decorated wrappers so SqlScriptRepl's
// CsScriptExecutor (which only supports "Class.NoArgMethod") can invoke
// DumpViewer SQLInsight analyzers that require arguments (e.g. reportFolder).
//
// Runtime wiring (environment variables):
//   SQLINSIGHT_OUT     -> report output folder (falls back to DumpViewer.ReportFolder)
//   SQLINSIGHT_MIRROR  -> folder containing SqlCsScripts.dll + SqlDebugTypes.dll
//                          (hydrated on first bridge call so analyzers work)
//
// Usage (from the REPL):
//   Bridge.Ping          -> sanity probe, prints loaded state
//   Latch.Analyze        -> runs LatchTimeout.Analyze(outDir)

internal static class BridgeLoader
{
    private static bool _hydrated;
    public static void Hydrate()
    {
        if (_hydrated) return;
        _hydrated = true;
        var mirror = Environment.GetEnvironmentVariable("SQLINSIGHT_MIRROR");
        if (string.IsNullOrEmpty(mirror)) { Console.WriteLine("[Bridge] SQLINSIGHT_MIRROR not set"); return; }
        foreach (var name in new[] { "SqlDebugTypes.dll", "SqlCsScripts.dll" })
        {
            var full = Path.Combine(mirror, name);
            if (File.Exists(full))
            {
                try { var a = Assembly.LoadFrom(full); Console.WriteLine("[Bridge] Loaded " + a.GetName().Name); }
                catch (Exception ex) { Console.WriteLine("[Bridge] Load " + name + " failed: " + ex.Message); }
            }
            else { Console.WriteLine("[Bridge] Missing " + full); }
        }
    }
}

internal static class BridgeCommon
{
    public static string ResolveOutDir()
    {
        var env = Environment.GetEnvironmentVariable("SQLINSIGHT_OUT");
        if (!string.IsNullOrEmpty(env)) return env;
        var rf = DumpViewer.ReportFolder;
        if (!string.IsNullOrEmpty(rf)) return rf;
        return Path.GetTempPath();
    }
}

[Script(true /*allowMiniDump*/)]
public static class Latch
{
    public static void Analyze()
    {
        BridgeLoader.Hydrate();
        var outDir = BridgeCommon.ResolveOutDir();
        Console.WriteLine("[Bridge.Latch] outDir=" + outDir);
        try
        {
            LatchTimeout.Analyze(outDir);
            Console.WriteLine("[Bridge.Latch] OK");
        }
        catch (Exception ex)
        {
            Console.WriteLine("[Bridge.Latch] FAILED " + ex.GetType().FullName + ": " + ex.Message);
            Console.WriteLine(ex.ToString());
        }
    }
}

[Script(true /*allowMiniDump*/)]
public static class Bridge
{
    public static void Ping()
    {
        BridgeLoader.Hydrate();
        Console.WriteLine("[Bridge.Ping] Hello from SqlInsightBridge.dll");
        Console.WriteLine("[Bridge.Ping] SQLINSIGHT_OUT    = " + (Environment.GetEnvironmentVariable("SQLINSIGHT_OUT") ?? "<null>"));
        Console.WriteLine("[Bridge.Ping] SQLINSIGHT_MIRROR = " + (Environment.GetEnvironmentVariable("SQLINSIGHT_MIRROR") ?? "<null>"));
        Console.WriteLine("[Bridge.Ping] DumpViewer.ReportFolder = " + (DumpViewer.ReportFolder ?? "<null>"));
        Console.WriteLine("[Bridge.Ping] Loaded (SQL-related):");
        foreach (var a in AppDomain.CurrentDomain.GetAssemblies())
        {
            var nm = a.GetName().Name;
            if (nm == "DumpViewer" || nm == "SqlCsScripts" || nm == "SqlDebugTypes" ||
                nm == "SqlInsightBridge" || nm.StartsWith("CsDebugScript"))
            {
                Console.WriteLine("  " + nm + " " + a.GetName().Version);
            }
        }
    }
}

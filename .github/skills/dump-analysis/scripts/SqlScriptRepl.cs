// SqlScriptRepl - Interactive REPL host that loads a SQL Server dump using the
// DumpViewer engine (self-hosted CsDebugScript, CodeGen works out of process),
// then lets you run arbitrary mirror scripts by name -- the equivalent of
// interactive WinDbg  !execute <Class>.<Method>  but without the dbgeng command loop.
//
// Reuses the INSTALLED DumpViewer.exe as a library:
//   DumpViewerConfig -> DumpViewer.Init -> LoadSqlScriptAssemblies -> CsScriptExecutor
//
// Build (x64, net472) into the DumpViewer folder so sibling deps resolve at runtime.
// C# 5 compatible (in-box Framework csc.exe). No 'dynamic', no string interpolation.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using CsDebugScript.Common;   // ScriptDiscovery
using CsDebugScript.Utils;    // InfoLoggerManager
using CsDebugScript.DumpViewer; // DumpViewer, DumpViewerConfig, CsScriptExecutor, Constants, Logger

namespace SqlScriptRepl
{
    public static class Program
    {
        // Assemblies loaded directly from the dump's LOG folder (version-matched mirror pair),
        // used to bypass the symbol-server manifest download when symweb lacks the manifest.
        private static readonly Dictionary<string, Assembly> _localAsm =
            new Dictionary<string, Assembly>(StringComparer.OrdinalIgnoreCase);
        private static string _dumpViewerDir;

        public static int Main(string[] args)
        {
            _dumpViewerDir = AppDomain.CurrentDomain.BaseDirectory;
            string cfgPath = System.IO.Path.Combine(_dumpViewerDir, "DumpViewerConfig.xml");

            // Optional: -scripts <path-to-SqlCsScripts.dll> to load mirror scripts locally
            // (bypasses symbol-server manifest download). Stripped before DumpViewerConfig parses args.
            string scriptsDllPath = null;
            List<string> passArgs = new List<string>();
            for (int i = 0; i < args.Length; i++)
            {
                if (string.Equals(args[i], "-scripts", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    scriptsDllPath = args[i + 1];
                    i++;
                }
                else
                {
                    passArgs.Add(args[i]);
                }
            }
            args = passArgs.ToArray();

            DumpViewerConfig config = new DumpViewerConfig(args, cfgPath);
            if (!config.Init())
            {
                Console.WriteLine("[REPL] Config init failed.");
                Console.WriteLine("Usage: SqlScriptRepl.exe -f \"<dump>\" -o \"<out>\" [-s \"<symbolpath>\"]");
                return 1;
            }

            Logger.SetLogger(new InfoLoggerManager(config.LogFilePath));

            DumpViewer dv = new DumpViewer(config);
            if (!dv.Init(Constants.SqlKeyModules))
            {
                Console.WriteLine("[REPL] DumpViewer.Init failed. See log: " + config.LogFilePath);
                return 1;
            }

            // Auto-detect the mirror scripts that ship next to the dump (LOG folder).
            if (scriptsDllPath == null && !string.IsNullOrEmpty(config.DumpFilePath))
            {
                string cand = System.IO.Path.Combine(
                    System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(config.DumpFilePath)),
                    "SqlCsScripts.dll");
                if (System.IO.File.Exists(cand))
                {
                    scriptsDllPath = cand;
                    Console.WriteLine("[REPL] Auto-detected local mirror scripts next to dump: " + cand);
                }
            }

            Assembly scriptsAsm;
            if (scriptsDllPath != null)
            {
                scriptsAsm = LoadLocalScripts(scriptsDllPath);
                if (scriptsAsm == null)
                {
                    Console.WriteLine("[REPL] Failed to load local mirror scripts: " + scriptsDllPath);
                    return 1;
                }
            }
            else
            {
                Console.WriteLine("[REPL] Loading SqlCsScripts assemblies from symbol server ...");
                if (!dv.LoadSqlScriptAssemblies(Constants.SqlScriptModuleInfo, null))
                {
                    Console.WriteLine("[REPL] LoadSqlScriptAssemblies failed. See log: " + config.LogFilePath);
                    return 1;
                }
                scriptsAsm = dv.sqlCsScriptsAssembly;
            }

            CsScriptExecutor exec = new CsScriptExecutor(scriptsAsm, null);
            Console.WriteLine("[REPL] Discovering scripts (may take a few minutes) ...");
            exec.DiscoverScripts();

            Console.WriteLine();
            Console.WriteLine("=== SQL Mirror Script REPL ready ===");
            Console.WriteLine("Enter:  <Class>.<Method>   (public static, no-arg)");
            Console.WriteLine("  e.g.  SOSRingBuffers.EnumerateSchedulerMonitorRecords");
            Console.WriteLine("        Tasks.Enumerate");
            Console.WriteLine("A leading '!execute' is accepted and ignored.");
            Console.WriteLine("Type 'quit' or 'exit' to leave.");
            Console.WriteLine();

            while (true)
            {
                Console.Write("mirror> ");
                string line = Console.ReadLine();
                if (line == null) break;
                line = line.Trim();
                if (line.Length == 0) continue;
                if (string.Equals(line, "quit", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(line, "exit", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(line, "q", StringComparison.OrdinalIgnoreCase))
                    break;

                string expr = line;
                if (expr.StartsWith("!execute", StringComparison.OrdinalIgnoreCase))
                    expr = expr.Substring("!execute".Length).Trim();

                int dot = expr.LastIndexOf('.');
                if (dot <= 0 || dot >= expr.Length - 1)
                {
                    Console.WriteLine("[REPL] Format must be Class.Method");
                    continue;
                }
                string cls = expr.Substring(0, dot).Trim();
                string method = expr.Substring(dot + 1).Trim();

                DateTime start = DateTime.Now;
                try
                {
                    object result = exec.ExecuteScript(cls, method);
                    PrintResult(result);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("[REPL] Execute error: " + ex.Message);
                }
                Console.WriteLine("[REPL] (" + (DateTime.Now - start).TotalMilliseconds.ToString("0") + " ms)");
                Console.WriteLine();
            }

            dv.Dispose();
            return 0;
        }

        // Loads the version-matched mirror pair (SqlDebugTypes.dll + SqlCsScripts.dll) directly
        // from the dump's LOG folder, replicating DumpViewer's AssemblyResolve behavior so the
        // scripts' dependencies resolve against the DumpViewer folder's CsDebugScript.* DLLs.
        private static Assembly LoadLocalScripts(string scriptsDllPath)
        {
            try
            {
                string full = System.IO.Path.GetFullPath(scriptsDllPath);
                string dir = System.IO.Path.GetDirectoryName(full);
                AppDomain.CurrentDomain.AssemblyResolve += LocalResolve;

                string typesPath = System.IO.Path.Combine(dir, "SqlDebugTypes.dll");
                if (System.IO.File.Exists(typesPath))
                {
                    Assembly t = Assembly.LoadFrom(typesPath);
                    _localAsm[t.GetName().Name] = t;
                    Console.WriteLine("[REPL] Loaded " + typesPath);
                }
                else
                {
                    Console.WriteLine("[REPL] Warning: SqlDebugTypes.dll not found next to SqlCsScripts.dll");
                }

                Assembly s = Assembly.LoadFrom(full);
                _localAsm[s.GetName().Name] = s;
                Console.WriteLine("[REPL] Loaded " + full);
                return s;
            }
            catch (Exception ex)
            {
                Console.WriteLine("[REPL] LoadLocalScripts error: " + ex.Message);
                return null;
            }
        }

        private static Assembly LocalResolve(object sender, ResolveEventArgs e)
        {
            string name = new AssemblyName(e.Name).Name;
            Assembly a;
            if (_localAsm.TryGetValue(name, out a)) return a;

            string p = System.IO.Path.Combine(_dumpViewerDir, name + ".dll");
            if (System.IO.File.Exists(p)) return Assembly.LoadFrom(p);
            p = System.IO.Path.Combine(_dumpViewerDir, name + ".exe");
            if (System.IO.File.Exists(p)) return Assembly.LoadFrom(p);
            return null;
        }

        private static void PrintResult(object result)
        {
            if (result == null) { Console.WriteLine("(null / no rows)"); return; }

            Type t = result.GetType();
            if (result is string || t.IsPrimitive)
            {
                Console.WriteLine(result.ToString());
                return;
            }

            IEnumerable seq = result as IEnumerable;
            if (seq != null)
            {
                int row = 0;
                List<string> headers = null;
                foreach (object item in seq)
                {
                    if (item == null) { Console.WriteLine("(null row)"); row++; continue; }
                    List<KeyValuePair<string, string>> cols = GetMembers(item);
                    if (cols.Count == 0)
                    {
                        Console.WriteLine(item.ToString());
                    }
                    else
                    {
                        if (headers == null)
                        {
                            headers = cols.Select(c => c.Key).ToList();
                            string head = string.Join(" | ", headers.ToArray());
                            Console.WriteLine(head);
                            Console.WriteLine(new string('-', Math.Min(160, head.Length)));
                        }
                        Console.WriteLine(string.Join(" | ", cols.Select(c => c.Value).ToArray()));
                    }
                    row++;
                }
                Console.WriteLine("[REPL] " + row + " row(s).");
                return;
            }

            List<KeyValuePair<string, string>> members = GetMembers(result);
            if (members.Count == 0) { Console.WriteLine(result.ToString()); return; }
            foreach (KeyValuePair<string, string> m in members)
                Console.WriteLine("  " + m.Key + " = " + m.Value);
        }

        private static List<KeyValuePair<string, string>> GetMembers(object item)
        {
            List<KeyValuePair<string, string>> list = new List<KeyValuePair<string, string>>();
            Type t = item.GetType();
            if (item is string || t.IsPrimitive) return list;

            foreach (PropertyInfo p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.GetIndexParameters().Length > 0) continue;
                string val;
                try
                {
                    object v = p.GetValue(item, null);
                    val = v == null ? "" : v.ToString();
                }
                catch (Exception ex) { val = "<err:" + ex.GetType().Name + ">"; }
                list.Add(new KeyValuePair<string, string>(p.Name, val));
            }
            foreach (FieldInfo f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                string val;
                try
                {
                    object v = f.GetValue(item);
                    val = v == null ? "" : v.ToString();
                }
                catch (Exception ex) { val = "<err:" + ex.GetType().Name + ">"; }
                list.Add(new KeyValuePair<string, string>(f.Name, val));
            }
            return list;
        }
    }
}

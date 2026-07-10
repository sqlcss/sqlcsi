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

            // Wrapper unwrap: types like SOSRingBufferOutput<T> expose scalar cols +
            // a single IEnumerable member (Records). Print the scalars as header lines,
            // then recurse into the inner sequence so callers get a real row set.
            if (seq == null)
            {
                object inner = null;
                string innerName = null;
                if (TryFindSingleEnumerable(result, out inner, out innerName))
                {
                    Console.WriteLine("[REPL] Wrapper: " + t.Name);
                    foreach (KeyValuePair<string, string> scalar in GetScalarMembers(result, innerName))
                        Console.WriteLine("  " + scalar.Key + " = " + scalar.Value);
                    Console.WriteLine();
                    PrintResult(inner);
                    return;
                }
            }

            if (seq != null)
            {
                // Two-pass: materialize rows so we can collect the UNION of member names
                // across ALL rows (DIA-typed mirror instances vary per event type -- e.g.
                // SchedulerMonitor STUCK_DISPATCHER records surface Worker/Exception fields
                // that SYSTEM_HEALTH records don't). Row 0 alone would misalign later rows.
                List<List<KeyValuePair<string, string>>> allRows = new List<List<KeyValuePair<string, string>>>();
                List<string> headers = new List<string>();
                Dictionary<string, int> headerIdx = new Dictionary<string, int>(StringComparer.Ordinal);
                int fallbackRows = 0;
                foreach (object item in seq)
                {
                    if (item == null) { allRows.Add(null); continue; }
                    List<KeyValuePair<string, string>> cols = GetMembers(item, 0);
                    if (cols.Count == 0)
                    {
                        // Non-record row (e.g. plain string / primitive) -- print inline later.
                        allRows.Add(new List<KeyValuePair<string, string>> {
                            new KeyValuePair<string,string>("__value__", item.ToString())
                        });
                        if (!headerIdx.ContainsKey("__value__"))
                        { headerIdx["__value__"] = headers.Count; headers.Add("__value__"); }
                        fallbackRows++;
                        continue;
                    }
                    foreach (KeyValuePair<string, string> kv in cols)
                    {
                        if (!headerIdx.ContainsKey(kv.Key))
                        { headerIdx[kv.Key] = headers.Count; headers.Add(kv.Key); }
                    }
                    allRows.Add(cols);
                }

                if (headers.Count == 0)
                {
                    Console.WriteLine("[REPL] 0 row(s).");
                    return;
                }

                string head = string.Join(" | ", headers.ToArray());
                Console.WriteLine(head);
                Console.WriteLine(new string('-', Math.Min(160, head.Length)));

                int rowCount = 0;
                foreach (List<KeyValuePair<string, string>> cols in allRows)
                {
                    if (cols == null) { Console.WriteLine("(null row)"); rowCount++; continue; }
                    string[] vals = new string[headers.Count];
                    for (int i = 0; i < vals.Length; i++) vals[i] = "";
                    foreach (KeyValuePair<string, string> kv in cols)
                    {
                        int idx;
                        if (headerIdx.TryGetValue(kv.Key, out idx)) vals[idx] = kv.Value;
                    }
                    Console.WriteLine(string.Join(" | ", vals));
                    rowCount++;
                }
                Console.WriteLine("[REPL] " + rowCount + " row(s).");
                return;
            }

            List<KeyValuePair<string, string>> members = GetMembers(result, 0);
            if (members.Count == 0) { Console.WriteLine(result.ToString()); return; }
            foreach (KeyValuePair<string, string> m in members)
                Console.WriteLine("  " + m.Key + " = " + m.Value);
        }

        // Look for exactly one public property/field whose value is a non-string IEnumerable.
        // Used to unwrap SOSRingBufferOutput<T>-style { RecordType; Records; } wrappers.
        private static bool TryFindSingleEnumerable(object item, out object value, out string name)
        {
            value = null; name = null;
            Type t = item.GetType();
            int count = 0;
            foreach (PropertyInfo p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.GetIndexParameters().Length > 0) continue;
                if (!IsEnumerableColumn(p.PropertyType)) continue;
                try { value = p.GetValue(item, null); } catch { value = null; }
                name = p.Name; count++;
            }
            foreach (FieldInfo f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                if (!IsEnumerableColumn(f.FieldType)) continue;
                try { value = f.GetValue(item); } catch { value = null; }
                name = f.Name; count++;
            }
            return count == 1 && value != null;
        }

        private static bool IsEnumerableColumn(Type ty)
        {
            if (ty == typeof(string)) return false;
            return typeof(IEnumerable).IsAssignableFrom(ty);
        }

        private static List<KeyValuePair<string, string>> GetScalarMembers(object item, string skipName)
        {
            List<KeyValuePair<string, string>> list = new List<KeyValuePair<string, string>>();
            Type t = item.GetType();
            foreach (PropertyInfo p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.GetIndexParameters().Length > 0) continue;
                if (p.Name == skipName) continue;
                if (IsEnumerableColumn(p.PropertyType)) continue;
                string val;
                try { object v = p.GetValue(item, null); val = v == null ? "" : v.ToString(); }
                catch (Exception ex) { val = "<err:" + ex.GetType().Name + ">"; }
                list.Add(new KeyValuePair<string, string>(p.Name, val));
            }
            foreach (FieldInfo f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                if (f.Name == skipName) continue;
                if (IsEnumerableColumn(f.FieldType)) continue;
                string val;
                try { object v = f.GetValue(item); val = v == null ? "" : v.ToString(); }
                catch (Exception ex) { val = "<err:" + ex.GetType().Name + ">"; }
                list.Add(new KeyValuePair<string, string>(f.Name, val));
            }
            return list;
        }

        // Return public props/fields as (name,value) pairs; nested "record-like" values
        // (class-typed, non-IEnumerable, has its own public props) are flattened inline so
        // e.g. a row's [Output("Record")] Record : SOS_SchedulerMonitorRecord becomes
        // sibling columns Event/NodeId/SchedulerId/... alongside its wrapper's own cols.
        // Depth-limited (2) to avoid runaway recursion on tree-shaped types.
        private static List<KeyValuePair<string, string>> GetMembers(object item, int depth)
        {
            List<KeyValuePair<string, string>> list = new List<KeyValuePair<string, string>>();
            Type t = item.GetType();
            if (item is string || t.IsPrimitive) return list;

            foreach (PropertyInfo p in t.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.GetIndexParameters().Length > 0) continue;
                AddMember(list, p.Name, SafeGet(p, item), depth);
            }
            foreach (FieldInfo f in t.GetFields(BindingFlags.Public | BindingFlags.Instance))
            {
                AddMember(list, f.Name, SafeGet(f, item), depth);
            }
            return list;
        }

        private static object SafeGet(PropertyInfo p, object item)
        {
            try { return p.GetValue(item, null); } catch { return "<err>"; }
        }
        private static object SafeGet(FieldInfo f, object item)
        {
            try { return f.GetValue(item); } catch { return "<err>"; }
        }

        private static void AddMember(List<KeyValuePair<string, string>> list, string name, object v, int depth)
        {
            if (v == null) { list.Add(new KeyValuePair<string, string>(name, "")); return; }
            Type vt = v.GetType();
            if (IsRecordLike(v, vt) && depth < 2)
            {
                // Inline nested record's members as siblings (no key prefix — mirrors
                // CsScript [IncludedObjectOutput] behavior for e.g. SOSRingBufferRecordOutput.Record).
                List<KeyValuePair<string, string>> nested = GetMembers(v, depth + 1);
                if (nested.Count > 0) { list.AddRange(nested); return; }
            }
            list.Add(new KeyValuePair<string, string>(name, v.ToString()));
        }

        private static bool IsRecordLike(object v, Type vt)
        {
            if (v is string) return false;
            if (vt.IsPrimitive || vt.IsEnum) return false;
            if (vt == typeof(DateTime) || vt == typeof(TimeSpan) || vt == typeof(decimal) || vt == typeof(Guid)) return false;
            if (typeof(IEnumerable).IsAssignableFrom(vt)) return false;
            // Class-like AND has at least one public instance property/field of its own.
            if (!vt.IsClass && !vt.IsValueType) return false;
            bool hasMember = false;
            foreach (PropertyInfo pi in vt.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            { if (pi.GetIndexParameters().Length == 0) { hasMember = true; break; } }
            if (!hasMember)
                foreach (FieldInfo fi in vt.GetFields(BindingFlags.Public | BindingFlags.Instance))
                { hasMember = true; break; }
            return hasMember;
        }
    }
}

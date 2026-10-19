// OpennessResolver.cs - TIA Portal V20 Openness export helper
// Compiled at runtime by export_tia.ps1 via Add-Type.
//
// API surface verified against:
//   C:\Program Files\Siemens\Automation\Portal V20\PublicAPI\V20\Siemens.Engineering.xml
//
// Key API facts (V20):
//   PlcSoftware.TypeGroup   -> PlcTypeSystemGroup   (system type root)
//   PlcTypeSystemGroup      -> .SystemTypeGroups    (PlcSystemTypeGroupComposition)
//   PlcSystemTypeGroup      -> .Types               (PlcTypeComposition of PlcType)
//   PlcType.Export(FileInfo, ExportOptions)         - same signature as PlcBlock.Export
//   ProgrammingLanguage enum - safety blocks: F_STL, F_LAD, F_FBD, F_DB, F_LAD_LIB, F_FBD_LIB, F_CALL
//   ExportOptions.WithDefaults - confirmed present

using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
using Siemens.Engineering;
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.Blocks;
using Siemens.Engineering.SW.Types;
using Siemens.Engineering.HW;
using Siemens.Engineering.HW.Features;

public static class Exporter
{
    // Set from export_tia.ps1 to the PublicAPI folder matching the project version
    // (Openness is version-locked; resolving V20 assemblies against a V17 project
    // fails with "can only be opened with a software product of the same version").
    public static string ApiDir = "";   // always set by export_tia.ps1 from the detected DLL

    // Assembly resolver - called for any dependency the runtime cannot find.
    public static Assembly Resolve(object s, ResolveEventArgs a)
    {
        var name = new AssemblyName(a.Name).Name;
        var dll  = ApiDir + name + ".dll";
        return File.Exists(dll) ? Assembly.LoadFrom(dll) : null;
    }

    public static void Run(string projectPath, string outDir, bool probe)
    {
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        RunInner(projectPath, outDir, probe);
    }

    // Navigation helpers

    private static PlcSoftware GetPlcSoftware(Project project)
    {
        foreach (var dev in project.Devices)
            foreach (var item in dev.DeviceItems)
            {
                var c = item.GetService<SoftwareContainer>();
                if (c != null && c.Software is PlcSoftware)
                    return (PlcSoftware)c.Software;
            }
        throw new Exception("No PlcSoftware found in project");
    }

    private static void PrintCompileErrors(Siemens.Engineering.Compiler.CompilerResultMessageComposition msgs, string indent)
    {
        foreach (var m in msgs)
        {
            if (m.State == Siemens.Engineering.Compiler.CompilerResultState.Error)
                Console.WriteLine(indent + m.Path + ": " + m.Description);
            PrintCompileErrors(m.Messages, indent + "  ");
        }
    }

    // Core export logic

    private static void RunInner(string projectPath, string outDir, bool probe)
    {
        Directory.CreateDirectory(outDir);

        Console.WriteLine("Opening TIA Portal (headless) - first use may trigger whitelist dialog.");
        using (var portal = new TiaPortal(TiaPortalMode.WithoutUserInterface))
        {
            Project project;
            if (Path.GetExtension(projectPath).StartsWith(".zap", StringComparison.OrdinalIgnoreCase))
            {
                // Archive: retrieve into <out>\_retrieved (archive itself untouched)
                var target = new DirectoryInfo(Path.Combine(outDir, "_retrieved"));
                if (target.Exists) target.Delete(true);
                target.Create();
                try
                {
                    Console.WriteLine("Retrieving archive into " + target.FullName);
                    project = portal.Projects.Retrieve(new FileInfo(projectPath), target);
                }
                catch (Exception ex)
                {
                    if (!ex.ToString().Contains("Compatibility") && !ex.ToString().Contains("upgrade")) throw;
                    Console.WriteLine("Version mismatch - retrying with RetrieveWithUpgrade...");
                    target.Delete(true);
                    target.Create();
                    project = portal.Projects.RetrieveWithUpgrade(new FileInfo(projectPath), target);
                }
            }
            else try
            {
                project = portal.Projects.Open(new FileInfo(projectPath));
            }
            catch (Exception ex)
            {
                if (!ex.ToString().Contains("Compatibility")) throw;
                // Older-version project (e.g. .ap19): upgrade-open. Writes an
                // upgraded copy alongside; original untouched (copy-only rule).
                Console.WriteLine("Version mismatch - retrying with OpenWithUpgrade...");
                project = portal.Projects.OpenWithUpgrade(new FileInfo(projectPath));
            }
            Console.WriteLine("Project opened: " + project.Name);

            var sw  = GetPlcSoftware(project);

            // Compile first: an upgraded (V17->V20) project is inconsistent and
            // Openness refuses to export inconsistent blocks/UDTs.
            Console.WriteLine("Compiling PLC software...");
            var cres = sw.GetService<Siemens.Engineering.Compiler.ICompilable>().Compile();
            Console.WriteLine("Compile: " + cres.State + "  errors=" + cres.ErrorCount + "  warnings=" + cres.WarningCount);
            PrintCompileErrors(cres.Messages, "  ");
            project.Save();

            var manifest = new List<string>();

            // Walk PLC blocks (recursive through groups)
            WalkBlocks(sw.BlockGroup, outDir, probe, manifest);

            // Export UDTs from TypeGroup hierarchy
            // PlcSoftware.TypeGroup -> PlcTypeSystemGroup
            //   .SystemTypeGroups   -> PlcSystemTypeGroup[]
            //     .Types            -> PlcType[]
            if (!probe)
            {
                var udtsDir = Path.Combine(outDir, "udt");
                Directory.CreateDirectory(udtsDir);

                try
                {
                    foreach (var sysGroup in sw.TypeGroup.SystemTypeGroups)
                    {
                        foreach (var t in sysGroup.Types)
                        {
                            try
                            {
                                var f = new FileInfo(Path.Combine(udtsDir, SanitizeName(t.Name) + ".xml"));
                                t.Export(f, ExportOptions.WithDefaults);
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine("SKIP udt " + t.Name + ": " + ex.Message);
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine("WARN: UDT export failed: " + ex.Message);
                }

                // User-defined UDTs live directly in TypeGroup.Types + user groups
                // (SystemTypeGroups above only holds Siemens library/system types).
                try
                {
                    int nUser = ExportUserTypes(sw.TypeGroup, udtsDir);
                    Console.WriteLine("User UDTs exported: " + nUser);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("WARN: user UDT export failed: " + ex.Message);
                }
            }

            // Walk Technology Objects (PositioningAxis / SynchronousAxis / etc.)
            // PlcSoftware.TechnologicalObjectGroup -> (reflected) TechnologicalInstanceDBs + subgroups
            // Each TechnologicalInstanceDB has .Name, .Parameters (Name/Value), .Export(FileInfo, ExportOptions)
            try
            {
                var toRootProp = sw.GetType().GetProperty("TechnologicalObjectGroup");
                var toRoot = toRootProp != null ? toRootProp.GetValue(sw) : null;
                if (toRoot != null)
                {
                    var toDir = Path.Combine(outDir, "to");
                    Directory.CreateDirectory(toDir);
                    WalkTOGroup(toRoot, toDir, probe, manifest, new HashSet<object>());
                }
                else Console.WriteLine("WARN: no TechnologicalObjectGroup on PlcSoftware");
            }
            catch (Exception ex) { Console.WriteLine("WARN: TO export failed: " + ex.Message); }

            if (!probe)
            {
                // PLC tag tables, watch/force tables, alarm text lists (generic walker)
                ExportRoot("PLC tags",        sw.TagTableGroup,           Path.Combine(outDir, "tags"));
                ExportRoot("Watch tables",    sw.WatchAndForceTableGroup, Path.Combine(outDir, "watch"));
                ExportRoot("Alarm textlists", sw.PlcAlarmTextlistGroup,   Path.Combine(outDir, "alarm_textlists"));

                // HMI targets (WinCC Advanced/Comfort "classic"): screens, templates,
                // pop-ups, tags, connections, text/graphic lists, cycles, scripts
                foreach (var hmi in FindSoftware(project, "HmiTarget"))
                {
                    string hname = GetName(hmi.Value);
                    string hdir  = Path.Combine(outDir, "hmi", SanitizeName(hname));
                    Console.WriteLine("HMI found: " + hname + " (device " + hmi.Key + ")");
                    try
                    {
                        var hc = ((IEngineeringServiceProvider)hmi.Value).GetService<Siemens.Engineering.Compiler.ICompilable>();
                        if (hc != null)
                        {
                            var hres = hc.Compile();
                            Console.WriteLine("HMI compile: " + hres.State + "  errors=" + hres.ErrorCount + "  warnings=" + hres.WarningCount);
                            PrintCompileErrors(hres.Messages, "  ");
                        }
                    }
                    catch (Exception ex) { Console.WriteLine("WARN: HMI compile failed: " + InnerMsg(ex)); }
                    ExportRoot("HMI " + hname, hmi.Value, hdir);
                }
                foreach (var u in FindSoftware(project, "HmiSoftware"))
                    Console.WriteLine("NOTE: WinCC Unified HMI '" + GetName(u.Value) + "' found - Unified export not implemented");

                // Hardware: AutomationML (CAx) for the whole project + readable device list
                ExportHardware(project, Path.Combine(outDir, "hw"));
                project.Save();
            }

            // Write manifest
            var projectFile = Path.GetFileName(projectPath);
            var json = "{\"project\":\"" + projectFile + "\",\"blocks\":["
                     + string.Join(",", manifest) + "]}";
            File.WriteAllText(Path.Combine(outDir, "manifest.json"), json);

            project.Close();
            Console.WriteLine("DONE: " + manifest.Count + " blocks, probe=" + probe.ToString().ToLower());
        }
    }

    private static int ExportUserTypes(PlcTypeGroup g, string udtsDir)
    {
        int n = 0;
        foreach (PlcType t in g.Types)
        {
            try
            {
                var f = new FileInfo(Path.Combine(udtsDir, SanitizeName(t.Name) + ".xml"));
                if (f.Exists) f.Delete();
                t.Export(f, ExportOptions.WithDefaults);
                n++;
            }
            catch (Exception ex) { Console.WriteLine("SKIP udt " + t.Name + ": " + InnerMsg(ex)); }
        }
        foreach (PlcTypeUserGroup sub in g.Groups)
            n += ExportUserTypes(sub, udtsDir);
        return n;
    }

    // Block walker (recursive)

    private static void WalkBlocks(PlcBlockGroup g, string outDir, bool probe,
                                   List<string> manifest)
    {
        foreach (var b in g.Blocks)
        {
            bool kh   = b.IsKnowHowProtected;
            string lang = b.ProgrammingLanguage.ToString();

            // Safety detection: all F-language variants start with "F_"
            bool safety = lang.StartsWith("F_", StringComparison.OrdinalIgnoreCase);

            manifest.Add(
                "{\"name\":\"" + JsonEscape(b.Name) + "\","
              + "\"type\":\"" + b.GetType().Name + "\","
              + "\"language\":\"" + lang + "\","
              + "\"isKnowHowProtected\":" + kh.ToString().ToLower() + ","
              + "\"isSafety\":" + safety.ToString().ToLower() + "}");

            if (!probe && !kh)
            {
                try
                {
                    var f = new FileInfo(Path.Combine(outDir, "blocks", SanitizeName(b.Name) + ".xml"));
                    f.Directory.Create();
                    b.Export(f, ExportOptions.WithDefaults);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("SKIP block " + b.Name + ": " + ex.Message);
                }
            }
        }

        foreach (var sub in g.Groups)
            WalkBlocks(sub, outDir, probe, manifest);
    }

    // Technology Object walker (reflection-based auto-discovery of the group tree)

    private static void WalkTOGroup(object group, string toDir, bool probe,
                                    List<string> manifest, HashSet<object> seen)
    {
        if (group == null || !seen.Add(group)) return;
        foreach (var prop in group.GetType().GetProperties())
        {
            if (prop.Name == "Parent") continue;
            if (prop.GetIndexParameters().Length > 0) continue;
            object val;
            try { val = prop.GetValue(group); } catch { continue; }
            if (val == null || val is string) continue;
            var en = val as System.Collections.IEnumerable;
            if (en == null) continue;
            foreach (var item in en)
            {
                if (item == null) continue;
                string tn = item.GetType().Name;
                if (tn.IndexOf("InstanceDB", StringComparison.OrdinalIgnoreCase) >= 0)
                    ExportTO(item, toDir, probe, manifest);
                else if (tn.IndexOf("Group", StringComparison.OrdinalIgnoreCase) >= 0)
                    WalkTOGroup(item, toDir, probe, manifest, seen);
            }
        }
    }

    private static void ExportTO(object db, string toDir, bool probe, List<string> manifest)
    {
        try
        {
            var t = db.GetType();
            string name = (string)t.GetProperty("Name").GetValue(db);
            manifest.Add(
                "{\"name\":\"" + JsonEscape(name) + "\","
              + "\"type\":\"TechnologicalObject\","
              + "\"language\":\"TO\","
              + "\"isKnowHowProtected\":false,"
              + "\"isSafety\":false}");

            // Dump parameters (Name = Value) - the human-readable config
            var paramsProp = t.GetProperty("Parameters");
            if (paramsProp != null)
            {
                var coll = paramsProp.GetValue(db) as System.Collections.IEnumerable;
                if (coll != null)
                {
                    var sb = new System.Text.StringBuilder();
                    sb.AppendLine("# Technology Object: " + name);
                    sb.AppendLine("# format: <Parameter.Path> = <Value>");
                    sb.AppendLine();
                    int n = 0;
                    foreach (var par in coll)
                    {
                        var pt = par.GetType();
                        var np = pt.GetProperty("Name");
                        var vp = pt.GetProperty("Value");
                        string pn = np != null ? (np.GetValue(par) ?? "?").ToString() : "?";
                        object pv = vp != null ? vp.GetValue(par) : null;
                        sb.AppendLine(pn + " = " + (pv != null ? pv.ToString() : "<null>"));
                        n++;
                    }
                    File.WriteAllText(Path.Combine(toDir, SanitizeName(name) + ".params.txt"), sb.ToString());
                    Console.WriteLine("TO params: " + name + " (" + n + " params)");
                }
            }

            // Also SimaticML export (backup / full detail)
            if (!probe)
            {
                var exportMethod = t.GetMethod("Export", new[] { typeof(FileInfo), typeof(ExportOptions) });
                if (exportMethod != null)
                {
                    var f = new FileInfo(Path.Combine(toDir, SanitizeName(name) + ".xml"));
                    if (f.Exists) f.Delete();   // Openness refuses to overwrite
                    exportMethod.Invoke(db, new object[] { f, ExportOptions.WithDefaults });
                }
            }
        }
        catch (Exception ex) { Console.WriteLine("SKIP TO: " + ex.Message); }
    }

    // Generic export walker (reflection): exports every child that has
    // Export(FileInfo, ExportOptions); recurses into *Folder / *Group children,
    // mirroring the TIA folder tree on disk.

    private static void ExportRoot(string label, object root, string dir)
    {
        if (root == null) { Console.WriteLine("WARN: " + label + ": not present"); return; }
        int ok = 0, skip = 0;
        try { ExportTree(root, dir, new HashSet<object>(), 0, ref ok, ref skip); }
        catch (Exception ex) { Console.WriteLine("WARN: " + label + " export failed: " + InnerMsg(ex)); }
        Console.WriteLine(label + ": exported " + ok + ", skipped " + skip);
    }

    private static void ExportTree(object node, string dir, HashSet<object> seen, int depth,
                                   ref int ok, ref int skip)
    {
        if (node == null || depth > 12 || !seen.Add(node)) return;
        foreach (var prop in node.GetType().GetProperties())
        {
            if (prop.Name == "Parent" || prop.GetIndexParameters().Length > 0) continue;
            object val;
            try { val = prop.GetValue(node); } catch { continue; }
            if (val == null || val is string) continue;

            var en = val as System.Collections.IEnumerable;
            if (en == null)
            {
                // Single folder property, e.g. HmiTarget.ScreenFolder
                if (IsContainer(val.GetType()))
                    ExportTree(val, Path.Combine(dir, SanitizeName(prop.Name)), seen, depth + 1, ref ok, ref skip);
                continue;
            }
            foreach (var item in en)
            {
                if (item == null) continue;
                var t = item.GetType();
                string name = GetName(item);
                var exp = t.GetMethod("Export", new[] { typeof(FileInfo), typeof(ExportOptions) });
                if (exp != null)
                {
                    try
                    {
                        var f = new FileInfo(Path.Combine(dir, SanitizeName(name) + ".xml"));
                        f.Directory.Create();
                        if (f.Exists) f.Delete();   // Openness refuses to overwrite
                        exp.Invoke(item, new object[] { f, ExportOptions.WithDefaults });
                        ok++;
                    }
                    catch (Exception ex)
                    {
                        skip++;
                        Console.WriteLine("SKIP " + t.Name + " " + name + ": " + InnerMsg(ex));
                    }
                }
                else if (IsContainer(t))
                    ExportTree(item, Path.Combine(dir, SanitizeName(name)), seen, depth + 1, ref ok, ref skip);
            }
        }
    }

    private static bool IsContainer(Type t)
    {
        return t.Name.IndexOf("Folder", StringComparison.Ordinal) >= 0
            || t.Name.IndexOf("Group",  StringComparison.Ordinal) >= 0;
    }

    // All software of a given type name (HmiTarget, HmiSoftware...) anywhere in the
    // device tree - HMIs on a PC station sit several DeviceItem levels down.
    private static List<KeyValuePair<string, object>> FindSoftware(Project project, string typeName)
    {
        var found = new List<KeyValuePair<string, object>>();
        foreach (var dev in project.Devices)
            FindSoftwareIn(dev.Name, dev.DeviceItems, typeName, found);
        foreach (var grp in project.DeviceGroups)
            FindSoftwareInGroup(grp, typeName, found);
        return found;
    }

    private static void FindSoftwareInGroup(DeviceUserGroup g, string typeName, List<KeyValuePair<string, object>> found)
    {
        foreach (var dev in g.Devices) FindSoftwareIn(dev.Name, dev.DeviceItems, typeName, found);
        foreach (var sub in g.Groups)  FindSoftwareInGroup(sub, typeName, found);
    }

    private static void FindSoftwareIn(string devName, DeviceItemComposition items, string typeName,
                                       List<KeyValuePair<string, object>> found)
    {
        foreach (var item in items)
        {
            try
            {
                var c = item.GetService<SoftwareContainer>();
                if (c != null && c.Software != null && c.Software.GetType().Name == typeName)
                    found.Add(new KeyValuePair<string, object>(devName, c.Software));
            }
            catch { }
            FindSoftwareIn(devName, item.DeviceItems, typeName, found);
        }
    }

    // Hardware: CAx/AutomationML export + a readable device/module/address list

    private static void ExportHardware(Project project, string hwDir)
    {
        Directory.CreateDirectory(hwDir);
        try
        {
            var cax = project.GetService<Siemens.Engineering.Cax.CaxProvider>();
            var aml = new FileInfo(Path.Combine(hwDir, "project.aml"));
            var log = new FileInfo(Path.Combine(hwDir, "cax_export.log"));
            if (aml.Exists) aml.Delete();
            if (log.Exists) log.Delete();
            bool ok = cax.Export(project, aml, log);
            aml.Refresh();
            Console.WriteLine("HW CAx export: " + (ok ? "OK" : aml.Exists ? "written WITH ERRORS (see ERROR lines in hw/cax_export.log)" : "FAILED (see hw/cax_export.log)"));
        }
        catch (Exception ex) { Console.WriteLine("WARN: HW CAx export failed: " + InnerMsg(ex)); }

        try
        {
            var sb = new System.Text.StringBuilder();
            sb.AppendLine("# Devices / modules / network addresses");
            foreach (var dev in project.Devices) DumpDevice(dev, sb);
            foreach (var grp in project.DeviceGroups) DumpGroup(grp, sb);
            foreach (var dev in project.UngroupedDevicesGroup.Devices) DumpDevice(dev, sb);
            File.WriteAllText(Path.Combine(hwDir, "devices.txt"), sb.ToString());
            Console.WriteLine("HW device list written");
        }
        catch (Exception ex) { Console.WriteLine("WARN: HW device list failed: " + InnerMsg(ex)); }
    }

    private static void DumpGroup(DeviceUserGroup g, System.Text.StringBuilder sb)
    {
        foreach (var dev in g.Devices) DumpDevice(dev, sb);
        foreach (var sub in g.Groups)  DumpGroup(sub, sb);
    }

    private static void DumpDevice(Device dev, System.Text.StringBuilder sb)
    {
        sb.AppendLine();
        sb.AppendLine("DEVICE " + dev.Name + "  [" + Attr(dev, "TypeIdentifier") + "]");
        DumpItems(dev.DeviceItems, sb, "  ");
    }

    private static void DumpItems(DeviceItemComposition items, System.Text.StringBuilder sb, string ind)
    {
        foreach (var it in items)
        {
            string line = ind + it.Name;
            string order = Attr(it, "OrderNumber");
            string fw    = Attr(it, "FirmwareVersion");
            if (order != "") line += "  order=" + order;
            if (fw != "")    line += "  fw=" + fw;
            string slot = Attr(it, "PositionNumber");
            if (slot != "")  line += "  slot=" + slot;
            sb.AppendLine(line);

            try
            {
                var ni = it.GetService<NetworkInterface>();
                if (ni != null)
                    foreach (var node in ni.Nodes)
                    {
                        string subnet = node.ConnectedSubnet != null ? node.ConnectedSubnet.Name : "-";
                        sb.AppendLine(ind + "  NODE " + node.Name + "  addr=" + Attr(node, "Address")
                                      + "  pnName=" + Attr(node, "PnDeviceName") + "  subnet=" + subnet);
                    }
            }
            catch { }

            // I/O address ranges of the module
            try
            {
                foreach (var addr in it.Addresses)
                    sb.AppendLine(ind + "  IO " + Attr(addr, "IoType") + " start=" + Attr(addr, "StartAddress")
                                  + " len=" + Attr(addr, "Length"));
            }
            catch { }

            DumpItems(it.DeviceItems, sb, ind + "  ");
        }
    }

    private static string Attr(IEngineeringObject o, string name)
    {
        try { var v = o.GetAttribute(name); return v != null ? v.ToString() : ""; }
        catch { return ""; }
    }

    private static string GetName(object o)
    {
        try
        {
            var p = o.GetType().GetProperty("Name");
            var v = p != null ? p.GetValue(o) : null;
            return v != null ? v.ToString() : o.GetType().Name;
        }
        catch { return o.GetType().Name; }
    }

    private static string InnerMsg(Exception ex)
    {
        while (ex.InnerException != null) ex = ex.InnerException;
        return ex.Message.Replace("\r", " ").Replace("\n", " ");
    }

    // Utilities

    private static string SanitizeName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return name;
    }

    private static string JsonEscape(string s)
    {
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}


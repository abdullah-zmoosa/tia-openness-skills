// TiaWriter.cs - import blocks / UDTs / tag tables / SCL sources into a TIA V20
// project via Openness, compile, and save ONLY if the compile is clean.
// Compiled at runtime by tia_write.ps1 via Add-Type (PS 5.1 = C# 5: keep it simple, ASCII only).

using System;
using System.IO;
using System.Reflection;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Xml;
using Siemens.Engineering;
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.Blocks;
using Siemens.Engineering.SW.Types;
using Siemens.Engineering.SW.Tags;
using Siemens.Engineering.SW.ExternalSources;
using Siemens.Engineering.HW;
using Siemens.Engineering.HW.Features;
using Siemens.Engineering.Compiler;

public static class TiaWriter
{
    public static string ApiDir = "";

    public static Assembly Resolve(object s, ResolveEventArgs a)
    {
        var dll = ApiDir + new AssemblyName(a.Name).Name + ".dll";
        return File.Exists(dll) ? Assembly.LoadFrom(dll) : null;
    }

    // Returns 0 = saved, 1 = not saved (compile errors / dry run), 2 = import failure
    public static int Run(string projectPath, string[] files, string groupPath, bool dryRun)
    {
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        return RunInner(projectPath, files, groupPath, dryRun);
    }

    private static int RunInner(string projectPath, string[] files, string groupPath, bool dryRun)
    {
        Console.WriteLine("Opening TIA Portal (headless)...");
        using (var portal = new TiaPortal(TiaPortalMode.WithoutUserInterface))
        {
            var project = portal.Projects.Open(new FileInfo(projectPath));
            Console.WriteLine("Project opened: " + project.Name);
            bool saved = false;
            try
            {
                var sw = GetPlc(project);
                int failures = 0;
                foreach (var f in files)
                {
                    try { ImportOne(sw, f, groupPath); }
                    catch (Exception ex)
                    {
                        failures++;
                        Console.WriteLine("IMPORT FAILED " + Path.GetFileName(f) + ": " + InnerMsg(ex));
                    }
                }
                if (failures > 0)
                {
                    Console.WriteLine("RESULT: " + failures + " import(s) failed - project NOT saved (changes discarded).");
                    return 2;
                }

                Console.WriteLine("Compiling PLC software...");
                var res = sw.GetService<ICompilable>().Compile();
                Console.WriteLine("Compile: " + res.State + "  errors=" + res.ErrorCount + "  warnings=" + res.WarningCount);
                PrintMessages(res.Messages, "  ");

                if (res.ErrorCount > 0)
                {
                    Console.WriteLine("RESULT: compile errors - project NOT saved (changes discarded).");
                    return 1;
                }
                if (dryRun)
                {
                    Console.WriteLine("RESULT: dry run OK (imports + compile clean) - project NOT saved.");
                    return 1;
                }
                project.Save();
                saved = true;
                Console.WriteLine("RESULT: SAVED. Review in TIA, then download yourself.");
                return 0;
            }
            finally
            {
                // Closing without Save discards all in-memory changes
                project.Close();
                if (!saved) Console.WriteLine("Project closed without saving.");
            }
        }
    }

    // ---- full-source generation (run on a reader COPY; never saves) -------

    public static int GenerateSources(string projectPath, string[] blockNames, string outDir)
    {
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        Directory.CreateDirectory(outDir);
        using (var portal = new TiaPortal(TiaPortalMode.WithoutUserInterface))
        {
            var project = portal.Projects.Open(new FileInfo(projectPath));
            int bad = 0;
            try
            {
                var sw = GetPlc(project);
                foreach (var n in blockNames)
                {
                    try
                    {
                        IGenerateSource item = FindBlock(sw.BlockGroup, n) as IGenerateSource;
                        if (item == null) item = FindType(sw.TypeGroup, n) as IGenerateSource;
                        if (item == null) throw new Exception("not found, or its language has no text source (LAD/FBD: edit the XML instead)");
                        string ext = item is PlcType ? ".udt" : (item is DataBlock ? ".db" : ".scl");
                        var f = new FileInfo(Path.Combine(outDir, SanitizeName(n) + ext));
                        if (f.Exists) f.Delete();
                        sw.ExternalSourceGroup.GenerateSource(new IGenerateSource[] { item }, f, GenerateOptions.None);
                        Console.WriteLine("Source: " + f.FullName);
                    }
                    catch (Exception ex) { bad++; Console.WriteLine("SKIP " + n + ": " + InnerMsg(ex)); }
                }
            }
            finally { project.Close(); }
            return bad;
        }
    }

    private static string SanitizeName(string name)
    {
        foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
        return name;
    }

    // ---- import dispatch ---------------------------------------------------

    private static void ImportOne(PlcSoftware sw, string path, string groupPath)
    {
        var fi = new FileInfo(path);
        string ext = fi.Extension.ToLowerInvariant();
        string text = File.ReadAllText(fi.FullName);

        if (Regex.IsMatch(text, @"<ProgrammingLanguage>\s*F_", RegexOptions.IgnoreCase))
            throw new Exception("refused: file contains a safety (F_) block");

        if (ext == ".xml") ImportXml(sw, fi, text, groupPath);
        else if (ext == ".scl" || ext == ".db" || ext == ".udt" || ext == ".awl") ImportSource(sw, fi, text, groupPath);
        else throw new Exception("unsupported file type " + ext + " (use .xml SimaticML, .scl, .db, .udt, .awl)");
    }

    private static void ImportXml(PlcSoftware sw, FileInfo fi, string text, string groupPath)
    {
        var doc = new XmlDocument();
        doc.LoadXml(text);
        XmlElement obj = null;
        foreach (XmlNode n in doc.DocumentElement.ChildNodes)
        {
            var e = n as XmlElement;
            if (e != null && e.LocalName.StartsWith("SW.")) { obj = e; break; }
        }
        if (obj == null) throw new Exception("no SW.* object in XML");
        string kind = obj.LocalName;
        var nameNode = obj.SelectSingleNode("*[local-name()='AttributeList']/*[local-name()='Name']");
        string name = nameNode != null ? nameNode.InnerText.Trim() : "?";

        if (kind.StartsWith("SW.Blocks."))
        {
            var existing = FindBlock(sw.BlockGroup, name);
            if (existing != null) RefuseIfSafety(existing);
            PlcBlockGroup target = existing != null ? (PlcBlockGroup)existing.Parent : BlockGroupFor(sw, groupPath);
            target.Blocks.Import(fi, ImportOptions.Override);
            Console.WriteLine("Imported block " + name + (existing != null ? " (replaced, group '" + target.Name + "')" : " (new, group '" + target.Name + "')"));
        }
        else if (kind == "SW.Types.PlcStruct")
        {
            var existing = FindType(sw.TypeGroup, name);
            PlcTypeGroup target = existing != null ? (PlcTypeGroup)existing.Parent : (PlcTypeGroup)sw.TypeGroup;
            target.Types.Import(fi, ImportOptions.Override);
            Console.WriteLine("Imported UDT " + name + (existing != null ? " (replaced)" : " (new)"));
        }
        else if (kind == "SW.Tags.PlcTagTable")
        {
            var existing = FindTagTable(sw.TagTableGroup, name);
            PlcTagTableGroup target = existing != null ? (PlcTagTableGroup)existing.Parent : (PlcTagTableGroup)sw.TagTableGroup;
            target.TagTables.Import(fi, ImportOptions.Override);
            Console.WriteLine("Imported tag table " + name + (existing != null ? " (replaced)" : " (new)"));
        }
        else throw new Exception("unsupported SimaticML object " + kind);
    }

    private static void ImportSource(PlcSoftware sw, FileInfo fi, string text, string groupPath)
    {
        // Block names declared in the source, e.g. FUNCTION_BLOCK "X"
        var names = new List<string>();
        foreach (Match m in Regex.Matches(text,
            @"^\s*(FUNCTION_BLOCK|FUNCTION|ORGANIZATION_BLOCK|DATA_BLOCK|TYPE)\s+""([^""]+)""",
            RegexOptions.Multiline | RegexOptions.IgnoreCase))
            names.Add(m.Groups[2].Value);
        if (names.Count == 0) throw new Exception("no block declarations found in source");

        PlcBlockGroup common = null;
        bool sameGroup = true;
        foreach (var n in names)
        {
            var b = FindBlock(sw.BlockGroup, n);
            if (b == null) continue;
            RefuseIfSafety(b);
            var g = (PlcBlockGroup)b.Parent;
            if (common == null) common = g; else if (!ReferenceEquals(common, g)) sameGroup = false;
        }

        var srcs = sw.ExternalSourceGroup.ExternalSources;
        var old = srcs.Find(fi.Name);
        if (old != null) old.Delete();
        var src = srcs.CreateFromFile(fi.Name, fi.FullName);
        try
        {
            PlcBlockGroup target = (common != null && sameGroup) ? common : BlockGroupFor(sw, groupPath);
            var ug = target as PlcBlockUserGroup;
            if (ug != null) src.GenerateBlocksFromSource(ug, GenerateBlockOption.None);
            else src.GenerateBlocksFromSource(GenerateBlockOption.None);
            Console.WriteLine("Generated from " + fi.Name + ": " + string.Join(", ", names.ToArray()) + " (group '" + target.Name + "')");
        }
        finally { src.Delete(); }
    }

    // ---- helpers -----------------------------------------------------------

    private static void RefuseIfSafety(PlcBlock b)
    {
        if (b.ProgrammingLanguage.ToString().StartsWith("F_", StringComparison.OrdinalIgnoreCase))
            throw new Exception("refused: '" + b.Name + "' is a safety (F_) block");
        if (b.IsKnowHowProtected)
            throw new Exception("refused: '" + b.Name + "' is know-how protected");
    }

    private static PlcBlockGroup BlockGroupFor(PlcSoftware sw, string groupPath)
    {
        PlcBlockGroup g = sw.BlockGroup;
        if (string.IsNullOrEmpty(groupPath)) return g;
        foreach (var part in groupPath.Split('/'))
        {
            if (part.Length == 0) continue;
            var next = g.Groups.Find(part);
            if (next == null) { next = g.Groups.Create(part); Console.WriteLine("Created block group " + part); }
            g = next;
        }
        return g;
    }

    private static PlcBlock FindBlock(PlcBlockGroup g, string name)
    {
        var b = g.Blocks.Find(name);
        if (b != null) return b;
        foreach (PlcBlockUserGroup sub in g.Groups) { b = FindBlock(sub, name); if (b != null) return b; }
        return null;
    }

    private static PlcType FindType(PlcTypeGroup g, string name)
    {
        var t = g.Types.Find(name);
        if (t != null) return t;
        foreach (PlcTypeUserGroup sub in g.Groups) { t = FindType(sub, name); if (t != null) return t; }
        return null;
    }

    private static PlcTagTable FindTagTable(PlcTagTableGroup g, string name)
    {
        var t = g.TagTables.Find(name);
        if (t != null) return t;
        foreach (PlcTagTableUserGroup sub in g.Groups) { t = FindTagTable(sub, name); if (t != null) return t; }
        return null;
    }

    private static PlcSoftware GetPlc(Project project)
    {
        foreach (var dev in project.Devices)
            foreach (var item in dev.DeviceItems)
            {
                var c = item.GetService<SoftwareContainer>();
                if (c != null && c.Software is PlcSoftware) return (PlcSoftware)c.Software;
            }
        throw new Exception("No PlcSoftware found in project");
    }

    private static void PrintMessages(CompilerResultMessageComposition msgs, string indent)
    {
        foreach (var m in msgs)
        {
            if (m.State == CompilerResultState.Error || m.State == CompilerResultState.Warning)
                if (!string.IsNullOrEmpty(m.Description))
                    Console.WriteLine(indent + m.State + " " + m.Path + ": " + m.Description);
            PrintMessages(m.Messages, indent + "  ");
        }
    }

    private static string InnerMsg(Exception ex)
    {
        while (ex.InnerException != null) ex = ex.InnerException;
        return ex.Message.Replace("\r", " ").Replace("\n", " ");
    }
}

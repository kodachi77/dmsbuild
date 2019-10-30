////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2019 kodachi79
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
import std.algorithm;
import std.array;
import std.container;
import std.conv;
import std.format;
import std.functional;
import std.file;
import std.getopt;
import std.path;
import std.process : environment, spawnProcess, ProcessException, executeShell, wait;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.typecons;

import msver;

//----------------------------------------------------------------------------------------------------------------------

static bool isWin64Host()
{
    version (Win64)
    {
        return true;
    }
    else version (Windows)
    {
        import core.sys.windows.winbase : GetProcAddress, GetModuleHandleA, GetCurrentProcess;
        import core.sys.windows.windef : HANDLE, BOOL, PBOOL, FALSE;

        alias IsWow64Process = extern (Windows) BOOL function(HANDLE, PBOOL);
        __gshared IsWow64Process pIsWow64Process;

        if (!pIsWow64Process)
        {
            pIsWow64Process = cast(IsWow64Process) GetProcAddress(GetModuleHandleA("kernel32"), "IsWow64Process");
            if (!pIsWow64Process)
                return false;
        }
        BOOL bIsWow64 = FALSE;
        if (!pIsWow64Process(GetCurrentProcess(), &bIsWow64))
            return false;

        return bIsWow64 != 0;
    }
}

const bool bWin64Host;

//----------------------------------------------------------------------------------------------------------------------

struct Option
{
    bool listall;
    bool dbg;
    bool nocache;
    bool resetcache;
    bool novswhere;
    bool novs;
    bool nonetfx;

    // only these options affect cache entries
    bool noamd64;
    bool prerelease;
    string vswfilter;

    // VS-specific options; extracted from .sln file
    uint minVsVersion = 0;
    uint maxVsVersion = 0;
}

//----------------------------------------------------------------------------------------------------------------------

enum VsEdition
{
    Any,
    Community,
    Professional,
    Enterprise
}

//----------------------------------------------------------------------------------------------------------------------
struct VsInstance
{
    string path;
    VsEdition edition;
    MsVer ver;

    this(string p, string e, string v)
    {
        path = p;

        edition = cast(VsEdition) e.toLower().among("microsoft.visualstudio.product.community",
                "microsoft.visualstudio.product.professional", "microsoft.visualstudio.product.enterprise");

        ver = MsVer(v);
    }

    int opCmp(ref const VsInstance rhs) const
    {
        if (this.edition != rhs.edition)
            return this.edition < rhs.edition ? -1 : 1;

        return this.ver.opCmp(rhs.ver);
    }

    string toString() const
    {
        return format("%s, %s, %s", this.path, this.edition, this.ver);
    }
}

//----------------------------------------------------------------------------------------------------------------------

struct CacheEntry
{
    string msbPath;
    VsInstance vsVersion;
    bool isWin64 = false;

    this(string p, VsInstance v, bool x)
    {
        msbPath = p;
        vsVersion = v;
        isWin64 = x;
    }

    this(string p, string v, string e, int x64) //>
    {
        msbPath = p;
        vsVersion = VsInstance("", v, e);
        isWin64 = x64 > 0;
    }
}

//----------------------------------------------------------------------------------------------------------------------

uint getHashString(string filter, bool prerelease)
{
    import std.digest.murmurhash : MurmurHash3;

    auto mh = new MurmurHash3!(32);

    mh.put(cast(ubyte[]) format("==%s=%d=%d==", filter.toLower(), prerelease, g_option.noamd64));
    mh.finish();

    return mh.get();
}

//----------------------------------------------------------------------------------------------------------------------

class Cache
{
    alias Key = uint;

    private string _filename = "";
    private CacheEntry[Key] _cache;

    public this()
    {
        string cachePath = format("%s\\dmsbuild_cache", environment.get("Temp"));
        dbgprint("cache path: %s", cachePath);

        if (!cachePath.exists())
            cachePath.mkdirRecurse();

        version (Win64)
        {
            const uint ARCH = 64;
        }
        else
        {
            const uint ARCH = 32;
        }
        _filename = format("%s\\msbuild%d.txt", cachePath, ARCH);
    }

    public CacheEntry get(Key k)
    {
        return _cache[k];
    }

    public void put(Key k, CacheEntry v)
    {
        _cache[k] = v;
    }

    public bool opBinaryRight(string op)(Key rhs) const
    {
        if (op == "in")
        {
            return (rhs in _cache) != null;
        }
        else
            assert(0, "Operator " ~ op ~ " not implemented.");
    }

    public void read()
    {
        import std.meta : AliasSeq;

        alias TL = AliasSeq!(Key, string, string, string, int);
        alias Entry = Tuple!TL;

        if (_filename.exists())
        {
            auto entries = slurp!TL(_filename, "%u=%s,%s,%s,%d");
            foreach (Entry e; entries)
                _cache[e[0]] = CacheEntry(e.expand[1 .. $]);
        }
    }

    public void write()
    {
        auto file = File(_filename, "w");
        foreach (Key k, CacheEntry v; _cache)
            file.writeln(format("%u=%s,%s,%s,%d", k, v.msbPath, v.vsVersion.ver, v.vsVersion.edition, v.isWin64)); //>

        file.flush();
        scope (exit)
            if (file.isOpen)
                file.close();
    }

    public void reset()
    {
        if (_filename.exists())
        {
            dbgprint("resetting dmsbuild cache...");
            _filename.remove();
        }
    }
}

static Option g_option;
static auto g_msbuild = Array!string();

//----------------------------------------------------------------------------------------------------------------------

static this()
{
    bWin64Host = isWin64Host();
    g_option = Option();
}

//----------------------------------------------------------------------------------------------------------------------

bool isCrLf(dchar c) @safe pure nothrow @nogc
{
    return c == '\r' || c == '\n';
}

//----------------------------------------------------------------------------------------------------------------------

void dbgprint(A...)(lazy const char[] msg, lazy A args)
{
    if (g_option.dbg)
        stdout.writeln(format("[debug] %s", format(msg, args)));
}

//----------------------------------------------------------------------------------------------------------------------

string batOrExe(string filename)
{
    foreach (string ext; [".exe", ".bat", ".cmd"])
    {
        if (exists(filename ~ ext))
            return filename ~ ext;
    }
    return null;
}

//----------------------------------------------------------------------------------------------------------------------

string findVswhere()
{
    foreach (string envVar; ["ProgramFiles(x86)", "ProgramFiles"])
    {
        auto programFiles = environment.get(envVar);
        if (programFiles)
        {
            auto vswhere = batOrExe(format("%s\\Microsoft Visual Studio\\Installer\\vswhere", programFiles));
            if (vswhere)
                return vswhere;
        }
    }
    dbgprint("vswhere executable was not found.");
    return null;
}

//----------------------------------------------------------------------------------------------------------------------

bool findVsMsbuild(VsInstance vsver, ref string msb)
{
    bool ret = false;

    immutable auto majorVersion = vsver.ver.part(VersionPart.Major);
    auto vsverStr = format("%u.0", majorVersion);

    if (majorVersion >= 16)
        vsverStr = "Current";

    string check(string t)
    {
        auto ret = format(t, vsver.path, vsverStr);
        return exists(ret) ? ret : null;
    }

    msb = (bWin64Host && !g_option.noamd64) ? check("%s\\MSBuild\\%s\\Bin\\amd64\\MSBuild.exe") : check(
            "%s\\MSBuild\\%s\\Bin\\MSBuild.exe");
    if (msb)
    {
        immutable bool skipCheck = !g_option.minVsVersion && !g_option.maxVsVersion;
        immutable uint majorVer = skipCheck ? 0 : majorVersion;
        if (majorVer >= g_option.minVsVersion && majorVer <= g_option.maxVsVersion)
        {
            ret = g_msbuild.insertBack(msb) > 0;
        }
    }

    return g_option.listall ? false : ret;
}

//----------------------------------------------------------------------------------------------------------------------

string msbToolsPathFromRegistry(string ver)
{
    import std.windows.registry : Registry, Key, REGSAM, RegistryException;

    auto openFlag = REGSAM.KEY_READ;
    if (bWin64Host)
        openFlag |= g_option.noamd64 ? REGSAM.KEY_WOW64_32KEY : REGSAM.KEY_WOW64_64KEY;
    else
        openFlag |= REGSAM.KEY_WOW64_32KEY;

    try
    {
        auto key = Registry.localMachine().getKey("Software", openFlag).getKey("Microsoft")
            .getKey("MSBuild").getKey("ToolsVersions").getKey(ver);
        if (key)
        {
            auto path = key.getValue("MSBuildToolsPath").value_SZ;
            if (exists(path))
                return path;
        }
    }
    catch (RegistryException e)
    {
        // do nothing
    }
    return null;
}

//----------------------------------------------------------------------------------------------------------------------

bool findMsBuildFromRegistry(string ver)
in
{
    assert(ver.length);
}
do
{
    bool ret = false;

    auto path = msbToolsPathFromRegistry(ver);
    if (path)
    {
        path = stripRight(path, "\\");
        auto msb = format("%s\\MSBuild.exe", path);
        if (exists(msb))
            ret = g_msbuild.insertBack(msb) > 0;
    }
    return g_option.listall ? false : ret;
}

//----------------------------------------------------------------------------------------------------------------------

auto execVswhere(string vswhere, string vswfilter, bool prerelease)
{
    auto vspath = [
        "installationPath" : Array!string(), "installationVersion" : Array!string(),
        "productId" : Array!string()
    ];
    void addVsPath(string[] row)
    {
        if (row !is null && row.length == 2 && row[0] in vspath)
            vspath[row[0]].insertBack(row[1]);
    }

    string vswprerelease = prerelease ? "-prerelease" : "";

    auto cmdLine = format("\"%s\" -nologo %s -all -products * -requires %s Microsoft.Component.MSBuild",
            vswhere, vswprerelease, vswfilter);
    immutable auto res = executeShell(cmdLine);
    dbgprint("vswhere command line: %s", cmdLine);

    res.output
        .split!(isCrLf)
        .filter!(l => l.startsWith("installationPath") || l.startsWith("installationVersion")
                || l.startsWith("productId"))
        .map!(a => splitter(a, regex(": +")).array)
        .each!addVsPath;

    assert(vspath["installationPath"].length == vspath["installationVersion"].length);
    assert(vspath["installationPath"].length == vspath["productId"].length);

    return vspath;
}

//----------------------------------------------------------------------------------------------------------------------

bool msbFromVswhere()
{
    if (g_option.novswhere)
        return false;

    dbgprint("Searching using vswhere...");

    bool ret = false;

    auto cache = new Cache();

    if (!g_option.nocache)
        cache.read();

    if (g_option.resetcache)
        cache.reset();

    scope (exit)
        if (!g_option.nocache)
            cache.write();

    auto hash = getHashString(g_option.vswfilter, g_option.prerelease);
    if (hash in cache)
    {
        string msb = cache.get(hash).msbPath;
        return g_msbuild.insertBack(msb) > 0;
    }
    auto vswhere = findVswhere();
    if (vswhere)
    {
        auto vspath = execVswhere(vswhere, g_option.vswfilter, g_option.prerelease);
        if (vspath["installationPath"].length == 0)
        {
            dbgprint("MSBuild not found; relaxing condition...");

            vspath = execVswhere(vswhere, "", g_option.prerelease);
            if (vspath["installationPath"].length > 0)
            {
                hash = getHashString("", g_option.prerelease);
            }
            else if (!g_option.prerelease)
            {
                vspath = execVswhere(vswhere, "", true);
                hash = getHashString("", true);
            }
        }

        if (vspath["installationPath"].length > 0)
        {
            size_t len = vspath["installationPath"].length;
            VsInstance[] sortableVersion = new VsInstance[](len);

            for (size_t i = 0; i < len; ++i)
                sortableVersion[i] = VsInstance(vspath["installationPath"][i],
                        vspath["productId"][i], vspath["installationVersion"][i]);

            sortableVersion.sort!("a > b");

            dbgprint("VS sorted instances: ");
            for (size_t i = 0; i < len; ++i)
            {
                dbgprint("    %s", sortableVersion[i].toString());
                string msb;
                ret = findVsMsbuild(sortableVersion[i], msb);
                if (msb)
                    cache.put(hash, CacheEntry(msb, sortableVersion[i], g_option.noamd64));

                if (ret)
                    break;
            }
        }
    }
    return g_option.listall ? false : ret;
}

//----------------------------------------------------------------------------------------------------------------------

bool msbFromOldVS()
{
    if (g_option.novs)
        return false;

    bool ret = false;

    dbgprint("Searching in older Visual Studio - 2015, 2013...");
    foreach (string ver; ["14.0", "12.0"])
    {
        ret = findMsBuildFromRegistry(ver);
        if (ret)
            break;
    }
    return g_option.listall ? false : ret;
}

//----------------------------------------------------------------------------------------------------------------------

bool msbFromNetFramework()
{
    if (g_option.nonetfx)
        return false;

    bool ret = false;

    dbgprint("Searching in .NET Framework - .NET 4.0, 3.5, 2.0...");
    foreach (string ver; ["4.0", "3.5", "2.0"])
    {
        ret = findMsBuildFromRegistry(ver);
        if (ret)
            break;
    }
    return g_option.listall ? false : ret;
}

//----------------------------------------------------------------------------------------------------------------------

int runMsbuild(string msbuildExe, string[] args)
{
    auto shellArgs = args;
    shellArgs[0] = msbuildExe;

    string shellCommand = shellArgs.join(" ");
    dbgprint("Launching msbuild with the following command line: %s", shellCommand);

    try
    {
        auto pid = spawnProcess(shellArgs);
        return wait(pid);
    }
    catch (ProcessException e)
    {
        stderr.writeln("Failed to create msbuild process: %s", e.msg);
        return 1;
    }
}

//----------------------------------------------------------------------------------------------------------------------

auto detectSolutionVersion(string slnFile)
{
    // see https://docs.microsoft.com/en-us/visualstudio/extensibility/internals/solution-dot-sln-file?view=vs-2019

    uint[] versions = [10, 16];
    if (exists(slnFile))
    {
        auto r = regex([r"\w+\s*=\s*([0-9\.]+)", r"#\s+Visual Studio Version\s+([0-9]+)"]);
        auto file = File(slnFile, "r");
        foreach (char[] line; file.byLine())
        {
            int i = -1;
            if (line.startsWith("MinimumVisualStudioVersion"))
                i = 0;
            if (line.startsWith("#") || line.startsWith("VisualStudioVersion"))
                i = 1;

            if (i >= 0)
            {
                auto c = line.matchFirst(r);
                if (c.length == 2 && c[1].length)
                {
                    versions[i] = to!uint(c.whichPattern == 1 ? c[1].split(".")[0] : c[1]);
                }
            }

            if (line.startsWith("Project("))
                break;
        }
        scope (exit)
            if (file.isOpen)
                file.close();
    }

    dbgprint("Visual Studio solution versions: (%d, %d)", versions[0], versions[1]);
    return tuple(versions[0], versions[1]);
}

//----------------------------------------------------------------------------------------------------------------------

void processRemainingArgs(string[] args)
{
    foreach (string arg; args)
    {
        if (arg.endsWith(".sln"))
        {
            auto slnVer = detectSolutionVersion(arg);

            g_option.minVsVersion = slnVer[0];
            g_option.maxVsVersion = slnVer[1];
            return;
        }
    }
}

//----------------------------------------------------------------------------------------------------------------------
version (unittest)
{
}
else
    int main(string[] args)
{
    version (Windows)
    {
        bool showVersion = false, printPath = false;

        GetoptResult help;
        string[] vswRequire;
        try
        {
            arraySep = ",";
            // dfmt off
            help = getopt(args,
                config.passThrough,
                config.caseSensitive,
                "all", &g_option.listall,
                "no-vs", &g_option.novs,
                "no-netfx", &g_option.nonetfx,
                "no-vswhere", &g_option.novswhere,
                "vsw-require", &vswRequire,
                "no-cache", &g_option.nocache,
                "reset-cache", &g_option.resetcache,
                "no-amd64", &g_option.noamd64,
                "prerelease", &g_option.prerelease,
//>                "force", &g_option.vsversion,
                "print-path", &printPath,
                "debug", &g_option.dbg,
                "version", &showVersion);
            // dfmt off
        }
        catch(GetOptException e)
        {
            help.helpWanted = true;
        }

        if (help.helpWanted)
        {
            stdout.writeln("Usage: dmsuild [dmsbuild args] [msbuild.exe args]");
            // dfmt off
            auto helpString =
                "----------\n" ~
                "Arguments:\n" ~
                "----------\n" ~
                " --no-vs             - Disable searching for older Visual Studio (2013, 2015).\n" ~
                " --no-netfx          - Disable searching in .NET Framework folders.\n" ~
                " --no-vswhere        - Do not search via vswhere.\n" ~
                "\n" ~
                " --vsw-require {IDs} - Non-strict components preference: https://aka.ms/vs/workloads\n" ~
                "                       Comma-separated list.\n" ~
                "\n" ~
                " --all               - Collects info about all msbuild versions.\n" ~
                " --no-cache          - Do not cache vswhere for this request.\n" ~
                " --reset-cache       - Reset all cached vswhere versions before processing.\n" ~
                " --no-amd64          - Use 32-bit version of msbuild.exe.\n" ~
                " --prerelease        - Include possible beta releases.\n" ~
                //>" --force {version}   - Force certain Visual Studio version. 'latest' is used by default.\n" ~
                //>"                       You can also use partial versions like 15 or 16.2\n" ~
                " --print-path        - Display full path to msbuild.exe and exit.\n" ~
                " --debug             - Show dmsbuild diagnostic information.\n" ~
                " --version           - Display version of dmsbuild.\n" ~
                " --help              - Display this help.\n" ~
                "\n" ~
                "\n" ~
                "--------\n" ~
                "Examples:\n" ~
                "--------\n" ~
                "dmsbuild --no-amd64 \"UE4.sln\" /t:rebuild /p:configuration=\"Development Editor\"\n" ~
                "\n" ~
                //>"dmsbuild --force 15.9.21.664 \"UE4.sln\"\n" ~
                "dmsbuild --no-netfx --no-vs --no-amd64 \"UE4.sln\"\n" ~
                "dmsbuild --no-vs \"UE4.sln\"\n" ~
                "\n" ~
                "dmsbuild --all\n";
            // dfmt on
            stdout.writeln(helpString);

            return 1;
        }

        if (showVersion)
        {
            stdout.writeln("dmsbuild -- 0.0.1 -- Flexible way to access to msbuild.exe");
            stdout.writeln("Copyright (c) 2019 kodachi79\n");
            return 0;
        }

        g_option.vswfilter = vswRequire.length ? vswRequire.join(" ") : "";

        processRemainingArgs(args);

        if (g_option.listall)
        {
            g_option.nocache = true;
            g_option.resetcache = false;
            g_option.prerelease = true;
            g_option.vswfilter = "";
            g_option.novswhere = false;
            g_option.novs = false;
            g_option.nonetfx = false;
            g_option.noamd64 = false;

            g_option.minVsVersion = 0;
            g_option.maxVsVersion = 0;
        }

        bool ret = msbFromVswhere() || msbFromOldVS() || msbFromNetFramework();

        if (g_option.listall)
        {
            if (bWin64Host)
            {
                g_option.noamd64 = true;
                ret = msbFromVswhere() || msbFromOldVS() || msbFromNetFramework();
            }

            foreach (path; g_msbuild)
            {
                stdout.writeln(path);
                runMsbuild(path, ["", "-nologo", "-version"]);
                stdout.writeln();
            }
            return 0;
        }

        if (g_msbuild.length > 0)
        {
            string msbuildExe = g_msbuild[0];
            if (printPath)
            {
                stdout.writeln(msbuildExe);
                return 0;
            }

            return runMsbuild(msbuildExe, args);
        }

        stdout.writeln("MSBuild was not found. Use `--debug` command argument for details.");
    }

    return 0;
}

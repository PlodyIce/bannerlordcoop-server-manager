using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;

// Loaded into the game engine through DOTNET_STARTUP_HOOKS, and only when
// the server is started with mods (see lib/mods.sh).
//
// WHY IT EXISTS
// -------------
// Mods reference interface assemblies such as SandBox.View or
// TaleWorlds.GauntletUI. A dedicated server has those only inside the Coop
// module, and the engine loads Coop after every mod, so a mod's types fail
// to load before anything could have supplied them. The engine gives up with
// a ReflectionTypeLoadException and exit code 82.
//
// WHAT IT DOES
// ------------
// When the runtime cannot find an assembly, this looks for it in the
// folders listed in COOP_ASSEMBLY_DIRS, separated by ';', in that order. The
// manager puts the server's own folders first, Coop's above all, so a
// library both sides carry, 0Harmony for one, always comes from the server's
// build. A mod's private libraries are found in its own folder after that.
//
// It is a fallback and nothing more: it runs only once normal probing has
// failed, it hands back an assembly that is already loaded rather than load a
// second copy, and it patches no game code.
internal static class StartupHook
{
    private const string Prefix = "[coop-hook] ";
    private static string[] _dirs = Array.Empty<string>();

    public static void Initialize()
    {
        _dirs = (Environment.GetEnvironmentVariable("COOP_ASSEMBLY_DIRS") ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(Directory.Exists)
            .ToArray();
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        Console.WriteLine($"{Prefix}assembly fallback over {_dirs.Length} folder(s)");
    }

    private static Assembly? Resolve(object? sender, ResolveEventArgs args)
    {
        var name = new AssemblyName(args.Name).Name;
        if (string.IsNullOrEmpty(name) || name.EndsWith(".resources", StringComparison.OrdinalIgnoreCase))
            return null;

        var loaded = AppDomain.CurrentDomain.GetAssemblies()
            .FirstOrDefault(a => string.Equals(a.GetName().Name, name, StringComparison.OrdinalIgnoreCase));
        if (loaded != null)
            return loaded;

        foreach (var dir in _dirs)
        {
            var path = Path.Combine(dir, name + ".dll");
            if (!File.Exists(path))
                continue;
            try
            {
                var assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(path);
                Console.WriteLine($"{Prefix}{name} <- {path}");
                return assembly;
            }
            catch (Exception e) when (e is BadImageFormatException || e is FileLoadException)
            {
                Console.WriteLine($"{Prefix}{name}: {path} could not be loaded ({e.GetType().Name})");
            }
        }
        return null;
    }
}

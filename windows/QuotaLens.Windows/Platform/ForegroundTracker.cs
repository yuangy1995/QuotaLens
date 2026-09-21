using System.Diagnostics;
using System.Runtime.InteropServices;
using QuotaLens.Core;

namespace QuotaLens.Windows.Platform;

public sealed record ForegroundState(Provider? Tool, IntPtr Window, bool Ambiguous);

/// <summary>App/window identity only. No screen capture, keystrokes, titles, conversation text or UI Automation reads.</summary>
public sealed class ForegroundTracker : IDisposable
{
    private readonly NativeMethods.WinEventProc callback;
    private readonly IntPtr foregroundHook;
    private readonly IntPtr locationHook;
    private readonly Timer timer;
    private readonly int ownPid = Environment.ProcessId;
    private int pending;
    private int disposed;
    private ForegroundState current = new(null, IntPtr.Zero, false);
    public ForegroundState Current => Volatile.Read(ref current);
    public Provider? LastTool { get; private set; }
    public event Action<ForegroundState>? Changed;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, ProcessId; public UIntPtr DefaultHeap; public uint ModuleId, Threads, ParentProcessId;
        public int Priority; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Executable;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
    public ForegroundTracker()
    {
        callback = OnEvent;
        foregroundHook = NativeMethods.SetWinEventHook(3, 3, IntPtr.Zero, callback, 0, 0, 0);
        locationHook = NativeMethods.SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, callback, 0, 0, 0);
        timer = new Timer(_ => Schedule(), null, TimeSpan.Zero, TimeSpan.FromSeconds(2));
    }
    private void OnEvent(IntPtr hook, uint evt, IntPtr window, int objectId, int childId, uint thread, uint time)
    {
        if (evt == 3 || window == Current.Window && objectId == 0) Schedule();
    }
    private void Schedule()
    {
        if (disposed != 0 || Interlocked.Exchange(ref pending, 1) != 0) return;
        _ = Task.Run(() => {
            try
            {
                var state = Inspect(); Volatile.Write(ref current, state);
                if (state.Tool is { } tool) LastTool = tool;
                if (disposed == 0) Changed?.Invoke(state);
            }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or ArgumentException) { }
            finally { Interlocked.Exchange(ref pending, 0); }
        });
    }
    private ForegroundState Inspect()
    {
        IntPtr window = NativeMethods.GetForegroundWindow();
        if (window == IntPtr.Zero || !NativeMethods.IsWindowVisible(window) || NativeMethods.IsIconic(window)) return new(null, window, false);
        NativeMethods.GetWindowThreadProcessId(window, out uint pid);
        if (pid == ownPid || pid == 0) return new(null, window, false);
        using var process = Process.GetProcessById((int)pid); string name = process.ProcessName.ToLowerInvariant();
        var direct = Tool(name);
        if (direct is not null) return new(direct, window, false);
        if (name is not ("windowsterminal" or "wt" or "powershell" or "pwsh" or "cmd" or "conhost" or "code" or "code - insiders")) return new(null, window, false);
        var descendants = DescendantTools(pid);
        return descendants.Count == 1 ? new(descendants.Single(), window, false) : new(null, window, descendants.Count > 1);
    }
    private static Provider? Tool(string name)
    {
        name = Path.GetFileNameWithoutExtension(name).ToLowerInvariant();
        return name switch { "codex" => Provider.Codex, "claude" => Provider.Claude,
            "antigravity" or "antigravity ide" => Provider.Antigravity, _ => null };
    }
    private static HashSet<Provider> DescendantTools(uint host)
    {
        var rows = new List<(uint Id, uint Parent, string Name)>(); var result = new HashSet<Provider>();
        IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) return result;
        try
        {
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>(), Executable = "" };
            if (!Process32FirstW(snapshot, ref entry)) return result;
            do { rows.Add((entry.ProcessId, entry.ParentProcessId, entry.Executable)); } while (Process32NextW(snapshot, ref entry) && rows.Count < 20000);
        }
        finally { CloseHandle(snapshot); }
        var parents = rows.GroupBy(x => x.Id).ToDictionary(x => x.Key, x => x.First().Parent);
        foreach (var row in rows)
        {
            if (Tool(row.Name) is not { } tool) continue;
            uint cursor = row.Parent; var visited = new HashSet<uint>();
            while (cursor != 0 && visited.Add(cursor))
            {
                if (cursor == host) { result.Add(tool); break; }
                if (!parents.TryGetValue(cursor, out cursor)) break;
            }
        }
        return result;
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        timer.Dispose(); if (foregroundHook != IntPtr.Zero) NativeMethods.UnhookWinEvent(foregroundHook);
        if (locationHook != IntPtr.Zero) NativeMethods.UnhookWinEvent(locationHook);
    }
}

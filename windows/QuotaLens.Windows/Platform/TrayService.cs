using System.Runtime.InteropServices;

namespace QuotaLens.Windows.Platform;

public sealed class TrayService : IDisposable
{
    private const uint CallbackMessage = 0x8000 + 81;
    private readonly IntPtr hwnd;
    private readonly NativeMethods.SubclassProc callback;
    private readonly uint taskbarCreated = NativeMethods.RegisterWindowMessage("TaskbarCreated");
    private readonly IntPtr icon;
    private readonly bool ownsIcon;
    private int disposed;
    private string tooltip = "QuotaLens";
    public bool IsAdded { get; private set; }
    public bool Chinese { get; set; }
    public bool Paused { get; set; }
    public event Action? OpenRequested;
    public event Action? PanelRequested;
    public event Action? RefreshRequested;
    public event Action? PauseRequested;
    public event Action? SettingsRequested;
    public event Action? ExitRequested;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size; public IntPtr Window; public uint Id, Flags, Callback; public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public IntPtr BalloonIcon;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);
    public TrayService(IntPtr window)
    {
        hwnd = window; callback = WindowMessage;
        string file = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(file)) { icon = NativeMethods.LoadImage(IntPtr.Zero, file, 1, 0, 0, 0x10 | 0x40); ownsIcon = icon != IntPtr.Zero; }
        if (icon == IntPtr.Zero) icon = NativeMethods.LoadIconW(IntPtr.Zero, new IntPtr(32512));
        if (!NativeMethods.SetWindowSubclass(hwnd, callback, new UIntPtr(0x514C), UIntPtr.Zero))
            throw new InvalidOperationException("The taskbar callback could not be registered.");
        Add();
    }
    private NotifyIconData Data(uint flags) => new() { Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = hwnd, Id = 1,
        Flags = flags, Callback = CallbackMessage, Icon = icon, Tip = tooltip, Info = "", InfoTitle = "", Version = 4 };
    private void Add()
    {
        var data = Data(1 | 2 | 4 | 0x80); IsAdded = Shell_NotifyIconW(0, ref data);
        if (IsAdded) Shell_NotifyIconW(4, ref data);
    }
    public void Update(string text)
    {
        tooltip = text.Length > 127 ? text[..127] : text;
        if (!IsAdded) { Add(); return; }
        var data = Data(4 | 0x80); Shell_NotifyIconW(1, ref data);
    }
    public void Notify(string title, string message)
    {
        if (!IsAdded) return;
        var data = Data(0x10); data.InfoTitle = title.Length > 63 ? title[..63] : title;
        data.Info = message.Length > 255 ? message[..255] : message; data.InfoFlags = 1;
        Shell_NotifyIconW(1, ref data);
    }
    private IntPtr WindowMessage(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        try
        {
            if (message == taskbarCreated) { IsAdded = false; Add(); }
            else if (message == CallbackMessage)
            {
                uint action = (uint)(lParam.ToInt64() & 0xffff);
                if (action is 0x400 or 0x401 or 0x202) PanelRequested?.Invoke();
                else if (action == 0x203) OpenRequested?.Invoke();
                else if (action is 0x7B or 0x205) ContextMenu();
                return IntPtr.Zero;
            }
        }
        catch { /* Never propagate a managed exception across a native window procedure. */ }
        return NativeMethods.DefSubclassProc(window, message, wParam, lParam);
    }
    private void ContextMenu()
    {
        IntPtr menu = NativeMethods.CreatePopupMenu();
        try
        {
            void Add(uint id, string zh, string en) => NativeMethods.AppendMenu(menu, 0, new UIntPtr(id), Chinese ? zh : en);
            Add(1, "打开 QuotaLens", "Open QuotaLens"); Add(2, "刷新额度", "Refresh quotas");
            Add(3, Paused ? "恢复自动刷新" : "暂停自动刷新", Paused ? "Resume automatic refresh" : "Pause automatic refresh");
            Add(4, "应用设置", "Settings"); NativeMethods.AppendMenu(menu, 0x800, UIntPtr.Zero, null); Add(5, "退出", "Exit");
            NativeMethods.GetCursorPos(out var point); NativeMethods.SetForegroundWindow(hwnd);
            uint selected = NativeMethods.TrackPopupMenuEx(menu, 0x100 | 2, point.X, point.Y, hwnd, IntPtr.Zero);
            NativeMethods.PostMessageW(hwnd, 0, UIntPtr.Zero, IntPtr.Zero);
            switch (selected) { case 1: OpenRequested?.Invoke(); break; case 2: RefreshRequested?.Invoke(); break;
                case 3: PauseRequested?.Invoke(); break; case 4: SettingsRequested?.Invoke(); break; case 5: ExitRequested?.Invoke(); break; }
        }
        finally { NativeMethods.DestroyMenu(menu); }
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        var data = Data(0); Shell_NotifyIconW(2, ref data); IsAdded = false;
        NativeMethods.RemoveWindowSubclass(hwnd, callback, new UIntPtr(0x514C));
        if (ownsIcon) NativeMethods.DestroyIcon(icon);
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace YakuLingo.Desktop
{
    internal static class Program
    {
        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [STAThread]
        private static void Main(string[] args)
        {
            if (TryRunCleanupWatcher(args)) return;
            foreach (string raw in args)
            {
                if (String.Equals(raw, "--self-test", StringComparison.OrdinalIgnoreCase))
                {
                    Environment.ExitCode = RunSelfTest();
                    return;
                }
            }
            try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            string command = "HOME";
            foreach (string arg in args)
            {
                if (String.Equals(arg, "--background", StringComparison.OrdinalIgnoreCase)) command = "BACKGROUND";
                if (String.Equals(arg, "--quick", StringComparison.OrdinalIgnoreCase)) command = "QUICK";
                if (String.Equals(arg, "--cat", StringComparison.OrdinalIgnoreCase)) command = "CAT";
            }

            string identity = WindowsIdentity.GetCurrent().User.Value;
            string suffix = ShortHash(identity);
            string mutexName = "Local\\YakuLingoShell-" + suffix;
            string pipeName = "YakuLingoShell-" + suffix;
            bool created;
            using (Mutex mutex = new Mutex(true, mutexName, out created))
            {
                if (!created)
                {
                    SendExistingCommand(pipeName, command == "BACKGROUND" ? "HOME" : command);
                    return;
                }
                PurgeStaleWebViewData();
                using (ShellForm form = new ShellForm(pipeName, command))
                {
                    Application.Run(form);
                }
            }
        }

        private static bool TryRunCleanupWatcher(string[] args)
        {
            if (args == null || args.Length != 4 || !String.Equals(args[0], "--cleanup-udf", StringComparison.OrdinalIgnoreCase)) return false;
            int pid;
            long startedTicks;
            if (!Int32.TryParse(args[1], out pid) || !Int64.TryParse(args[2], out startedTicks)) return true;
            try
            {
                string root = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YakuLingo", "webview2-temp"));
                string target = Path.GetFullPath(args[3]);
                if (!target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return true;
                try
                {
                    Process owner = Process.GetProcessById(pid);
                    if (owner.StartTime.ToUniversalTime().Ticks == startedTicks) owner.WaitForExit();
                }
                catch { }
                for (int attempt = 0; attempt < 40 && Directory.Exists(target); attempt++)
                {
                    try { Directory.Delete(target, true); }
                    catch { Thread.Sleep(500); }
                }
            }
            catch { }
            return true;
        }

        private static void PurgeStaleWebViewData()
        {
            try
            {
                string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YakuLingo", "webview2-temp");
                if (!Directory.Exists(root)) return;
                foreach (string directory in Directory.GetDirectories(root))
                {
                    try { Directory.Delete(directory, true); } catch { }
                }
            }
            catch { }
        }

        private static int RunSelfTest()
        {
            try
            {
                string desktop = AppDomain.CurrentDomain.BaseDirectory;
                string app = Directory.GetParent(desktop.TrimEnd(Path.DirectorySeparatorChar)).FullName;
                string[] required = {
                    Path.Combine(desktop, "Microsoft.Web.WebView2.Core.dll"),
                    Path.Combine(desktop, "Microsoft.Web.WebView2.WinForms.dll"),
                    Path.Combine(desktop, "WebView2Loader.dll"),
                    Path.Combine(app, "Start-YakuLingo.ps1"),
                    Path.Combine(app, "config", "build.txt")
                };
                foreach (string path in required) if (!File.Exists(path)) return 2;
                string version = CoreWebView2Environment.GetAvailableBrowserVersionString(null);
                return String.IsNullOrWhiteSpace(version) ? 3 : 0;
            }
            catch { return 4; }
        }

        private static string ShortHash(string value)
        {
            using (SHA256 sha = SHA256.Create())
            {
                byte[] bytes = sha.ComputeHash(Encoding.UTF8.GetBytes(value));
                StringBuilder result = new StringBuilder();
                for (int i = 0; i < 12; i++) result.Append(bytes[i].ToString("x2"));
                return result.ToString();
            }
        }

        private static void SendExistingCommand(string pipeName, string command)
        {
            try
            {
                using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out))
                {
                    pipe.Connect(1500);
                    using (StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false)))
                    {
                        writer.WriteLine(command);
                        writer.Flush();
                    }
                }
            }
            catch { }
        }
    }

    internal sealed class ShellForm : Form
    {
        private const int HotkeyId = 0x594A;
        private const uint ModAlt = 0x0001;
        private const uint ModControl = 0x0002;
        private const uint ModNoRepeat = 0x4000;
        private const uint VkJ = 0x4A;
        private const int WmHotkey = 0x0312;

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        // Ctrl+Alt+J は「押すだけで、いま選んでいる文章を訳す」ためのもの。
        // 選択の取り方は相手のアプリで違う（2026-08-11 実測）。
        //   Word(OpusApp) / Excel(XLMAIN) : Office COM。バックエンドが読む。ここでは
        //                                   窓のクラスとハンドルを覚えるだけ
        //   それ以外                      : COM が無いので Ctrl+C を送ってから
        //                                   クリップボードを読む
        // 疑似 Ctrl+C は Office には使わない。COM で確実に取れるのに、利用者の
        // クリップボードを壊す理由がない。
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll")]
        private static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        private const int InputKeyboard = 1;
        private const uint KeyEventKeyUp = 0x0002;
        private const ushort VkControl = 0x11;
        private const ushort VkC = 0x43;
        private const ushort VkAlt = 0x12;
        private const ushort VkShift = 0x10;
        private const ushort VkLWin = 0x5B;
        private const ushort VkRWin = 0x5C;

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public int type; public KEYBDINPUT ki; public int padding1; public int padding2;
        }
        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        // 通知領域のバルーンは、アイコンが隠れた領域にあると Windows が出さない。
        // 既定ではそこへ入るので、バルーンだけに頼ると完了に気づけない。
        // タスクバーの点滅は、アイコンの可視状態にも応答不可設定にも左右されない。
        [StructLayout(LayoutKind.Sequential)]
        private struct FLASHWINFO
        {
            public uint cbSize;
            public IntPtr hwnd;
            public uint dwFlags;
            public uint uCount;
            public uint dwTimeout;
        }
        [DllImport("user32.dll")]
        private static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
        private const uint FlashAll = 3;
        private const uint FlashTimerNoFg = 12;

        private readonly string appRoot;
        private readonly string dataRoot;
        private readonly string preferencesPath;
        private readonly string userDataFolder;
        private readonly string pipeName;
        private readonly JavaScriptSerializer json = new JavaScriptSerializer();
        private readonly WebView2 webView = new WebView2();
        private readonly NotifyIcon tray = new NotifyIcon();
        private readonly ToolStripMenuItem trayStatus = new ToolStripMenuItem("準備しています");
        private readonly ToolStripMenuItem startupItem = new ToolStripMenuItem("次回から、サインイン時に自動で準備する");
        // 2026-08-13: 「その場で訳す」「資料翻訳」という2つの呼び名をやめた。
        // 貼り付けた文章も資料と同じ確認作業になり、/quick と /cat は同じ画面を返す。
        // 2つの項目が同じ所へ着くのに違う名前で並んでいると、片方だけの機能が
        // あるように読める。違うのは「選択を読んでから開くか」だけなので、そう書く。
        private readonly ToolStripMenuItem quickItem = new ToolStripMenuItem("選んでいる文章を訳す    Ctrl+Alt+J");
        private readonly ToolStripMenuItem catItem = new ToolStripMenuItem("YakuLingo を開く");
        private readonly System.Windows.Forms.Timer backendTimer = new System.Windows.Forms.Timer();
        private Thread pipeThread;
        private volatile bool stopping;
        private bool exiting;
        private bool hotkeyRegistered;
        private bool firstHideNoticeShown;
        private bool webReady;
        private bool backendStarting;
        private int backendFailureCount;
        private DateTime backendRetryAfter = DateTime.MinValue;
        private bool tutorialCompleted;
        private string activeOrigin = "";
        private string activeBaseUrl = "";
        private string desiredRoute = "/";
        // 資料翻訳は ?project=<id> を持つ。desiredRoute と分けて覚えないと、
        // 画面サイズの判定（"/cat" との文字列比較）が壊れる。
        private string desiredQuery = "";
        // 資料翻訳へ入るときの自動リサイズは1回だけ。以後は利用者の大きさを尊重する。
        private bool catWindowResizedByUser;
        private string pendingQuickText = "";
        private bool pendingQuickSubmit;
        // Office のときは本文をここで読まない。窓のクラスとハンドルだけ覚え、
        // バックエンドに COM で読ませる。
        private string pendingOfficeClass = "";
        private long pendingOfficeHwnd;
        // いま実際に読み込みが終わっている画面。webView.Source は使えない。
        // 二重に裏切られた場所なので、両方書いておく。
        //   1. Navigate を始めた瞬間に新しい URL へ変わる（まだ居ない画面へ通知を投げた）
        //   2. 画面が history.replaceState で書き換える。cat.js は /quick で開いても
        //      アドレスを /cat へ直すので、読み込み完了時には /quick が消えている
        // どちらも実機で選択が黙って消える形で出た（2026-08-11）。判断はこちらが
        // 指示した行き先（navigatingPath）だけで行う。
        private string loadedPath = "";
        private string navigatingPath = "";
        private Size quickWindowSize = new Size(650, 640);
        // 確認作業の窓。1400x900 で固定していたため、1920px の画面でも 1400px に
        // 縮めており、原文と訳文の列に回せる幅を自分で捨てていた（実測 2026-08-13:
        // 1920px なら 1列 501px 取れるのに、1400px では 421px）。画面の作業領域から
        // 決める。利用者が自分で変えたら RememberCurrentWindowSize がここへ書き戻す
        // ので、以後はその大きさが優先される。
        private Size catWindowSize = new Size(1400, 900);
        private bool catWindowSizeChosenByUser;
        private Size PreferredCatWindowSize()
        {
            if (catWindowSizeChosenByUser) return catWindowSize;
            Rectangle work;
            try { work = Screen.FromControl(this).WorkingArea; }
            catch { return catWindowSize; }
            // 端に少し余白を残す。上限は、これ以上広げても1行が長くなりすぎる幅で止める。
            int width = Math.Min(work.Width - 64, 1760);
            int height = Math.Min(work.Height - 64, 1040);
            if (width < 900) width = Math.Min(work.Width, 900);
            if (height < 620) height = Math.Min(work.Height, 620);
            return new Size(width, height);
        }
        // 大きさだけ変えると、窓が画面の外へ出る。実機で確認（2026-08-13）:
        // ホームの窓は中央寄せで x=340 に居り、そこから幅 1760 にすると右端が 2100 と
        // なって、画面（1920）から 180px はみ出していた。広げたら位置も戻す。
        private void ApplyCatWindowSize(Size target)
        {
            MinimumSize = new Size(900, 620);
            Size = target;
            Rectangle work;
            try { work = Screen.FromControl(this).WorkingArea; }
            catch { return; }
            int x = Left;
            int y = Top;
            if (x + target.Width > work.Right) x = work.Right - target.Width;
            if (y + target.Height > work.Bottom) y = work.Bottom - target.Height;
            if (x < work.Left) x = work.Left;
            if (y < work.Top) y = work.Top;
            Location = new Point(x, y);
        }
        private Size homeWindowSize = new Size(1240, 840);
        private Process backendProcess;
        private Icon appIcon;

        internal ShellForm(string pipeName, string initialCommand)
        {
            this.pipeName = pipeName;
            appRoot = Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)).FullName;
            string profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            dataRoot = Path.Combine(profile, ".yakulingo-ps");
            preferencesPath = Path.Combine(dataRoot, "config", "desktop_preferences.json");
            userDataFolder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "YakuLingo", "webview2-temp", Guid.NewGuid().ToString("N"));
            StartCleanupWatcher();

            Text = "YakuLingo";
            // 通知領域に8個も並ぶ中で、Windows既定の汎用アイコンでは
            // どれが YakuLingo か見分けられない。専用アイコンを使う。
            appIcon = LoadAppIcon();
            Icon = appIcon;
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(520, 480);
            Size = new Size(1240, 840);
            AutoScaleMode = AutoScaleMode.Dpi;
            Controls.Add(webView);
            webView.Dock = DockStyle.Fill;

            tray.Icon = appIcon;
            tray.Text = "YakuLingo";
            tray.Visible = true;
            // 通知領域のアイコンを両押しするのは「アプリを前に出す」動作。
            // ここで /quick へ飛ばすと、打ちかけの訳文がある資料翻訳から黙って離れてしまう。
            tray.DoubleClick += delegate { RestoreLastScreen(); };
            ContextMenuStrip menu = new ContextMenuStrip();
            trayStatus.Enabled = false;
            menu.Items.Add(trayStatus);
            menu.Items.Add(new ToolStripSeparator());
            quickItem.Click += delegate { OpenQuick(); };
            menu.Items.Add(quickItem);
            catItem.Click += delegate { OpenCat(); };
            menu.Items.Add(catItem);
            menu.Items.Add(new ToolStripSeparator());
            startupItem.CheckOnClick = false;
            startupItem.Click += delegate { RequestStartupChange(!startupItem.Checked); };
            menu.Items.Add(startupItem);
            ToolStripMenuItem exit = new ToolStripMenuItem("YakuLingoを終了");
            exit.Click += delegate { RequestExit(); };
            menu.Items.Add(exit);
            menu.Opening += delegate { RefreshPreferencesMenu(); };
            tray.ContextMenuStrip = menu;

            backendTimer.Interval = 850;
            backendTimer.Tick += async delegate { await CheckBackendAsync(); };
            FormClosing += OnFormClosing;
            bool startHidden = String.Equals(initialCommand, "BACKGROUND", StringComparison.OrdinalIgnoreCase);
            if (startHidden)
            {
                Opacity = 0;
                ShowInTaskbar = false;
                WindowState = FormWindowState.Minimized;
            }
            Shown += async delegate
            {
                if (startHidden)
                {
                    Hide();
                    Opacity = 1;
                    ShowInTaskbar = true;
                    WindowState = FormWindowState.Normal;
                }
                else if (String.Equals(initialCommand, "QUICK", StringComparison.OrdinalIgnoreCase)) OpenQuick();
                else if (String.Equals(initialCommand, "CAT", StringComparison.OrdinalIgnoreCase)) OpenCat();
                try
                {
                    await InitializeWebViewAsync();
                    StartBackendIfNeeded();
                    backendTimer.Start();
                }
                catch
                {
                    webReady = false;
                    backendStarting = false;
                    trayStatus.Text = "画面を準備できませんでした";
                    if (!startHidden) MessageBox.Show(this, "YakuLingoの画面を準備できませんでした。WebView2 Runtimeがインストールされているか確認し、YakuLingoを再起動してください。", "YakuLingo", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            };
            FormClosed += delegate { Cleanup(); };
            NetworkChange.NetworkAvailabilityChanged += OnNetworkAvailabilityChanged;
            SystemEvents.PowerModeChanged += OnPowerModeChanged;

            tutorialCompleted = ReadBooleanPreference("tutorial_completed", false);
            if (!tutorialCompleted) desiredRoute = "/tutorial";
            EnsureShortcutsForCurrentVersion();
            StartPipeServer();
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            hotkeyRegistered = RegisterHotKey(Handle, HotkeyId, ModControl | ModAlt | ModNoRepeat, VkJ);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WmHotkey && m.WParam.ToInt32() == HotkeyId)
            {
                CaptureForegroundSelection();
                OpenQuick();
                FlushPendingOfficeSelection();
            }
            base.WndProc(ref m);
        }

        // Office のときは本文をここで持たない。窓のクラスとハンドルだけ渡し、
        // ページからバックエンドへ読ませる。C# は COM を1行も書かない。
        //
        // 既に /quick を開いている窓では再ナビゲートが起きず NavigationCompleted が
        // 発火しないので、ホットキー処理からも直接呼ぶ。別の画面から来たときは
        // loadedPath がまだ /quick ではないのでここでは何もせず、読み込みが
        // 終わってから NavigationCompleted 側で送る。控えは送った時だけ消す。
        private void FlushPendingOfficeSelection()
        {
            if (!webReady) return;
            if (!loadedPath.Equals("/quick", StringComparison.OrdinalIgnoreCase)) return;
            if (String.IsNullOrEmpty(pendingOfficeClass)) return;
            string cls = pendingOfficeClass;
            long hwnd = pendingOfficeHwnd;
            pendingOfficeClass = "";
            pendingOfficeHwnd = 0;
            try
            {
                webView.CoreWebView2.PostWebMessageAsJson(
                    "{\"type\":\"yaku-office-selection\",\"window_class\":" + json.Serialize(cls) + ",\"foreground_hwnd\":" + hwnd + "}");
            }
            catch { }
        }

        // 押した瞬間の前面の窓を見て、選択を取る。窓を出すより先に取ること。
        // 先に出すと前面が自分になり、自分の入力欄を読んでしまう。
        private void CaptureForegroundSelection()
        {
            pendingOfficeClass = "";
            pendingOfficeHwnd = 0;
            try
            {
                IntPtr fg = GetForegroundWindow();
                if (fg == IntPtr.Zero) return;
                StringBuilder cls = new StringBuilder(256);
                GetClassName(fg, cls, cls.Capacity);
                string name = cls.ToString();
                // PPTFrameClass = PowerPoint。図形を選んだ状態では疑似 Ctrl+C で
                // 文字が取れないため（2026-08-12 実測）、COM で読む側へ回す。
                // Outlook はここに入れない。理由は src/Selection.ps1 に書いた。
                if (name == "OpusApp" || name == "XLMAIN" || name == "PPTFrameClass")
                {
                    // Office はバックエンドが COM で読む。クリップボードには触れない。
                    pendingOfficeClass = name;
                    pendingOfficeHwnd = fg.ToInt64();
                    return;
                }
                string copied = CopySelectionFromForeground();
                if (!String.IsNullOrWhiteSpace(copied))
                {
                    pendingQuickText = copied;
                    pendingQuickSubmit = false;
                }
            }
            catch { }
        }

        // Office 以外には COM が無いので Ctrl+C を送る。クリップボードは置き換わる
        // （利用者判断で受け入れ、復元は試みない。Excel 由来の遅延描画形式は原理的に
        // 復元できず、「復元したつもりで壊れている」ほうが悪い）。
        //
        // 選択が無いときに前の中身を送らないことが要点。連番が変わらなければ、
        // 新しく置かれていないので読まない。
        private string CopySelectionFromForeground()
        {
            uint before = GetClipboardSequenceNumber();
            SendCtrlC();
            for (int i = 0; i < 12; i++)
            {
                System.Threading.Thread.Sleep(40);
                if (GetClipboardSequenceNumber() == before) continue;
                try
                {
                    if (Clipboard.ContainsText()) return Clipboard.GetText();
                }
                catch { }
                return "";
            }
            return "";
        }

        // WM_HOTKEY は「押した瞬間」に来るので、この時点で Ctrl と Alt はまだ
        // 押されたままである。そのまま Ctrl+C を送ると Ctrl+Alt+C になり、コピーに
        // ならない（2026-08-11、メモ帳で1文字もコピーされず実機で判明）。
        // 少し待って離してもらい、それでも残っていれば離した扱いの入力を送る。
        private void ReleaseHotkeyModifiers()
        {
            for (int i = 0; i < 20; i++)
            {
                bool held = (GetAsyncKeyState(VkAlt) & 0x8000) != 0 || (GetAsyncKeyState(VkControl) & 0x8000) != 0;
                if (!held) return;
                System.Threading.Thread.Sleep(15);
            }
            ushort[] stuck = new ushort[] { VkAlt, VkShift, VkLWin, VkRWin, VkControl };
            INPUT[] seq = new INPUT[stuck.Length];
            for (int i = 0; i < stuck.Length; i++)
            {
                seq[i].type = InputKeyboard;
                seq[i].ki.wVk = stuck[i];
                seq[i].ki.dwFlags = KeyEventKeyUp;
            }
            SendInput((uint)seq.Length, seq, Marshal.SizeOf(typeof(INPUT)));
        }

        private void SendCtrlC()
        {
            ReleaseHotkeyModifiers();
            INPUT[] seq = new INPUT[4];
            seq[0].type = InputKeyboard; seq[0].ki.wVk = VkControl;
            seq[1].type = InputKeyboard; seq[1].ki.wVk = VkC;
            seq[2].type = InputKeyboard; seq[2].ki.wVk = VkC; seq[2].ki.dwFlags = KeyEventKeyUp;
            seq[3].type = InputKeyboard; seq[3].ki.wVk = VkControl; seq[3].ki.dwFlags = KeyEventKeyUp;
            SendInput((uint)seq.Length, seq, Marshal.SizeOf(typeof(INPUT)));
        }

        private void StartCleanupWatcher()
        {
            try
            {
                Process current = Process.GetCurrentProcess();
                ProcessStartInfo start = new ProcessStartInfo(Application.ExecutablePath,
                    "--cleanup-udf " + current.Id.ToString() + " " + current.StartTime.ToUniversalTime().Ticks.ToString() + " \"" + userDataFolder + "\"");
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                Process.Start(start);
            }
            catch { }
        }

        private async Task InitializeWebViewAsync()
        {
            Directory.CreateDirectory(userDataFolder);
            CoreWebView2EnvironmentOptions options = new CoreWebView2EnvironmentOptions("--disk-cache-size=1 --media-cache-size=1 --disable-session-crashed-bubble");
            CoreWebView2Environment environment = await CoreWebView2Environment.CreateAsync(null, userDataFolder, options);
            await webView.EnsureCoreWebView2Async(environment);
            CoreWebView2 core = webView.CoreWebView2;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = true;
            core.Settings.AreHostObjectsAllowed = false;
            core.NavigationStarting += OnNavigationStarting;
            core.NavigationCompleted += OnNavigationCompleted;
            core.NewWindowRequested += OnNewWindowRequested;
            core.PermissionRequested += delegate(object sender, CoreWebView2PermissionRequestedEventArgs e) { e.State = CoreWebView2PermissionState.Deny; };
            core.DownloadStarting += delegate(object sender, CoreWebView2DownloadStartingEventArgs e) { e.Cancel = true; };
            core.WebMessageReceived += OnWebMessageReceived;
            webReady = true;
            ShowLocalWaitingPage(desiredRoute == "/quick");
        }

        private void OnNavigationStarting(object sender, CoreWebView2NavigationStartingEventArgs e)
        {
            Uri uri;
            // 読み込みが始まった時点で「いま居る画面」は無効になる。読み終えるまで
            // 画面あての通知を投げない。
            loadedPath = "";
            navigatingPath = "";
            if (String.Equals(e.Uri, "about:blank", StringComparison.OrdinalIgnoreCase)) return;
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out uri) || !IsTrustedOrigin(uri))
            {
                e.Cancel = true;
                return;
            }
            navigatingPath = uri.AbsolutePath;
        }

        private async void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (!e.IsSuccess || webView.Source == null || !IsTrustedOrigin(webView.Source)) return;
            loadedPath = String.IsNullOrEmpty(navigatingPath) ? webView.Source.AbsolutePath : navigatingPath;
            InjectHotkeyStatus();
            // 画面の中のカードから資料翻訳へ入ると OpenCat() を通らないので、
            // ホームの窓（1240x840）のまま3列の作業画面が開き、原文と訳文の列が潰れていた。
            // 資料翻訳に必要な広さへ広げる。利用者が自分で小さくした場合は尊重する。
            if (loadedPath.StartsWith("/cat", StringComparison.OrdinalIgnoreCase))
            {
                desiredRoute = "/cat";
                desiredQuery = webView.Source.Query;
                Size preferredCat = PreferredCatWindowSize();
                if (WindowState == FormWindowState.Normal && Width < preferredCat.Width && !catWindowResizedByUser)
                {
                    ApplyCatWindowSize(preferredCat);
                    catWindowResizedByUser = true;
                }
            }
            FlushPendingOfficeSelection();
            if (loadedPath.Equals("/quick", StringComparison.OrdinalIgnoreCase) && !String.IsNullOrEmpty(pendingQuickText))
            {
                string source = json.Serialize(pendingQuickText);
                bool submit = pendingQuickSubmit;
                pendingQuickText = "";
                pendingQuickSubmit = false;
                // Office と同じく、どこから来た文章かを画面に出す。出さないと
                // 「勝手に何か入った」になり、送る前の確認ができない。
                string script = "(function(){var x=document.getElementById('quick-input');if(!x)return;x.value=" + source + ";x.dispatchEvent(new Event('input',{bubbles:true}));x.focus({preventScroll:true});window.scrollTo(0,0);" +
                    "var n=document.getElementById('quick-selection-note');if(n){n.textContent='選んでいた文章を読み込みました（' + Array.from(x.value).length + ' 文字）。';n.hidden=false;}" +
                    // 取り込んだ事実を記録へ回す。本文は渡さない（文字数だけ）。
                    // Office 側はサーバが自分で記録するので、こちらの経路だけ知らせる。
                    "window.dispatchEvent(new CustomEvent('yaku-clipboard-selection',{detail:{chars:Array.from(x.value).length}}));" +
                    (submit ? "window.__yakuPendingQuickSubmit=true;window.dispatchEvent(new Event('yaku-pending-quick-submit'));" : "") + "})()";
                try { await webView.ExecuteScriptAsync(script); } catch { }
            }
        }

        private void OnNewWindowRequested(object sender, CoreWebView2NewWindowRequestedEventArgs e)
        {
            e.Handled = true;
        }

        private void OnWebMessageReceived(object sender, CoreWebView2WebMessageReceivedEventArgs e)
        {
            if (webView.Source == null || !IsTrustedOrigin(webView.Source)) return;
            Uri source;
            if (!Uri.TryCreate(e.Source, UriKind.Absolute, out source) || !IsTrustedOrigin(source)) return;
            try
            {
                Dictionary<string, object> message = json.Deserialize<Dictionary<string, object>>(e.WebMessageAsJson);
                if (message == null || message.Count != 1 || !message.ContainsKey("type")) return;
                string type = Convert.ToString(message["type"]);
                if (type == "desktop-preferences-changed")
                {
                    tutorialCompleted = ReadBooleanPreference("tutorial_completed", true);
                    EnsureShortcutsForCurrentVersion();
                    RefreshPreferencesMenu();
                }
                else if (type == "desktop-preferences-error")
                {
                    tray.ShowBalloonTip(7000, "YakuLingo", "自動起動の設定を変更できませんでした。最初の画面で「使い方を見る」を開き、起動の設定をやり直してください。", ToolTipIcon.Warning);
                }
                else if (type == "cat-workspace-opened")
                {
                    // 確認作業は3列で、狭いとツールバーが折り返す。画面を一つに
                    // したので、その場で訳す状態から画面遷移なしで確認作業へ入る
                    // 道ができた。NavigationCompleted の広げ直しはその道を通らない。
                    Size preferredCatOpen = PreferredCatWindowSize();
                    if (WindowState == FormWindowState.Normal && Width < preferredCatOpen.Width && !catWindowResizedByUser)
                    {
                        ApplyCatWindowSize(preferredCatOpen);
                        catWindowResizedByUser = true;
                    }
                }
                else if (type == "copilot-ready")
                {
                    // 起動直後、Copilot を開くために Edge が前へ出てこの窓を覆う。
                    // 準備が終わった時点で1回だけ戻す。利用者が自分で最小化して
                    // いるなら、それは意図した操作なので触らない。
                    if (Visible && WindowState != FormWindowState.Minimized && !ContainsFocus)
                    {
                        ShowAndActivate();
                    }
                }
                else if (type == "translation-finished")
                {
                    // 数十分かかる翻訳のあいだ、利用者はExcelやOutlookで別の仕事をしている。
                    // 画面を見ていれば分かるので、前に出ていないときだけ知らせる。
                    if (!Visible || WindowState == FormWindowState.Minimized || !ContainsFocus)
                    {
                        NotifyTranslationFinished();
                    }
                }
            }
            catch { }
        }

        private bool IsTrustedOrigin(Uri uri)
        {
            if (String.IsNullOrEmpty(activeOrigin) || uri == null) return false;
            return String.Equals(uri.GetLeftPart(UriPartial.Authority), activeOrigin, StringComparison.OrdinalIgnoreCase);
        }

        private async Task CheckBackendAsync()
        {
            if (stopping) return;
            if (backendStarting && backendProcess != null)
            {
                try
                {
                    if (backendProcess.HasExited)
                    {
                        backendStarting = false;
                        backendFailureCount++;
                        int delay = Math.Min(30, 1 << Math.Min(5, backendFailureCount));
                        backendRetryAfter = DateTime.UtcNow.AddSeconds(delay);
                        trayStatus.Text = backendFailureCount >= 3 ? "準備できませんでした。再試行します" : "再準備しています";
                    }
                }
                catch { backendStarting = false; }
            }
            RuntimeInfo runtime = ReadVerifiedRuntime();
            if (runtime == null)
            {
                trayStatus.Text = "再準備しています";
                StartBackendIfNeeded();
                return;
            }
            bool changed = !String.Equals(activeBaseUrl, runtime.Url, StringComparison.OrdinalIgnoreCase);
            activeBaseUrl = runtime.Url;
            activeOrigin = new Uri(runtime.Url).GetLeftPart(UriPartial.Authority);
            trayStatus.Text = "すぐ使えます";
            backendStarting = false;
            backendFailureCount = 0;
            backendRetryAfter = DateTime.MinValue;
            if (changed || webView.Source == null || !IsTrustedOrigin(webView.Source)) await TransferWaitingInputAndNavigateAsync();
        }

        private RuntimeInfo ReadVerifiedRuntime()
        {
            try
            {
                string path = Path.Combine(dataRoot, "runtime", "server.json");
                if (!File.Exists(path)) return null;
                Dictionary<string, object> state = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(path, Encoding.UTF8));
                int pid = Convert.ToInt32(state["pid"]);
                string url = Convert.ToString(state["url"]);
                string root = Path.GetFullPath(Convert.ToString(state["root"])).TrimEnd(Path.DirectorySeparatorChar);
                string expectedRoot = Path.GetFullPath(appRoot).TrimEnd(Path.DirectorySeparatorChar);
                string build = Convert.ToString(state["build_id"]);
                string expectedBuild = File.ReadAllText(Path.Combine(appRoot, "config", "build.txt"), Encoding.UTF8).Trim().TrimStart('\uFEFF');
                if (!String.Equals(root, expectedRoot, StringComparison.OrdinalIgnoreCase) || !String.Equals(build, expectedBuild, StringComparison.Ordinal)) return null;
                Uri uri;
                if (!Uri.TryCreate(url, UriKind.Absolute, out uri) || uri.Scheme != "http" || uri.Host != "127.0.0.1") return null;
                Process process = Process.GetProcessById(pid);
                if (process.HasExited) return null;
                string startedText = Convert.ToString(state["process_started_at"]);
                DateTimeOffset expectedStarted;
                if (!DateTimeOffset.TryParse(startedText, out expectedStarted)) return null;
                double startDelta = Math.Abs((process.StartTime.ToUniversalTime() - expectedStarted.UtcDateTime).TotalSeconds);
                if (startDelta > 3.0) return null;
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(new Uri(uri, "api/instance"));
                request.Timeout = 1200;
                request.ReadWriteTimeout = 1200;
                string payload;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8)) payload = reader.ReadToEnd();
                Dictionary<string, object> probe = json.Deserialize<Dictionary<string, object>>(payload);
                if (Convert.ToInt32(probe["pid"]) != pid ||
                    !String.Equals(Convert.ToString(probe["instance_id"]), Convert.ToString(state["instance_id"]), StringComparison.Ordinal) ||
                    !String.Equals(Convert.ToString(probe["build_id"]), expectedBuild, StringComparison.Ordinal)) return null;
                return new RuntimeInfo { Url = url.EndsWith("/") ? url : url + "/", Pid = pid };
            }
            catch { return null; }
        }

        private void StartBackendIfNeeded()
        {
            if (backendStarting || stopping || DateTime.UtcNow < backendRetryAfter || ReadVerifiedRuntime() != null) return;
            backendStarting = true;
            trayStatus.Text = "再準備しています";
            try
            {
                string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershell)) powershell = "powershell.exe";
                string script = Path.Combine(appRoot, "Start-YakuLingo.ps1");
                ProcessStartInfo start = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -NoBrowser");
                start.WorkingDirectory = appRoot;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.WindowStyle = ProcessWindowStyle.Hidden;
                backendProcess = Process.Start(start);
            }
            catch
            {
                backendStarting = false;
                trayStatus.Text = "準備できませんでした";
            }
        }

        private async Task TransferWaitingInputAndNavigateAsync()
        {
            if (!webReady || String.IsNullOrEmpty(activeBaseUrl)) return;
            if (webView.Source == null || !IsTrustedOrigin(webView.Source))
            {
                try
                {
                    string raw = await webView.ExecuteScriptAsync("(function(){return JSON.stringify({text:window.pendingSnapshot||'',requested:!!window.pendingRequested});})()");
                    string inner = json.Deserialize<string>(raw);
                    Dictionary<string, object> pending = json.Deserialize<Dictionary<string, object>>(inner);
                    pendingQuickText = Convert.ToString(pending["text"]);
                    pendingQuickSubmit = Convert.ToBoolean(pending["requested"]);
                }
                catch { }
            }
            NavigateDesired();
        }

        private void NavigateDesired()
        {
            if (!webReady || String.IsNullOrEmpty(activeBaseUrl)) return;
            string route = desiredRoute;
            if (route == "/quick") route = "/quick?compact=1";
            else if (!String.IsNullOrEmpty(desiredQuery)) route = route + desiredQuery;
            Uri target = new Uri(new Uri(activeBaseUrl), route.TrimStart('/'));
            // 出て行く画面あてに通知を投げないよう、ここで「いま居る画面」を捨てる。
            // NavigationStarting は非同期に来るので、それを待つと、ホットキー処理の
            // 続きが古い画面へ選択を投げて控えを消してしまう（2026-08-11、実機で
            // Word の選択が黙って消えた）。
            if (webView.Source == null || !Uri.Equals(webView.Source, target)) loadedPath = "";
            webView.Source = target;
        }

        // スリープ復帰やネットワーク切替のあとで、いま開いていた資料へ戻れるようにする。
        // これを取らないと、再ナビゲートで ?project= が落ちて作業一覧に戻ってしまう。
        private void CaptureCurrentLocation()
        {
            try
            {
                Uri source = webView.Source;
                if (source == null || !IsTrustedOrigin(source)) return;
                string path = source.AbsolutePath;
                if (path.StartsWith("/cat", StringComparison.OrdinalIgnoreCase))
                {
                    desiredRoute = "/cat";
                    desiredQuery = source.Query;
                }
                else if (path.StartsWith("/quick", StringComparison.OrdinalIgnoreCase)) { desiredRoute = "/quick"; desiredQuery = ""; }
                else if (path.StartsWith("/tutorial", StringComparison.OrdinalIgnoreCase)) { desiredRoute = "/tutorial"; desiredQuery = ""; }
                else { desiredRoute = "/"; desiredQuery = ""; }
            }
            catch { }
        }

        private void NotifyTranslationFinished()
        {
            // 手段を2つ出す。どちらか一方は利用者の設定で消えることがある。
            // バルーンは通知領域のアイコンが隠れていると出ず、応答不可でも抑止される。
            // タスクバーの点滅はどちらにも影響されないので、こちらを主にする。
            try
            {
                FLASHWINFO info = new FLASHWINFO();
                info.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
                info.hwnd = Handle;
                info.dwFlags = FlashAll | FlashTimerNoFg;
                info.uCount = 3;
                info.dwTimeout = 0;
                FlashWindowEx(ref info);
            }
            catch { }
            try { tray.ShowBalloonTip(7000, "YakuLingo", "翻訳が終わりました。YakuLingoを開くと結果を確認できます。", ToolTipIcon.Info); }
            catch { }
        }

        private Icon LoadAppIcon()
        {
            // exe と同じ場所に置く。読めないときだけ既定へ落とす（起動は止めない）。
            try
            {
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "YakuLingo.ico");
                if (File.Exists(path)) return new Icon(path);
            }
            catch { }
            try { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            return SystemIcons.Application;
        }

        private void ShowLocalWaitingPage(bool quick)
        {
            if (!webReady || !String.IsNullOrEmpty(activeBaseUrl)) return;
            string body;
            if (quick)
            {
                body = "<h1>訳したい文章</h1><p>再準備しています。文章はまだ送信されていません。</p><label for='pending-input'>訳したい文章</label><textarea id='pending-input' autofocus></textarea><button id='pending-send' type='button'>準備でき次第、この文章を翻訳</button><button type='button' onclick=\"document.getElementById('pending-input').value='';document.getElementById('pending-input').readOnly=false;window.pendingRequested=false;window.pendingSnapshot='';document.getElementById('wait-status').textContent='取り消しました。';\">取消</button><p id='wait-status' role='status'></p><script>window.pendingRequested=false;window.pendingSnapshot='';document.getElementById('pending-send').onclick=function(){var x=document.getElementById('pending-input');window.pendingSnapshot=x.value;window.pendingRequested=!!window.pendingSnapshot.trim();x.readOnly=window.pendingRequested;document.getElementById('wait-status').textContent=window.pendingRequested?'準備でき次第、押した時点の文章を翻訳します。':'文章を入力してください。';};document.getElementById('pending-input').onkeydown=function(e){if(e.ctrlKey&&e.key==='Enter'){e.preventDefault();document.getElementById('pending-send').click();}};</script>";
            }
            else body = "<h1>YakuLingo</h1><p>再準備しています。文章はまだ送信されていません。</p>";
            string html = "<!doctype html><html lang='ja'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>YakuLingo</title><style>body{font-family:'Segoe UI','Yu Gothic UI',sans-serif;font-size:17px;line-height:1.7;margin:0;padding:28px;color:#202124;background:#fafafa}h1{font-size:25px}label{display:block;font-weight:700;margin-top:18px}textarea{box-sizing:border-box;width:100%;height:280px;padding:14px;font:inherit;border:2px solid #60646c;border-radius:10px}button{min-height:44px;margin:16px 10px 0 0;padding:8px 18px;font:inherit;font-weight:700;border-radius:9px;border:1px solid #3c5bdc;background:#3c5bdc;color:white}button+button{background:white;color:#30333a}</style><body>" + body + "</body></html>";
            webView.NavigateToString(html);
        }

        private void OpenQuick()
        {
            if (!tutorialCompleted) { OpenHome(); return; }
            RememberCurrentWindowSize();
            bool changed = !String.Equals(desiredRoute, "/quick", StringComparison.OrdinalIgnoreCase);
            desiredRoute = "/quick";
            desiredQuery = "";
            MinimumSize = new Size(520, 480);
            if (changed) Size = quickWindowSize;
            ShowAndActivate();
            if (!String.IsNullOrEmpty(activeBaseUrl)) NavigateDesired(); else if (webReady) ShowLocalWaitingPage(true);
        }

        private void OpenCat()
        {
            if (!tutorialCompleted) { OpenHome(); return; }
            RememberCurrentWindowSize();
            bool changed = !String.Equals(desiredRoute, "/cat", StringComparison.OrdinalIgnoreCase);
            desiredRoute = "/cat";
            MinimumSize = new Size(900, 620);
            if (changed) Size = PreferredCatWindowSize();
            ShowAndActivate();
            if (!String.IsNullOrEmpty(activeBaseUrl)) NavigateDesired(); else if (webReady) ShowLocalWaitingPage(false);
        }

        // いま開いている画面のまま、ウィンドウを前に出すだけ。読み込み済みなら再読み込みしない。
        private void RestoreLastScreen()
        {
            CaptureCurrentLocation();
            ShowAndActivate();
            if (String.IsNullOrEmpty(activeBaseUrl)) { if (webReady) ShowLocalWaitingPage(String.Equals(desiredRoute, "/quick", StringComparison.OrdinalIgnoreCase)); return; }
            if (webView.Source == null || !IsTrustedOrigin(webView.Source)) NavigateDesired();
        }

        private void OpenHome()
        {
            RememberCurrentWindowSize();
            desiredQuery = "";
            string nextRoute = tutorialCompleted ? "/" : "/tutorial";
            bool changed = !String.Equals(desiredRoute, nextRoute, StringComparison.OrdinalIgnoreCase);
            desiredRoute = nextRoute;
            MinimumSize = new Size(760, 560);
            if (changed) Size = homeWindowSize;
            ShowAndActivate();
            if (!String.IsNullOrEmpty(activeBaseUrl)) NavigateDesired(); else if (webReady) ShowLocalWaitingPage(false);
        }

        private void RememberCurrentWindowSize()
        {
            if (WindowState != FormWindowState.Normal || Width < MinimumSize.Width || Height < MinimumSize.Height) return;
            if (String.Equals(desiredRoute, "/quick", StringComparison.OrdinalIgnoreCase)) quickWindowSize = Size;
            else if (String.Equals(desiredRoute, "/cat", StringComparison.OrdinalIgnoreCase)) { catWindowSize = Size; catWindowSizeChosenByUser = true; }
            else homeWindowSize = Size;
        }

        private void ShowAndActivate()
        {
            backendRetryAfter = DateTime.MinValue;
            if (String.IsNullOrEmpty(activeBaseUrl)) StartBackendIfNeeded();
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
        }

        private void InjectHotkeyStatus()
        {
            if (hotkeyRegistered || webView.CoreWebView2 == null) return;
            const string script = "(function(){if(document.getElementById('yaku-hotkey-warning'))return;var x=document.createElement('div');x.id='yaku-hotkey-warning';x.setAttribute('role','status');x.style.cssText='padding:12px 16px;background:#fff4ce;color:#4b3a00;border-bottom:2px solid #8a6d00;font:600 16px sans-serif';x.textContent='Ctrl＋Alt＋Jは別のアプリが使用しているため登録できませんでした。通知領域のYakuLingoから開けます。';document.body.insertBefore(x,document.body.firstChild);})()";
            try { webView.ExecuteScriptAsync(script); } catch { }
        }

        private void RequestStartupChange(bool enabled)
        {
            if (!tutorialCompleted || webView.CoreWebView2 == null || webView.Source == null || !IsTrustedOrigin(webView.Source))
            {
                OpenHome();
                return;
            }
            string message = "{\"type\":\"set-startup-enabled\",\"enabled\":" + (enabled ? "true" : "false") + "}";
            try { webView.CoreWebView2.PostWebMessageAsJson(message); } catch { }
        }

        private void RefreshPreferencesMenu()
        {
            tutorialCompleted = ReadBooleanPreference("tutorial_completed", tutorialCompleted);
            quickItem.Enabled = tutorialCompleted;
            catItem.Enabled = tutorialCompleted;
            startupItem.Enabled = tutorialCompleted;
            startupItem.Checked = tutorialCompleted && ReadBooleanPreference("startup_enabled", false);
        }

        private bool ReadBooleanPreference(string name, bool fallback)
        {
            try
            {
                if (!File.Exists(preferencesPath)) return fallback;
                Dictionary<string, object> state = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(preferencesPath, Encoding.UTF8));
                object value;
                if (state != null && state.TryGetValue(name, out value)) return Convert.ToBoolean(value);
            }
            catch { }
            return fallback;
        }

        private void EnsureShortcutsForCurrentVersion()
        {
            try
            {
                if (!tutorialCompleted) return;
                string exe = Application.ExecutablePath;
                EnsureShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Programs), "YakuLingo.lnk"), exe, "");
                ApplyOptionalShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "YakuLingo.lnk"), exe, "--background", ReadBooleanPreference("startup_enabled", false));
                bool desktop = ReadBooleanPreference("desktop_shortcut", ReadBooleanPreference("desktop_shortcut_enabled", false));
                ApplyOptionalShortcut(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "YakuLingo.lnk"), exe, "", desktop);
            }
            catch { }
        }

        private void ApplyOptionalShortcut(string path, string target, string arguments, bool enabled)
        {
            if (enabled) EnsureShortcut(path, target, arguments);
            else if (File.Exists(path) && IsYakuLingoShortcut(path)) File.Delete(path);
        }

        private void EnsureShortcut(string path, string target, string arguments)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            if (File.Exists(path) && !IsYakuLingoShortcut(path)) throw new IOException("同名の別ショートカットがあるため変更できません。");
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp.lnk";
            dynamic shell = null;
            dynamic shortcut = null;
            try
            {
                Type type = Type.GetTypeFromProgID("WScript.Shell");
                shell = Activator.CreateInstance(type);
                shortcut = shell.CreateShortcut(temporary);
                shortcut.TargetPath = target;
                shortcut.Arguments = arguments;
                shortcut.WorkingDirectory = Path.GetDirectoryName(target);
                shortcut.Description = "YakuLingo";
                shortcut.Save();
                if (File.Exists(path)) File.Replace(temporary, path, null);
                else File.Move(temporary, path);
            }
            finally
            {
                if (shortcut != null) try { Marshal.FinalReleaseComObject(shortcut); } catch { }
                if (shell != null) try { Marshal.FinalReleaseComObject(shell); } catch { }
                try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
            }
        }

        private bool IsYakuLingoShortcut(string path)
        {
            try
            {
                Type type = Type.GetTypeFromProgID("WScript.Shell");
                dynamic shell = Activator.CreateInstance(type);
                dynamic shortcut = shell.CreateShortcut(path);
                string target = Convert.ToString(shortcut.TargetPath);
                string description = Convert.ToString(shortcut.Description);
                Marshal.FinalReleaseComObject(shortcut);
                Marshal.FinalReleaseComObject(shell);
                string fullTarget = Path.GetFullPath(target);
                if (String.Equals(Path.GetFileName(fullTarget), "YakuLingo起動.cmd", StringComparison.OrdinalIgnoreCase))
                {
                    if (!String.Equals(description, "YakuLingo", StringComparison.Ordinal) &&
                        !String.Equals(description, "Start YakuLingo HTMX + PowerShell edition", StringComparison.Ordinal)) return false;
                    string legacyRoot = Path.GetDirectoryName(fullTarget);
                    return File.Exists(Path.Combine(legacyRoot, "bootstrap.ps1")) && File.Exists(Path.Combine(legacyRoot, "current.txt"));
                }
                if (!String.Equals(description, "YakuLingo", StringComparison.Ordinal)) return false;
                if (!String.Equals(Path.GetFileName(fullTarget), "YakuLingo.exe", StringComparison.OrdinalIgnoreCase)) return false;
                string desktop = Path.GetDirectoryName(fullTarget);
                if (!String.Equals(Path.GetFileName(desktop), "desktop", StringComparison.OrdinalIgnoreCase)) return false;
                string ownerRoot = Directory.GetParent(desktop).FullName;
                return File.Exists(Path.Combine(ownerRoot, "Start-YakuLingo.ps1")) && File.Exists(Path.Combine(ownerRoot, "config", "build.txt"));
            }
            catch { return false; }
        }

        private void StartPipeServer()
        {
            pipeThread = new Thread(delegate()
            {
                SecurityIdentifier sid = WindowsIdentity.GetCurrent().User;
                PipeSecurity security = new PipeSecurity();
                security.SetAccessRuleProtection(true, false);
                security.AddAccessRule(new PipeAccessRule(sid, PipeAccessRights.ReadWrite, AccessControlType.Allow));
                while (!stopping)
                {
                    try
                    {
                        using (NamedPipeServerStream server = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Message, PipeOptions.None, 0, 0, security))
                        {
                            server.WaitForConnection();
                            using (StreamReader reader = new StreamReader(server, Encoding.UTF8))
                            {
                                string command = reader.ReadLine();
                                if (!String.IsNullOrEmpty(command) && !stopping) BeginInvoke((MethodInvoker)delegate { HandleExternalCommand(command); });
                            }
                        }
                    }
                    catch { if (!stopping) Thread.Sleep(250); }
                }
            });
            pipeThread.IsBackground = true;
            pipeThread.Name = "YakuLingo command pipe";
            pipeThread.Start();
        }

        private void HandleExternalCommand(string command)
        {
            if (String.Equals(command, "QUICK", StringComparison.OrdinalIgnoreCase)) OpenQuick();
            else if (String.Equals(command, "CAT", StringComparison.OrdinalIgnoreCase)) OpenCat();
            else OpenHome();
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            if (exiting) return;
            if (e.CloseReason == CloseReason.WindowsShutDown || e.CloseReason == CloseReason.TaskManagerClosing)
            {
                exiting = true;
                stopping = true;
                return;
            }
            e.Cancel = true;
            Hide();
            if (!firstHideNoticeShown)
            {
                firstHideNoticeShown = true;
                tray.ShowBalloonTip(5000, "YakuLingo", "画面を閉じました。すぐ使えるよう通知領域で準備を続けます。Ctrl＋Alt＋Jで開けます。", ToolTipIcon.Info);
            }
        }

        private async void RequestExit()
        {
            string activeKind = GetActiveTranslationKind();
            bool running = !String.IsNullOrEmpty(activeKind);
            string message = running
                ? ((activeKind == "cat" ? "資料の取り込み" : "翻訳処理") + "を実行中です。終了すると現在の処理を中止します。保存済みの確認内容は残ります。\r\n\r\n中止してYakuLingoを完全に終了しますか？")
                : "YakuLingoを完全に終了しますか？";
            DialogResult answer = MessageBox.Show(this,
                message,
                "YakuLingoを終了", MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
            if (answer != DialogResult.Yes) return;
            exiting = true;
            stopping = true;
            try
            {
                if (webView.CoreWebView2 != null) await webView.CoreWebView2.Profile.ClearBrowsingDataAsync();
            }
            catch { }
            StopBackendSafely();
            Close();
        }

        private string GetActiveTranslationKind()
        {
            if (String.IsNullOrEmpty(activeBaseUrl)) return "";
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(new Uri(new Uri(activeBaseUrl), "api/instance"));
                request.Timeout = 700;
                request.ReadWriteTimeout = 700;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                using (StreamReader reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
                {
                    Dictionary<string, object> payload = json.Deserialize<Dictionary<string, object>>(reader.ReadToEnd());
                    object running;
                    if (payload != null && payload.TryGetValue("active_job_running", out running) && Convert.ToBoolean(running)) return Convert.ToString(payload["active_job_kind"]);
                }
            }
            catch { }
            return "";
        }

        private void StopBackendSafely()
        {
            try
            {
                string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
                if (!File.Exists(powershell)) powershell = "powershell.exe";
                string script = Path.Combine(appRoot, "tools", "Stop-YakuLingo.ps1");
                ProcessStartInfo start = new ProcessStartInfo(powershell, "-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
                start.WorkingDirectory = appRoot;
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                Process stop = Process.Start(start);
                stop.WaitForExit(6000);
            }
            catch { }
        }

        // 会議室へ移ってWi-Fiが切り替わった、席を外してスリープした。どちらも日常的に起きる。
        // ここで activeBaseUrl を空にすると、次のタイマーで必ず changed=true になり、
        // 開いていた資料を捨てて作業一覧へ戻っていた。控えめに再確認するだけにする。
        // バックエンドが本当に落ちて別ポートで上がったときは、runtime.Url が変わるので
        // 従来どおり再ナビゲートされる。
        private void RecheckBackendAfterInterruption()
        {
            if (stopping) return;
            CaptureCurrentLocation();
            StartBackendIfNeeded();
        }

        private void OnNetworkAvailabilityChanged(object sender, NetworkAvailabilityEventArgs e)
        {
            if (!stopping) BeginInvoke((MethodInvoker)delegate { RecheckBackendAfterInterruption(); });
        }

        private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
        {
            if (e.Mode == PowerModes.Resume && !stopping) BeginInvoke((MethodInvoker)delegate { RecheckBackendAfterInterruption(); });
        }

        private void Cleanup()
        {
            stopping = true;
            backendTimer.Stop();
            try { if (hotkeyRegistered) UnregisterHotKey(Handle, HotkeyId); } catch { }
            try { NetworkChange.NetworkAvailabilityChanged -= OnNetworkAvailabilityChanged; } catch { }
            try { SystemEvents.PowerModeChanged -= OnPowerModeChanged; } catch { }
            tray.Visible = false;
            tray.Dispose();
            try { webView.Dispose(); } catch { }
            try { if (Directory.Exists(userDataFolder)) Directory.Delete(userDataFolder, true); } catch { }
        }

        private sealed class RuntimeInfo
        {
            internal string Url;
            internal int Pid;
        }
    }
}

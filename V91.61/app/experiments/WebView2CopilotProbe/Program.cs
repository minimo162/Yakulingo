using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Diagnostics;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Web.Script.Serialization;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace YakuLingo.WebView2CopilotProbe
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string autoDiagnosePath = null;
            for (int i = 0; i < args.Length; i++)
            {
                if (String.Equals(args[i], "--auto-diagnose", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                {
                    autoDiagnosePath = Path.GetFullPath(args[++i]);
                }
            }
            Application.Run(new ProbeForm(autoDiagnosePath));
        }
    }

    internal sealed class ProbeForm : Form
    {
        private const string CopilotUrl = "https://m365.cloud.microsoft/chat/";
        private readonly WebView2 primary = new WebView2();
        private readonly WebView2 secondary = new WebView2();
        private readonly SplitContainer browserSplit = new SplitContainer();
        private readonly TextBox logBox = new TextBox();
        private readonly Label statusLabel = new Label();
        private readonly Button initializeButton = new Button();
        private readonly Button navigateButton = new Button();
        private readonly Button inspectButton = new Button();
        private readonly Button toggleSecondaryButton = new Button();
        private readonly Button cookieButton = new Button();
        private readonly string probeRoot;
        private readonly string userDataFolder;
        private readonly string logPath;
        private readonly string autoDiagnosePath;
        private readonly JavaScriptSerializer serializer = new JavaScriptSerializer();
        private CoreWebView2Environment environment;
        private bool initialized;

        public ProbeForm(string autoDiagnosePath)
        {
            this.autoDiagnosePath = autoDiagnosePath;
            Text = "YakuLingo WebView2 Copilot Probe (送信しない診断版)";
            Width = 1380;
            Height = 900;
            MinimumSize = new Size(980, 650);
            StartPosition = FormStartPosition.CenterScreen;

            string bin = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
            probeRoot = Path.GetFullPath(Path.Combine(bin, ".."));
            userDataFolder = Path.Combine(probeRoot, "data", "CopilotWebView2Profile");
            string logDirectory = Path.Combine(probeRoot, "logs");
            Directory.CreateDirectory(logDirectory);
            logPath = Path.Combine(logDirectory, "probe-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");

            BuildUi();
            Log("START runtime=" + SafeRuntimeVersion());
            Log("UDF=" + userDataFolder);
            Log("この試作は入力内容・Cookie値をログへ保存せず、Copilotへの送信も行いません。");
            if (!String.IsNullOrWhiteSpace(autoDiagnosePath))
            {
                Opacity = 0;
                ShowInTaskbar = false;
                Shown += async delegate { await RunAutoDiagnoseAsync(); };
            }
        }

        private void BuildUi()
        {
            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.RowCount = 4;
            root.ColumnCount = 1;
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 70));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 30));
            Controls.Add(root);

            Label warning = new Label();
            warning.AutoSize = true;
            warning.Padding = new Padding(8);
            warning.ForeColor = Color.DarkRed;
            warning.Text = "評価専用：認証情報を入力しない／Copilotへ送信しない。DOM診断は要素の有無だけを記録します。";
            root.Controls.Add(warning, 0, 0);

            FlowLayoutPanel toolbar = new FlowLayoutPanel();
            toolbar.AutoSize = true;
            toolbar.Dock = DockStyle.Fill;
            toolbar.Padding = new Padding(6, 2, 6, 4);
            root.Controls.Add(toolbar, 0, 1);

            ConfigureButton(initializeButton, "1. 2画面を初期化", InitializeClicked);
            ConfigureButton(navigateButton, "2. Copilotを開く", NavigateClicked);
            ConfigureButton(inspectButton, "3. DOM状態を診断", InspectClicked);
            ConfigureButton(toggleSecondaryButton, "第2画面を隠す", ToggleSecondaryClicked);
            ConfigureButton(cookieButton, "Cookie持続を診断", CookieClicked);
            toolbar.Controls.Add(initializeButton);
            toolbar.Controls.Add(navigateButton);
            toolbar.Controls.Add(inspectButton);
            toolbar.Controls.Add(toggleSecondaryButton);
            toolbar.Controls.Add(cookieButton);
            statusLabel.AutoSize = true;
            statusLabel.Padding = new Padding(12, 8, 0, 0);
            statusLabel.Text = "未初期化";
            toolbar.Controls.Add(statusLabel);

            browserSplit.Dock = DockStyle.Fill;
            browserSplit.Orientation = Orientation.Vertical;
            browserSplit.SplitterDistance = 650;
            browserSplit.Panel1.Controls.Add(WrapBrowser("WebView A", primary));
            browserSplit.Panel2.Controls.Add(WrapBrowser("WebView B（同一UDF）", secondary));
            root.Controls.Add(browserSplit, 0, 2);

            logBox.Dock = DockStyle.Fill;
            logBox.Multiline = true;
            logBox.ReadOnly = true;
            logBox.ScrollBars = ScrollBars.Both;
            logBox.WordWrap = false;
            logBox.Font = new Font(FontFamily.GenericMonospace, 9f);
            root.Controls.Add(logBox, 0, 3);
        }

        private static Control WrapBrowser(string title, WebView2 browser)
        {
            Panel panel = new Panel();
            panel.Dock = DockStyle.Fill;
            Label label = new Label();
            label.Dock = DockStyle.Top;
            label.Height = 24;
            label.TextAlign = ContentAlignment.MiddleLeft;
            label.Text = title;
            browser.Dock = DockStyle.Fill;
            panel.Controls.Add(browser);
            panel.Controls.Add(label);
            return panel;
        }

        private static void ConfigureButton(Button button, string text, EventHandler handler)
        {
            button.AutoSize = true;
            button.Text = text;
            button.Click += handler;
        }

        private async void InitializeClicked(object sender, EventArgs e)
        {
            initializeButton.Enabled = false;
            try
            {
                await InitializeAsync();
            }
            catch (Exception ex)
            {
                Log("INIT_FAIL " + ex.GetType().Name + ": " + ex.Message);
                statusLabel.Text = "初期化失敗";
            }
            finally
            {
                initializeButton.Enabled = true;
            }
        }

        private async Task InitializeAsync()
        {
            if (initialized)
            {
                Log("INIT_SKIP すでに初期化済み");
                return;
            }

            Directory.CreateDirectory(userDataFolder);
            CoreWebView2EnvironmentOptions options = new CoreWebView2EnvironmentOptions(
                "--disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-features=CalculateNativeWinOcclusion");
            environment = await CoreWebView2Environment.CreateAsync(null, userDataFolder, options);
            await primary.EnsureCoreWebView2Async(environment);
            await secondary.EnsureCoreWebView2Async(environment);
            ConfigureCore("A", primary.CoreWebView2);
            ConfigureCore("B", secondary.CoreWebView2);

            string aPath = primary.CoreWebView2.Profile.ProfilePath;
            string bPath = secondary.CoreWebView2.Profile.ProfilePath;
            bool sameProfile = String.Equals(aPath, bPath, StringComparison.OrdinalIgnoreCase);
            Log("INIT_OK browserVersion=" + environment.BrowserVersionString);
            Log("PROFILE_A name=" + primary.CoreWebView2.Profile.ProfileName + " path=" + aPath);
            Log("PROFILE_B name=" + secondary.CoreWebView2.Profile.ProfileName + " path=" + bPath);
            Log("SAME_PROFILE=" + sameProfile);
            initialized = true;
            statusLabel.Text = sameProfile ? "初期化済み（同一プロファイル）" : "警告：プロファイル不一致";
        }

        private void ConfigureCore(string name, CoreWebView2 core)
        {
            core.Settings.AreDevToolsEnabled = true;
            core.Settings.AreDefaultContextMenusEnabled = true;
            core.NavigationCompleted += delegate(object sender, CoreWebView2NavigationCompletedEventArgs e)
            {
                Log("NAV_" + name + " success=" + e.IsSuccess + " status=" + e.WebErrorStatus + " url=" + SafeUri(core.Source));
            };
            core.ProcessFailed += delegate(object sender, CoreWebView2ProcessFailedEventArgs e)
            {
                Log("PROCESS_FAILED_" + name + " kind=" + e.ProcessFailedKind);
            };
            core.DownloadStarting += delegate(object sender, CoreWebView2DownloadStartingEventArgs e)
            {
                e.Cancel = true;
                Log("DOWNLOAD_BLOCKED_" + name);
            };
        }

        private async void NavigateClicked(object sender, EventArgs e)
        {
            if (!await RequireInitializedAsync()) return;
            primary.CoreWebView2.Navigate(CopilotUrl);
            secondary.CoreWebView2.Navigate(CopilotUrl);
            Log("NAV_REQUEST both=" + CopilotUrl);
        }

        private async void InspectClicked(object sender, EventArgs e)
        {
            if (!await RequireInitializedAsync()) return;
            await InspectBrowserAsync("A", primary);
            await InspectBrowserAsync("B", secondary);
        }

        private async Task<object> InspectBrowserAsync(string name, WebView2 browser)
        {
            const string script = @"(function(){
                var inputs = Array.prototype.slice.call(document.querySelectorAll('textarea,[contenteditable=""true""],input[type=""text""]'));
                var visible = inputs.filter(function(e){var r=e.getBoundingClientRect();var s=getComputedStyle(e);return r.width>0&&r.height>0&&s.visibility!=='hidden'&&s.display!=='none';});
                var auth = !!document.querySelector('input[type=""password""],a[href*=""login""],button[data-testid*=""sign""]');
                return {url:location.href,title:document.title,readyState:document.readyState,inputCount:inputs.length,visibleInputCount:visible.length,authControlLikely:auth};
            })();";
            try
            {
                string result = await browser.CoreWebView2.ExecuteScriptAsync(script);
                Log("DOM_" + name + " " + result);
                object parsed = serializer.DeserializeObject(result);
                if (parsed == null) return new Dictionary<string, object> { { "error", "DOM script returned null." } };
                return parsed;
            }
            catch (Exception ex)
            {
                Log("DOM_FAIL_" + name + " " + ex.GetType().Name + ": " + ex.Message);
                return new Dictionary<string, object> { { "error", ex.GetType().Name + ": " + ex.Message } };
            }
        }

        private void ToggleSecondaryClicked(object sender, EventArgs e)
        {
            browserSplit.Panel2Collapsed = !browserSplit.Panel2Collapsed;
            toggleSecondaryButton.Text = browserSplit.Panel2Collapsed ? "第2画面を再表示" : "第2画面を隠す";
            Log("SECONDARY_VISIBLE=" + (!browserSplit.Panel2Collapsed));
        }

        private async void CookieClicked(object sender, EventArgs e)
        {
            if (!await RequireInitializedAsync()) return;
            await GetCookieMetadataAsync("A", primary.CoreWebView2);
            await GetCookieMetadataAsync("B", secondary.CoreWebView2);
            Log("Cookie値は意図的に記録していません。再起動前後で件数とドメイン一覧だけを比較してください。");
        }

        private async Task<Dictionary<string, object>> GetCookieMetadataAsync(string name, CoreWebView2 core)
        {
            try
            {
                IReadOnlyList<CoreWebView2Cookie> cookies = await core.CookieManager.GetCookiesAsync("https://m365.cloud.microsoft/");
                SortedSet<string> domains = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (CoreWebView2Cookie cookie in cookies) domains.Add(cookie.Domain);
                Log("COOKIE_" + name + " count=" + cookies.Count + " domains=" + String.Join(",", domains));
                return new Dictionary<string, object>
                {
                    { "count", cookies.Count },
                    { "domains", new List<string>(domains) }
                };
            }
            catch (Exception ex)
            {
                Log("COOKIE_FAIL_" + name + " " + ex.GetType().Name + ": " + ex.Message);
                return new Dictionary<string, object> { { "error", ex.GetType().Name + ": " + ex.Message } };
            }
        }

        private async Task RunAutoDiagnoseAsync()
        {
            DateTime startedAt = DateTime.UtcNow;
            Stopwatch stopwatch = Stopwatch.StartNew();
            Dictionary<string, object> result = new Dictionary<string, object>();
            List<string> errors = new List<string>();
            result["schemaVersion"] = 1;
            result["startedAtUtc"] = startedAt.ToString("o");
            result["copilotUrl"] = CopilotUrl;
            result["userDataFolder"] = userDataFolder;
            try
            {
                await InitializeAsync();
                string aPath = primary.CoreWebView2.Profile.ProfilePath;
                string bPath = secondary.CoreWebView2.Profile.ProfilePath;
                result["browserVersion"] = environment.BrowserVersionString;
                result["sameProfile"] = String.Equals(aPath, bPath, StringComparison.OrdinalIgnoreCase);
                result["profiles"] = new Dictionary<string, object>
                {
                    { "a", new Dictionary<string, object> { { "name", primary.CoreWebView2.Profile.ProfileName }, { "path", aPath } } },
                    { "b", new Dictionary<string, object> { { "name", secondary.CoreWebView2.Profile.ProfileName }, { "path", bPath } } }
                };

                primary.CoreWebView2.Navigate(CopilotUrl);
                secondary.CoreWebView2.Navigate(CopilotUrl);
                Log("AUTO_NAV_REQUEST both=" + CopilotUrl);
                bool navigationReady = await WaitForBothDocumentsAsync(TimeSpan.FromSeconds(60));
                result["navigation"] = new Dictionary<string, object>
                {
                    { "readyWithin60Seconds", navigationReady },
                    { "elapsedSeconds", Math.Round(stopwatch.Elapsed.TotalSeconds, 3) },
                    { "aUrl", SafeUri(primary.CoreWebView2.Source) },
                    { "bUrl", SafeUri(secondary.CoreWebView2.Source) }
                };

                result["domBeforeHide"] = new Dictionary<string, object>
                {
                    { "a", await InspectBrowserAsync("A", primary) },
                    { "b", await InspectBrowserAsync("B", secondary) }
                };

                browserSplit.Panel2Collapsed = true;
                Log("AUTO_SECONDARY_VISIBLE=False");
                await Task.Delay(1500);
                object hiddenDom = await InspectBrowserAsync("B_HIDDEN", secondary);
                browserSplit.Panel2Collapsed = false;
                Log("AUTO_SECONDARY_VISIBLE=True");
                await Task.Delay(1500);
                object restoredDom = await InspectBrowserAsync("B_RESTORED", secondary);
                result["hiddenRestore"] = new Dictionary<string, object>
                {
                    { "hiddenDom", hiddenDom },
                    { "restoredDom", restoredDom }
                };

                result["cookies"] = new Dictionary<string, object>
                {
                    { "a", await GetCookieMetadataAsync("A", primary.CoreWebView2) },
                    { "b", await GetCookieMetadataAsync("B", secondary.CoreWebView2) }
                };
                if (!navigationReady) errors.Add("Navigation did not reach document.readyState=complete in both WebViews within 60 seconds.");
            }
            catch (Exception ex)
            {
                errors.Add(ex.GetType().Name + ": " + ex.Message);
                Log("AUTO_FAIL " + ex.GetType().Name + ": " + ex.Message);
            }
            finally
            {
                result["errors"] = errors;
                result["success"] = errors.Count == 0;
                result["completedAtUtc"] = DateTime.UtcNow.ToString("o");
                result["elapsedSeconds"] = Math.Round(stopwatch.Elapsed.TotalSeconds, 3);
                try
                {
                    string directory = Path.GetDirectoryName(autoDiagnosePath);
                    if (!String.IsNullOrWhiteSpace(directory)) Directory.CreateDirectory(directory);
                    File.WriteAllText(autoDiagnosePath, serializer.Serialize(result), new UTF8Encoding(false));
                    Log("AUTO_RESULT=" + autoDiagnosePath);
                }
                catch (Exception ex)
                {
                    Log("AUTO_RESULT_FAIL " + ex.GetType().Name + ": " + ex.Message);
                }
                Close();
            }
        }

        private async Task<bool> WaitForBothDocumentsAsync(TimeSpan timeout)
        {
            DateTime deadline = DateTime.UtcNow.Add(timeout);
            while (DateTime.UtcNow < deadline)
            {
                if (await IsDocumentReadyAsync(primary) && await IsDocumentReadyAsync(secondary)) return true;
                await Task.Delay(500);
            }
            return false;
        }

        private static async Task<bool> IsDocumentReadyAsync(WebView2 browser)
        {
            try
            {
                if (browser.CoreWebView2 == null || String.IsNullOrWhiteSpace(browser.CoreWebView2.Source) ||
                    String.Equals(browser.CoreWebView2.Source, "about:blank", StringComparison.OrdinalIgnoreCase)) return false;
                string ready = await browser.CoreWebView2.ExecuteScriptAsync("document.readyState");
                return String.Equals(ready, "\"complete\"", StringComparison.Ordinal);
            }
            catch { return false; }
        }

        private async Task<bool> RequireInitializedAsync()
        {
            if (!initialized)
            {
                try { await InitializeAsync(); }
                catch (Exception ex)
                {
                    Log("INIT_FAIL " + ex.GetType().Name + ": " + ex.Message);
                    statusLabel.Text = "初期化失敗";
                    return false;
                }
            }
            return true;
        }

        private void Log(string message)
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message;
            logBox.AppendText(line + Environment.NewLine);
            File.AppendAllText(logPath, line + Environment.NewLine, new UTF8Encoding(false));
        }

        private static string SafeRuntimeVersion()
        {
            try { return CoreWebView2Environment.GetAvailableBrowserVersionString(null); }
            catch (Exception ex) { return "UNAVAILABLE(" + ex.GetType().Name + ")"; }
        }

        private static string SafeUri(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return "(empty)";
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri)) return "(invalid)";
            return uri.GetLeftPart(UriPartial.Path);
        }
    }
}

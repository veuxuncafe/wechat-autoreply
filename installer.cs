// installer.cs -- one exe that installs, upgrades and uninstalls the WeChat auto-reply console.
//   install : copies the embedded payload into the install folder (program files only),
//             creates the shortcuts and registers an entry in "apps and features".
//   upgrade : run the same installer again; program files are replaced, state\ logs\ shots\ stay.
//   remove  : uninstall.exe (a copy of this exe) stops the bot, removes shortcuts, autostart,
//             the registry entry and the program files; user data is kept unless --purge.
// Command line: --silent  --dir <path>  --purge  --no-shortcuts  --uninstall
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program
{
    internal const string AppName = "微信自动回复";
    internal const string Version = "1.0.0";
    internal const string Publisher = "DSH";
    internal const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\DSH.WeChatAutoReply";
    internal const string DefaultDir = @"C:\WeChatAutoReply";
    static readonly string[] Keep = new string[] { "state", "logs", "shots" };

    static string dir = DefaultDir;
    static bool dirGiven, silent, purge, noShortcuts, uninstall;
    static string logPath;

    internal static bool IsUninstall { get { return uninstall; } }
    internal static string LogPath
    {
        get
        {
            Note("");
            return logPath;
        }
    }
    internal static bool IsPurge { get { return purge; } }
    internal static string Dir
    {
        get { return dir; }
        set { dir = value; }
    }

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string me = Path.GetFileNameWithoutExtension(Application.ExecutablePath);
            if (me.StartsWith("卸载")) uninstall = true;
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "--silent" || a == "-s" || a == "/s") silent = true;
                else if (a == "--purge") purge = true;
                else if (a == "--no-shortcuts") noShortcuts = true;
                else if (a == "--uninstall") uninstall = true;
                else if ((a == "--dir" || a == "/dir") && i + 1 < args.Length) { dir = args[++i]; dirGiven = true; }
                else if (a.StartsWith("--dir=")) { dir = args[i].Substring(6); dirGiven = true; }
            }
            string known = ReadInstallLocation();
            if (!dirGiven && known != null) dir = known;
            dir = Path.GetFullPath(dir);
            Note("main: exe=" + Application.ExecutablePath + " uninstall=" + uninstall + " silent=" + silent + " purge=" + purge + " dir=" + dir + " args=" + string.Join(" ", args));
        }
        catch (Exception ex)
        {
            Note("bad command line: " + ex.Message);
            return 2;
        }

        if (silent) return Run(null);

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        InstallerForm f = new InstallerForm();
        Application.Run(f);
        return f.ExitCode;
    }

    internal static int Run(Action<string> report)
    {
        int pre = PrepareTarget(!uninstall);
        if (pre != 0) return pre;
        try
        {
            if (uninstall) DoUninstall(report);
            else DoInstall(report);
            return 0;
        }
        catch (Exception ex)
        {
            Note("FAILED: " + ex);
            Say(report, "失败：" + ex.Message);
            return 1;
        }
    }

    internal static int RunWithUi(Action<string> report, bool purgeData)
    {
        purge = purgeData;
        return Run(report);
    }

    static int PrepareTarget(bool create)
    {
        try
        {
            if (!create)
            {
                // uninstalling: do not recreate the folder we are about to remove
                if (!Directory.Exists(dir)) return 0;
            }
            else Directory.CreateDirectory(dir);
            string probe = Path.Combine(dir, ".write-test-" + Guid.NewGuid().ToString("N") + ".tmp");
            File.WriteAllText(probe, "x");
            File.Delete(probe);
            return 0;
        }
        catch (UnauthorizedAccessException)
        {
            Note("access denied on " + dir + " - asking for administrator rights");
            return RelaunchElevated();
        }
        catch (Exception ex)
        {
            Note("cannot use " + dir + " :: " + ex.Message);
            return 2;
        }
    }

    static int RelaunchElevated()
    {
        try
        {
            string self = Application.ExecutablePath;
            string a = (uninstall ? "--uninstall" : "") + " --silent --dir \"" + dir + "\"";
            if (purge) a += " --purge";
            if (noShortcuts) a += " --no-shortcuts";
            ProcessStartInfo si = new ProcessStartInfo(self, a);
            si.UseShellExecute = true;
            si.Verb = "runas";
            using (Process p = Process.Start(si))
            {
                p.WaitForExit();
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Note("elevation was refused or failed: " + ex.Message);
            return 2;
        }
    }

    static void DoInstall(Action<string> report)
    {
        Note("install -> " + dir + "  version " + Version);
        Say(report, "安装位置：" + dir);
        Directory.CreateDirectory(dir);
        Say(report, "正在复制程序文件（聊天记录与设置会保留）…");
        ExtractPayload();
        if (!noShortcuts)
        {
            Say(report, "正在创建桌面和开始菜单快捷方式…");
            RunPowerShell("-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(dir, "app-tools.ps1") + "\" -Action install-shortcuts");
        }
        Say(report, "正在登记卸载信息…");
        WriteRegistry();
        CopySelfAsUninstaller();
        Say(report, "安装完成，版本 " + Version);
        Note("install done");
    }

    static void DoUninstall(Action<string> report)
    {
        Note("uninstall <- " + dir + "  purge=" + purge);
        Say(report, "正在停止后台自动回复…");
        KillRunning();
        Say(report, "正在删除快捷方式和开机自启…");
        string tools = Path.Combine(dir, "app-tools.ps1");
        if (File.Exists(tools)) RunPowerShell("-NoProfile -ExecutionPolicy Bypass -File \"" + tools + "\" -Action remove-shortcuts");
        Say(report, "正在删除注册表卸载项…");
        DeleteRegistry();
        Say(report, purge ? "正在删除程序文件和全部数据…" : "正在删除程序文件（聊天记录与设置保留）…");
        DeleteProgramFiles();
        Say(report, "卸载完成");
        Note("uninstall done");
        bool empty = !Directory.Exists(dir);
        if (!empty)
        {
            try { empty = Directory.GetFileSystemEntries(dir).Length <= 1; } catch { }
        }
        ScheduleCleanup(purge || empty);
    }

    static void Say(Action<string> report, string msg)
    {
        Note(msg);
        if (report != null) report(msg);
    }

    static void Note(string msg)
    {
        try { Console.WriteLine(DateTime.Now.ToString("HH:mm:ss") + " | " + msg); }
        catch { }
        try
        {
            if (logPath == null)
            {
                // keep the log outside the install folder so that it survives an uninstall
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "微信自动回复");
                Directory.CreateDirectory(d);
                logPath = Path.Combine(d, "install.log");
            }
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " | " + msg + "\r\n";
            File.AppendAllText(logPath, line, Encoding.UTF8);
            string dbg = Environment.GetEnvironmentVariable("WX_INSTALL_DEBUG");
            if (!string.IsNullOrEmpty(dbg)) { try { File.AppendAllText(dbg, line, Encoding.UTF8); } catch { } }
        }
        catch { }
    }

    static void ExtractPayload()
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        {
            if (s == null) throw new Exception("内置的程序包缺失");
            using (ZipArchive zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry e in zip.Entries)
                {
                    if (e.Name.Length == 0) continue;
                    string target = Path.Combine(dir, e.FullName.Replace('/', Path.DirectorySeparatorChar));
                    string parent = Path.GetDirectoryName(target);
                    if (!string.IsNullOrEmpty(parent)) Directory.CreateDirectory(parent);
                    using (Stream input = e.Open())
                    using (FileStream output = new FileStream(target, FileMode.Create, FileAccess.Write))
                    {
                        input.CopyTo(output);
                    }
                }
            }
        }
    }

    static int RunPowerShell(string args)
    {
        return RunHidden("powershell.exe", args);
    }

    static int RunHidden(string file, string args)
    {
        try
        {
            ProcessStartInfo si = new ProcessStartInfo(file, args);
            si.UseShellExecute = false;
            si.CreateNoWindow = true;
            si.WindowStyle = ProcessWindowStyle.Hidden;
            using (Process p = Process.Start(si))
            {
                if (!p.WaitForExit(180000)) { try { p.Kill(); } catch { } return -1; }
                return p.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Note("run failed: " + file + " " + args + " :: " + ex.Message);
            return -1;
        }
    }

    static void KillRunning()
    {
        try
        {
            foreach (Process p in Process.GetProcessesByName("wx-panel"))
            {
                try { p.Kill(); } catch { }
            }
        }
        catch { }
        // a helper script, so that this command line never contains the pattern it searches for
        string script;
        string helperDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "微信自动回复");
        try { Directory.CreateDirectory(helperDir); script = Path.Combine(helperDir, "wxar-stop.ps1"); }
        catch { script = Path.Combine(Path.GetTempPath(), "wxar-stop.ps1"); }
        try
        {
            string body =
                "$p = 'wx-' + 'wa' + 'tch'\r\n" +
                "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" |\r\n" +
                "  Where-Object { $_.CommandLine -like ('*' + $p + '*') -and $_.ProcessId -ne $PID } |\r\n" +
                "  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }\r\n";
            File.WriteAllText(script, body, new UTF8Encoding(false));
            RunPowerShell("-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"");
        }
        catch (Exception ex) { Note("stop helper failed: " + ex.Message); }
        try { File.Delete(script); } catch { }
    }

    static void WriteRegistry()
    {
        using (RegistryKey k = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            k.SetValue("DisplayName", AppName);
            k.SetValue("DisplayVersion", Version);
            k.SetValue("Publisher", Publisher);
            k.SetValue("InstallLocation", dir);
            k.SetValue("DisplayIcon", Path.Combine(dir, "wx-panel.exe"));
            k.SetValue("UninstallString", "\"" + Path.Combine(dir, "卸载.exe") + "\"");
            k.SetValue("QuietUninstallString", "\"" + Path.Combine(dir, "卸载.exe") + "\" --silent");
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            k.SetValue("InstallDate", DateTime.Now.ToString("yyyyMMdd"));
            long kb = DirSize(dir) / 1024;
            if (kb > 0 && kb < int.MaxValue) k.SetValue("EstimatedSize", (int)kb, RegistryValueKind.DWord);
        }
    }

    static void DeleteRegistry()
    {
        // delete, then verify: the managed API has been seen to report success while
        // leaving the key behind, so fall back to reg.exe (a separate process) if needed
        for (int attempt = 0; attempt < 2; attempt++)
        {
            try { Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, false); }
            catch (Exception ex) { Note("registry delete failed: " + ex.Message); }
            if (!RegistryKeyExists()) { Note("registry uninstall entry removed"); return; }
            Note("registry entry still present after attempt " + (attempt + 1) + " - falling back to reg.exe");
            int rc = RunHidden("reg.exe", "delete \"HKCU\\" + UninstallKey + "\" /f");
            Note("reg.exe delete exit " + rc);
        }
        if (!RegistryKeyExists()) { Note("registry uninstall entry removed"); return; }
        // last resort: an entry with no DisplayName is invisible to 设置/应用, so clearing the
        // values is enough for the app to disappear from the installed list
        try
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(UninstallKey, true))
            {
                if (k != null)
                {
                    foreach (string v in new string[] { "DisplayName", "DisplayVersion", "Publisher", "DisplayIcon", "UninstallString", "QuietUninstallString", "InstallLocation", "EstimatedSize" })
                    {
                        try { k.DeleteValue(v, false); } catch { }
                    }
                    k.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
            }
            Note("registry entry neutralised (DisplayName removed)");
        }
        catch (Exception ex) { Note("registry neutralise failed: " + ex.Message); }
    }

    static bool RegistryKeyExists()
    {
        try { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(UninstallKey)) { return k != null; } }
        catch { return false; }
    }

    static string ReadInstallLocation()
    {
        try
        {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(UninstallKey))
            {
                if (k != null)
                {
                    object v = k.GetValue("InstallLocation");
                    if (v != null)
                    {
                        string s = Convert.ToString(v);
                        if (!string.IsNullOrEmpty(s) && Directory.Exists(s)) return s;
                    }
                }
            }
        }
        catch { }
        return null;
    }

    static void CopySelfAsUninstaller()
    {
        try
        {
            string self = Application.ExecutablePath;
            string target = Path.Combine(dir, "卸载.exe");
            if (!string.Equals(self, target, StringComparison.OrdinalIgnoreCase))
                File.Copy(self, target, true);
        }
        catch (Exception ex) { Note("copy uninstaller failed: " + ex.Message); }
    }

    static void DeleteProgramFiles()
    {
        string[] entries;
        try { entries = Directory.GetFileSystemEntries(dir); }
        catch { return; }
        foreach (string entry in entries)
        {
            string name = Path.GetFileName(entry);
            if (!purge && Array.IndexOf(Keep, name.ToLowerInvariant()) >= 0) continue;
            if (string.Equals(name, "卸载.exe", StringComparison.OrdinalIgnoreCase)) continue; // still running
            try
            {
                if (Directory.Exists(entry)) Directory.Delete(entry, true);
                else File.Delete(entry);
            }
            catch (Exception ex) { Note("could not delete " + entry + " :: " + ex.Message); }
        }
    }

    static void ScheduleCleanup(bool removeDir)
    {
        try
        {
            string self = Application.ExecutablePath;
            string cmd = "/c ping 127.0.0.1 -n 3 >nul & ";
            cmd += removeDir ? "rmdir /s /q \"" + dir + "\"" : "del /f /q \"" + self + "\"";
            ProcessStartInfo si = new ProcessStartInfo("cmd.exe", cmd);
            si.UseShellExecute = false;
            si.CreateNoWindow = true;
            si.WindowStyle = ProcessWindowStyle.Hidden;
            Process.Start(si);
        }
        catch (Exception ex) { Note("cleanup failed: " + ex.Message); }
    }

    static long DirSize(string path)
    {
        long total = 0;
        try
        {
            foreach (string f in Directory.GetFiles(path, "*", SearchOption.AllDirectories))
            {
                try { total += new FileInfo(f).Length; } catch { }
            }
        }
        catch { }
        return total;
    }
}

class InstallerForm : Form
{
    public int ExitCode = 0;
    readonly bool un;
    readonly TextBox box;
    readonly CheckBox chk;
    readonly ProgressBar bar;
    readonly Label status;
    readonly Button go;
    readonly Button browse;
    readonly Button cancel;

    public InstallerForm()
    {
        un = Program.IsUninstall;
        Text = (un ? "卸载 " : "安装 ") + Program.AppName;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(470, 236);
        Font = new Font("Microsoft YaHei UI", 9F);
        // the dialog is built in code, so runtime autoscaling does nothing: scale it by hand
        AutoScaleMode = AutoScaleMode.None;

        Label title = new Label();
        title.Text = un ? ("卸载 " + Program.AppName) : ("安装 " + Program.AppName + "  " + Program.Version);
        title.Font = new Font("Microsoft YaHei UI", 12F, FontStyle.Bold);
        title.SetBounds(18, 16, 430, 26);
        Controls.Add(title);

        Label sub = new Label();
        sub.Text = un
            ? "会关闭正在运行的后台回复、删除快捷方式、开机自启和程序文件。"
            : "会把程序文件装到下面的位置，并创建快捷方式和卸载入口。";
        sub.ForeColor = Color.FromArgb(110, 110, 110);
        sub.SetBounds(20, 48, 430, 20);
        Controls.Add(sub);

        Label lbl = new Label();
        lbl.Text = "安装位置";
        lbl.SetBounds(20, 82, 60, 20);
        Controls.Add(lbl);

        box = new TextBox();
        box.Text = Program.Dir;
        box.SetBounds(84, 79, 268, 24);
        Controls.Add(box);

        browse = new Button();
        browse.Text = "浏览…";
        browse.SetBounds(360, 78, 88, 26);
        browse.Click += delegate
        {
            FolderBrowserDialog fb = new FolderBrowserDialog();
            fb.Description = "选择安装位置";
            fb.SelectedPath = box.Text;
            if (fb.ShowDialog(this) == DialogResult.OK) box.Text = fb.SelectedPath;
        };
        Controls.Add(browse);

        chk = new CheckBox();
        chk.Text = un ? "同时删除聊天记录与设置（state、logs）" : "创建桌面和开始菜单快捷方式";
        chk.Checked = !un;
        chk.SetBounds(84, 112, 360, 22);
        Controls.Add(chk);

        bar = new ProgressBar();
        bar.Style = ProgressBarStyle.Marquee;
        bar.MarqueeAnimationSpeed = 30;
        bar.SetBounds(20, 146, 430, 16);
        bar.Visible = false;
        Controls.Add(bar);

        status = new Label();
        status.Text = un ? "点「卸载」开始。" : "点「安装」开始。";
        status.SetBounds(20, 168, 430, 20);
        status.AutoEllipsis = true;
        Controls.Add(status);

        go = new Button();
        go.Text = un ? "卸载" : "安装";
        go.SetBounds(266, 194, 88, 28);
        go.Click += delegate { Go(); };
        Controls.Add(go);

        cancel = new Button();
        cancel.Text = "取消";
        cancel.SetBounds(360, 194, 88, 28);
        cancel.Click += delegate
        {
            if (go.Enabled) { Close(); }
            else { Close(); }
        };
        Controls.Add(cancel);
        AcceptButton = go;
        CancelButton = cancel;
        using (Graphics g = CreateGraphics())
        {
            float s = g.DpiX / 96f;
            if (s > 1.01f) Scale(new SizeF(s, s));
        }
    }

    void Go()
    {
        go.Enabled = false;
        browse.Enabled = false;
        box.Enabled = false;
        bar.Visible = true;
        chk.Enabled = false;
        string target = box.Text.Trim();
        if (target.Length == 0) target = Program.DefaultDir;
        Program.Dir = target;
        bool purge = un && chk.Checked;
        if (purge)
        {
            if (MessageBox.Show(this, "确定连聊天记录和设置一起删除吗？此操作不可恢复。", "确认",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
            {
                go.Enabled = true; browse.Enabled = true; box.Enabled = true; bar.Visible = false; chk.Enabled = true;
                return;
            }
        }
        Cursor = Cursors.WaitCursor;
        Application.DoEvents();
        ExitCode = Program.RunWithUi(delegate(string msg)
        {
            status.Text = msg;
            Application.DoEvents();
        }, purge);
        Cursor = Cursors.Default;
        bar.Style = ProgressBarStyle.Continuous;
        bar.Value = 100;
        go.Enabled = true;
        if (go.Text != "关闭")
        {
            go.Text = "关闭";
            go.Click += delegate { Close(); };
        }
        cancel.Visible = false;
        if (ExitCode == 0)
        {
            status.Text = un ? "卸载完成。" : "安装完成，可以从桌面快捷方式启动。";
            MessageBox.Show(this, un ? "卸载完成。" : "安装完成。", Program.AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        else
        {
            status.Text = "失败，详情见 " + Program.LogPath;
        }
    }
}

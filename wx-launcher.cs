// wx-launcher.cs - hosts wx-panel.ps1 inside this process.
//
// Why not just Process.Start("powershell.exe")? Because then the window belongs
// to powershell.exe: the taskbar draws the PowerShell logo for it (a custom
// WM_SETICON does not win over the process identity on Windows 11). Running the
// script in an in-process PowerShell runspace makes wx-panel.exe the owning
// process, so the taskbar/Task Manager/Alt+Tab pick up the icon embedded in this
// exe, and an explicit AppUserModelID keeps it out of PowerShell's group.
using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;

internal static class WxPanelHost
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("kernel32.dll")]
    private static extern bool AttachConsole(int processId);

    private const string AppId = "DSH.WeChatAutoReply.Panel";

    private static string Dir()
    {
        return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
    }

    private static void Log(string msg)
    {
        try
        {
            string logDir = Path.Combine(Dir(), "logs");
            Directory.CreateDirectory(logDir);
            File.AppendAllText(Path.Combine(logDir, "panel.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " host: " + msg + Environment.NewLine,
                System.Text.Encoding.UTF8);
        }
        catch { }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            SetCurrentProcessExplicitAppUserModelID(AppId);
            Log("appid: " + AppId);
        }
        catch (Exception ex) { Log("appid failed: " + ex.Message); }

        string dir = Dir();
        string script = Path.Combine(dir, "wx-panel.ps1");
        if (!File.Exists(script)) { Log("missing " + script); return 2; }

        try { AttachConsole(-1); } catch { }   // keep -StatusLine output visible when run from a shell

        try
        {
            using (Runspace rs = RunspaceFactory.CreateRunspace())
            {
                rs.Open();
                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;
                    ps.AddCommand(script);
                    string[] switches = { "Shot", "StartBot", "StopBot", "StatusLine", "SelfTest", "Logs", "Stats", "NoticeTest", "Contacts" };
                    for (int i = 0; i < args.Length; i++)
                    {
                        string a = args[i];
                        if (a.Length == 0 || (a[0] != '-' && a[0] != '/')) { Log("ignoring argument: " + a); continue; }
                        string name = a.TrimStart('-', '/');
                        bool isSwitch = Array.Exists(switches, s => string.Equals(s, name, StringComparison.OrdinalIgnoreCase));
                        if (isSwitch) ps.AddParameter(name, true);
                        else if (i + 1 < args.Length) ps.AddParameter(name, args[++i]);
                        else ps.AddParameter(name, true);
                    }
                    Log("running " + script);
                    foreach (PSObject o in ps.Invoke())
                        try { Console.WriteLine(o == null ? string.Empty : o.ToString()); } catch { }
                    foreach (ErrorRecord e in ps.Streams.Error) Log("ps error: " + e.ToString());
                }
            }
            Log("panel closed normally");
            return 0;
        }
        catch (Exception ex)
        {
            Log("runspace failed: " + ex.Message + " - falling back to powershell.exe");
            try
            {
                string extra = string.Empty;
                foreach (string a in args) extra += " " + a;
                System.Diagnostics.ProcessStartInfo psi = new System.Diagnostics.ProcessStartInfo("powershell.exe");
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"" + extra;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WorkingDirectory = dir;
                System.Diagnostics.Process.Start(psi);
                return 0;
            }
            catch (Exception ex2) { Log("fallback failed: " + ex2.Message); return 3; }
        }
    }
}
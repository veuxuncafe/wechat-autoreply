#requires -version 5.1
<#
  winenum.ps1 -- raw Win32 window enumeration, including INVISIBLE windows.

  Why: UIA's desktop child enumeration does not surface every top-level window (a client
  minimised to the notification area, or any hidden window, is missed), and PowerShell 5.1
  cannot declare a delegate with Add-Type -MemberDefinition, so the enum callback must live
  in compiled C#. This exposes:
      [WinEnum]::TopLevel()            -> every top-level window (visible + hidden)
      [WinEnum]::Children(<hwnd>)      -> every descendant window
      [WinEnum]::Describe(<hwnd>)      -> one-line descriptor
  Each line is: hwnd|visible|pid|class|title

  Usage:
    . (Join-Path $PSScriptRoot 'winenum.ps1')
    [WinEnum]::TopLevel() | ForEach-Object { $_ }
#>

if (-not ('WinEnum' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WinEnum
{
    private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetWindowTextW")]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetClassNameW")]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    private static extern IntPtr GetParent(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    private static string Line(IntPtr h)
    {
        StringBuilder cls = new StringBuilder(256);
        GetClassNameW(h, cls, cls.Capacity);
        StringBuilder txt = new StringBuilder(512);
        GetWindowTextW(h, txt, txt.Capacity);
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return string.Format("{0}|{1}|{2}|{3}|{4}",
            h.ToInt64(), IsWindowVisible(h) ? "vis" : "hid", pid, cls.ToString(), txt.ToString());
    }

    public static string[] TopLevel()
    {
        List<string> res = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr p) { res.Add(Line(h)); return true; }, IntPtr.Zero);
        return res.ToArray();
    }

    public static string[] Children(IntPtr parent)
    {
        List<string> res = new List<string>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr p) { res.Add(Line(h)); return true; }, IntPtr.Zero);
        return res.ToArray();
    }

    public static string Describe(IntPtr h) { return Line(h); }

    // Windows that only exist on the desktop's root (topmost), used to spot tray windows.
    public static IntPtr OwnerOf(IntPtr h) { return GetWindow(h, 4 /*GW_OWNER*/); }
}
'@
}

param([switch]$Diagnose, [switch]$EnableAutostart, [switch]$ConfigureOnly, [switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

public static class TraySettings {
    const string RunKey="Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    const string RunName="ViewSonicBrightnessTray";
    public static string StartupCommand;
    public static void Configure(string scriptPath) {
        string powershell=System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell\\v1.0\\powershell.exe");
        StartupCommand="\"" + powershell + "\" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + scriptPath + "\"";
    }
    public static bool AutostartEnabled {
        get {
            using (RegistryKey key=Registry.CurrentUser.OpenSubKey(RunKey)) {
                return key != null && String.Equals(key.GetValue(RunName) as string, StartupCommand, StringComparison.OrdinalIgnoreCase);
            }
        }
    }
    public static void SetAutostart(bool enabled) {
        using (RegistryKey key=Registry.CurrentUser.CreateSubKey(RunKey)) {
            if (enabled) key.SetValue(RunName, StartupCommand, RegistryValueKind.String);
            else key.DeleteValue(RunName, false);
        }
    }
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr icon);
    public static Icon CreateMonitorIcon() {
        using (Bitmap bitmap=new Bitmap(32,32)) {
            using (Graphics g=Graphics.FromImage(bitmap)) {
                g.SmoothingMode=System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (SolidBrush frame=new SolidBrush(Color.FromArgb(49,65,84)))
                using (SolidBrush screen=new SolidBrush(Color.FromArgb(38,166,218)))
                using (SolidBrush light=new SolidBrush(Color.FromArgb(255,223,90)))
                using (Pen ray=new Pen(Color.FromArgb(255,223,90),1.5f)) {
                    g.FillRectangle(frame,1,3,30,22);
                    g.FillRectangle(screen,3,5,26,17);
                    g.FillRectangle(frame,13,24,6,4);
                    g.FillRectangle(frame,8,28,16,3);
                    g.FillEllipse(light,12,9,8,8);
                    g.DrawLine(ray,16,6,16,8); g.DrawLine(ray,16,18,16,20);
                    g.DrawLine(ray,9,13,11,13); g.DrawLine(ray,21,13,23,13);
                    g.DrawLine(ray,11,8,12,9); g.DrawLine(ray,20,17,21,18);
                    g.DrawLine(ray,11,18,12,17); g.DrawLine(ray,20,9,21,8);
                }
            }
            IntPtr handle=bitmap.GetHicon();
            try { using (Icon borrowed=Icon.FromHandle(handle)) { return (Icon)borrowed.Clone(); } }
            finally { DestroyIcon(handle); }
        }
    }
}

public sealed class MonitorDevice : IDisposable {
    public IntPtr Handle;
    public string Name;
    public uint Maximum;
    public uint Current;
    public string Error;
    public uint ContrastMaximum;
    public uint ContrastMinimum;
    public uint ContrastCurrent;
    public string ContrastError;
    public bool ContrastHighLevel;
    public override string ToString() { return Name; }
    public void Dispose() {
        if (Handle != IntPtr.Zero) { NativeMonitor.DestroyPhysicalMonitor(Handle); Handle = IntPtr.Zero; }
    }
}
public static class NativeMonitor {
    static DateTime lastCommand=DateTime.MinValue;
    // All monitor I/O is serialized by the application's single worker.
    static void Pace() {
        double remaining=500 - (DateTime.UtcNow-lastCommand).TotalMilliseconds;
        if (remaining > 0) System.Threading.Thread.Sleep((int)Math.Ceiling(remaining));
        lastCommand=DateTime.UtcNow;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct PhysicalMonitor {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    }
    public delegate bool EnumProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, EnumProc callback, IntPtr data);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("dxva2.dll", SetLastError=true, CharSet=CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PhysicalMonitor[] physical);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint maximum);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool GetMonitorContrast(IntPtr monitor, out uint minimum, out uint current, out uint maximum);
    [DllImport("dxva2.dll", SetLastError=true)] static extern bool SetMonitorContrast(IntPtr monitor, uint value);
    [DllImport("dxva2.dll", SetLastError=true)] public static extern bool DestroyPhysicalMonitor(IntPtr monitor);
    public static void Read(MonitorDevice device) {
        uint type, current, maximum;
        Pace();
        if (!GetVCPFeatureAndVCPFeatureReply(device.Handle, 0x10, out type, out current, out maximum))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        if (maximum == 0 || current > maximum) throw new Exception("Monitor returned an invalid brightness range.");
        device.Current = current; device.Maximum = maximum;
    }
    public static void Write(MonitorDevice device, int percent) {
        uint value = (uint)Math.Round(device.Maximum * (Math.Max(0, Math.Min(100, percent)) / 100.0));
        Pace();
        if (!SetVCPFeature(device.Handle, 0x10, value)) throw new Win32Exception(Marshal.GetLastWin32Error());
        device.Current = value;
    }
    public static void ReadContrast(MonitorDevice device) {
        uint type, current, maximum, minimum;
        int vcpError=0;
        device.ContrastError=null;
        for (int attempt=0; attempt<1; attempt++) {
            Pace();
            if (GetVCPFeatureAndVCPFeatureReply(device.Handle, 0x12, out type, out current, out maximum)) {
                if (maximum == 0 || current > maximum) continue;
                device.ContrastMinimum=0; device.ContrastCurrent=current;
                device.ContrastMaximum=maximum; device.ContrastHighLevel=false;
                return;
            }
            vcpError=Marshal.GetLastWin32Error();
        }
        Pace();
        if (GetMonitorContrast(device.Handle, out minimum, out current, out maximum)) {
            if (maximum <= minimum || current < minimum || current > maximum)
                throw new Exception("Monitor returned an invalid contrast range.");
            device.ContrastMinimum=minimum; device.ContrastCurrent=current;
            device.ContrastMaximum=maximum; device.ContrastHighLevel=true;
            return;
        }
        int apiError=Marshal.GetLastWin32Error();
        throw new Exception("VCP 0x12: " + vcpError + "; Windows API: " + apiError + ". " + new Win32Exception(apiError).Message);
    }
    public static void WriteContrast(MonitorDevice device, int percent) {
        uint value = device.ContrastMinimum + (uint)Math.Round((device.ContrastMaximum - device.ContrastMinimum) * (Math.Max(0, Math.Min(100, percent)) / 100.0));
        Pace();
        bool success=device.ContrastHighLevel ? SetMonitorContrast(device.Handle, value) : SetVCPFeature(device.Handle, 0x12, value);
        if (!success) throw new Win32Exception(Marshal.GetLastWin32Error());
        device.ContrastCurrent = value;
    }
    public static List<MonitorDevice> Find() {
        List<MonitorDevice> result = new List<MonitorDevice>();
        EnumProc callback = delegate(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data) {
            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count)) {
                result.Add(new MonitorDevice { Name="Display", Error=new Win32Exception(Marshal.GetLastWin32Error()).Message });
                return true;
            }
            PhysicalMonitor[] items = new PhysicalMonitor[count];
            if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, items)) {
                result.Add(new MonitorDevice { Name="Display", Error=new Win32Exception(Marshal.GetLastWin32Error()).Message });
                return true;
            }
            foreach (PhysicalMonitor item in items) {
                MonitorDevice device = new MonitorDevice { Handle=item.Handle, Name=item.Description };
                try { Read(device); } catch (Exception ex) { device.Error=ex.Message; }
                try { ReadContrast(device); } catch (Exception ex) { device.ContrastError=ex.Message; }
                result.Add(device);
            }
            return true;
        };
        if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero)) {
            foreach (MonitorDevice device in result) device.Dispose();
            throw new Exception("Cannot enumerate displays.");
        }
        return result;
    }
}
public sealed class BrightnessApp : ApplicationContext {
    NotifyIcon tray;
    Icon monitorIcon;
    Form popup;
    ComboBox displays;
    TrackBar slider;
    TrackBar contrastSlider;
    Label brightnessLabel;
    Label contrastLabel;
    Label status;
    System.Windows.Forms.Timer debounce;
    System.Windows.Forms.Timer recovery;
    bool busy;
    bool exiting;
    int recoverySeconds=15;
    DateTime nextRecovery=DateTime.MinValue;
    List<MonitorDevice> devices = new List<MonitorDevice>();
    bool loading;
    bool brightnessPending;
    bool contrastPending;
    public BrightnessApp() {
        popup = new Form { Text="Monitor Brightness", ClientSize=new Size(380,345), FormBorderStyle=FormBorderStyle.FixedToolWindow, ShowInTaskbar=false, TopMost=true, StartPosition=FormStartPosition.Manual };
        displays = new ComboBox { Left=14, Top=14, Width=350, DropDownStyle=ComboBoxStyle.DropDownList };
        brightnessLabel = new Label { Left=16, Top=49, Width=348, Height=20, Text="Brightness" };
        slider = new TrackBar { Left=10, Top=72, Width=358, Minimum=0, Maximum=100, TickFrequency=10, SmallChange=1, LargeChange=10 };
        contrastLabel = new Label { Left=16, Top=122, Width=348, Height=20, Text="Contrast" };
        contrastSlider = new TrackBar { Left=10, Top=145, Width=358, Minimum=0, Maximum=100, TickFrequency=10, SmallChange=1, LargeChange=10 };
        status = new Label { Left=16, Top=198, Width=348, Height=102 };
        Button refresh = new Button { Text="Refresh", Left=264, Top=310, Width=100 };
        popup.Controls.AddRange(new Control[] { displays, brightnessLabel, slider, contrastLabel, contrastSlider, status, refresh });
        debounce = new System.Windows.Forms.Timer { Interval=700 };
        debounce.Tick += delegate {
            if (slider.Capture || contrastSlider.Capture || busy) return;
            debounce.Stop(); Apply();
        };
        recovery = new System.Windows.Forms.Timer { Interval=1000 };
        recovery.Tick += delegate {
            if (!busy && nextRecovery != DateTime.MinValue && DateTime.UtcNow >= nextRecovery) Reload();
        };
        recovery.Start();
        displays.SelectedIndexChanged += delegate { debounce.Stop(); brightnessPending=false; contrastPending=false; UpdateSelection(); };
        slider.ValueChanged += delegate {
            if (loading) return;
            brightnessLabel.Text="Brightness: " + slider.Value + "%";
            brightnessPending=true;
            debounce.Stop(); debounce.Start();
        };
        contrastSlider.ValueChanged += delegate {
            if (loading) return;
            contrastLabel.Text="Contrast: " + contrastSlider.Value + "%";
            contrastPending=true;
            debounce.Stop(); debounce.Start();
        };
        refresh.Click += delegate { Reload(); };
        popup.FormClosing += delegate(object sender, FormClosingEventArgs e) { e.Cancel=true; popup.Hide(); };
        popup.Deactivate += delegate { popup.Hide(); };
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("Brightness", null, delegate { ShowPopup(); });
        menu.Items.Add("Refresh monitors", null, delegate { Reload(); ShowPopup(); });
        ToolStripMenuItem autostart=new ToolStripMenuItem("Start with Windows");
        autostart.Checked=TraySettings.AutostartEnabled;
        autostart.Click += delegate {
            try { TraySettings.SetAutostart(!TraySettings.AutostartEnabled); autostart.Checked=TraySettings.AutostartEnabled; }
            catch (Exception ex) { MessageBox.Show("Could not update autostart: " + ex.Message, "Monitor Brightness", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        };
        menu.Opening += delegate { autostart.Checked=TraySettings.AutostartEnabled; };
        menu.Items.Add(autostart);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { ExitThread(); });
        monitorIcon=TraySettings.CreateMonitorIcon();
        popup.Icon=monitorIcon;
        tray = new NotifyIcon { Icon=monitorIcon, Text="Monitor Brightness - brightness and contrast", ContextMenuStrip=menu, Visible=true };
        tray.MouseClick += delegate(object sender, MouseEventArgs e) { if (e.Button == MouseButtons.Left) ShowPopup(); };
        EventHandler initialLoad=null;
        initialLoad=delegate { Application.Idle -= initialLoad; Reload(); };
        Application.Idle += initialLoad;
        tray.ShowBalloonTip(3500, "Monitor Brightness", "Click the tray icon to adjust brightness.", ToolTipIcon.Info);
    }
    void Reload() {
        if (busy || exiting) return;
        if (nextRecovery != DateTime.MinValue && DateTime.UtcNow < nextRecovery) {
            status.Text="DDC/CI cooling down. Automatic retry in " + Math.Max(1, (int)Math.Ceiling((nextRecovery-DateTime.UtcNow).TotalSeconds)) + "s.";
            return;
        }
        debounce.Stop();
        brightnessPending=false; contrastPending=false;
        string previous = displays.SelectedItem == null ? null : displays.SelectedItem.ToString();
        loading=true;
        displays.Items.Clear();
        slider.Enabled=false; contrastSlider.Enabled=false; displays.Enabled=false;
        status.Text="Reading monitor settings...";
        RunIo(delegate {
            foreach (MonitorDevice device in devices) device.Dispose();
            devices.Clear();
            devices=NativeMonitor.Find();
        }, delegate(Exception error) {
          try {
            if (error != null) throw error;
            foreach (MonitorDevice device in devices) displays.Items.Add(device);
            int selected=devices.FindIndex(d => d.Name == previous);
            if (selected < 0) selected=devices.FindIndex(d => d.Name.IndexOf("ViewSonic", StringComparison.OrdinalIgnoreCase) >= 0 || d.Name.IndexOf("VX2780", StringComparison.OrdinalIgnoreCase) >= 0);
            if (selected < 0 && devices.Count > 0) selected=0;
            displays.SelectedIndex=selected;
          } catch (Exception ex) { status.Text=ex.Message; }
          finally { loading=false; displays.Enabled=true; }
          if (error == null) UpdateSelection();
          ScheduleRecovery(error != null);
        });
    }
    void RunIo(Action operation, Action<Exception> completed) {
        busy=true;
        BackgroundWorker worker=new BackgroundWorker();
        worker.DoWork += delegate { operation(); };
        worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs e) {
            busy=false;
            worker.Dispose();
            if (exiting) { ExitThread(); return; }
            completed(e.Error);
        };
        worker.RunWorkerAsync();
    }
    void ScheduleRecovery(bool failed) {
        foreach (MonitorDevice device in devices) {
            if (device.Error != null || device.ContrastError != null) failed=true;
        }
        if (!failed) { recoverySeconds=15; nextRecovery=DateTime.MinValue; return; }
        nextRecovery=DateTime.UtcNow.AddSeconds(recoverySeconds);
        recoverySeconds=Math.Min(120, recoverySeconds * 2);
        status.Text += "\r\nAutomatic retry after a pause.";
    }
    void UpdateSelection() {
        if (loading) return;
        MonitorDevice device=displays.SelectedItem as MonitorDevice;
        slider.Enabled=device != null && device.Error == null;
        contrastSlider.Enabled=device != null && device.Handle != IntPtr.Zero && device.ContrastError == null && device.ContrastMaximum > 0;
        brightnessLabel.Text="Brightness: unavailable";
        contrastLabel.Text="Contrast: unavailable";
        if (device == null) { status.Text="No monitors found. Click Refresh after reconnecting."; return; }
        loading=true;
        if (slider.Enabled) {
            slider.Value=(int)Math.Round(100.0 * device.Current / device.Maximum);
            brightnessLabel.Text="Brightness: " + slider.Value + "%";
        }
        if (contrastSlider.Enabled) {
            contrastSlider.Value=(int)Math.Round(100.0 * (device.ContrastCurrent - device.ContrastMinimum) / (device.ContrastMaximum - device.ContrastMinimum));
            contrastLabel.Text="Contrast: " + contrastSlider.Value + "%";
        }
        loading=false;
        status.Text=device.Error != null ? "Brightness unavailable: " + device.Error : "";
        if (device.ContrastError != null) status.Text += (status.Text.Length > 0 ? "\r\n" : "") + "Contrast unavailable: " + device.ContrastError;
    }
    void Apply() {
        if (busy || exiting) return;
        if (nextRecovery != DateTime.MinValue && DateTime.UtcNow < nextRecovery) {
            brightnessPending=false; contrastPending=false;
            UpdateSelection();
            status.Text="DDC/CI cooling down. Automatic retry after a pause.";
            return;
        }
        MonitorDevice device=displays.SelectedItem as MonitorDevice;
        bool writeBrightness=brightnessPending, writeContrast=contrastPending;
        brightnessPending=false; contrastPending=false;
        if (device == null) return;
        int brightness=slider.Value, contrast=contrastSlider.Value;
        writeBrightness=writeBrightness && slider.Enabled;
        writeContrast=writeContrast && contrastSlider.Enabled;
        displays.Enabled=false;
        status.Text="Applying...";
        RunIo(delegate {
            // Stop on the first error; do not send another command into a failing connection.
            if (writeBrightness) {
                try { NativeMonitor.Write(device, brightness); }
                catch (Exception ex) { device.Error=ex.Message; throw; }
            }
            if (writeContrast) {
                try { NativeMonitor.WriteContrast(device, contrast); }
                catch (Exception ex) { device.ContrastError=ex.Message; throw; }
            }
        }, delegate(Exception error) {
            displays.Enabled=true;
            if (error != null) {
                debounce.Stop(); brightnessPending=false; contrastPending=false;
                UpdateSelection();
                ScheduleRecovery(true);
            } else {
                status.Text="Applied";
                if (brightnessPending || contrastPending) { debounce.Stop(); debounce.Start(); }
            }
        });
    }
    void ShowPopup() {
        Rectangle area=Screen.FromPoint(Cursor.Position).WorkingArea;
        popup.Location=new Point(Math.Max(area.Left, Math.Min(Cursor.Position.X-popup.Width/2, area.Right-popup.Width)), Math.Max(area.Top, Math.Min(Cursor.Position.Y-popup.Height, area.Bottom-popup.Height)));
        popup.Show(); popup.Activate();
    }
    protected override void ExitThreadCore() {
        recovery.Stop(); debounce.Stop();
        if (busy) {
            exiting=true;
            popup.Hide(); tray.Visible=false;
            return;
        }
        recovery.Dispose();
        debounce.Stop(); debounce.Dispose(); tray.Visible=false; tray.Dispose();
        foreach (MonitorDevice device in devices) device.Dispose();
        popup.Dispose(); base.ExitThreadCore();
        monitorIcon.Dispose();
    }
}
'@

[TraySettings]::Configure($PSCommandPath)
if ($ValidateOnly) { Write-Output 'Compilation OK'; return }
if ($EnableAutostart) {
    [TraySettings]::SetAutostart($true)
    Write-Output 'Autostart enabled for the current Windows user.'
}
if ($ConfigureOnly) { return }

if ($Diagnose) {
    $devices = [NativeMonitor]::Find()
    try {
        foreach ($device in $devices) {
            if ($device.Error) { Write-Output ("{0}: DDC/CI ERROR: {1}" -f $device.Name, $device.Error) }
            else { Write-Output ("{0}: brightness {1}/{2}; DDC/CI OK" -f $device.Name, $device.Current, $device.Maximum) }
            if ($device.ContrastError) { Write-Output ("{0}: contrast ERROR: {1}" -f $device.Name, $device.ContrastError) }
            elseif ($device.ContrastMaximum -gt 0) { Write-Output ("{0}: contrast {1}/{2}; DDC/CI OK" -f $device.Name, $device.ContrastCurrent, $device.ContrastMaximum) }
        }
        if ($devices.Count -eq 0) { Write-Output 'No physical monitors found.' }
    } finally { foreach ($device in $devices) { $device.Dispose() } }
    exit
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\ViewSonicBrightnessTray')
$owned = $false
try {
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit }
    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::Run((New-Object BrightnessApp))
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

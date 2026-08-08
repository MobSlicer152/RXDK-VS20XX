using System.ComponentModel;
using Microsoft.VisualStudio.Shell;

namespace RxdkVs.Package.Options
{
    /// <summary>
    /// Tools &gt; Options &gt; RXDK &gt; General. Per-user settings, persisted automatically by the
    /// shell. Mirrors the RXDK-VSCode "rxdk.xemuPath" / "rxdk.xemuParams" configuration.
    /// </summary>
    public sealed class RxdkOptionsPage : DialogPage
    {
        [Category("xemu")]
        [DisplayName("xemu path")]
        [Description("Path to the xemu executable. When set to a valid path, 'Launch in xemu' " +
                     "becomes available (builds the ISO and boots it in xemu — no debugging).")]
        public string XemuPath { get; set; } = "";

        [Category("xemu")]
        [DisplayName("xemu parameters")]
        [Description("Parameters passed to xemu before '-dvd_path <iso>'. The default " +
                     "(-device lpc47m157 -serial stdio) routes the Xbox debug serial to the RXDK " +
                     "output pane so you see the title's console output.")]
        public string XemuParams { get; set; } = "-device lpc47m157 -serial stdio";
    }
}

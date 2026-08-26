using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.VisualStudio.Shell;
using Microsoft.VisualStudio.Shell.Interop;
using Task = System.Threading.Tasks.Task;

namespace RxdkVs.Package.Services
{
    /// <summary>
    /// A dedicated "Xbox Title" Output pane that shows only the running title's debug spew
    /// (DM_DEBUGSTR / OutputDebugString), separate from the raw debugger-adapter stream in the
    /// standard Debug pane. Mirrors RXDK-VSCode's "Xbox Title" channel: the shared debug adapter
    /// (<c>Rxdk.Dap</c>) writes the title text to the launch config's <c>__titleOutputFile</c>, and
    /// this class tails that file into the pane while the session runs. The raw output still appears
    /// in the Debug pane via the adapter's console OutputEvents; this is the clean, formatted view.
    /// </summary>
    internal sealed class TitleOutputPane
    {
        // Stable pane guid so the pane is reused across sessions rather than duplicated.
        private static readonly Guid PaneGuid = new Guid("6f2a1d94-3c7b-4e58-9a1e-2d0b6c8f41a2");
        private const string PaneTitle = "Xbox Title";

        private readonly AsyncPackage _package;
        private IVsOutputWindowPane _pane;
        private Timer _timer;
        private string _file = "";
        private long _offset;
        private bool _revealed;
        private EnvDTE.DebuggerEvents _debuggerEvents; // kept alive to receive OnEnterDesignMode
        private EnvDTE._dispDebuggerEvents_OnEnterDesignModeEventHandler _onEnterDesignMode;

        public TitleOutputPane(AsyncPackage package) => _package = package;

        /// <summary>
        /// Truncates <paramref name="file"/> (fresh per session), clears and reveals the pane, and
        /// begins tailing the file. Stops automatically when the debugger returns to design mode.
        /// </summary>
        public async Task StartAsync(string file)
        {
            await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
            _file = file;
            _offset = 0;
            _revealed = false;
            try { File.WriteAllText(file, string.Empty); } catch { /* adapter recreates on first write */ }

            if (await _package.GetServiceAsync(typeof(SVsOutputWindow)) is IVsOutputWindow ow)
            {
                var guid = PaneGuid;
                ow.CreatePane(ref guid, PaneTitle, fInitVisible: 1, fClearWithSolution: 0); // idempotent per guid
                ow.GetPane(ref guid, out _pane);
                _pane?.Clear();
                _pane?.OutputStringThreadSafe("--- Xbox title output ---" + Environment.NewLine);
            }

            // Stop tailing when the debug session ends (debugger returns to design mode).
            if (await _package.GetServiceAsync(typeof(EnvDTE.DTE)) is EnvDTE.DTE dte)
            {
                _debuggerEvents = dte.Events?.DebuggerEvents;
                if (_debuggerEvents != null)
                {
                    _onEnterDesignMode = _ => Stop();
                    _debuggerEvents.OnEnterDesignMode += _onEnterDesignMode;
                }
            }

            _timer = new Timer(_ => Poll(), null, 0, 100);
        }

        private void Poll()
        {
            try
            {
                if (string.IsNullOrEmpty(_file) || !File.Exists(_file))
                    return;
                var len = new FileInfo(_file).Length;
                if (len <= _offset)
                    return;

                byte[] buf;
                using (var fs = new FileStream(_file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    fs.Seek(_offset, SeekOrigin.Begin);
                    buf = new byte[len - _offset];
                    var read = fs.Read(buf, 0, buf.Length);
                    if (read < buf.Length)
                        Array.Resize(ref buf, read);
                }
                _offset += buf.Length;

                var text = Encoding.UTF8.GetString(buf);
                if (text.Length == 0)
                    return;

                // The adapter writes lone \n; the Output pane wants \r\n for clean line breaks.
                text = text.Replace("\r\n", "\n").Replace("\n", Environment.NewLine);
                var pane = _pane;
                // OutputStringThreadSafe is explicitly safe to call off the UI thread (that is the
                // point of the ...ThreadSafe variant), which is exactly what the timer thread needs.
#pragma warning disable VSTHRD010
                pane?.OutputStringThreadSafe(text);
#pragma warning restore VSTHRD010
                if (!_revealed && pane != null)
                {
                    _revealed = true;
                    _ = ThreadHelper.JoinableTaskFactory.RunAsync(async () =>
                    {
                        await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                        pane.Activate();
                    });
                }
            }
            catch
            {
                /* transient IO (file locked mid-write) — the next poll catches up */
            }
        }

        public void Stop()
        {
            var timer = _timer;
            _timer = null;
            Poll(); // final flush
            try { timer?.Dispose(); } catch { /* ignore */ }

            var handler = _onEnterDesignMode;
            var events = _debuggerEvents;
            if (handler != null && events != null)
            {
                _onEnterDesignMode = null;
                // Unsubscribe on the UI thread (DTE events are UI-affine) so old sessions' handlers
                // don't accumulate on the shared DebuggerEvents object.
                _ = ThreadHelper.JoinableTaskFactory.RunAsync(async () =>
                {
                    await ThreadHelper.JoinableTaskFactory.SwitchToMainThreadAsync();
                    try { events.OnEnterDesignMode -= handler; } catch { /* ignore */ }
                });
            }
        }
    }
}

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace Rxdk.Installer
{
    class Installer
    {
        public required string InstallPath;
        public required string StartMenuFolder;
        public required bool CreateStartMenuFolder;
        public required bool InstallVsExtension;
        public required bool InstallDocs;
        public required bool InstallSamples;

        public delegate void InstallCompletedHandler(bool incomplete);
        public event InstallCompletedHandler? InstallCompleted;
        public delegate void ProgressHandler(float progress, string progressText);
        public event ProgressHandler? Progress;

        public bool Cancelled { get; private set; }
        private Assembly? engine = null;
        private Dispatcher? dispatcher;

        public const string InstallRootVariable = "RXDK_INSTALL_ROOT";

        public Installer()
        {
            Cancelled = false;
        }

        /// <summary>
        /// Begin installing on the current thread, which is expected to not be the main thread
        /// </summary>
        public void Install()
        {
            if (Cancelled)
            {
                return;
            }

            dispatcher = Dispatcher.FromThread(Thread.CurrentThread);
            try
            {
                StageEngine();
                if (InstallVsExtension)
                {
                    StageVsExtension();
                }
                StageComponents();
            }
            catch (Exception ex) { App.Log($"Installation terminated: {ex.Message}"); Cancelled = true; }

            InstallCompleted?.Invoke(Cancelled);
        }

        /// <summary>
        /// Terminate the thread the installation is running on
        /// </summary>
        public void Cancel()
        {
            // if there's no dispatcher, there's nothing to cancel
            if (dispatcher != null)
            {
                try
                {
                    dispatcher.Invoke(new Action(() =>
                    {
                        throw new Exception("cancelled by user");
                    }));
                }
                catch { }

                Cancelled = true;
                dispatcher = null;
            }
        }

        void SetEnvironmentVariable(string name, string value)
        {
            App.Log($"Setting {name} to {value}");
            Environment.SetEnvironmentVariable(name, value);
            try
            {
                Environment.SetEnvironmentVariable(name, value, EnvironmentVariableTarget.Machine);
            }
            catch
            {
                // set it for the user if setting it globally didnt work
                App.Log($"Failed to to set {name} globally, setting for current user");
                Environment.SetEnvironmentVariable(name, value, EnvironmentVariableTarget.User);
            }
        }

        /// <summary>
        /// Set RXDK_INSTALL_ROOT, install the engine, load it
        /// </summary>
        public void StageEngine()
        {
            // set the install root
            Progress?.Invoke(0.0f, $"Setting {InstallRootVariable}");
            SetEnvironmentVariable(InstallRootVariable, InstallPath);

            // TODO: install the engine

            // load the engine
            var enginePath = $"{InstallPath}\\engine\\Rxdk.Engine.dll";
            Progress?.Invoke(0.6f, $"Loading {enginePath}");
            App.Log($"Loading {enginePath}");
            engine = Assembly.LoadFrom(enginePath);
        }

        /// <summary>
        /// Install the VS extension
        /// </summary>
        public void StageVsExtension()
        {
        }

        /// <summary>
        /// Install the SDK, Zig, docs, and samples
        /// </summary>
        public void StageComponents()
        {
        }
    }
}

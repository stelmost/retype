# Embedded by the CLI; the helper returns a decision and does not perform Undo.
$ErrorActionPreference = 'Stop'
try {
	$forms = [Reflection.Assembly]::Load(
		'System.Windows.Forms, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
	$drawing = [Reflection.Assembly]::Load(
		'System.Drawing, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
	Add-Type -ReferencedAssemblies @($forms.Location, $drawing.Location, [Uri].Assembly.Location) -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Windows.Forms;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

public static class RetypeReview {
	const int TimeoutMs = 60000;
	const int WTSConnectState = 8, WTSActive = 0, UOI_NAME = 2;
	const uint DesktopReadObjects = 1;

	[DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
	[DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
	[DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
	[DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
	[DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
	static extern bool GetUserObjectInformationW(IntPtr handle, int index, StringBuilder name, uint size, out uint needed);
	[DllImport("wtsapi32.dll", ExactSpelling = true)]
	static extern bool WTSQuerySessionInformationW(IntPtr server, int session, int info, out IntPtr buffer, out uint size);
	[DllImport("wtsapi32.dll")] static extern void WTSFreeMemory(IntPtr buffer);

	static bool IsDefaultDesktop(IntPtr handle) {
		var name = new StringBuilder(256);
		uint needed;
		return handle != IntPtr.Zero
			&& GetUserObjectInformationW(handle, UOI_NAME, name, (uint)name.Capacity * sizeof(char), out needed)
			&& String.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
	}

	static bool OnInteractiveDesktop() {
		if (!Environment.UserInteractive) return false;
		int session;
		using (var process = Process.GetCurrentProcess()) session = process.SessionId;
		if (session == 0 || !IsDefaultDesktop(GetThreadDesktop(GetCurrentThreadId()))) return false;

		// A disconnected session can still return an input desktop handle.
		IntPtr state;
		uint bytes;
		if (!WTSQuerySessionInformationW(IntPtr.Zero, session, WTSConnectState, out state, out bytes)) return false;
		try {
			if (state == IntPtr.Zero || bytes < sizeof(int) || Marshal.ReadInt32(state) != WTSActive) return false;
		} finally { WTSFreeMemory(state); }

		var input = OpenInputDesktop(0, false, DesktopReadObjects);
		if (input == IntPtr.Zero) return false;
		try { return IsDefaultDesktop(input); }
		finally {
			if (!CloseDesktop(input)) throw new InvalidOperationException("Could not close the input desktop handle.");
		}
	}

	sealed class ReviewForm : Form {
		protected override bool ProcessCmdKey(ref Message message, Keys keys) {
			// WinForms can redirect Enter to a focused button even with AcceptButton set.
			if ((keys & Keys.KeyCode) != Keys.Enter) return base.ProcessCmdKey(ref message, keys);
			DialogResult = DialogResult.Cancel;
			return true;
		}
	}

	static bool Fits(Form form) {
		if (!Screen.FromRectangle(form.Bounds).WorkingArea.Contains(form.Bounds)) return false;
		for (int i = 0; i < form.Controls.Count; i++) {
			var control = form.Controls[i];
			var preferred = control.PreferredSize;
			if (control.Width < preferred.Width || control.Height < preferred.Height
				|| !form.ClientRectangle.Contains(control.Bounds)) return false;
			for (int j = 0; j < i; j++)
				if (control.Bounds.IntersectsWith(form.Controls[j].Bounds)) return false;
		}
		return true;
	}

	static Button AddButton(Form form, int left, int top, string text) {
		var button = new Button {
			Text = text, UseMnemonic = false, Location = new Point(left, top),
			AutoSize = true, MinimumSize = new Size(80, 28)
		};
		form.Controls.Add(button);
		return button;
	}

	static bool Layout(Form form, string text, string undoLabel) {
		const int Gap = 16;
		var area = Screen.FromPoint(Cursor.Position).WorkingArea;
		int width = Math.Min(900, area.Width - 4 * Gap);
		if (width < 1) return false;
		var summary = new Label {
			Text = text, UseMnemonic = false, UseCompatibleTextRendering = true, AutoSize = true,
			MaximumSize = new Size(width, 0), Location = new Point(Gap, Gap)
		};
		form.Controls.Add(summary);
		var close = AddButton(form, Gap, summary.Bottom + Gap, "Close");
		close.DialogResult = DialogResult.Cancel;
		var last = close;
		if (!String.IsNullOrWhiteSpace(undoLabel)) {
			last = AddButton(form, close.Right + Gap, close.Top, undoLabel);
			last.Click += (sender, args) => {
				if (!Fits(form)) throw new InvalidOperationException("The whole Review must fit on screen.");
				form.DialogResult = DialogResult.Yes;
			};
		}
		form.ClientSize = new Size(Math.Max(summary.Right, last.Right) + Gap, Math.Max(close.Bottom, last.Bottom) + Gap);
		form.Location = new Point(area.Left + (area.Width - form.Width) / 2, area.Top + (area.Height - form.Height) / 2);
		form.AcceptButton = form.CancelButton = close;
		form.ActiveControl = close;
		return Fits(form);
	}

	public static int Show(string text, string undoLabel) {
		if (String.IsNullOrWhiteSpace(text) || text.Length > 4096 || (undoLabel != null && undoLabel.Length > 80)
			|| !OnInteractiveDesktop()) return 1;
		using (var identity = WindowsIdentity.GetCurrent())
			if (new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) return 1;

		Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
		Application.EnableVisualStyles();
		var clock = Stopwatch.StartNew();
		// Enforce the deadline even if the UI message loop is blocked.
		using (var timeout = new System.Threading.Timer(_ => Environment.Exit(0), null, TimeoutMs, -1)) {
			using (var form = new ReviewForm {
				Text = "Retype Review", StartPosition = FormStartPosition.Manual, FormBorderStyle = FormBorderStyle.FixedDialog,
				AutoScaleMode = AutoScaleMode.None, MinimizeBox = false, MaximizeBox = false, Font = SystemFonts.MessageBoxFont
			}) {
				if (!Layout(form, text, undoLabel) || !OnInteractiveDesktop()) return 1;
				if (form.ShowDialog() != DialogResult.Yes || String.IsNullOrWhiteSpace(undoLabel)) return 0;
				if (!OnInteractiveDesktop()) return 1;
			}
			if (clock.ElapsedMilliseconds >= TimeoutMs) return 0;
			return 42;
		}
	}
}
'@
	exit ([RetypeReview]::Show(
		[Environment]::GetEnvironmentVariable('RETYPE_REVIEW_TEXT'),
		[Environment]::GetEnvironmentVariable('RETYPE_REVIEW_UNDO_LABEL')))
} catch { exit 1 }

# Native shell-link identity for the per-user CLI installation. No daemon is started here.
function New-RetypeShortcut {
	param([string]$Path, [string]$Target, [string]$Arguments)
	if (-not ('RetypeShortcutIdentity' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class RetypeShortcutIdentity {
	[StructLayout(LayoutKind.Sequential)]
	struct PropertyKey {
		public Guid Format;
		public uint Id;
	}

	[StructLayout(LayoutKind.Explicit, Size = 24)]
	struct PropertyValue {
		[FieldOffset(0)] public ushort Type;
		[FieldOffset(8)] public IntPtr Text;
	}

	[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
	interface IPropertyStore {
		[PreserveSig] int GetCount(out uint count);
		[PreserveSig] int GetAt(uint index, out PropertyKey key);
		[PreserveSig] int GetValue(ref PropertyKey key, out PropertyValue value);
		[PreserveSig] int SetValue(ref PropertyKey key, ref PropertyValue value);
		[PreserveSig] int Commit();
	}

	[DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
	static extern int SHGetPropertyStoreFromParsingName(
		string path, IntPtr context, uint flags, ref Guid id, out IPropertyStore store);

	[DllImport("ole32.dll", PreserveSig = true)]
	static extern int PropVariantClear(ref PropertyValue value);

	public static void Set(string path) {
		var id = typeof(IPropertyStore).GUID;
		IPropertyStore store;
		Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 2, ref id, out store));
		var key = new PropertyKey {
			Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5
		};
		var value = new PropertyValue {
			Type = 31, Text = Marshal.StringToCoTaskMemUni("com.lapilliworks.retype.cli")
		};
		try {
			Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
			Marshal.ThrowExceptionForHR(store.Commit());
		} finally {
			PropVariantClear(ref value);
			Marshal.ReleaseComObject(store);
		}
	}
}
'@
	}
	$shell = New-Object -ComObject WScript.Shell
	try {
		$link = $shell.CreateShortcut($Path)
		try {
			$link.TargetPath = $Target
			$link.Arguments = $Arguments
			$link.WorkingDirectory = Split-Path -Parent $Target
			$link.Description = 'retype file conversion daemon'
			$link.WindowStyle = 7
			$link.Save()
		} finally {
			[Runtime.InteropServices.Marshal]::ReleaseComObject($link) | Out-Null
		}
	} finally {
		[Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
	}
	[RetypeShortcutIdentity]::Set($Path)
}

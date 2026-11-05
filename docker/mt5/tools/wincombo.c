// wincombo - read and select entries of standard Win32 combo boxes in the
// MT5 terminal, through window messages (the interface accessibility tools
// use). No process memory is read or written.
//
//   wincombo list           every visible combo box: handle, entry count, entries
//   wincombo select TEXT    select the entry equal to TEXT (case-insensitive) in the
//                           visible combo box that has it, and notify the dialog as a
//                           user's pick would (WM_COMMAND/CBN_SELCHANGE)
//
// Exit: 0 ok; 2 TEXT not in any visible combo box; 1 usage.
// The controls hold UTF-16 text, so the W APIs are used (the A ones returned
// only the first character). Built with mingw-w64 in docker/mt5/Dockerfile and
// run under Wine. Why: the account wizard's server list ignores typed names,
// and its order varies between runs (seen on FTMO: FTMO-Demo was entry 5 with
// the other five servers in two different orders).
#include <windows.h>
#include <stdio.h>
#include <string.h>

static WCHAR want[256];
static int found, listed;

static void out(const WCHAR *w) {
	char u[1024];
	WideCharToMultiByte(CP_UTF8, 0, w, -1, u, sizeof u, NULL, NULL);
	fputs(u, stdout);
}

static void dump(HWND combo) {
	LRESULT n = SendMessageW(combo, CB_GETCOUNT, 0, 0);
	LRESULT cur = SendMessageW(combo, CB_GETCURSEL, 0, 0);
	printf("combo %p entries=%ld selected=%ld\n", (void *)combo, (long)n, (long)cur);
	for (LRESULT i = 0; i < n && i < 200; i++) {
		WCHAR item[256] = L"";
		LRESULT len = SendMessageW(combo, CB_GETLBTEXTLEN, (WPARAM)i, 0);
		if (len >= 0 && len < 256) SendMessageW(combo, CB_GETLBTEXT, (WPARAM)i, (LPARAM)item);
		printf("  [%ld] ", (long)i);
		out(item);
		printf("\n");
	}
	listed++;
}

static int pick(HWND combo) {
	LRESULT i = SendMessageW(combo, CB_FINDSTRINGEXACT, (WPARAM)-1, (LPARAM)want);
	if (i == CB_ERR) return 0;
	SendMessageW(combo, CB_SETCURSEL, (WPARAM)i, 0);
	SendMessageW(GetParent(combo), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(combo), CBN_SELCHANGE), (LPARAM)combo);
	WCHAR now[256] = L"";
	SendMessageW(combo, CB_GETLBTEXT, (WPARAM)SendMessageW(combo, CB_GETCURSEL, 0, 0), (LPARAM)now);
	printf("selected [%ld] ", (long)i);
	out(now);
	printf("\n");
	return 1;
}

static BOOL CALLBACK child(HWND h, LPARAM mode) {
	WCHAR cls[64];
	if (!IsWindowVisible(h)) return TRUE;
	GetClassNameW(h, cls, 64);
	if (_wcsicmp(cls, L"ComboBox") != 0) return TRUE;
	if (mode == 0) dump(h);
	else if (!found && pick(h)) found = 1;
	return !found;
}

static BOOL CALLBACK top(HWND h, LPARAM mode) {
	if (IsWindowVisible(h)) EnumChildWindows(h, child, mode);
	return !found;
}

int main(int argc, char **argv) {
	if (argc >= 2 && strcmp(argv[1], "list") == 0) {
		EnumWindows(top, 0);
		if (!listed) printf("no visible combo box\n");
		return 0;
	}
	if (argc >= 3 && strcmp(argv[1], "select") == 0) {
		MultiByteToWideChar(CP_UTF8, 0, argv[2], -1, want, 256);
		EnumWindows(top, 1);
		if (!found) {
			printf("'%s' not in any visible combo box\n", argv[2]);
			return 2;
		}
		return 0;
	}
	fprintf(stderr, "usage: wincombo list | wincombo select TEXT\n");
	return 1;
}

/// \brief To create a basic Windows command line program.

#if defined(__MINGW32__)
#include <windows.h>
#else
#include <Windows.h>
#endif
#include <tchar.h>
#include <stdio.h>

#include "thoth-ipc/ipc.h"

int _tmain (int argc, TCHAR *argv[]) {
    _tprintf(_T("My Sample Client: Entry\n"));
    thoth::channel ipc_r{thoth::prefix{"Global\\"}, "service ipc r", thoth::receiver};
    thoth::channel ipc_w{thoth::prefix{"Global\\"}, "service ipc w", thoth::sender};
    while (1) {
        if (!ipc_r.reconnect(thoth::receiver)) {
            Sleep(1000);
            continue;
        }
        auto msg = ipc_r.recv();
        if (msg.empty()) {
            _tprintf(_T("My Sample Client: message recv error\n"));
            ipc_r.disconnect();
            continue;
        }
        printf("My Sample Client: message recv: [%s]\n", (char const *)msg.data());
        for (;;) {
            if (!ipc_w.reconnect(thoth::sender)) {
                Sleep(1000);
                continue;
            }
            if (ipc_w.send("Copy.")) {
                break;
            }
            _tprintf(_T("My Sample Client: message send error\n"));
            ipc_w.disconnect();
            Sleep(1000);
        }
        _tprintf(_T("My Sample Client: message send [Copy]\n"));
    }
    _tprintf(_T("My Sample Client: Exit\n"));
    return 0;
}

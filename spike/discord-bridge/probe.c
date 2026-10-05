/* Development smoke probe: imitates a game's Discord SDK, never contacts Discord itself. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int write_frame(HANDLE pipe, uint32_t op, const char *json) {
    uint32_t size = (uint32_t)strlen(json); unsigned char frame[2048];
    if (size > sizeof(frame) - 8) return 0;
    memcpy(frame, &op, 4); memcpy(frame + 4, &size, 4); memcpy(frame + 8, json, size);
    /* Fragment writes to exercise stream framing rather than relying on message boundaries. */
    for (uint32_t i = 0; i < size + 8; i++) {
        DWORD n;
        if (!WriteFile(pipe, frame + i, 1, &n, NULL) || n != 1) return 0;
    }
    return 1;
}
static int read_exact(HANDLE pipe, void *buffer, DWORD size) {
    char *p = buffer;
    while (size) {
        DWORD n;
        if (!ReadFile(pipe, p, size, &n, NULL) || !n) return 0;
        p += n; size -= n;
    }
    return 1;
}
static int read_frame(HANDLE pipe) {
    uint32_t header[2]; char json[4096];
    if (!read_exact(pipe, header, 8) || header[1] >= sizeof(json)) return 0;
    if (!read_exact(pipe, json, header[1])) return 0;
    json[header[1]] = 0;
    puts(json); fflush(stdout);
    return header[0] == 1;
}
int main(int argc, char **argv) {
    const char *slot = argc > 1 ? argv[1] : "0";
    char name[80]; snprintf(name, sizeof(name), "\\\\.\\pipe\\discord-ipc-%s", slot);
    HANDLE pipe = INVALID_HANDLE_VALUE;
    for (int i = 0; i < 100 && pipe == INVALID_HANDLE_VALUE; i++) {
        pipe = CreateFileA(name, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
        if (pipe == INVALID_HANDLE_VALUE) Sleep(50);
    }
    if (pipe == INVALID_HANDLE_VALUE) return 1;
    if (!write_frame(pipe, 0, "{\"v\":1,\"client_id\":\"356942674672091136\"}") || !read_frame(pipe)) return 2;
    if (!write_frame(pipe, 1, "{\"cmd\":\"SET_ACTIVITY\",\"nonce\":\"wine-probe\",\"args\":{\"pid\":999,\"activity\":{\"state\":\"A level\",\"secrets\":{\"join\":\"kept\"}}}}") || !read_frame(pipe)) return 3;
    CloseHandle(pipe);
    return 0;
}

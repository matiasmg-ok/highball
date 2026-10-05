/* Wine-side Discord IPC bridge. Ordinary Win32 named pipes + Winsock work with both
 * Intel Wine and the native arm64 Wine loader; no host syscalls or injected DLLs. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static char token[37], prefix[4097];
static unsigned short port;
static HANDLE ready[10];

static int send_all(SOCKET s, const void *data, int count) {
    const char *p = data;
    while (count > 0) {
        int n = send(s, p, count, 0);
        if (n <= 0) return 0;
        p += n; count -= n;
    }
    return 1;
}
static SOCKET connect_host(unsigned char index) {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return s;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    if (connect(s, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        !send_all(s, token, 36) || !send_all(s, &index, 1)) {
        closesocket(s); return INVALID_SOCKET;
    }
    return s;
}
struct client { HANDLE pipe; HANDLE request_thread; SOCKET socket; };
static DWORD WINAPI replies(void *arg) {
    struct client *client = arg;
    char buffer[16384]; int n;
    while ((n = recv(client->socket, buffer, sizeof(buffer), 0)) > 0) {
        int offset = 0;
        while (offset < n) {
            DWORD written;
            if (!WriteFile(client->pipe, buffer + offset, (DWORD)(n - offset), &written, NULL) || !written) goto done;
            offset += (int)written;
        }
    }
done:
    shutdown(client->socket, SD_BOTH);
    /* Cancel the blocking pipe read of the opposite direction. */
    CancelSynchronousIo(client->request_thread);
    return 0;
}
static DWORD WINAPI connection(void *arg) {
    struct client *client = arg;
    DuplicateHandle(GetCurrentProcess(), GetCurrentThread(), GetCurrentProcess(),
        &client->request_thread, 0, FALSE, DUPLICATE_SAME_ACCESS);
    HANDLE reader = CreateThread(NULL, 0, replies, client, 0, NULL);
    if (reader) {
        char buffer[16384]; DWORD n;
        while (ReadFile(client->pipe, buffer, sizeof(buffer), &n, NULL) && n > 0)
            if (!send_all(client->socket, buffer, (int)n)) break;
        shutdown(client->socket, SD_BOTH);
        CancelSynchronousIo(reader);
        WaitForSingleObject(reader, INFINITE);
        CloseHandle(reader);
    }
    if (client->request_thread) CloseHandle(client->request_thread);
    DisconnectNamedPipe(client->pipe);
    CloseHandle(client->pipe);
    closesocket(client->socket);
    free(client);
    return 0;
}
static DWORD WINAPI pipe_server(void *arg) {
    unsigned int index = (unsigned int)(uintptr_t)arg;
    char name[64];
    snprintf(name, sizeof(name), "\\\\.\\pipe\\discord-ipc-%u", index);
    int first = 1;
    for (;;) {
        HANDLE pipe = CreateNamedPipeA(name, PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, NULL);
        if (pipe == INVALID_HANDLE_VALUE) { if (first) SetEvent(ready[index]); return 0; }
        if (first) { SetEvent(ready[index]); first = 0; }
        if (!ConnectNamedPipe(pipe, NULL) && GetLastError() != ERROR_PIPE_CONNECTED) { CloseHandle(pipe); continue; }
        SOCKET s = connect_host((unsigned char)index);
        if (s == INVALID_SOCKET) { DisconnectNamedPipe(pipe); CloseHandle(pipe); Sleep(250); continue; }
        struct client *client = calloc(1, sizeof(*client));
        if (!client) { DisconnectNamedPipe(pipe); CloseHandle(pipe); closesocket(s); continue; }
        client->pipe = pipe; client->socket = s;
        HANDLE thread = CreateThread(NULL, 0, connection, client, 0, NULL);
        if (thread) CloseHandle(thread);
        else { DisconnectNamedPipe(pipe); CloseHandle(pipe); closesocket(s); free(client); }
    }
}
int main(void) {
    char port_string[8];
    if (GetEnvironmentVariableA("HIGHBALL_DISCORD_TOKEN", token, sizeof(token)) != 36 ||
        !GetEnvironmentVariableA("HIGHBALL_DISCORD_PORT", port_string, sizeof(port_string)) ||
        !GetEnvironmentVariableA("HIGHBALL_DISCORD_PREFIX", prefix, sizeof(prefix))) return 1;
    port = (unsigned short)atoi(port_string);
    if (!port) return 1;
    HANDLE mutex = CreateMutexA(NULL, TRUE, "Local\\HighballDiscordBridge");
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return 1;
    /* Control connection is also a host-lifetime watchdog. */
    SOCKET control = connect_host(255);
    if (control == INVALID_SOCKET) return 1;
    for (unsigned int i = 0; i < 10; i++) {
        ready[i] = CreateEventA(NULL, TRUE, FALSE, NULL);
        if (!ready[i]) return 1;
        HANDLE thread = CreateThread(NULL, 0, pipe_server, (void *)(uintptr_t)i, 0, NULL);
        if (!thread) return 1;
        CloseHandle(thread);
    }
    WaitForMultipleObjects(10, ready, TRUE, INFINITE);
    uint16_t length = (uint16_t)strlen(prefix);
    if (!send_all(control, &length, 2) || !send_all(control, prefix, length)) return 1;
    for (unsigned int i = 0; i < 10; i++) CloseHandle(ready[i]);
    char byte;
    recv(control, &byte, 1, 0);  /* host gone: process exit releases all named pipes */
    return 0;
}

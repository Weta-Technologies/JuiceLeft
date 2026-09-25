// juiceleft-led — sets the MagSafe charging light. The only binary JuiceLeft's root helper ever runs.
//   juiceleft-led <v> [<v>]   v ∈ {0 1 3 4 5 6 7}; a second value is written 300 ms after the first
//                             (the colour macOS expects, then 0 to hand the light back — 0 alone leaves the last colour latched)
//   juiceleft-led read        prints the current value (no root needed)
// The light is the SMC key ACLC: 0 = macOS decides, 1 = off, 3 = green, 4 = orange, 5 = flash, 6 = slow orange
// blink, 7 = fast orange blink — all driven by the hardware, so holding one costs nothing. Nothing else is touched.
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { KERNEL_INDEX_SMC = 2, CMD_READ = 5, CMD_WRITE = 6, CMD_KEYINFO = 9 };
typedef struct { char major, minor, build, reserved[1]; UInt16 release; } Vers;
typedef struct { UInt16 version, length; UInt32 cpu, gpu, mem; } PLimit;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } KeyInfo;
typedef struct { UInt32 key; Vers vers; PLimit pLimit; KeyInfo keyInfo; char result, status, data8; UInt32 data32; unsigned char bytes[32]; } SMCData;

static io_connect_t conn;
static const UInt32 ACLC = ('A' << 24) | ('C' << 16) | ('L' << 8) | 'C';

static kern_return_t call(SMCData *in, SMCData *out) {
    size_t size = sizeof(SMCData);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCData), out, &size);
}

static int keyinfo(KeyInfo *info) {
    SMCData in = {0}, out = {0};
    in.key = ACLC; in.data8 = CMD_KEYINFO;
    if (call(&in, &out) != kIOReturnSuccess || out.result != 0) return -1;
    *info = out.keyInfo; return 0;
}

static int readLight(void) {
    KeyInfo info; if (keyinfo(&info)) return -1;
    SMCData in = {0}, out = {0};
    in.key = ACLC; in.keyInfo.dataSize = info.dataSize; in.data8 = CMD_READ;
    if (call(&in, &out) != kIOReturnSuccess || out.result != 0) return -1;
    return out.bytes[0];
}

static int writeLight(unsigned char v) {
    KeyInfo info; if (keyinfo(&info)) return -1;
    SMCData in = {0}, out = {0};
    in.key = ACLC; in.keyInfo.dataSize = info.dataSize; in.data8 = CMD_WRITE; in.bytes[0] = v;
    return (call(&in, &out) == kIOReturnSuccess && out.result == 0) ? 0 : -1;
}

/// Exactly one of the allowed single digits, nothing else.
static int allowed(const char *s, unsigned char *v) {
    if (strlen(s) != 1 || strchr("0134567", s[0]) == NULL) return 0;
    *v = (unsigned char)(s[0] - '0');
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) { fprintf(stderr, "usage: juiceleft-led read | <0|1|3|4|5|6|7> [<0|1|3|4|5|6|7>]\n"); return 64; }
    unsigned char values[2] = {0, 0};
    int reading = strcmp(argv[1], "read") == 0;
    if (!reading) {
        for (int i = 1; i < argc; i++) {
            if (!allowed(argv[i], &values[i - 1])) { fprintf(stderr, "juiceleft-led: '%s' is not an allowed value\n", argv[i]); return 64; }
        }
    } else if (argc != 2) { fprintf(stderr, "usage: juiceleft-led read\n"); return 64; }
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &conn) != kIOReturnSuccess) { fprintf(stderr, "juiceleft-led: cannot open AppleSMC\n"); return 1; }
    if (reading) {
        int v = readLight();
        if (v < 0) { printf("absent\n"); return 2; }
        printf("%d\n", v); return 0;
    }
    for (int i = 0; i < argc - 1; i++) {
        if (i > 0) usleep(300000);
        if (writeLight(values[i])) { fprintf(stderr, "juiceleft-led: write of %d failed\n", values[i]); return 1; }
    }
    return 0;
}

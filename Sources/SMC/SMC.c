#include "SMC.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { char major, minor, build, reserved; UInt16 release; } SMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { UInt32 dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    UInt32 key;
    SMCVersion version;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    char result, status, data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCKeyData;

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyInfo = 9 };

static io_connect_t connection = IO_OBJECT_NULL;

static UInt32 fourcc(const char *s) {
    return ((UInt32)s[0] << 24) | ((UInt32)s[1] << 16) | ((UInt32)s[2] << 8) | (UInt32)s[3];
}

static bool call(SMCKeyData *input, SMCKeyData *output) {
    size_t outputSize = sizeof(SMCKeyData);
    kern_return_t result = IOConnectCallStructMethod(connection, kSMCHandleYPCEvent,
                                                     input, sizeof(SMCKeyData), output, &outputSize);
    return result == KERN_SUCCESS && output->result == 0;
}

bool smc_open(void) {
    if (connection != IO_OBJECT_NULL) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return false;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

void smc_close(void) {
    if (connection == IO_OBJECT_NULL) return;
    IOServiceClose(connection);
    connection = IO_OBJECT_NULL;
}

bool smc_read_float(const char *key, float *value) {
    if (connection == IO_OBJECT_NULL || strlen(key) != 4) return false;

    SMCKeyData input = {0}, output = {0};
    input.key = fourcc(key);
    input.data8 = kSMCGetKeyInfo;
    if (!call(&input, &output)) return false;
    if (output.keyInfo.dataType != fourcc("flt ") || output.keyInfo.dataSize != sizeof(float)) return false;

    SMCKeyInfo info = output.keyInfo;
    memset(&input, 0, sizeof input);
    memset(&output, 0, sizeof output);
    input.key = fourcc(key);
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = kSMCReadKey;
    if (!call(&input, &output)) return false;

    memcpy(value, output.bytes, sizeof(float));
    return true;
}

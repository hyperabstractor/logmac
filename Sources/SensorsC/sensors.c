#include "sensors.h"

#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <stdio.h>
#include <string.h>

// Private IOHIDFamily API used to read Apple Silicon thermal sensors.
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kTemperatureField (kIOHIDEventTypeTemperature << 16)

static IOHIDEventSystemClientRef client;
static CFArrayRef services;

static void setup(void) {
    if (client) return;
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return;

    int page = 0xff00, usage = 5; // AppleVendor / TemperatureSensor
    CFNumberRef pageNum = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {pageNum, usageNum};
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(pageNum);
    CFRelease(usageNum);

    services = IOHIDEventSystemClientCopyServices(client);
}

static int product_name(IOHIDServiceClientRef service, char *buf, size_t len) {
    CFStringRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
    if (!name) return 0;
    int ok = CFGetTypeID(name) == CFStringGetTypeID() && CFStringGetCString(name, buf, len, kCFStringEncodingUTF8);
    CFRelease(name);
    for (char *c = buf; ok && *c; c++) *c = (char)tolower(*c);
    return ok;
}

static int read_temp(IOHIDServiceClientRef service, double *out) {
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
    if (!event) return 0;
    *out = IOHIDEventGetFloatValue(event, kTemperatureField);
    CFRelease(event);
    return *out > 0 && *out < 130;
}

SensorsTemps sensors_read_temperatures(void) {
    SensorsTemps result = {-1, -1, -1, 0};
    setup();
    if (!services) return result;

    double cpuSum = 0, gpuSum = 0;
    int cpuCount = 0, gpuCount = 0;
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        char name[128];
        double temp;
        if (!product_name(service, name, sizeof name) || !read_temp(service, &temp)) continue;
        result.count++;

        if (strstr(name, "battery") || strstr(name, "gas gauge") || strstr(name, "nand") || strstr(name, "tcal"))
            continue;
        if (temp > result.hottest) result.hottest = temp;

        if (strstr(name, "tdie") || strstr(name, "pacc") || strstr(name, "eacc")) {
            cpuSum += temp;
            cpuCount++;
        } else if (strstr(name, "gpu")) {
            gpuSum += temp;
            gpuCount++;
        }
    }
    if (cpuCount) result.cpu = cpuSum / cpuCount;
    if (gpuCount) result.gpu = gpuSum / gpuCount;
    return result;
}

void sensors_dump(void) {
    setup();
    if (!services) {
        printf("no HID temperature services\n");
        return;
    }
    CFIndex n = CFArrayGetCount(services);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        char name[128] = "?";
        double temp = -1;
        product_name(service, name, sizeof name);
        read_temp(service, &temp);
        printf("%-32s %6.1f\n", name, temp);
    }
}

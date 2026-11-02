//
//  SMCTemperature.m
//  MacCheck
//
//  Created by Ramzayev Hermann on 02.11.2026.
//

#import "SMCTemperature.h"
#import <IOKit/IOKitLib.h>
#import <string.h>
#import <stdint.h>

#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    uint32_t dataSize;
    char     dataType[4];
    uint8_t  bytes[32];
} SMCVal_t;

typedef struct {
    uint32_t key;
    uint32_t vers;
    uint32_t pLimit;
    uint32_t data1;
    uint32_t data2;
    uint8_t  status;
    SMCVal_t bytes;
} SMCParamStruct;

static uint32_t SMCPackKey(NSString *k) {
    const char *s = k.UTF8String;
    uint32_t v = 0;
    for (int i = 0; i < 4 && s[i]; i++) v = (v << 8) | (uint8_t)s[i];
    return v;
}

static double NormalizeTempLocal(double raw) {
    if (raw <= 0) return -1;
    if (raw > 1000) return raw / 100.0;
    if (raw > 200)  return raw / 10.0;
    return raw;
}

static double NumberFromObjectLocal(id v) {
    if (!v) return -1;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSScanner *sc = [NSScanner scannerWithString:v];
        double d = 0;
        if ([sc scanDouble:&d]) return d;
    }
    return -1;
}

static BOOL SMCParseValue(const SMCVal_t *val, double *outTemp) {
    char type[5] = {0};
    memcpy(type, val->dataType, 4);
    const uint8_t *b = val->bytes;

    if (strcmp(type, "sp78") == 0) {
        int16_t raw = (int16_t)((b[0] << 8) | b[1]);
        *outTemp = raw / 256.0;
        return YES;
    }
    if (strcmp(type, "fpe2") == 0) {
        int16_t raw = (int16_t)((b[0] << 8) | b[1]);
        *outTemp = raw / 4.0;
        return YES;
    }
    if (strcmp(type, "flt ") == 0) {
        uint32_t be = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                      ((uint32_t)b[2] << 8)  |  (uint32_t)b[3];
        float f;
        memcpy(&f, &be, 4);
        *outTemp = f;
        return YES;
    }
    if (strcmp(type, "ui8 ") == 0) { *outTemp = b[0]; return YES; }
    if (strcmp(type, "si8 ") == 0) { *outTemp = (int8_t)b[0]; return YES; }
    if (strcmp(type, "ui16") == 0) { *outTemp = (b[0] << 8) | b[1]; return YES; }
    if (strcmp(type, "si16") == 0) { *outTemp = (int16_t)((b[0] << 8) | b[1]); return YES; }

    return NO;
}

static BOOL SMCReadKey(io_connect_t conn, NSString *keyName, double *outTemp) {
    SMCParamStruct in = {0}, out = {0};
    size_t outSize = sizeof(out);

    in.key = SMCPackKey(keyName);

    kern_return_t kr = IOConnectCallMethod(conn, SMC_CMD_READ_KEYINFO,
                                           NULL, 0,
                                           &in, sizeof(in),
                                           NULL, NULL,
                                           &out, &outSize);
    if (kr != KERN_SUCCESS) return NO;

    uint32_t dataSize = out.bytes.dataSize;
    char dataType[4];
    memcpy(dataType, out.bytes.dataType, 4);

    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    outSize = sizeof(out);

    in.key = SMCPackKey(keyName);
    in.bytes.dataSize = dataSize;
    memcpy(in.bytes.dataType, dataType, 4);

    kr = IOConnectCallMethod(conn, SMC_CMD_READ_BYTES,
                             NULL, 0,
                             &in, sizeof(in),
                             NULL, NULL,
                             &out, &outSize);
    if (kr != KERN_SUCCESS) return NO;

    double v = 0;
    if (!SMCParseValue(&out.bytes, &v)) return NO;

    *outTemp = v;
    return YES;
}

NSArray<NSDictionary *> *SMCReadTemperatures(void) {
    NSMutableArray *result = [NSMutableArray array];

    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("AppleSMC"));
    if (svc) {
        io_connect_t conn = 0;
        if (IOServiceOpen(svc, mach_task_self(), 0, &conn) == KERN_SUCCESS) {
            NSDictionary *names = @{
                @"TC0P": @"CPU 0 (proximity)",
                @"TC0D": @"CPU 0 (die)",
                @"TC0E": @"CPU 0 (filter)",
                @"TC0F": @"CPU 0 (mirror)",
                @"TC1C": @"CPU 1 (core)",
                @"TC2C": @"CPU 2 (core)",
                @"TC3C": @"CPU 3 (core)",
                @"TCXC": @"CPU X (core)",
                @"TCSC": @"CPU package",
                @"TCAH": @"CPU ambient high",
                @"TCAD": @"CPU die alt",
                @"TCHP": @"CPU hot point",
                @"TC0H": @"CPU 0 hot",
                @"TC1H": @"CPU 1 hot",
                @"TC2H": @"CPU 2 hot",
                @"TC3H": @"CPU 3 hot",
                @"TG0P": @"GPU (proximity)",
                @"TG0D": @"GPU (die)",
                @"TG0F": @"GPU (filter)",
                @"TGTD": @"GPU (thermal)",
                @"TB0T": @"Battery 0",
                @"TB1T": @"Battery 1",
                @"TB2T": @"Battery 2",
                @"TA1P": @"Ambient / exposed",
                @"TA2P": @"Ambient 2",
                @"TM0P": @"Memory 0",
                @"TM1P": @"Memory 1",
                @"TM2P": @"Memory 2",
                @"TN0D": @"Northbridge (die)",
                @"TN0P": @"Northbridge (prox)",
                @"Th0H": @"Heatpipe 0",
                @"Th1H": @"Heatpipe 1",
                @"Tp0C": @"Power supply",
                @"Tp1C": @"Power supply 1",
                @"Tp2C": @"Power supply 2",
                @"TS0C": @"Thunderbolt ctrl"
            };

            for (NSString *key in names) {
                double t = 0;
                if (SMCReadKey(conn, key, &t)) {
                    double norm = NormalizeTempLocal(t);
                    if (norm > 0 && norm < 130) {
                        [result addObject:@{ @"name": names[key], @"key": key, @"value": @(norm) }];
                    }
                }
            }

            IOServiceClose(conn);
        }
        IOObjectRelease(svc);
    }

    // Fallback / дополнение: температура батареи из AppleSmartBattery.
    io_service_t bat = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("AppleSmartBattery"));
    if (bat) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(bat, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            id t = (__bridge id)CFDictionaryGetValue(props, CFSTR("Temperature"));
            double raw = NumberFromObjectLocal(t);
            double norm = NormalizeTempLocal(raw);
            if (norm > 0) {
                [result addObject:@{ @"name": @"Battery (IOKit)", @"key": @"BAT", @"value": @(norm) }];
            }
            CFRelease(props);
        }
        IOObjectRelease(bat);
    }

    return result;
}

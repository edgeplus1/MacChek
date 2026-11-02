//
//  SystemInfo.m
//  MacCheck
//
//  Created by Ramzayev Hermann on 02.11.2026.
//

#import "SystemInfo.h"
#import "SMCTemperature.h"
#import "Compat.h"
#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <math.h>

#pragma mark - Запуск CLI и парсинг

static NSString *RunTask(NSString *path, NSArray<NSString *> *args) {
    @try {
        NSTask *t = [[NSTask alloc] init];
        if (@available(macOS 10.13, *)) {
            t.executableURL = [NSURL fileURLWithPath:path];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
            [t performSelector:@selector(setExecutablePath:) withObject:path];
#pragma clang diagnostic pop
        }
        t.arguments = args;
        NSPipe *pipe = [NSPipe pipe];
        t.standardOutput = pipe;
        t.standardError  = [NSPipe pipe];
        [t launch];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    } @catch (NSException *e) {
        NSLog(@"💥 RunTask(%@) упал: %@ — %@", path, e.name, e.reason);
        return nil;
    }
}

static NSDictionary *Profiler(NSString *type) {
    NSString *out = RunTask(@"/usr/sbin/system_profiler", @[type, @"-json"]);
    if (!out.length) return nil;
    NSError *e = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:[out dataUsingEncoding:NSUTF8StringEncoding]
                                             options:0 error:&e];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static id DeepFind(id node, NSString *needle) {
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in (NSDictionary *)node) {
            if ([k rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
                return [(NSDictionary *)node objectForKey:k];
        }
        for (id v in [(NSDictionary *)node allValues]) {
            id r = DeepFind(v, needle); if (r) return r;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)node) { id r = DeepFind(v, needle); if (r) return r; }
    }
    return nil;
}

static id DeepFindAny(id node, NSArray<NSString *> *needles) {
    for (NSString *n in needles) { id r = DeepFind(node, n); if (r) return r; }
    return nil;
}

static NSString *Str(id v) {
    if (!v) return @"—";
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return [v description];
}

static double NumberFromObject(id v) {
    if (!v) return -1;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSScanner *sc = [NSScanner scannerWithString:v];
        double d = 0;
        if ([sc scanDouble:&d]) return d;
    }
    return -1;
}

static double NormalizeTemp(double raw) {
    if (raw <= 0) return -1;
    if (raw > 1000) return raw / 100.0;
    if (raw > 200)  return raw / 10.0;
    return raw;
}

static NSDictionary *BatteryRegistry(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                   IOServiceMatching("AppleSmartBattery"));
    if (!svc) return nil;

    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0);
    IOObjectRelease(svc);

    if (kr != KERN_SUCCESS || !props) return nil;
    return CFBridgingRelease(props);
}

static NSString *CapacityString(double v) {
    if (v <= 0) return @"—";
    NSString *unit = (v >= 10000.0) ? @"mWh" : @"mAh";
    return [NSString stringWithFormat:@"%.0f %@", v, unit];
}

#pragma mark - Форматирование отчёта

static NSMutableAttributedString *NewDoc(void) { return [[NSMutableAttributedString alloc] init]; }

static void AddHeader(NSMutableAttributedString *m, NSString *title) {
    NSDictionary *a = @{ NSFontAttributeName: CFont(13, YES),
                         NSForegroundColorAttributeName: [NSColor secondaryLabelColor] };
    NSString *line = [NSString stringWithFormat:@"\n%@\n", [title uppercaseString]];
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:a]];
}

static void AddKV(NSMutableAttributedString *m, NSString *k, NSString *v) {
    NSString *kk = [k stringByPaddingToLength:26 withString:@" " startingAtIndex:0];
    NSFont *mono = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont userFixedPitchFontOfSize:11];
    NSDictionary *ak = @{ NSFontAttributeName: mono, NSForegroundColorAttributeName: [NSColor secondaryLabelColor] };
    NSDictionary *av = @{ NSFontAttributeName: mono, NSForegroundColorAttributeName: [NSColor labelColor] };
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:kk attributes:ak]];
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:[v stringByAppendingString:@"\n"] attributes:av]];
}

static void AddRaw(NSMutableAttributedString *m, NSString *s, NSColor *color, CGFloat size, BOOL bold) {
    NSDictionary *a = @{ NSFontAttributeName: CFont(size, bold), NSForegroundColorAttributeName: color };
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:a]];
}

static void WalkStats(NSMutableAttributedString *m, id node, int depth) {
    NSString *pad = [@"" stringByPaddingToLength:depth*2 withString:@" " startingAtIndex:0];
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = node;
        NSSet *critical = [NSSet setWithArray:@[@"Reallocated", @"Pending", @"Uncorrectable",
                                                @"CRC", @"Wear", @"Media Wearout", @"Read Error",
                                                @"Seek Error", @"Offline"]];
        for (NSString *k in [[d.allKeys sortedArrayUsingSelector:@selector(compare:)] reverseObjectEnumerator]) {
            id v = d[k];
            BOOL isCrit = NO;
            for (NSString *c in critical) if ([k rangeOfString:c].location != NSNotFound) { isCrit = YES; break; }
            if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
                AddRaw(m, [NSString stringWithFormat:@"%@%@\n", pad, k], [NSColor secondaryLabelColor], 11, YES);
                WalkStats(m, v, depth+1);
            } else {
                NSColor *col = isCrit ? CCOrange() : [NSColor labelColor];
                AddRaw(m, [NSString stringWithFormat:@"%@%@: ", pad, k], col, 11, isCrit);
                AddRaw(m, [Str(v) stringByAppendingString:@"\n"], col, 11, NO);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) WalkStats(m, v, depth);
    }
}

#pragma mark - Реализация

@implementation SystemInfo

+ (NSAttributedString *)overviewReport {
    NSMutableAttributedString *m = NewDoc();

    NSDictionary *batReg = BatteryRegistry();
    NSDictionary *pw = Profiler(@"SPPowerDataType");

    double cycleD = NumberFromObject(batReg[@"CycleCount"]);
    if (cycleD <= 0) cycleD = NumberFromObject(DeepFindAny(pw, @[@"cycle_count", @"Cycle Count"]));

    double maxD = NumberFromObject(batReg[@"MaxCapacity"]);
    if (maxD <= 0) maxD = NumberFromObject(DeepFindAny(pw, @[@"maximum_capacity", @"Maximum Capacity", @"max_capacity"]));

    double designD = NumberFromObject(batReg[@"DesignCapacity"]);
    if (designD <= 0) designD = NumberFromObject(DeepFindAny(pw, @[@"nominal_charge_capacity", @"Nominal Charge Capacity", @"nominal_capacity"]));

    NSString *cond = nil;
    id rc = batReg[@"BatteryState"] ?: batReg[@"Condition"];
    if ([rc isKindOfClass:[NSString class]] && [(NSString *)rc length]) cond = rc;

    if (!cond.length) {
        NSString *pc = Str(DeepFindAny(pw, @[@"condition", @"Condition"]));
        if (![pc isEqualToString:@"—"]) cond = pc;
    }

    NSInteger health = -1;
    if (maxD > 0 && designD > 0) health = (NSInteger)round(maxD / designD * 100.0);

    if (!cond.length) {
        cond = (health < 0) ? @"—" : ((health < 80) ? @"Service Recommended" : @"Normal");
    }

    NSNumber *cycles = (cycleD > 0) ? @((long long)cycleD) : nil;

    NSDictionary *sto = Profiler(@"SPStorageDataType");
    NSString *smart = Str(DeepFindAny(sto, @[@"smart_status", @"SMART Status"]));

    NSString *fv  = RunTask(@"/usr/bin/fdesetup", @[@"status"]) ?: @"";
    NSString *sip = RunTask(@"/usr/bin/csrutil",  @[@"status"]) ?: @"";
    NSString *gk  = RunTask(@"/usr/sbin/spctl",   @[@"--status"]) ?: @"";
    NSString *mmm = RunTask(@"/usr/bin/defaults", @[@"read", @"MobileMeAccounts"]) ?: @"";
    BOOL icloudBound = Has(mmm, @"AccountID");

    BOOL mdm = NO, dep = NO;
    NSString *prof = RunTask(@"/usr/bin/profiles", @[@"status", @"-type", @"enrollment"]);
    if (prof.length) { mdm = Has(prof, @"MDM enrollment: Yes"); dep = Has(prof, @"Enrolled via DEP: Yes"); }

    AddHeader(m, @"ИТОГОВАЯ ОЦЕНКА");

    void (^badge)(NSString *, NSInteger, NSString *) = ^(NSString *title, NSInteger level, NSString *detail){
        NSColor *c = (level == 0) ? CCGreen() : ((level == 1) ? CCOrange() : CCRed());
        NSString *dot = (level == 0) ? @"●  " : ((level == 1) ? @"◐  " : @"▲  ");
        AddRaw(m, dot, c, 15, YES);
        AddRaw(m, [NSString stringWithFormat:@"%@  ", title], [NSColor labelColor], 15, YES);
        AddRaw(m, [detail stringByAppendingString:@"\n"], (level == 2) ? CCRed() : [NSColor secondaryLabelColor], 12, NO);
    };

    badge(@"Батарея", ((health < 0 || health >= 80) && !Has(cond, @"Service")) ? 0 : 2,
          [NSString stringWithFormat:@"износ %@%%, циклы %@, состояние %@",
           health < 0 ? @"?" : [@((long)(100 - health)) stringValue], Str(cycles), cond]);

    badge(@"Диск (SMART)", [[smart lowercaseString] rangeOfString:@"verified"].location != NSNotFound ? 0 : 2,
          [NSString stringWithFormat:@"статус: %@", smart]);

    badge(@"FileVault", 0, [fv stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    badge(@"SIP (защита системы)", Has(sip, @"enabled") ? 0 : 2,
          [sip stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    badge(@"Gatekeeper", Has(gk, @"assessment") ? 0 : 1,
          [gk stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);

    if (icloudBound) {
        badge(@"iCloud / Activation Lock", 1,
              @"Найден Apple ID текущего пользователя. На своём маке для отладки — это ТВОЙ аккаунт (не блокер). "
              @"Истинный Activation Lock (чужой) проверяется ТОЛЬКО загрузкой в Recovery (Cmd+R): попросит Apple ID — не покупай.");
    } else {
        badge(@"iCloud / Activation Lock", 0, @"не привязан (всё равно проверь при загрузке в Recovery)");
    }

    if (mdm) {
        badge(@"MDM (корпоративное управление)", 2,
              [NSString stringWithFormat:@"Зарегистрирован в MDM%@. Mac под удалённым контролем — НЕ ПОКУПАЙ без снятия продавцом.",
               dep ? @" и DEP" : @""]);
    } else {
        badge(@"MDM (корпоративное управление)", 0,
              [NSString stringWithFormat:@"чисто (DEP: %@, MDM: No)", dep ? @"Yes" : @"No"]);
    }

    AddRaw(m, @"\nСовет: обязательно загрузи Mac в Recovery (Cmd+R) и убедись, что он НЕ просит пароль прошивки и Apple ID продавца.\n",
           [NSColor tertiaryLabelColor], 11, NO);
    AddRaw(m, @"Для проверки пароля прошивки (firmware) и температур powermetrics нажми «🔓 Расширенно (sudo)».\n",
           [NSColor tertiaryLabelColor], 11, NO);
    return m;
}

+ (NSAttributedString *)hardwareReport {
    NSMutableAttributedString *m = NewDoc();
    NSDictionary *hw = Profiler(@"SPHardwareDataType");
    AddHeader(m, @"Оборудование");
    AddKV(m, @"Модель",           Str(DeepFindAny(hw, @[@"machine_name", @"Model Name"])));
    AddKV(m, @"Model Identifier", Str(DeepFindAny(hw, @[@"machine_model", @"Model Identifier"])));
    AddKV(m, @"Серийный номер",   Str(DeepFindAny(hw, @[@"serial_number", @"Serial Number (system)"])));
    AddKV(m, @"Процессор",        Str(DeepFindAny(hw, @[@"cpu_type", @"Processor Name"])));
    AddKV(m, @"Ядер / потоков",   [NSString stringWithFormat:@"%@ / %@",
                                   Str(DeepFindAny(hw, @[@"number_processors", @"Processor Cores"])),
                                   Str(DeepFindAny(hw, @[@"total_number_of_threads", @"Logical Processor Count"]))]);
    AddKV(m, @"Память (RAM)",     Str(DeepFindAny(hw, @[@"physical_memory", @"Memory"])));
    AddKV(m, @"Boot ROM",         Str(DeepFindAny(hw, @[@"boot_rom_version", @"Boot ROM Version"])));
    AddKV(m, @"SMC (system)",     Str(DeepFindAny(hw, @[@"smc_version", @"SMC Version (system)"])));
    AddKV(m, @"Platform UUID",    Str(DeepFindAny(hw, @[@"platform_uuid", @"Provisioning UDID"])));
    AddKV(m, @"Hardware UUID",    Str(DeepFindAny(hw, @[@"hardware_uuid", @"Hardware UUID"])));
    AddRaw(m, @"\nСверь серийник на дне корпуса с тем, что выше — они должны совпадать.\n",
           [NSColor tertiaryLabelColor], 11, NO);
    return m;
}

+ (NSAttributedString *)batteryReport {
    NSMutableAttributedString *m = NewDoc();

    NSDictionary *batReg = BatteryRegistry();
    NSDictionary *pw = Profiler(@"SPPowerDataType");

    double cycleD = NumberFromObject(batReg[@"CycleCount"]);
    if (cycleD <= 0) cycleD = NumberFromObject(DeepFindAny(pw, @[@"cycle_count", @"Cycle Count"]));

    double maxD = NumberFromObject(batReg[@"MaxCapacity"]);
    if (maxD <= 0) maxD = NumberFromObject(DeepFindAny(pw, @[@"maximum_capacity", @"Maximum Capacity", @"max_capacity"]));

    double designD = NumberFromObject(batReg[@"DesignCapacity"]);
    if (designD <= 0) designD = NumberFromObject(DeepFindAny(pw, @[@"nominal_charge_capacity", @"Nominal Charge Capacity", @"nominal_capacity"]));

    double tempD = NumberFromObject(batReg[@"Temperature"]);
    if (tempD <= 0) tempD = NumberFromObject(DeepFindAny(pw, @[@"temperature", @"Temperature"]));
    double tempC = NormalizeTemp(tempD);

    NSString *cond = nil;
    id rc = batReg[@"BatteryState"] ?: batReg[@"Condition"];
    if ([rc isKindOfClass:[NSString class]] && [(NSString *)rc length]) cond = rc;
    if (!cond.length) {
        NSString *pc = Str(DeepFindAny(pw, @[@"condition", @"Condition"]));
        if (![pc isEqualToString:@"—"]) cond = pc;
    }

    NSInteger health = -1;
    if (maxD > 0 && designD > 0) health = (NSInteger)round(maxD / designD * 100.0);
    if (!cond.length) cond = (health < 0) ? @"—" : ((health < 80) ? @"Service Recommended" : @"Normal");

    NSString *charged  = Str(DeepFindAny(pw, @[@"fully_charged", @"Fully Charged"]));
    NSString *charging = Str(DeepFindAny(pw, @[@"is_charging", @"Is Charging"]));

    AddHeader(m, @"Аккумулятор");
    AddKV(m, @"Циклов заряда",     cycleD > 0 ? [NSString stringWithFormat:@"%.0f", cycleD] : @"—");
    AddKV(m, @"Макс. ёмкость",     CapacityString(maxD));
    AddKV(m, @"Проектная ёмкость", CapacityString(designD));
    AddKV(m, @"Состояние (health)", health < 0 ? @"—" : [NSString stringWithFormat:@"%ld%%", (long)health]);
    AddKV(m, @"Статус",            cond);
    AddKV(m, @"Температура",       tempC < 0 ? @"—" : [NSString stringWithFormat:@"%.1f °C", tempC]);
    AddKV(m, @"Заряжен полностью",  charged);
    AddKV(m, @"Заряжается",        charging);

    NSColor *hc = (health >= 80) ? CCGreen() : (health >= 0 ? CCOrange() : [NSColor labelColor]);
    AddRaw(m, [NSString stringWithFormat:@"\nИзнос: %@%%  (до 80%% — норма, ниже — батарея под замену)\n",
               health < 0 ? @"?" : [@((long)(100 - health)) stringValue]], hc, 12, YES);
    return m;
}

+ (NSAttributedString *)diskReport {
    NSMutableAttributedString *m = NewDoc();
    NSDictionary *sto = Profiler(@"SPStorageDataType");
    AddHeader(m, @"Накопитель (system_profiler)");
    AddKV(m, @"SMART-статус",    Str(DeepFindAny(sto, @[@"smart_status", @"SMART Status"])));
    AddKV(m, @"Тип / интерфейс", [NSString stringWithFormat:@"%@ / %@",
                                  Str(DeepFindAny(sto, @[@"medium_type", @"Solid State", @"Medium Type", @"Device Location"])),
                                  Str(DeepFindAny(sto, @[@"protocol", @"Interface Type"]))]);
    AddKV(m, @"Объём",           Str(DeepFindAny(sto, @[@"size", @"Capacity"])));
    AddKV(m, @"Свободно",        Str(DeepFindAny(sto, @[@"free_space", @"Free Space"])));
    AddKV(m, @"Имя носителя",    Str(DeepFindAny(sto, @[@"media_name", @"Device Name"])));

    AddHeader(m, @"SMART / статистика контроллера (IORegistry)");
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS) {
        io_object_t e;
        while ((e = IOIteratorNext(it))) {
            CFDictionaryRef stats = IORegistryEntryCreateCFProperty(e, CFSTR("Device Statistics"),
                                                                    kCFAllocatorDefault, 0);
            if (stats) { WalkStats(m, (__bridge id)stats, 0); CFRelease(stats); }
            IOObjectRelease(e);
        }
        IOObjectRelease(it);
    }
    AddRaw(m, @"\nСмотри на Reallocated / Pending / Uncorrectable / CRC — любые ненулевые значения = диск умирает.\n",
           [NSColor tertiaryLabelColor], 11, NO);
    return m;
}

+ (NSAttributedString *)tempReport {
    NSMutableAttributedString *m = NewDoc();
    AddHeader(m, @"Датчики температуры (AppleSMC / IOKit)");
    NSArray *temps = SMCReadTemperatures();
    if (!temps.count) {
        AddRaw(m, @"Не удалось прочитать SMC/батарею. Нажми «🔓 Расширенно (sudo)» — там будет powermetrics.\n",
               [NSColor secondaryLabelColor], 11, NO);
        return m;
    }
    NSArray *sorted = [temps sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    for (NSDictionary *d in sorted) {
        double v = [d[@"value"] doubleValue];
        NSColor *c = v > 95 ? CCRed() : (v > 80 ? CCOrange() : CCGreen());
        NSString *line = [NSString stringWithFormat:@"%@  (%@)  ", d[@"name"], d[@"key"]];
        NSString *pad = [line stringByPaddingToLength:34 withString:@" " startingAtIndex:0];
        AddRaw(m, pad, [NSColor labelColor], 11, NO);
        AddRaw(m, [NSString stringWithFormat:@"%.1f °C\n", v], c, 11, YES);
    }
    AddRaw(m, @"\nВ простое CPU 40–60°C нормально; под нагрузкой до ~90–100°C. Выше — перегрев/паста.\n",
           [NSColor tertiaryLabelColor], 11, NO);
    return m;
}

+ (NSAttributedString *)networkReport {
    NSMutableAttributedString *m = NewDoc();
    AddHeader(m, @"Wi-Fi");
    NSString *ap = @"/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport";
    NSString *wi = [[NSFileManager defaultManager] fileExistsAtPath:ap] ? RunTask(ap, @[@"-I"]) : nil;
    if (wi.length) {
        for (NSString *key in @[@"SSID", @"BSSID", @"RSSI", @"channel", @"agrCtlRSSI", @"lastTxRate", @"state"]) {
            NSRange r = [wi rangeOfString:[key stringByAppendingString:@":"]];
            if (r.location != NSNotFound) {
                NSString *rest = [wi substringFromIndex:r.location + r.length];
                NSString *val = [[rest componentsSeparatedByString:@"\n"].firstObject
                                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                AddKV(m, key, val);
            }
        }
        NSRange rr = [wi rangeOfString:@"agrCtlRSSI:"];
        if (rr.location != NSNotFound) {
            NSString *rest = [wi substringFromIndex:rr.location + rr.length];
            NSInteger rssi = [[rest componentsSeparatedByString:@"\n"].firstObject integerValue];
            NSString *q = rssi > -60 ? @"отличное" : (rssi > -70 ? @"хорошее" : (rssi > -80 ? @"среднее" : @"слабое"));
            AddKV(m, @"Качество сигнала", [NSString stringWithFormat:@"%@ (%ld dBm)", q, (long)rssi]);
        }
    } else AddRaw(m, @"airport недоступен\n", [NSColor secondaryLabelColor], 11, NO);

    AddHeader(m, @"Bluetooth");
    NSDictionary *bt = Profiler(@"SPBluetoothDataType");
    AddKV(m, @"Статус", Str(DeepFindAny(bt, @[@"state", @"Controller Status"])));
    AddKV(m, @"Адрес",  Str(DeepFindAny(bt, @[@"address", @"Address (MAC)"])));

    AddHeader(m, @"Ethernet / IP");
    NSDictionary *net = Profiler(@"SPNetworkDataType");
    AddKV(m, @"IP (en0)", Str(DeepFindAny(net, @[@"ip_address", @"IP Address"])));
    AddKV(m, @"MAC",      Str(DeepFindAny(net, @[@"mac_address", @"MAC Address"])));
    return m;
}

+ (NSAttributedString *)securityReport {
    NSMutableAttributedString *m = NewDoc();
    AddHeader(m, @"Защита и блокировки");
    AddKV(m, @"macOS",      Str(DeepFindAny(Profiler(@"SPSoftwareDataType"), @[@"os_version", @"System Version"])));
    AddKV(m, @"FileVault",  [Str(RunTask(@"/usr/bin/fdesetup", @[@"status"])) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    AddKV(m, @"SIP",        [Str(RunTask(@"/usr/bin/csrutil", @[@"status"])) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    AddKV(m, @"Gatekeeper", [Str(RunTask(@"/usr/sbin/spctl", @[@"--status"])) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);

    NSString *mmm = RunTask(@"/usr/bin/defaults", @[@"read", @"MobileMeAccounts"]) ?: @"";
    BOOL bound = Has(mmm, @"AccountID");
    AddKV(m, @"iCloud (текущий юзер)", bound ? @"ПРИВЯЗАН ⚠ (свой аккаунт — не блокер)" : @"не привязан");

    BOOL mdm = NO, dep = NO;
    NSString *prof = RunTask(@"/usr/bin/profiles", @[@"status", @"-type", @"enrollment"]);
    if (prof.length) { mdm = Has(prof, @"MDM enrollment: Yes"); dep = Has(prof, @"Enrolled via DEP: Yes"); }
    AddKV(m, @"MDM-профиль",   mdm ? @"ЕСТЬ ⚠" : @"нет");
    AddKV(m, @"DEP-регистрация", dep ? @"ЕСТЬ ⚠" : @"нет");

    NSString *users = RunTask(@"/usr/bin/dscl", @[@".", @"-list", @"/Users"]) ?: @"";
    AddHeader(m, @"Учётные записи");
    for (NSString *u in [users componentsSeparatedByString:@"\n"]) {
        if (u.length && ![u hasPrefix:@"_"]) AddRaw(m, [NSString stringWithFormat:@"  %@\n", u], [NSColor labelColor], 11, NO);
    }
    AddRaw(m, @"\nFirmware-пароль и Activation Lock на уровне прошивки без sudo не читаются — нажми «🔓 Расширенно (sudo)» для firmware, и загрузи в Recovery (Cmd+R) для Activation Lock.\n",
           CCRed(), 11, NO);
    return m;
}

+ (NSAttributedString *)portsReport {
    NSMutableAttributedString *m = NewDoc();
    AddHeader(m, @"USB");
    [self dumpTree:m node:Profiler(@"SPUSBDataType") depth:0];
    AddHeader(m, @"Thunderbolt");
    NSDictionary *tb = Profiler(@"SPThunderboltDataType");
    if (tb) [self dumpTree:m node:tb depth:0]; else AddRaw(m, @"нет данных / не поддерживается\n", [NSColor secondaryLabelColor], 11, NO);
    return m;
}

+ (void)dumpTree:(NSMutableAttributedString *)m node:(id)node depth:(int)d {
    NSString *pad = [@"" stringByPaddingToLength:d*2 withString:@" " startingAtIndex:0];
    if ([node isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in [(NSDictionary *)node allKeys]) {
            id v = [(NSDictionary *)node objectForKey:k];
            if ([v isKindOfClass:[NSDictionary class]] || [v isKindOfClass:[NSArray class]]) {
                AddRaw(m, [NSString stringWithFormat:@"%@%@\n", pad, k], [NSColor secondaryLabelColor], 11, YES);
                [self dumpTree:m node:v depth:d+1];
            } else {
                AddRaw(m, [NSString stringWithFormat:@"%@%@: ", pad, k], [NSColor labelColor], 11, NO);
                AddRaw(m, [Str(v) stringByAppendingString:@"\n"], [NSColor tertiaryLabelColor], 11, NO);
            }
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id v in node) [self dumpTree:m node:v depth:d];
    }
}

+ (NSAttributedString *)sudoReportFromRaw:(NSString *)raw {
    NSMutableAttributedString *m = NewDoc();
    if (!raw.length) { AddRaw(m, @"Нет данных (проверка отменена или не запустилась).\n", CCRed(), 12, NO); return m; }

    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *(^Grab)(NSString *) = ^NSString *(NSString *tag){
        NSString *open = [@"@@@" stringByAppendingString:tag];
        NSRange r = [raw rangeOfString:open];
        if (r.location == NSNotFound) return @"";
        NSUInteger start = r.location + r.length;
        if (start < raw.length && [raw characterAtIndex:start] == '\n') start++;
        NSRange nxt = [raw rangeOfString:@"@@@" options:0 range:NSMakeRange(start, raw.length - start)];
        NSUInteger end = (nxt.location == NSNotFound) ? raw.length : nxt.location;
        if (end <= start) return @"";
        return [[raw substringWithRange:NSMakeRange(start, end - start)] stringByTrimmingCharactersInSet:ws];
    };

    AddHeader(m, @"РАСШИРЕННАЯ ПРОВЕРКА (sudo)");

    NSString *fw = Grab(@"FIRMWARE");
    BOOL fwLocked = NO;
    for (NSString *ln in [fw componentsSeparatedByString:@"\n"]) {
        NSString *low = [ln lowercaseString];
        if ([low rangeOfString:@"security-mode"].location != NSNotFound &&
            [low rangeOfString:@"password"].location != NSNotFound) { fwLocked = YES; break; }
    }
    if (fwLocked) {
        AddRaw(m, @"▲  Пароль прошивки (firmware): УСТАНОВЛЕН\n", CCRed(), 14, YES);
        AddRaw(m, @"   Без этого пароля Mac нельзя переустановить/стереть. Требуй у продавца сброс (firmwarepasswd -d) при тебе.\n", CCRed(), 11, NO);
    } else {
        AddRaw(m, @"●  Пароль прошивки (firmware): не обнаружен\n", CCGreen(), 14, YES);
    }
    if (fw.length) AddKV(m, @"   nvram security-mode", [fw stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]);

    NSString *mdm = Grab(@"MDM");
    if (mdm.length) {
        BOOL enrolled = [[mdm lowercaseString] rangeOfString:@"yes"].location != NSNotFound;
        AddRaw(m, enrolled ? @"▲  MDM (детали profiles show)\n" : @"●  MDM (детали profiles show)\n",
               enrolled ? CCRed() : CCGreen(), 14, YES);
        for (NSString *ln in [mdm componentsSeparatedByString:@"\n"])
            AddRaw(m, [@"   " stringByAppendingString:[ln stringByAppendingString:@"\n"]], [NSColor labelColor], 11, NO);
    }

    NSString *fv = Grab(@"FILEVAULT");
    AddRaw(m, @"●  FileVault (fdesetup)\n", CCGreen(), 14, YES);
    for (NSString *ln in [fv componentsSeparatedByString:@"\n"])
        AddRaw(m, [@"   " stringByAppendingString:[ln stringByAppendingString:@"\n"]], [NSColor labelColor], 11, NO);

    NSString *disk = Grab(@"DISK");
    AddRaw(m, @"●  Накопитель (diskutil info disk0)\n", CCGreen(), 14, YES);
    for (NSString *ln in [disk componentsSeparatedByString:@"\n"])
        AddRaw(m, [@"   " stringByAppendingString:[ln stringByAppendingString:@"\n"]], [NSColor labelColor], 11, NO);

    NSString *batt = Grab(@"BATT");
    AddRaw(m, @"●  Батарея (pmset -g batt)\n", CCGreen(), 14, YES);
    for (NSString *ln in [batt componentsSeparatedByString:@"\n"])
        AddRaw(m, [@"   " stringByAppendingString:[ln stringByAppendingString:@"\n"]], [NSColor labelColor], 11, NO);

    NSString *temps = Grab(@"TEMPS");
    if (temps.length) {
        AddRaw(m, @"●  Температуры (powermetrics, sudo)\n", CCGreen(), 14, YES);
        for (NSString *ln in [temps componentsSeparatedByString:@"\n"])
            AddRaw(m, [@"   " stringByAppendingString:[ln stringByAppendingString:@"\n"]], [NSColor labelColor], 11, NO);
    }

    AddRaw(m, @"\nПримечание: на Mac с чипом T2 / Apple Silicon firmware-пароль управляется иначе и через nvram может не отражаться — проверяй его в Recovery и в «Настройки пользователя».\n",
           [NSColor tertiaryLabelColor], 11, NO);
    return m;
}

@end

//
//  AppDelegate.m
//  MacCheck
//
//  Created by Ramzayev Hermann on 02.11.2026.
//

#import "AppDelegate.h"
#import "SystemInfo.h"
#import "Compat.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <sys/sysctl.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/vm_statistics.h>
#import <math.h>
#import <objc/runtime.h>

#pragma mark - Перехват uncaught-исключений

static void LogUncaughtException(NSException *e) {
    NSLog(@"💥 UNCAUGHT: %@ — %@", e.name, e.reason);
    NSLog(@"%@", [e callStackSymbols]);
}

static NSAttributedString *SafeReport(NSAttributedString *(^block)(void)) {
    @try { return block(); }
    @catch (NSException *e) {
        NSMutableAttributedString *m = [[NSMutableAttributedString alloc] init];
        NSDictionary *red  = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:13],
                                NSForegroundColorAttributeName: [NSColor redColor] };
        NSDictionary *norm = @{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                                NSForegroundColorAttributeName: [NSColor labelColor] };
        [m appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"⚠ Сбор этой вкладки упал\n\n" attributes:red]];
        [m appendAttributedString:[[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:
                @"Исключение: %@\nПричина: %@\n\nСкопируйте этот текст разработчику.\n",
                e.name, e.reason ?: @"—"] attributes:norm]];
        NSLog(@"💥 SafeReport caught: %@ — %@", e.name, e.reason);
        return m;
    }
}

#pragma mark - sudo (osascript with administrator privileges)

static NSDictionary *RunSudo(NSString *shellScript) {
    @try {
        NSString *dir = NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"maccheck_sudo_%lld.sh",
                           (long long)[[NSDate date] timeIntervalSince1970]]];
        if (![shellScript writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])
            return @{ @"out":@"", @"err":@"не удалось записать скрипт", @"code":@(-1) };

        NSString *osa = [NSString stringWithFormat:
            @"do shell script \"sh \\\"%@\\\"\" with administrator privileges", path];

        NSTask *t = [[NSTask alloc] init];
        if (@available(macOS 10.13, *)) {
            t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/osascript"];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
            [t performSelector:@selector(setExecutablePath:) withObject:@"/usr/bin/osascript"];
#pragma clang diagnostic pop
        }
        t.arguments = @[ @"-e", osa ];
        NSPipe *o = [NSPipe pipe], *er = [NSPipe pipe];
        t.standardOutput = o; t.standardError = er;
        [t launch];
        NSData *od = [[o fileHandleForReading] readDataToEndOfFile];
        NSData *ed = [[er fileHandleForReading] readDataToEndOfFile];
        [t waitUntilExit];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return @{ @"out": [[NSString alloc] initWithData:od encoding:NSUTF8StringEncoding] ?: @"",
                  @"err": [[NSString alloc] initWithData:ed encoding:NSUTF8StringEncoding] ?: @"",
                  @"code": @(t.terminationStatus) };
    } @catch (NSException *e) {
        return @{ @"out":@"", @"err": e.reason ?: e.name, @"code":@(-2) };
    }
}

#pragma mark - Метрики нагрузки (CPU / RAM / GPU)

static const NSUInteger kMaxPoints = 120;   // ~2 минуты истории при 1 Гц

static double ExtractDouble(id v) {
    if (!v) return -1;
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSScanner *sc = [NSScanner scannerWithString:v];
        double d = 0;
        if ([sc scanDouble:&d]) return d;
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        id val = [(NSDictionary *)v objectForKey:@"Value"];
        if (val) return ExtractDouble(val);
        for (id x in [(NSDictionary *)v allValues]) {
            double d = ExtractDouble(x);
            if (d >= 0) return d;
        }
    }
    if ([v isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)v) {
            double d = ExtractDouble(x);
            if (d >= 0) return d;
        }
    }
    return -1;
}

static double RAMUsedPercent(void) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
        return -1;

    uint64_t pageSize = (uint64_t)vm_page_size;
    uint64_t used = ((uint64_t)vm.active_count +
                     (uint64_t)vm.wire_count +
                     (uint64_t)vm.compressor_page_count) * pageSize;

    uint64_t total = 0;
    size_t len = sizeof(total);
    if (sysctlbyname("hw.memsize", &total, &len, NULL, 0) != 0 || total == 0) return -1;

    return used * 100.0 / (double)total;
}

static double GPUUtilization(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
                                     IOServiceMatching("IOAccelerator"), &it) != KERN_SUCCESS)
        return -1;

    io_object_t obj;
    double res = -1;

    while ((obj = IOIteratorNext(it)) && res < 0) {
        CFDictionaryRef perf = IORegistryEntryCreateCFProperty(obj, CFSTR("PerformanceStatistics"),
                                                               kCFAllocatorDefault, 0);
        if (perf) {
            NSArray *keys = @[@"Device Utilization %",
                              @"GPU Core Utilization",
                              @"Utilization %",
                              @"Device Utilization",
                              @"Renderer Utilization %"];
            for (NSString *k in keys) {
                CFTypeRef val = CFDictionaryGetValue(perf, (__bridge CFStringRef)k);
                if (val) {
                    double d = ExtractDouble((__bridge id)val);
                    if (d >= 0) { res = d; break; }
                }
            }
            if (res < 0) {
                NSDictionary *dict = (__bridge NSDictionary *)perf;
                for (id key in dict) {
                    if ([key isKindOfClass:[NSString class]] &&
                        [(NSString *)key rangeOfString:@"Util" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                        double d = ExtractDouble(dict[key]);
                        if (d >= 0) { res = d; break; }
                    }
                }
            }
            CFRelease(perf);
        }
    }
    IOObjectRelease(it);
    return res;
}

@interface MetricsSampler : NSObject
@property (strong) NSMutableArray<NSNumber *> *cpu;
@property (strong) NSMutableArray<NSNumber *> *ram;
@property (strong) NSMutableArray<NSNumber *> *gpu;
@property (copy) void (^onUpdate)(void);
@property (assign) BOOL running;
- (void)start;
- (void)stop;
- (void)sampleOnce;
@end

@implementation MetricsSampler {
    host_cpu_load_info_data_t prevCPU;
    BOOL hasPrevCPU;
    dispatch_source_t timerSrc;   // dispatch_source вместо NSTimer: нет retain-цикла, 10.10+
}

- (instancetype)init {
    if ((self = [super init])) {
        _cpu = [NSMutableArray array];
        _ram = [NSMutableArray array];
        _gpu = [NSMutableArray array];
    }
    return self;
}

- (double)cpuLoad {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS)
        return -1;

    if (!hasPrevCPU) {
        prevCPU = info;
        hasPrevCPU = YES;
        return 0;
    }

    unsigned long long user   = (unsigned long long)info.cpu_ticks[CPU_STATE_USER]   - prevCPU.cpu_ticks[CPU_STATE_USER];
    unsigned long long system = (unsigned long long)info.cpu_ticks[CPU_STATE_SYSTEM] - prevCPU.cpu_ticks[CPU_STATE_SYSTEM];
    unsigned long long idle   = (unsigned long long)info.cpu_ticks[CPU_STATE_IDLE]   - prevCPU.cpu_ticks[CPU_STATE_IDLE];
    unsigned long long nice   = (unsigned long long)info.cpu_ticks[CPU_STATE_NICE]   - prevCPU.cpu_ticks[CPU_STATE_NICE];
    prevCPU = info;

    unsigned long long busy  = user + system + nice;
    unsigned long long total = busy + idle;
    if (total == 0) return 0;
    return busy * 100.0 / (double)total;
}

- (void)push:(NSMutableArray *)arr value:(double)v {
    [arr addObject:@(v)];
    if (arr.count > kMaxPoints) [arr removeObjectAtIndex:0];
}

- (void)sampleOnce {
    double c = [self cpuLoad];  if (c < 0) c = 0;
    double r = RAMUsedPercent(); if (r < 0) r = 0;
    double g = GPUUtilization();

    [self push:_cpu value:c];
    [self push:_ram value:r];
    [self push:_gpu value:g];

    if (self.onUpdate) self.onUpdate();
}

- (void)start {
    if (self.running) return;
    self.running = YES;
    [self sampleOnce];

    timerSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t sec = 1000000000ULL;            // 1 секунда в наносекундах (без зависимости от NSEC_PER_SEC)
    dispatch_source_set_timer(timerSrc,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)sec),
                              sec,
                              sec / 10);     // leeway 0.1 с
    __weak MetricsSampler *weakSelf = self;
    dispatch_source_set_event_handler(timerSrc, ^{ [weakSelf sampleOnce]; });
    dispatch_resume(timerSrc);
}

- (void)stop {
    if (timerSrc) { dispatch_source_cancel(timerSrc); timerSrc = nil; }
    self.running = NO;
}

@end

@interface LoadGraphView : NSView
@property (weak) MetricsSampler *sampler;
@end

@implementation LoadGraphView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    (void)dirtyRect;

    if (!_sampler) return;

    NSRect b = self.bounds;
    CGFloat rowH = floor(b.size.height / 3.0) - 10;
    CGFloat y = 8;

    NSArray *names  = @[@"CPU", @"RAM", @"GPU"];
    NSArray *arrays = @[_sampler.cpu, _sampler.ram, _sampler.gpu];
    NSArray *colors = @[CCBlue(), CCGreen(), CCOrange()];

    for (NSInteger i = 0; i < 3; i++) {
        NSRect row       = NSMakeRect(10, y, b.size.width - 20, rowH);
        NSRect labelRect = NSMakeRect(row.origin.x, row.origin.y, 64, row.size.height);
        NSRect chartRect = NSMakeRect(row.origin.x + 72, row.origin.y, row.size.width - 72, row.size.height);

        NSArray *hist = arrays[i];
        double cur = hist.lastObject ? [hist.lastObject doubleValue] : 0;

        NSFont *fName = [NSFont boldSystemFontOfSize:12];
        NSFont *fVal  = [NSFont systemFontOfSize:11];
        NSDictionary *aName = @{ NSFontAttributeName: fName,
                                 NSForegroundColorAttributeName: [NSColor labelColor] };
        NSDictionary *aVal  = @{ NSFontAttributeName: fVal,
                                 NSForegroundColorAttributeName: [NSColor secondaryLabelColor] };

        NSString *valText = (i == 2 && cur < 0) ? @"нет данных" : [NSString stringWithFormat:@"%.0f%%", cur];

        // ✅ ВНЕШНИЕ скобки на месте: [ [получатель] drawInRect:arg ]
        [[[NSAttributedString alloc] initWithString:names[i] attributes:aName]
            drawInRect:NSMakeRect(labelRect.origin.x, labelRect.origin.y, labelRect.size.width, 16)];
        [[[NSAttributedString alloc] initWithString:valText attributes:aVal]
            drawInRect:NSMakeRect(labelRect.origin.x, labelRect.origin.y + 18, labelRect.size.width, 16)];

        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.06] setFill];
        NSRectFill(chartRect);

        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.12] setStroke];
        NSBezierPath *border = [NSBezierPath bezierPathWithRect:chartRect];
        border.lineWidth = 1;
        [border stroke];

        if (!(i == 2 && cur < 0) && hist.count > 0) {
            NSBezierPath *path = [NSBezierPath bezierPath];
            BOOL started = NO;
            CGFloat step = chartRect.size.width / (CGFloat)(kMaxPoints - 1);

            for (NSUInteger j = 0; j < hist.count; j++) {
                double v = [hist[j] doubleValue];
                if (v < 0) v = 0;
                if (v > 100) v = 100;
                CGFloat xx = chartRect.origin.x + (CGFloat)j * step;
                CGFloat yy = chartRect.origin.y + chartRect.size.height - (CGFloat)(v / 100.0 * chartRect.size.height);
                NSPoint p = NSMakePoint(xx, yy);
                if (!started) { [path moveToPoint:p]; started = YES; }
                else [path lineToPoint:p];
            }
            if (started) {
                [colors[i] setStroke];
                path.lineWidth = 2;
                [path stroke];
            }
        }

        y += rowH + 12;
    }
}

@end

#pragma mark - Подклассы окон

@interface FullscreenTestWindow : NSWindow
@end
@implementation FullscreenTestWindow
- (BOOL)canBecomeKey  { return YES; }
- (BOOL)canBecomeMain { return YES; }
@end

@interface ScreenTestView : NSView
@property (strong) NSArray<NSColor *> *colors;
@property (assign) NSUInteger idx;
@property (copy) void (^dismissHandler)(void);
@end
@implementation ScreenTestView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _colors = @[NSColor.whiteColor, NSColor.blackColor,
                    [NSColor redColor], [NSColor greenColor], [NSColor blueColor],
                    [NSColor yellowColor], [NSColor cyanColor], [NSColor magentaColor]];
        _idx = 0;
    }
    return self;
}
- (void)drawRect:(NSRect)r { [[self.colors objectAtIndex:self.idx] setFill]; NSRectFill(r); }
- (void)dismiss { if (self.dismissHandler) self.dismissHandler(); }
- (void)mouseDown:(NSEvent *)e {
    if (self.idx + 1 >= self.colors.count) { [self dismiss]; return; }
    self.idx += 1;
    [self setNeedsDisplay:YES];
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e { [self dismiss]; }
@end

@interface KeyTestView : NSView
@property (strong) NSMutableSet<NSNumber *> *seen;
@property (strong) NSTextField *counter;
@property (strong) NSTextField *last;
@end
@implementation KeyTestView
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) _seen = [NSMutableSet set];
    return self;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e {
    [self.seen addObject:@(e.keyCode)];
    self.counter.stringValue = [NSString stringWithFormat:@"Уникальных клавиш: %lu",
                                (unsigned long)self.seen.count];
    NSString *ch = e.charactersIgnoringModifiers.length ? e.charactersIgnoringModifiers : @"(спец)";
    self.last.stringValue = [NSString stringWithFormat:@"Последняя: %@  (keyCode %ld)",
                             ch, (long)e.keyCode];
}
@end

@interface CamPreviewRenderer : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (weak)   CALayer *targetLayer;
@property (strong) dispatch_queue_t queue;
@property (assign) BOOL paused;
@end
@implementation CamPreviewRenderer
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("maccheck.cam.preview", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    if (self.paused) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb) return;

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    size_t w     = CVPixelBufferGetWidth(pb);
    size_t h     = CVPixelBufferGetHeight(pb);
    void   *base = CVPixelBufferGetBaseAddress(pb);
    size_t  bpr  = CVPixelBufferGetBytesPerRow(pb);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
        (CGBitmapInfo)(kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little));
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    if (!img) return;

    CALayer *layer = self.targetLayer;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (layer) {
            layer.contents = (__bridge id)img;
            layer.contentsGravity = kCAGravityResizeAspect;
        }
        CGImageRelease(img);
    });
}
@end

#pragma mark - AppDelegate

@interface AppDelegate ()
@property (strong) NSTabView *tabs;
@property (strong) NSTextField *status;
@property (strong) NSButton *runButton;
@property (strong) NSButton *sudoButton;
@property (strong) NSWindow *screenTestWindow;
@property (strong) NSWindow *cameraTestWindow;
@property (strong) NSWindow *keyboardTestWindow;
@property (strong) MetricsSampler *sampler;
@property (strong) LoadGraphView *loadGraph;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    NSSetUncaughtExceptionHandler(&LogUncaughtException);
    [self buildMenu];
    [self buildWindow];
    [self checkPrivacyThenRun];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self.sampler stop];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }

#pragma mark TCC (10.14+)

- (void)checkPrivacyThenRun {
    if (@available(macOS 10.14, *)) {
        @try {
            AVAuthorizationStatus cam = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
            AVAuthorizationStatus mic = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
            if (cam == AVAuthorizationStatusNotDetermined)
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL g){ }];
            if (mic == AVAuthorizationStatusNotDetermined)
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL g){ }];
            BOOL camDenied = (cam == AVAuthorizationStatusDenied);
            BOOL micDenied = (mic == AVAuthorizationStatusDenied);
            if (camDenied || micDenied) [self showPrivacyAlertCamera:camDenied mic:micDenied];
        } @catch (NSException *e) {
            NSLog(@"💥 TCC-запрос пропущен (%@): %@", e.name, e.reason);
            self.status.stringValue = @"⚠ Камера/микрофон недоступны (нет ключей в Info.plist). Железо соберём без них.";
        }
    }
    [self runAllChecks];
}

- (void)showPrivacyAlertCamera:(BOOL)camera mic:(BOOL)mic {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Требуется разрешение на конфиденциальность";
    NSMutableArray *parts = [NSMutableArray array];
    if (camera) [parts addObject:@"Камера"];
    if (mic)    [parts addObject:@"Микрофон"];
    alert.informativeText = [NSString stringWithFormat:
        @"Для тестов камеры и микрофона macOS требует ваше разрешение.\nСейчас запрещено: %@.\n\n"
        @"Нажмите «Открыть Настройки», включите MacCheck в разделе «Конфиденциальность», затем перезапустите программу.",
        [parts componentsJoinedByString:@", "]];
    [alert addButtonWithTitle:@"Открыть Настройки"];
    [alert addButtonWithTitle:@"Позже"];
    NSString *scheme;
    if (camera && mic) scheme = @"x-apple.systempreferences:com.apple.preference.security?Privacy";
    else if (camera)   scheme = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Camera";
    else               scheme = @"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone";
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){
        if (r == NSAlertFirstButtonReturn)
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:scheme]];
    }];
}

#pragma mark Меню

- (void)buildMenu {
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [main addItem:appItem];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"О программе MacCheck" action:NULL keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Выйти" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [NSApp setMainMenu:main];
}

#pragma mark Окно

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 980, 680);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"MacCheck — диагностика б/у Mac";
    [self.window center];
    [self.window setMinSize:NSMakeSize(820, 520)];

    NSView *content = self.window.contentView;
    CGFloat W = frame.size.width, H = frame.size.height, barH = 44;

    NSView *topBar = [[NSView alloc] initWithFrame:NSMakeRect(0, H - barH, W, barH)];
    topBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:topBar];

    NSButton *btn = CButton(@"🔄  Проверить всё", self, @selector(runAllChecks));
    btn.frame = NSMakeRect(16, 8, 160, 28);
    btn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [topBar addSubview:btn];
    self.runButton = btn;

    NSButton *sbtn = CButton(@"🔓  Расширенно (sudo)", self, @selector(runSudoChecks));
    sbtn.frame = NSMakeRect(184, 8, 200, 28);
    sbtn.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [topBar addSubview:sbtn];
    self.sudoButton = sbtn;

    NSTextField *status = CLabel(@"Готово.");
    status.frame = NSMakeRect(396, 14, W - 412, 18);
    status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [topBar addSubview:status];
    self.status = status;

    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, W, H - barH)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:tabs];
    self.tabs = tabs;

    // 0 Обзор, 1 Система, 2 Батарея, 3 Диск, 4 Температуры, 5 Нагрузка,
    // 6 Сеть, 7 Безопасность, 8 Порты, 9 sudo, 10 Тесты
    NSArray *titles = @[@"Обзор", @"Система", @"Батарея", @"Диск", @"Температуры",
                        @"Нагрузка", @"Сеть", @"Безопасность", @"Порты", @"sudo", @"Тесты"];

    for (NSString *t in titles) {
        NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:t];
        item.label = t;
        if ([t isEqualToString:@"Нагрузка"])      item.view = [self buildLoadTab];
        else if ([t isEqualToString:@"Тесты"])    item.view = [self buildTestsTab];
        else                                      item.view = [self scrollText];
        [self.tabs addTabViewItem:item];
    }

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (NSScrollView *)scrollText {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 940, 600)];
    sv.hasVerticalScroller = YES;
    sv.hasHorizontalScroller = NO;
    sv.autohidesScrollers = YES;
    sv.borderType = NSNoBorder;
    sv.drawsBackground = NO;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.minSize = NSMakeSize(0.0, 0.0);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tv.textContainerInset = NSMakeSize(14.0, 14.0);
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    NSFont *mono = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont userFixedPitchFontOfSize:11];
    tv.font = mono;
    tv.textColor = [NSColor labelColor];
    tv.typingAttributes = @{ NSFontAttributeName: mono,
                             NSForegroundColorAttributeName: [NSColor labelColor] };
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainer.containerSize = NSMakeSize(sv.contentSize.width, CGFLOAT_MAX);
    sv.documentView = tv;
    return sv;
}

- (void)setTab:(NSUInteger)i text:(NSAttributedString *)a {
    if (i >= [self.tabs numberOfTabViewItems]) return;
    NSView *view = self.tabs.tabViewItems[i].view;
    if (![view isKindOfClass:[NSScrollView class]]) return;
    NSScrollView *sv = (NSScrollView *)view;
    NSView *doc = sv.documentView;
    if (![doc isKindOfClass:[NSTextView class]]) return;
    NSTextView *tv = (NSTextView *)doc;
    NSAttributedString *safe = a ?: [[NSAttributedString alloc] init];
    [tv.textStorage setAttributedString:safe];
    CGFloat width = MAX(tv.frame.size.width, 320.0);
    [tv.textContainer setContainerSize:NSMakeSize(width, CGFLOAT_MAX)];
    [tv.layoutManager ensureLayoutForTextContainer:tv.textContainer];
    [tv setNeedsDisplay:YES];
    [sv setNeedsDisplay:YES];
}

#pragma mark Сбор без sudo

- (void)runAllChecks {
    self.runButton.enabled = NO;
    self.status.stringValue = @"Собираю данные (без sudo)…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSAttributedString *ov  = SafeReport(^{ return [SystemInfo overviewReport]; });
        NSAttributedString *hw  = SafeReport(^{ return [SystemInfo hardwareReport]; });
        NSAttributedString *bat = SafeReport(^{ return [SystemInfo batteryReport]; });
        NSAttributedString *dsk = SafeReport(^{ return [SystemInfo diskReport]; });
        NSAttributedString *tmp = SafeReport(^{ return [SystemInfo tempReport]; });
        NSAttributedString *net = SafeReport(^{ return [SystemInfo networkReport]; });
        NSAttributedString *sec = SafeReport(^{ return [SystemInfo securityReport]; });
        NSAttributedString *prt = SafeReport(^{ return [SystemInfo portsReport]; });

        NSLog(@"🧾 DIAG lengths: ov=%lu hw=%lu bat=%lu dsk=%lu tmp=%lu net=%lu sec=%lu prt=%lu",
              (unsigned long)ov.length, (unsigned long)hw.length, (unsigned long)bat.length,
              (unsigned long)dsk.length, (unsigned long)tmp.length, (unsigned long)net.length,
              (unsigned long)sec.length, (unsigned long)prt.length);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTab:0 text:ov];
            [self setTab:1 text:hw];
            [self setTab:2 text:bat];
            [self setTab:3 text:dsk];
            [self setTab:4 text:tmp];
            [self setTab:6 text:net];
            [self setTab:7 text:sec];
            [self setTab:8 text:prt];

            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.timeStyle = NSDateFormatterMediumStyle;
            df.dateStyle = NSDateFormatterNoStyle;
            self.status.stringValue = [NSString stringWithFormat:@"Проверка завершена — %@",
                                       [df stringFromDate:[NSDate date]]];
            self.runButton.enabled = YES;
            [self.tabs selectTabViewItemAtIndex:0];
        });
    });
}

#pragma mark sudo

- (void)runSudoChecks {
    self.sudoButton.enabled = NO;
    self.runButton.enabled = NO;
    self.status.stringValue = @"🔓 Запрашиваю права администратора (диалог macOS)…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *lines = @[
            @"echo \"@@@FIRMWARE\"",
            @"nvram security-mode 2>&1",
            @"nvram -p 2>&1 | grep -i -E 'security-mode|boot-security'",
            @"echo \"@@@MDM\"",
            @"/usr/bin/profiles show -type enrollment 2>&1",
            @"echo \"@@@FILEVAULT\"",
            @"/usr/bin/fdesetup status 2>&1",
            @"/usr/bin/fdesetup isactive 2>&1",
            @"echo \"@@@DISK\"",
            @"/usr/sbin/diskutil info disk0 2>&1 | grep -E 'Serial Number|SMART Status|Media Name|Volume Name|Disk Size|Device Location|Protocol|Internal|Removable'",
            @"echo \"@@@BATT\"",
            @"/usr/bin/pmset -g batt 2>&1",
            @"echo \"@@@TEMPS\"",
            @"/usr/bin/powermetrics --samplers smc -i 1 -n 1 2>&1 | grep -Ei 'temperature|CPU|GPU|Battery|Thermal' | head -n 50"
        ];
        NSString *script = [lines componentsJoinedByString:@"\n"];
        NSDictionary *res = RunSudo(script);
        NSString *out = res[@"out"];
        NSString *err = res[@"err"];
        NSInteger code = [res[@"code"] integerValue];

        BOOL canceled = (out.length == 0) && (code != 0) &&
            ([err rangeOfString:@"canceled" options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [err rangeOfString:@"Cancel"  options:NSCaseInsensitiveSearch].location != NSNotFound ||
             [err rangeOfString:@"-128"].location != NSNotFound);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.sudoButton.enabled = YES;
            self.runButton.enabled = YES;
            if (canceled) {
                self.status.stringValue = @"🔓 sudo-проверка отменена (пароль не введён).";
                return;
            }
            if (out.length == 0) {
                NSMutableAttributedString *m = [[NSMutableAttributedString alloc] init];
                [m appendAttributedString:[[NSAttributedString alloc]
                    initWithString:[NSString stringWithFormat:
                        @"⚠ sudo-сбор не вернул данных.\nКод: %ld\nstderr: %@\n",
                        (long)code, err ?: @"—"]
                        attributes:@{ NSFontAttributeName: [NSFont systemFontOfSize:12],
                                      NSForegroundColorAttributeName: CCRed() }]];
                [self setTab:9 text:m];
                self.status.stringValue = @"🔓 sudo-проверка завершилась с ошибкой.";
                [self.tabs selectTabViewItemAtIndex:9];
                return;
            }
            NSAttributedString *rep = [SystemInfo sudoReportFromRaw:out];
            [self setTab:9 text:rep];
            self.status.stringValue = @"🔓 Расширенная проверка (sudo) завершена.";
            [self.tabs selectTabViewItemAtIndex:9];
        });
    });
}

#pragma mark Вкладка нагрузки

- (NSView *)buildLoadTab {
    LoadGraphView *gv = [[LoadGraphView alloc] initWithFrame:NSZeroRect];
    gv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.loadGraph = gv;

    if (!self.sampler) self.sampler = [[MetricsSampler alloc] init];
    gv.sampler = self.sampler;

    __weak typeof(self) weakSelf = self;
    self.sampler.onUpdate = ^{
        [weakSelf.loadGraph setNeedsDisplay:YES];
    };

    [self.sampler start];
    return gv;
}

#pragma mark Вкладка тесты

- (NSView *)buildTestsTab {
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 620, 430)];
    CGFloat H = 430, x = 18, w = 560, y;

    y = H - 18 - 18;
    NSTextField *l1 = CLabel(@"Интерактивные проверки — жми и смотри/слушай:");
    l1.frame = NSMakeRect(x, y, w, 18); [doc addSubview:l1];

    NSArray *specs = @[
        @"🖥  Тест экрана (битые пиксели / засветы)|testScreen",
        @"⌨️  Тест клавиатуры|testKeyboard",
        @"🔊  Тест динамиков|testSpeakers",
        @"🎤  Тест микрофона (запись 2 c + воспроизведение)|testMic",
        @"📷  Тест камеры (превью + снимок)|testCamera"
    ];
    y -= 10;
    for (NSString *s in specs) {
        NSArray *parts = [s componentsSeparatedByString:@"|"];
        y -= 30;
        NSButton *b = CButton(parts[0], self, NSSelectorFromString(parts[1]));
        b.frame = NSMakeRect(x, y, w, 30); [doc addSubview:b]; y -= 10;
    }
    y -= 10;
    NSTextField *l2 = CLabel(@"После тестов прогони нагрузку (видео 4K) и пощупай шарниры, порт зарядки, все USB/Thunderbolt физически.");
    l2.frame = NSMakeRect(x, y - 36, w, 36);
    l2.lineBreakMode = NSLineBreakByWordWrapping; l2.cell.wraps = YES; [doc addSubview:l2];

    sv.documentView = doc;
    return sv;
}

#pragma mark Тесты

- (void)testScreen {
    NSScreen *scr = NSScreen.mainScreen;
    FullscreenTestWindow *w = [[FullscreenTestWindow alloc] initWithContentRect:scr.frame
        styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
    w.level = NSMainMenuWindowLevel + 1;
    w.releasedWhenClosed = NO;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

    ScreenTestView *v = [[ScreenTestView alloc] initWithFrame:scr.frame];
    __weak AppDelegate *weakSelf = self;
    v.dismissHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.screenTestWindow orderOut:nil];
            weakSelf.screenTestWindow = nil;
        });
    };
    w.contentView = v;

    self.screenTestWindow = w;
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    self.status.stringValue = @"Тест экрана: клик = следующий цвет, Esc = выход. После последнего цвета окно закроется само.";
}

- (void)testKeyboard {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 260)
        styleMask:(NSTitledWindowMask | NSClosableWindowMask) backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Тест клавиатуры";
    w.releasedWhenClosed = NO;

    KeyTestView *kv = [[KeyTestView alloc] initWithFrame:w.contentView.bounds];
    kv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextField *c = CLabel(@"Уникальных клавиш: 0"); c.frame = NSMakeRect(16, 210, 400, 24);
    NSTextField *l = CLabel(@"Нажимай ВСЕ клавиши по очереди…");
    l.frame = NSMakeRect(16, 16, 480, 180); l.textColor = [NSColor secondaryLabelColor];
    kv.counter = c; kv.last = l;
    [w.contentView addSubview:kv]; [w.contentView addSubview:c]; [w.contentView addSubview:l];
    w.initialFirstResponder = kv;

    self.keyboardTestWindow = w;

    __weak AppDelegate *weakSelf = self;
    __block id closeToken = nil;
    closeToken = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSWindowWillCloseNotification object:w queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *note){
            [[NSNotificationCenter defaultCenter] removeObserver:closeToken];
            dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.keyboardTestWindow = nil; });
        }];

    [w center]; [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}

- (void)testSpeakers {
    NSSound *s = [[NSSound alloc] initWithContentsOfFile:@"/System/Library/Sounds/Glass.aiff" byReference:YES];
    if (s) { [s play]; self.status.stringValue = @"Динамики: проигран системный звук Glass."; }
    else   { self.status.stringValue = @"Не найден системный звук для теста."; }
}

- (void)testMic {
    @try {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"maccheck_mic.caf"];
        AVAudioRecorder *rec = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:path]
            settings:@{AVFormatIDKey:@(kAudioFormatLinearPCM), AVSampleRateKey:@44100.0,
                       AVNumberOfChannelsKey:@1, AVLinearPCMBitDepthKey:@16,
                       AVLinearPCMIsFloatKey:@NO} error:nil];
        if (!rec) { self.status.stringValue = @"🎤 Микрофон: не удалось инициализировать рекордер."; return; }
        [rec prepareToRecord]; [rec record];
        self.status.stringValue = @"🎤 Идёт запись 2 секунды… говори в микрофон.";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [rec stop];
            float peak = [rec averagePowerForChannel:0];
            AVAudioPlayer *pl = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
            [pl play];
            self.status.stringValue = [NSString stringWithFormat:
                @"🎤 Микрофон работает. Пик уровня: %.0f dB (ближе к 0 — громче). Воспроизвожу запись…", peak];
        });
    } @catch (NSException *e) {
        self.status.stringValue = [NSString stringWithFormat:@"🎤 Микрофон заблокирован/недоступен: %@",
                                   e.reason ?: e.name];
    }
}

- (void)testCamera {
    @try {
        AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (!dev) { self.status.stringValue = @"📷 Камера не найдена."; return; }
        NSError *err = nil;
        AVCaptureDeviceInput *inp = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!inp) {
            self.status.stringValue = [@"📷 Нет доступа к камере: "
                stringByAppendingString:(err.localizedDescription ?: @"запрещено")];
            return;
        }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        [session addInput:inp];

        AVCaptureStillImageOutput *still = [[AVCaptureStillImageOutput alloc] init];
        still.outputSettings = @{ AVVideoCodecKey : AVVideoCodecJPEG };
        [session addOutput:still];
        AVCaptureConnection *stillConn = [still connectionWithMediaType:AVMediaTypeVideo];

        AVCaptureVideoDataOutput *vid = [[AVCaptureVideoDataOutput alloc] init];
        vid.alwaysDiscardsLateVideoFrames = YES;
        vid.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
        CamPreviewRenderer *renderer = [[CamPreviewRenderer alloc] init];

        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 400)
            styleMask:(NSTitledWindowMask | NSClosableWindowMask)
            backing:NSBackingStoreBuffered defer:NO];
        w.title = @"Тест камеры";
        w.releasedWhenClosed = NO;

        NSView *container = [[NSView alloc] initWithFrame:w.contentView.bounds];
        container.wantsLayer = YES;
        container.layer.backgroundColor = [NSColor blackColor].CGColor;
        container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        CALayer *preview = [CALayer layer];
        preview.frame = container.bounds;
        preview.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        preview.contentsGravity = kCAGravityResizeAspect;
        preview.backgroundColor = [NSColor blackColor].CGColor;
        [container.layer addSublayer:preview];
        [w.contentView addSubview:container];
        renderer.targetLayer = preview;

        [vid setSampleBufferDelegate:renderer queue:renderer.queue];
        [session addOutput:vid];

        NSButton *snap = CButton(@"📸 Снимок", self, @selector(doSnap:));
        snap.frame = NSMakeRect(16, 8, 120, 28);
        snap.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
        objc_setAssociatedObject(snap, "still", still,     OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(snap, "conn",  stillConn, OBJC_ASSOCIATION_RETAIN);
        [w.contentView addSubview:snap];

        objc_setAssociatedObject(w, "session",  session,  OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(w, "renderer", renderer, OBJC_ASSOCIATION_RETAIN);
        self.cameraTestWindow = w;

        __weak AppDelegate *weakSelf = self;
        __block id closeToken = nil;
        closeToken = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowWillCloseNotification object:w queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note){
                [[NSNotificationCenter defaultCenter] removeObserver:closeToken];
                [session stopRunning];
                [vid setSampleBufferDelegate:nil queue:nil];
                renderer.paused = YES;
                renderer.targetLayer = nil;
                dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.cameraTestWindow = nil; });
            }];

        [session startRunning];
        [w center]; [w makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
        self.status.stringValue = @"📷 Камера активна (превью через CPU-рендер). Нажми «Снимок» — JPEG сохранится и откроется.";
    } @catch (NSException *e) {
        self.status.stringValue = [NSString stringWithFormat:@"📷 Камера заблокирована/недоступна: %@",
                                   e.reason ?: e.name];
    }
}

- (void)doSnap:(NSButton *)sender {
    AVCaptureStillImageOutput *still = objc_getAssociatedObject(sender, "still");
    AVCaptureConnection *conn = objc_getAssociatedObject(sender, "conn");
    NSString *jpg = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"maccheck_%lld.jpg",
                      (long long)[[NSDate date] timeIntervalSince1970]]];
    [still captureStillImageAsynchronouslyFromConnection:conn completionHandler:^(CMSampleBufferRef buf, NSError *e) {
        if (!buf) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.stringValue = [@"Ошибка снимка: "
                    stringByAppendingString:(e.localizedDescription ?: @"нет данных")];
            });
            return;
        }
        if (@available(macOS 10.11, *)) {
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(buf);
            if (!pb) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.status.stringValue = @"Ошибка: нет пиксельного буфера в кадре";
                });
                return;
            }
            CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCIImage:ci];
            NSData *data = [rep representationUsingType:NSJPEGFileType properties:@{}];
            [data writeToFile:jpg atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.stringValue = [@"📸 Снимок сохранён: " stringByAppendingString:jpg];
                [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:jpg]];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.stringValue = @"📷 Превью работает, но сохранение снимка доступно на macOS 10.11+.";
            });
        }
    }];
}

@end

//
//  Compat.h
//  MacCheck
//
//  Created by Ramzayev Hermann on 02.11.2026.
//

#import <Cocoa/Cocoa.h>

// Системные цвета (systemGreen/Red/Orange появились только в 10.14) — эмулируем RGB
static inline NSColor *CCGreen(void)  { return [NSColor colorWithCalibratedRed:0.20 green:0.78 blue:0.35 alpha:1.0]; }
static inline NSColor *CCRed(void)    { return [NSColor colorWithCalibratedRed:1.00 green:0.23 blue:0.19 alpha:1.0]; }
static inline NSColor *CCOrange(void) { return [NSColor colorWithCalibratedRed:1.00 green:0.58 blue:0.00 alpha:1.0]; }
static inline NSColor *CCBlue(void)   { return [NSColor colorWithCalibratedRed:0.00 green:0.48 blue:1.00 alpha:1.0]; }

// systemFontOfSize:weight: появился в 10.11 — в 10.10 есть только bold/regular
static inline NSFont *CFont(CGFloat size, BOOL bold) {
    return bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
}

// containsString: оставим, но регистронезависимый поиск безопаснее
static inline BOOL Has(NSString *hay, NSString *needle) {
    if (!hay || !needle) return NO;
    return [hay rangeOfString:needle].location != NSNotFound;
}

// labelWithString: (10.12+) — собираем NSTextField вручную
static inline NSTextField *CLabel(NSString *s) {
    NSTextField *l = [[NSTextField alloc] initWithFrame:NSZeroRect];
    l.editable = NO; l.selectable = NO;
    l.bordered = NO; l.bezeled = NO;
    l.drawsBackground = NO;
    l.backgroundColor = [NSColor clearColor];
    l.textColor = [NSColor secondaryLabelColor];
    l.font = [NSFont systemFontOfSize:12];
    l.stringValue = s ?: @"";
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

// buttonWithTitle: (10.12+) — собираем NSButton вручную
static inline NSButton *CButton(NSString *t, id target, SEL action) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    b.title = t ?: @"";
    b.target = target;
    b.action = action;
    b.bezelStyle = NSBezelStyleRounded;
    [b setButtonType:NSButtonTypeMomentaryPushIn];
    b.font = [NSFont systemFontOfSize:13];
    return b;
}

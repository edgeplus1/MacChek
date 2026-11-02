//
//  SystemInfo.h
//  MacCheck
//
//  Created by Ramzayev Hermann on 02.11.2026.
//

#import <Foundation/Foundation.h>

@interface SystemInfo : NSObject
+ (NSAttributedString *)overviewReport;   // цветные вердикты red/green
+ (NSAttributedString *)hardwareReport;
+ (NSAttributedString *)batteryReport;
+ (NSAttributedString *)diskReport;
+ (NSAttributedString *)tempReport;
+ (NSAttributedString *)networkReport;
+ (NSAttributedString *)securityReport;
+ (NSAttributedString *)portsReport;
+ (NSAttributedString *)sudoReportFromRaw:(NSString *)raw;
@end

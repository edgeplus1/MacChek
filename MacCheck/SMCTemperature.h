//
//  SMCTemperature.h
//  MacCheck
//
//  Created by Ramzayev Hermann on 02.11.2026.
//

#import <Foundation/Foundation.h>

// Читает температуры напрямую из AppleSMC (без sudo). Возвращает
// @[ @{@"name": @"CPU 0 (proximity)", @"value": @(52.3)}, ... ]
NSArray<NSDictionary *> *SMCReadTemperatures(void);

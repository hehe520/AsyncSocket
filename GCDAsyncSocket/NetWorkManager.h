//
//  NetWorkManager.h
//  GCDAsyncSocket
//
//  Created by caokun on 16/7/6.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import <Foundation/Foundation.h>

#define NetWorkDidChangeNotification @"NetWorkDidChangeNotification"    // 网络状态变化通知

// 网络状态管理
@interface NetWorkManager : NSObject

+ (NetWorkManager *)instance;

- (void)startListen;
- (void)stopListen;
- (BOOL)status;

@end

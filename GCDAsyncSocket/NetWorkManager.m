//
//  NetWorkManager.m
//  GCDAsyncSocket
//
//  Created by caokun on 16/7/6.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import "NetWorkManager.h"
#import "AFNetworkReachabilityManager.h"

@implementation NetWorkManager

static NetWorkManager *instance = nil;

+ (NetWorkManager *)instance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[NetWorkManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        // 网络状态监听
        [[AFNetworkReachabilityManager sharedManager] setReachabilityStatusChangeBlock:^(AFNetworkReachabilityStatus status) {
            if (status == AFNetworkReachabilityStatusReachableViaWWAN || status == AFNetworkReachabilityStatusReachableViaWiFi) {
                NSLog(@"有网络");
                [[NSNotificationCenter defaultCenter] postNotificationName:NetWorkDidChangeNotification object:nil userInfo:@{@"status": [NSNumber numberWithBool:true]}];
            } else {
                NSLog(@"无网络");
                [[NSNotificationCenter defaultCenter] postNotificationName:NetWorkDidChangeNotification object:nil userInfo:@{@"status": [NSNumber numberWithBool:false]}];
            }
        }];
    }
    return self;
}

- (void)startListen {
    [[AFNetworkReachabilityManager sharedManager] startMonitoring];
}

- (void)stopListen {
    [[AFNetworkReachabilityManager sharedManager] stopMonitoring];
}
     
- (BOOL)status {
    AFNetworkReachabilityStatus status = [AFNetworkReachabilityManager sharedManager].networkReachabilityStatus;
    if (status == AFNetworkReachabilityStatusReachableViaWWAN || status == AFNetworkReachabilityStatusReachableViaWiFi) {
        return true;
    }
    return false;
}

@end


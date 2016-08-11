//
//  SocketManager.h
//  GCDAsyncSocket使用
//
//  Created by caokun on 16/7/1.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "GCDAsyncSocket.h"

@protocol SocketManagerDelegate <NSObject>

- (void)socket:(GCDAsyncSocket *)socket didReadData:(NSData *)data;
- (void)socket:(GCDAsyncSocket *)socket didConnect:(NSString *)host port:(uint16_t)port;
- (void)socketDidDisconnect:(GCDAsyncSocket *)socket;

@end

// socket 连接管理类
@interface SocketManager : NSObject

@property (assign, nonatomic) BOOL isAutomatic;     // 默认使用负载均衡
@property (weak, nonatomic) id<SocketManagerDelegate> delegate;

+ (SocketManager *)instance;    // 可以使用单例，也可以 alloc 一个新的临时用

- (void)connectAutomatic:(void (^)())completion;            // 负载均衡寻找服务器
- (void)connectWithIp:(NSString *)ip port:(UInt16)port;     // 手动连接服务器
- (void)disConnect;
- (void)send:(NSData *)data;
- (BOOL)status;

@end


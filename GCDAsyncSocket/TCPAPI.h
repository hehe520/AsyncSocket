//
//  TCPAPI.h
//  GCDAsyncSocket使用
//
//  Created by caokun on 16/7/2.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef void (^TCPBlock)(id response, NSString *error);

// TCP 请求接口类
@interface TCPAPI : NSObject

+ (TCPAPI *)instance;

// 登录请求，网络恢复调用该接口实现自动登录，被踢，用户主动退出登录，不能自动登录
- (void)requestLogin:(NSString *)name password:(NSString *)psw completion:(TCPBlock)block;

// 发送单个心跳包
- (void)sendHeart;

// 开启心跳，登录时开启即可，其他情况自动开启或关闭
- (void)startHeartBeat;

// 关闭心跳，退出时关闭，关闭后不会自动开启
- (void)closeHeartBeat;

// 请求股票排行版数据
- (void)requestBlockWithcompletion:(TCPBlock)block;

// 模拟收到踢人包
- (void)receiveKick;

@end


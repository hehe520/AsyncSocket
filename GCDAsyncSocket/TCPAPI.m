//
//  TCPAPI.m
//  GCDAsyncSocket使用
//
//  Created by caokun on 16/7/2.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import "TCPAPI.h"
#import "Auth.pb.h"
#import "Common.pb.h"
#import "Report.pb.h"
#import "SocketManager.h"
#import "NetWorkManager.h"

@interface TCPAPI () <SocketManagerDelegate>

@property (strong, nonatomic) dispatch_queue_t APIQueue;
@property (strong, nonatomic) dispatch_semaphore_t semaphore;       // seq 同步信号
@property (strong, nonatomic) dispatch_semaphore_t loginSem;        // 重登录同步信号
@property (assign, nonatomic) UInt32 seq;
@property (strong, nonatomic) NSMutableDictionary *callbackBlock;   // 保存请求回调 {seq: block}, 超时要踢掉
@property (strong, nonatomic) NSLock *dictionaryLock;
@property (strong, nonatomic) NSMutableData *buffer;            // 接收缓冲区
@property (strong, nonatomic) NSTimer *heartTimer;              // 心跳 timer
@property (assign, nonatomic) BOOL shouldHeart;                 // 是否要心跳
@property (assign, nonatomic) BOOL netWorkStatus;               // 网络联通性
@property (assign, nonatomic) BOOL loginStatus;                 // 登录状态, 退出，被踢, socket断开，要设为 false
@property (assign, nonatomic) BOOL autoLogin;                   // 自动登录，收到踢人包, 主动退出置为 false, 登录时 true

@end

@implementation TCPAPI

static TCPAPI *instance = nil;

+ (TCPAPI *)instance {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TCPAPI alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if (self = [super init]) {
        [[NetWorkManager instance] startListen];     // 程序启动要开启网络状态监听
        [SocketManager instance].delegate = self;       // 创建 socket
        self.semaphore = dispatch_semaphore_create(1);
        self.APIQueue = dispatch_queue_create("com.api", DISPATCH_QUEUE_SERIAL);
        self.seq = 1000;
        self.dictionaryLock = [[NSLock alloc] init];
        self.callbackBlock = [[NSMutableDictionary alloc] init];
        self.buffer = [[NSMutableData alloc] init];
        [self.buffer setLength:0];
        self.netWorkStatus = true;      // 首次运行认为有网络，因为 NetWorkManager 启动要时间，假如没网会超时返回
        self.loginStatus = false;
        self.autoLogin = true;
        self.shouldHeart = true;        // 默认开启心跳，应该要获取登录状态判断要不要心跳
        if (self.shouldHeart) {
            [self startHeartBeat];
        } else {
            [self closeHeartBeat];
        }
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(netWorkStatusChanged:) name:NetWorkDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.semaphore = nil;
    self.APIQueue = nil;
    self.buffer = nil;
}

- (UInt32)seq {
    dispatch_semaphore_wait(self.semaphore, DISPATCH_TIME_FOREVER);
    _seq = _seq + 1;
    dispatch_semaphore_signal(self.semaphore);
    
    return _seq;
}

// ----------- tcp 打包，并发送, callback 回调 block ------------
- (void)send:(rpc_msg_rootBuilder *)rootMsg seq:(UInt32)s callback:(TCPBlock)block {
    // 无网络直接返回
    if (self.netWorkStatus == false) {
        if (block) block(nil, @"无网络");
        return ;
    }
    if (self.loginStatus == false && self.autoLogin == false) {
        if (block) block(nil, @"被踢不能自动登录");
        return ;
    }
    
    // 如果不是登录包，不是心跳包, 并且没登录，可以自动登录，先自动登录，登录失败返回错误
    if ((self.loginStatus == false || [[SocketManager instance] status] == false)
        && self.autoLogin == true
        && rootMsg != nil
        && rootMsg.service != eum_rpc_serviceCommonService
        && rootMsg.method != eum_method_typeClientLogin) {
        
        NSLog(@"进入自动登录");
        self.loginSem = dispatch_semaphore_create(0);
        
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *name = [ud objectForKey:@"UserName"];
        NSString *psw = [ud objectForKey:@"Password"];
        if (name && psw) {
            [[SocketManager instance] disConnect];      // 再次断开 socket，保证没登录
            [self createLoginAndSend:name password:psw completion:^(id response, NSString *error) {
                NSLog(@"自动登录返回");
                self.loginStatus = error == nil ? true : false;
                self.autoLogin = self.loginStatus;
                
                // 重登录不解析 response，都是一样的
                dispatch_semaphore_signal(self.loginSem);
            }];
        } else {
            self.loginStatus = false;
            self.autoLogin = false;
            dispatch_semaphore_signal(self.loginSem);
        }
        // 等待重登录信号
        NSLog(@"等待重登录信号");
        dispatch_semaphore_wait(self.loginSem, DISPATCH_TIME_FOREVER);
        NSLog(@"通过重登录信号");
        if (self.loginStatus == false) {
            if (block) block(nil, @"自动登录失败, 请重新登录");    // 收到自动登录失败的，应该弹框重登录
            return ;
        } else {
            NSLog(@"自动登录成功");
        }
    }
    
    // 打包
    if (rootMsg == nil) {   // 心跳包没 body
        SInt32 length = 0;
        NSMutableData *data = [NSMutableData dataWithBytes:&length length:4];
        [[SocketManager instance] send:data];
        
        return ;
    }
    
    rpc_msg_root *root = [rootMsg build];
    
    // 包头是 32 位的整型，表示包体长度
    SInt32 length = [root serializedSize];
    NSMutableData *data = [NSMutableData dataWithBytes:&length length:4];
    [data appendData:[root data]];      // 追加包体
    
    if (block != nil) {
        // 保存回调 block 到字典里，接收时候用到
        NSString *key = [NSString stringWithFormat:@"%u", s];
        [_dictionaryLock lock];
        [_callbackBlock setObject:block forKey:key];
        [_dictionaryLock unlock];
        
        // 5 秒超时, 找到 key 删除
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self timerRemove:key];
        });
    }
    NSLog(@"通知 socket 发送数据");
    [[SocketManager instance] send:data];   // 发送
}

- (void)timerRemove:(NSString *)key {
    if (key) {
        [_dictionaryLock lock];
        TCPBlock complete = [self.callbackBlock objectForKey:key];
        if (complete != nil) {
            complete(nil, @"null");
        }
        [_callbackBlock removeObjectForKey:key];
        [_dictionaryLock unlock];
    }
}

// ----------- tcp 拆包 ------------
// 上层调用者，同步队列回调该函数，所以不用加锁
- (void)socket:(GCDAsyncSocket *)socket didReadData:(NSData *)data {
    [_buffer appendData:data];
    
    while (_buffer.length >= 4) {
        SInt32 length = 0;
        [_buffer getBytes:&length length:4];    // 读取长度
        
        if (length == 0) {
            if (_buffer.length >= 4) {          // 长度够不够心跳包
                NSData *tmp = [_buffer subdataWithRange:NSMakeRange(4, _buffer.length - 4)];
                [_buffer setLength:0];      // 清零
                [_buffer appendData:tmp];
            } else {
                [_buffer setLength:0];
            }
            [self receive:nil];    // 分发数据包
        } else {
            NSUInteger packageLength = 4 + length;
            if (packageLength <= _buffer.length) {     // 长度判断
                NSData *rootData = [_buffer subdataWithRange:NSMakeRange(4, length)];
                rpc_msg_root *root = [rpc_msg_root parseFromData:rootData];
                
                // 截取
                NSData *tmp = [_buffer subdataWithRange:NSMakeRange(packageLength, _buffer.length - packageLength)];
                [_buffer setLength:0];      // 清零
                [_buffer appendData:tmp];
                [self receive:root];    // 分发包
            } else {
                break;
            }
        }
    }
}

// 收到包进行分发
- (void)receive:(rpc_msg_root *)root {
    if (root == nil) {
        NSLog(@"收到心跳包");
        return ;
    }
    NSString *key = [NSString stringWithFormat:@"%u", root.seq];
    [_dictionaryLock lock];
    id obj = [self.callbackBlock objectForKey:key];
    [self.callbackBlock removeObjectForKey:key];
    [_dictionaryLock unlock];
    
    TCPBlock complete = nil;
    if (obj != nil) {
        complete = (TCPBlock)obj;
    }
    if (complete == nil) {
        NSLog(@"被动接收的包/超时返回的包");
        
    } else {
        NSLog(@"主动请求的包");
        switch (root.method) {
            case eum_method_typeClientLoginRet:
                [self receiveLogin:root completion:complete];
                break;
                
            case eum_method_typeReportBoardreportResult:
                [self receiveBlock:root completion:complete];
                break;
                
            default:
                NSLog(@"收到未知包 %d", (int)root.method);
                break;
        }
    }
}

// 网络状态变化
- (void)netWorkStatusChanged:(NSNotification *)nofiy {
    dispatch_async(self.APIQueue, ^{
        NSDictionary *info = nofiy.userInfo;
        if (info && info[@"status"]) {
            NSNumber *status = info[@"status"];
            self.netWorkStatus = [status boolValue];
            if (self.netWorkStatus) {
                [self tryOpenTimer];
            } else {
                [self closeTimer];
                // 网络断开，清空发送回调队列，登录状态为 false
                self.loginStatus = false;
                [self cleanSendQueue];
            }
        }
    });
}

// socket 状态变化
- (void)socket:(GCDAsyncSocket *)socket didConnect:(NSString *)host port:(uint16_t)port {
    [self tryOpenTimer];
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)socket {
    self.loginStatus = false;
    [self closeTimer];
    [self.buffer setLength:0];
}

// 清空发送队列
- (void)cleanSendQueue {
    [_dictionaryLock lock];
    NSLog(@"清空发送队列");
    for (NSString *key in self.callbackBlock) {
        TCPBlock complete = [self.callbackBlock objectForKey:key];
        if (complete != nil) {
            complete(nil, @"null");
        }
    }
    [self.callbackBlock removeAllObjects];
    [_dictionaryLock unlock];
}

// 开启心跳
- (void)startHeartBeat {
    self.shouldHeart = true;
    [self tryOpenTimer];
}

// 关闭心跳
- (void)closeHeartBeat {
    self.shouldHeart = false;
    [self closeTimer];
}

- (void)tryOpenTimer {
    // 有网，tcp登录了，并且调用层要打开心跳时，才开启心跳
    if (self.netWorkStatus && [[SocketManager instance] status] && self.shouldHeart) {
        [self sendHeart];
        [self closeTimer];
        // timer 要在主线程中开启才有效
        dispatch_async(dispatch_get_main_queue(), ^{
            self.heartTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(sendHeart) userInfo:nil repeats:true];
        });
    }
}

- (void)closeTimer {
    if (self.heartTimer != nil) {
        [self.heartTimer invalidate];
        self.heartTimer = nil;
    }
}

- (void)sendHeart {
    [self send:nil seq:self.seq callback:nil];
}

#pragma - mark 以下是请求 api
// 登录请求包
- (void)requestLogin:(NSString *)name password:(NSString *)psw completion:(TCPBlock)block {
    dispatch_async(self.APIQueue, ^{
        self.autoLogin = true;      // 主动登录，设置自动登录
        
        // 如果登录了，先下线
        if ([[SocketManager instance] status] == true) {
            [[SocketManager instance] disConnect];
        }
        // 保存用户名密码到文件，应该加密保存
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:name forKey:@"UserName"];
        [ud setObject:psw forKey:@"Password"];
        
        [self createLoginAndSend:name password:psw completion:block];
    });
}

// 创建并发送登录包
- (void)createLoginAndSend:(NSString *)name password:(NSString *)psw completion:(TCPBlock)block {
    client_login_msgBuilder *loginMsg = [client_login_msg builder];     // 二级包体
    [loginMsg setName:name];
    [loginMsg setPassword:psw];
    [loginMsg setBios:@""];
    [loginMsg setCpu:@""];
    [loginMsg setMac:@""];
    [loginMsg setHdd:@""];
    [loginMsg setIp:@""];
    [loginMsg setLtype:client_login_msglogin_typeTgMobile];
    
    rpc_msg_rootBuilder *rootMsg = [rpc_msg_root builder];      // 一级包体
    [rootMsg setService:eum_rpc_serviceCommonService];
    [rootMsg setMethod:eum_method_typeClientLogin];
    [rootMsg setBody:[[loginMsg build] data]];
    UInt32 s = self.seq;
    [rootMsg setSeq:s];
    
    [self send:rootMsg seq:s callback:block];
}

// 登录返回包
- (void)receiveLogin:(rpc_msg_root *)root completion:(TCPBlock)block {
    client_login_result_msg *result = [client_login_result_msg parseFromData:root.body];
    if ([result result]) {
        self.loginStatus = true;
        self.autoLogin = true;
        [self startHeartBeat];
        
        NSMutableDictionary *dic = [[NSMutableDictionary alloc] init];
        for (ext_key_info *info in result.ext) {
            [dic setObject:info.value forKey:info.key];
        }
        if (block) block(dic, nil);
    } else {
        self.loginStatus = false;
        self.autoLogin = false;
        if (block) block(nil, @"登录失败");
    }
}

// 请求股票名称
- (void)requestBlockWithcompletion:(TCPBlock)block {
    dispatch_async(self.APIQueue, ^{
        s_board_report_data_msgBuilder *msg = [s_board_report_data_msg builder];
        [msg setBlockCode:0];
        [msg setBlockOffset:0];
        [msg setCount:2];
        [msg setIsAsc:false];
        [msg setSortColum:colum_typeColRiseScope];
        [msg setColumArrayArray:@[@(colum_typeColRiseScope)]];
        
        rpc_msg_rootBuilder *rootMsg = [rpc_msg_root builder];      // 一级包体
        [rootMsg setService:eum_rpc_serviceReportService];
        [rootMsg setMethod:eum_method_typeReportBoardreportRequest];
        [rootMsg setBody:[[msg build] data]];
        UInt32 s = self.seq;
        [rootMsg setSeq:s];
        
        [self send:rootMsg seq:s callback:block];
    });
}

// 请求股票名称收到
- (void)receiveBlock:(rpc_msg_root *)root completion:(TCPBlock)block {
    s_borad_report_result_msg *result = [s_borad_report_result_msg parseFromData:root.body];
    if (result.datas) {
        NSMutableArray *array = [[NSMutableArray alloc] init];
        for (s_borad_report_line_data *m in result.datas) {
            [array addObject:m.code];
            for (s_board_report_colum_data_msg *m2 in m.columData) {
                [array addObject:[NSString stringWithFormat:@"%.2f", m2.value]];
            }
        }
        if (block) block(array, nil);
    } else {
        if (block) block(nil, @"未找到数据");
    }
}

// 收到踢人包
- (void)receiveKick {
    [[SocketManager instance] disConnect];
    [self closeHeartBeat];
    self.loginStatus = false;
    self.autoLogin = false;
}

@end


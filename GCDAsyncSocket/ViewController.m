//
//  ViewController.m
//  GCDAsyncSocket使用
//
//  Created by caokun on 16/5/27.
//  Copyright © 2016年 caokun. All rights reserved.
//

#import "ViewController.h"
#import "SocketManager.h"
#import "TCPAPI.h"
#import "NetWorkManager.h"
#import "SpeedDectectManager.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];

}

- (IBAction)connectButton:(id)sender {
    [[SocketManager instance] connectAutomatic:nil];       
}

- (IBAction)disconnectButton:(id)sender {
    [[SocketManager instance] disConnect];
}

- (IBAction)heart:(id)sender {
    [[TCPAPI instance] sendHeart];
}

- (IBAction)TCPLogin:(id)sender {
    // 此处 tcp 请求可以在其他线程，以0.3秒/次的速度请求，模拟网络断开或连上
    // 用户名跟密码由于是公司的账号，不敢随便公布了
    [[TCPAPI instance] requestLogin:@"用户名" password:@"密码" completion:^(id response, NSString *error) {
        if (error == nil) {
            NSDictionary *dic = (NSDictionary *)response;
            NSLog(@"%@", dic);
        } else {
            NSLog(@"登录失败");
        }
    }];
}

// 普通应用层请求
- (IBAction)requestTcp:(id)sender {
    [[TCPAPI instance] requestBlockWithcompletion:^(id response, NSString *error) {
        if (error == nil) {
            NSArray *array = (NSArray *)response;
            NSLog(@"%@", array);
        } else {
            NSLog(@"UI层：%@", error);
        }
    }];
}

// 模拟 TCPAPI 类收到踢人包
- (IBAction)kick:(id)sender {
    [[TCPAPI instance] receiveKick];
}

@end


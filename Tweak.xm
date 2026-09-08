#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>

// ============================================================
//  RingerGainEQ
//  压制"比音乐热"的铃声/通知音量曲线。
//  原理：铃声类通道(Ringtone/Alert/System/Alarm)的音量曲线在音频 HAL 里
//  比 Media 曲线整体更"热"(同一 slider 位置 dB 更高)。rootless 改不了系统
//  框架二进制, 所以在曲线入口 AVSystemController 拦截音量写入, 把铃声类的
//  存储值乘系数 k 压低, 播放时曲线吐出的 dB 跟着降, 自然和媒体拉平。
//  setter 压低存盘 + getter 回算, UI 仍显示你设的真实数字。
//  不 hook mediaserverd/audiomxd, 避免全机没声风险。
// ============================================================

// ---------- config ----------
static NSString * const kDomain  = @"com.huhansibuxin.ringergaineq";
static NSString * const kChanged = @"com.huhansibuxin.ringergaineq-updated";
static const char *kLogFile = "/var/mobile/Documents/RingerGainEQ.log";

// ---------- state ----------
static BOOL   gEnabled = YES;
static double gFactor  = 0.6;   // 压低系数: 铃声存储值 = 真实值 * k
static BOOL   gDiag    = YES;
static BOOL   gRawMode = NO;    // normalize 期间旁路缩放
static BOOL   gInSet   = NO;    // 防止 setVolumeTo 内部再调 setVolumeLevel 导致双重缩放
static BOOL   gInGet   = NO;

// original IMPs (AVSystemController 在 Celestial 私有框架, 运行时解析)
static float  (*gOrigVF)    (id, SEL, id)            = NULL; // volumeForCategory:
static BOOL   (*gOrigGetLvl)(id, SEL, float *, id)   = NULL; // getVolumeLevel:forCategory:
static void   (*gOrigSet)   (id, SEL, float, id)     = NULL; // setVolumeTo:forCategory:
static BOOL   (*gOrigSetLvl)(id, SEL, float, id)     = NULL; // setVolumeLevel:forCategory:

// ---------- prefs ----------
static id rg_pref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kDomain));
}
static void rg_setPref(NSString *key, id value) {
    CFPreferencesSetAppValue((CFStringRef)key, (__bridge CFPropertyListRef)value, (CFStringRef)kDomain);
    CFPreferencesAppSynchronize((CFStringRef)kDomain);
}
static BOOL rg_bool(NSString *key, BOOL def) {
    Boolean valid = false;
    Boolean v = CFPreferencesGetAppBooleanValue((CFStringRef)key, (CFStringRef)kDomain, &valid);
    return valid ? (BOOL)v : def;
}
static double rg_double(NSString *key, double def) {
    id v = rg_pref(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([s length] == 0) return def;
        NSScanner *sc = [NSScanner scannerWithString:s];
        double d = 0;
        if ([sc scanDouble:&d] && [sc isAtEnd]) return d;
        return def;
    }
    return def;
}
static void rg_refresh(void) {
    gEnabled = rg_bool(@"enabled", YES);
    gDiag    = rg_bool(@"diagnostic", YES);
    gFactor  = rg_double(@"suppressFactor", 0.6);
    if (gFactor < 0.1 || gFactor > 1.0) gFactor = 0.6;
}
static BOOL rg_isTarget(NSString *cat) {
    if (!cat) return NO;
    return [cat isEqualToString:@"Ringtone"] || [cat isEqualToString:@"Alert"] ||
           [cat isEqualToString:@"System"]   || [cat isEqualToString:@"Alarm"];
}
static NSString *rg_trueKey(NSString *cat) {
    return [NSString stringWithFormat:@"true_%@", cat];
}

// ---------- logging (写文件, 不用 oslog, 沙盒外固定路径) ----------
static void rg_log(NSString *fmt, ...) {
    if (!gDiag) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [RingerGainEQ] %@\n", [NSDate date], msg];
    FILE *f = fopen(kLogFile, "a");
    if (f) { fputs([line UTF8String], f); fflush(f); fclose(f); }
}

// ---------- 统一调用入口 (走 hook 后的方法, 自动遵守 gRawMode) ----------
static float rg_callGet(id avsc, NSString *cat) {
    if (gOrigVF) {
        typedef float (*ft)(id, SEL, id);
        static SEL s = NULL; if (!s) s = @selector(volumeForCategory:);
        return ((ft)objc_msgSend)(avsc, s, cat);
    } else if (gOrigGetLvl) {
        typedef BOOL (*ft)(id, SEL, float *, id);
        static SEL s = NULL; if (!s) s = @selector(getVolumeLevel:forCategory:);
        float lv = 0; ((ft)objc_msgSend)(avsc, s, &lv, cat); return lv;
    }
    return 0;
}
static void rg_callSet(id avsc, float v, NSString *cat) {
    if (gOrigSet) {
        typedef void (*ft)(id, SEL, float, id);
        static SEL s = NULL; if (!s) s = @selector(setVolumeTo:forCategory:);
        ((ft)objc_msgSend)(avsc, s, v, cat);
    } else if (gOrigSetLvl) {
        typedef BOOL (*ft)(id, SEL, float, id);
        static SEL s = NULL; if (!s) s = @selector(setVolumeLevel:forCategory:);
        ((ft)objc_msgSend)(avsc, s, v, cat);
    }
}

// ---------- hooks ----------
static float rg_volumeForCategory(id self, SEL _cmd, NSString *cat) {
    float v = gOrigVF(self, _cmd, cat);
    if (gRawMode || !gEnabled || !rg_isTarget(cat)) return v;
    if (gInGet) return v;
    gInGet = YES;
    float out = v / (float)gFactor;
    rg_log(@"GET  cat=%-8s raw=%.4f shown=%.4f k=%.3f", [cat UTF8String], v, out, gFactor);
    gInGet = NO;
    return out;
}
static BOOL rg_getVolumeLevel(id self, SEL _cmd, float *level, NSString *cat) {
    BOOL r = gOrigGetLvl(self, _cmd, level, cat);
    if (gRawMode || !gEnabled || !rg_isTarget(cat) || !level) return r;
    if (gInGet) return r;
    gInGet = YES;
    *level = *level / (float)gFactor;
    rg_log(@"GETL cat=%-8s raw=%.4f shown=%.4f k=%.3f", [cat UTF8String], *level, *level, gFactor);
    gInGet = NO;
    return r;
}
static void rg_setVolumeTo(id self, SEL _cmd, float v, NSString *cat) {
    if (gRawMode || !gEnabled || !rg_isTarget(cat)) { gOrigSet(self, _cmd, v, cat); return; }
    if (gInSet) { gOrigSet(self, _cmd, v, cat); return; }
    gInSet = YES;
    rg_setPref(rg_trueKey(cat), @(v));
    float store = v * (float)gFactor;
    rg_log(@"SET  cat=%-8s raw=%.4f store=%.4f k=%.3f", [cat UTF8String], v, store, gFactor);
    gOrigSet(self, _cmd, store, cat);
    gInSet = NO;
}
static BOOL rg_setVolumeLevel(id self, SEL _cmd, float v, NSString *cat) {
    if (gRawMode || !gEnabled || !rg_isTarget(cat)) { return gOrigSetLvl(self, _cmd, v, cat); }
    if (gInSet) { return gOrigSetLvl(self, _cmd, v, cat); }
    gInSet = YES;
    rg_setPref(rg_trueKey(cat), @(v));
    float store = v * (float)gFactor;
    rg_log(@"SETL cat=%-8s raw=%.4f store=%.4f k=%.3f", [cat UTF8String], v, store, gFactor);
    BOOL r = gOrigSetLvl(self, _cmd, store, cat);
    gInSet = NO;
    return r;
}

// ---------- 归一化: 让效果立即生效, 无需手动重拖音量 (且避免每次 respring 双重缩放) ----------
static void rg_normalize(void) {
    if ((!gOrigVF && !gOrigGetLvl) || (!gOrigSet && !gOrigSetLvl)) {
        rg_log(@"normalize skipped: no AVSystemController volume hooks");
        return;
    }
    Class c = NSClassFromString(@"AVSystemController");
    if (!c) { rg_log(@"normalize skipped: AVSystemController class missing"); return; }
    id avsc = [c performSelector:@selector(sharedAVSystemController)];
    if (!avsc) { rg_log(@"normalize skipped: sharedAVSystemController nil"); return; }

    gRawMode = YES;
    NSArray *cats = @[@"Ringtone", @"Alert", @"System", @"Alarm"];
    for (NSString *cat in cats) {
        float S = rg_callGet(avsc, cat);   // 原始存储值 (gRawMode 旁路)
        if (gEnabled) {
            id m = rg_pref(rg_trueKey(cat));
            float T = ([m isKindOfClass:[NSNumber class]]) ? [m floatValue] : S;
            rg_setPref(rg_trueKey(cat), @(T));          // 记住真实值, 供后续恢复/防双重缩放
            rg_callSet(avsc, T * (float)gFactor, cat);    // 写回压低后的值
        } else {
            id m = rg_pref(rg_trueKey(cat));
            if (m) {
                rg_callSet(avsc, [m floatValue], cat);    // 恢复真实值
                CFPreferencesSetAppValue((CFStringRef)rg_trueKey(cat), NULL, (CFStringRef)kDomain);
                CFPreferencesAppSynchronize((CFStringRef)kDomain);
            }
        }
    }
    gRawMode = NO;
    rg_log(@"normalize done enabled=%d factor=%.3f", gEnabled, gFactor);
}

// ---------- 设置变更 Darwin 通知回调 (必须是 C 函数指针, 非 block) ----------
static void rg_notifCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *obj, CFDictionaryRef info) {
    rg_refresh();
    // Darwin 回调不在主线程, normalize 调 AVSystemController 需回主队列
    dispatch_async(dispatch_get_main_queue(), ^{
        rg_normalize();
    });
}

// ---------- ctor ----------
%ctor {
    rg_refresh();
    Class c = NSClassFromString(@"AVSystemController");
    if (c) {
        SEL gs = @selector(volumeForCategory:);
        SEL gl = @selector(getVolumeLevel:forCategory:);
        SEL ss = @selector(setVolumeTo:forCategory:);
        SEL sl = @selector(setVolumeLevel:forCategory:);
        if ([c instancesRespondToSelector:gs]) MSHookMessageEx(c, gs, (IMP)rg_volumeForCategory, (IMP*)&gOrigVF);
        if ([c instancesRespondToSelector:gl]) MSHookMessageEx(c, gl, (IMP)rg_getVolumeLevel,    (IMP*)&gOrigGetLvl);
        if ([c instancesRespondToSelector:ss]) MSHookMessageEx(c, ss, (IMP)rg_setVolumeTo,        (IMP*)&gOrigSet);
        if ([c instancesRespondToSelector:sl]) MSHookMessageEx(c, sl, (IMP)rg_setVolumeLevel,     (IMP*)&gOrigSetLvl);
    }
    rg_log(@"ctor enabled=%d factor=%.3f diag=%d VF=%d GET=%d SET=%d SETL=%d",
           gEnabled, gFactor, gDiag, gOrigVF!=NULL, gOrigGetLvl!=NULL, gOrigSet!=NULL, gOrigSetLvl!=NULL);

    // 设置变更通知 (Darwin notify, 跨进程)
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        rg_notifCallback,
        (CFStringRef)kChanged, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    // 延迟 2s, 确保 AVSystemController 已初始化
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        rg_normalize();
    });
}

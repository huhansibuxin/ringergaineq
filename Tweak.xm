#import <Foundation/Foundation.h>
#import <substrate.h>
#import <objc/runtime.h>
#include <dlfcn.h>

// ============================================================
//  RingerGainEQ v2.0.0
//  压制"比音乐热"的铃声/通知音量曲线。
//  v1 失败复盘: 压了 setVolumeTo:forCategory: 的值但播放无变化。
//  两个嫌疑(v1 都是猜的):
//   (A) roothide 下 CFPreferences/NSUserDefaults suiteName 读不到 jbroot 写的设置
//       -> gFactor 停在默认 0.6, 用户改 0.1 等于没改
//   (B) setVolumeTo:forCategory: 根本不是系统写/读铃声音量的真路径
//       (Settings 改音量可能直接写 plist, 不进 AVSystemController)
//  v2 改法:
//   * 设置读取改走 jbroot 文件直读(dladdr 自定位 jbroot + initWithContentsOfFile)
//     掐死嫌疑(A); 写入也直写文件, 跨进程必可见
//   * %ctor 运行时枚举 AVSystemController 全部 *olume* 方法, 对每个
//     (void)setXxx:(float)forCategory:(NSString*) 签名的 setter 都 hook 压低
//     -> 谁才是真路径, 日志里一目了然, 不再猜 selector
//   * 每次 SET 顺带打印系统 RingtoneVolume(CFPreferences com.apple.preferences.sounds),
//     确认我的写入有没有进系统存储(掐死嫌疑 B)
//  日志写 /var/mobile/Documents/RingerGainEQ.log (SB 沙盒内视角, 固定)
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
static BOOL   gInSet   = NO;    // 防 setVolumeTo 内部再调其它 setter 导致双重缩放
static CFMutableDictionaryRef gOrigMap = NULL;  // selName(NSString) -> 原 IMP(void*)
static SEL    gFirstSetterSel = NULL;            // normalize 用的首个已 hook setter

// ---------- jbroot 定位 (roothide 跨进程读设置铁律) ----------
static NSString *rg_jbroot(void) {
    Dl_info info;
    if (dladdr((const void*)&rg_jbroot, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        // dylib 路径形如 <jbroot>/usr/lib/TweakInject/RingerGainEQ.dylib
        NSRange r = [path rangeOfString:@"/usr/lib/TweakInject/"];
        if (r.location != NSNotFound) return [path substringToIndex:r.location];
    }
    return @"";
}
static NSString *rg_prefsPath(void) {
    return [NSString stringWithFormat:@"%@/var/mobile/Library/Preferences/%@.plist", rg_jbroot(), kDomain];
}

// ---------- prefs (jbroot 文件直读 + CFPreferences 兜底) ----------
static id rg_pref(NSString *key) {
    NSString *path = rg_prefsPath();
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
    id v = d ? d[key] : nil;
    if (v) return v;
    return CFBridgingRelease(CFPreferencesCopyAppValue((CFStringRef)key, (CFStringRef)kDomain));
}
static void rg_setPref(NSString *key, id value) {
    // 主: 直写 jbroot plist 文件 (跨进程必可见)
    NSString *path = rg_prefsPath();
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!d) d = [NSMutableDictionary dictionary];
    if (value) d[key] = value; else [d removeObjectForKey:key];
    [d writeToFile:path atomically:YES];
    // 兜底: CFPreferences
    CFPreferencesSetAppValue((CFStringRef)key, (__bridge CFPropertyListRef)value, (CFStringRef)kDomain);
    CFPreferencesAppSynchronize((CFStringRef)kDomain);
}
static BOOL rg_bool(NSString *key, BOOL def) {
    Boolean valid = false;
    Boolean v = CFPreferencesGetAppBooleanValue((CFStringRef)key, (CFStringRef)kDomain, &valid);
    if (valid) return (BOOL)v;
    id m = rg_pref(key);
    if ([m isKindOfClass:[NSNumber class]]) return [m boolValue];
    return def;
}
static double rg_double(NSString *key, double def) {
    id v = rg_pref(key);
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([s length]) { NSScanner *sc = [NSScanner scannerWithString:s]; double dd = 0;
                          if ([sc scanDouble:&dd] && [sc isAtEnd]) return dd; }
    }
    return def;
}
static void rg_refresh(void) {
    gEnabled = rg_bool(@"enabled", YES);
    gDiag    = rg_bool(@"diagnostic", YES);
    gFactor  = rg_double(@"suppressFactor", 0.6);
    if (gFactor < 0.05 || gFactor > 1.0) gFactor = 0.6;
}
static BOOL rg_isTarget(NSString *cat) {
    if (!cat) return NO;
    return [cat isEqualToString:@"Ringtone"] || [cat isEqualToString:@"Alert"] ||
           [cat isEqualToString:@"System"]   || [cat isEqualToString:@"Alarm"] ||
           [cat isEqualToString:@"PhoneCall"] || [cat isEqualToString:@"RingtoneVibration"];
}
static NSString *rg_trueKey(NSString *cat) {
    return [NSString stringWithFormat:@"true_%@", cat];
}

// ---------- logging ----------
static void rg_log(NSString *fmt, ...) {
    if (!gDiag) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [RGEQ] %@\n", [NSDate date], msg];
    FILE *f = fopen(kLogFile, "a");
    if (f) { fputs([line UTF8String], f); fflush(f); fclose(f); }
}

// ---------- 通用 setter 替换: 压低目标类别 ----------
static void rg_repl(id self, SEL _cmd, float v, NSString *cat) {
    NSString *selName = NSStringFromSelector(_cmd);
    void (*orig)(id, SEL, float, NSString*) =
        (void(*)(id,SEL,float,NSString*))CFDictionaryGetValue(gOrigMap, (__bridge CFStringRef)selName);
    if (gRawMode) { if (orig) orig(self, _cmd, v, cat); return; }   // normalize 旁路
    if (!orig)    { return; }
    if (gInSet)   { orig(self, _cmd, v, cat); return; }            // 重入守卫
    if (!rg_isTarget(cat)) { orig(self, _cmd, v, cat); return; }

    gInSet = YES;
    rg_setPref(rg_trueKey(cat), @(v));          // 记住未压缩的真实值
    float store = v * (float)gFactor;
    // 顺带读系统 RingtoneVolume, 确认我的写入有没有进系统存储
    float sysRinger = -1;
    CFPropertyListRef rp = CFPreferencesCopyValue((CFStringRef)@"RingtoneVolume",
                 (CFStringRef)@"com.apple.preferences.sounds",
                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (rp) {
        if (CFGetTypeID(rp) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)rp, kCFNumberFloatType, &sysRinger);
        CFRelease(rp);
    }
    if (gDiag) rg_log(@"SET %@ cat=%@ raw=%.4f store=%.4f k=%.3f sysRinger=%.4f",
                     selName, cat, v, store, gFactor, sysRinger);
    orig(self, _cmd, store, cat);
    gInSet = NO;
}

// ---------- 枚举 AVSystemController 全部 volume setter 并 hook ----------
static void rg_hookAVSC(void) {
    Class c = NSClassFromString(@"AVSystemController");
    if (!c) { rg_log(@"rg_hookAVSC: class not loaded yet, retry later"); return; }
    unsigned int n = 0;
    Method *ml = class_copyMethodList(c, &n);
    for (unsigned i = 0; i < n; i++) {
        SEL sel = method_getName(ml[i]);
        NSString *name = NSStringFromSelector(sel);
        if ([name rangeOfString:@"olume" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        rg_log(@"AVSC-method %@", name);
        unsigned int argc = method_getNumberOfArguments(ml[i]);
        if (argc != 4) continue;                       // 仅处理 2 参数实例方法
        char t0[64], t1[64];
        method_getArgumentType(ml[i], 2, t0, 64);
        method_getArgumentType(ml[i], 3, t1, 64);
        if (strcmp(t0, "f") != 0) continue;            // 第1参 float
        if (strcmp(t1, "@") != 0) continue;            // 第2参 id(NSString*)
        if (![name hasPrefix:@"set"]) continue;        // 仅 hook setter
        if (CFDictionaryGetValue(gOrigMap, (__bridge CFStringRef)name)) continue; // 已 hook
        IMP orig = NULL;
        MSHookMessageEx(c, sel, (IMP)rg_repl, &orig);
        if (orig) {
            CFDictionarySetValue(gOrigMap, (__bridge CFStringRef)name, (const void*)orig);
            if (!gFirstSetterSel) gFirstSetterSel = sel;
            rg_log(@"AVSC-hooked %@", name);
        }
    }
    free(ml);
}

// ---------- 调原 setter (arm64 下必须用 typed 函数指针, 不能直接 objc_msgSend 传 float) ----------
static void rg_callOrigSetter(id avsc, SEL sel, float val, NSString *cat) {
    NSString *nm = NSStringFromSelector(sel);
    void (*fn)(id,SEL,float,NSString*) =
        (void(*)(id,SEL,float,NSString*))CFDictionaryGetValue(gOrigMap, (__bridge CFStringRef)nm);
    if (fn) fn(avsc, sel, val, cat);
}

// ---------- 归一化: 改系数/respring 后, 用已记真实值立即重压所有目标类别 ----------
static void rg_normalize(void) {
    Class c = NSClassFromString(@"AVSystemController");
    if (!c) { rg_log(@"normalize skipped: class missing"); return; }
    id avsc = [c performSelector:@selector(sharedAVSystemController)];
    if (!avsc) { rg_log(@"normalize skipped: shared nil"); return; }
    if (!gFirstSetterSel) { rg_log(@"normalize skipped: no setter hooked"); return; }

    gRawMode = YES;
    NSArray *cats = @[@"Ringtone", @"Alert", @"System", @"Alarm", @"PhoneCall"];
    for (NSString *cat in cats) {
        id m = rg_pref(rg_trueKey(cat));
        if (gEnabled) {
            if (m) {
                float T = [m floatValue];
                rg_callOrigSetter(avsc, gFirstSetterSel, T*(float)gFactor, cat);
                rg_log(@"normalize reapply %@ true=%.4f store=%.4f k=%.3f", cat, T, T*(float)gFactor, gFactor);
            }
        } else {
            if (m) {
                rg_callOrigSetter(avsc, gFirstSetterSel, [m floatValue], cat);
                rg_setPref(rg_trueKey(cat), nil);
            }
        }
    }
    gRawMode = NO;
}

// ---------- 设置变更 Darwin 通知回调 (必须是 C 函数指针) ----------
static void rg_notifCallback(CFNotificationCenterRef center, void *observer,
                             CFStringRef name, const void *obj, CFDictionaryRef info) {
    rg_refresh();
    dispatch_async(dispatch_get_main_queue(), ^{ rg_normalize(); });
}

// ---------- ctor ----------
%ctor {
    gOrigMap = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, NULL);
    rg_refresh();

    // prefs 路径自检 (排查 roothide 跨进程读)
    NSString *pp = rg_prefsPath();
    rg_log(@"ctor jbroot=%@ prefsPath=%@ fileExists=%d enabled=%d factor=%.3f diag=%d",
           rg_jbroot(), pp, [[NSFileManager defaultManager] fileExistsAtPath:pp],
           gEnabled, gFactor, gDiag);

    // 枚举 + hook (类可能尚未加载, 延迟重试)
    rg_hookAVSC();
    if (CFDictionaryGetCount(gOrigMap) == 0) {
        for (int k = 1; k <= 3; k++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(k * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ rg_hookAVSC(); });
        }
    }

    // 设置变更通知 (Darwin notify, 跨进程)
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        rg_notifCallback, (CFStringRef)kChanged, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    // 延迟 2s 归一化 (确保 AVSystemController 已初始化 + 类已加载)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ rg_normalize(); });
}

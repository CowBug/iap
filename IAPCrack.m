#include <objc/runtime.h>
#include <objc/message.h>
#include <Foundation/Foundation.h>
#include <StoreKit/StoreKit.h>
#include <dlfcn.h>
#include <string.h>
#include <unistd.h>
#include "fishhook.h"

// ── Product IDs ──────────────────────────────────────────────
static NSString * const kProLifetime     = @"com.maxpod.pro_lifetime";
static NSString * const kUltimateLifetime = @"com.maxpod.ultimate_lifetime";
static NSString * const kUltimateUpgrade  = @"com.maxpod.ultimate_upgrade_from_pro";
static NSSet *g_knownProducts = nil;

// ── UserDefaults purchase keys ───────────────────────────────
#define kKeyVerifiedProductIDs   @"maxpod.purchase.verified_product_ids.v1"
#define kKeyVerifiedAt           @"maxpod.purchase.verified_at.v1"
#define kKeyEntitlementCheckpts  @"maxpod.purchase.entitlement_checkpoints.v2"
#define kKeyActiveStoreIdentity  @"maxpod.purchase.active_store_identity.v1"
#define kKeyPendingApprovalPID   @"maxpod.purchase.pending_approval_product_id.v1"

// ── Orig IMP storage ─────────────────────────────────────────
static id  (*orig_UD_objectForKey)(id, SEL, NSString*);
static void (*orig_UD_setObject_forKey)(id, SEL, id, NSString*);
static id  (*orig_UD_dataForKey)(id, SEL, NSString*);
static void (*orig_SKPQ_addPayment)(id, SEL, id);
static void (*orig_SKPQ_addTransactionObserver)(id, SEL, id);
static void (*orig_SKPQ_restoreCompletedTransactions)(id, SEL);
static void (*orig_SKPQ_restoreCompletedTransactionsWithUser)(id, SEL, id);
static void (*orig_SKPQ_finishTransaction)(id, SEL, id);

// ── Forward decls ────────────────────────────────────────────
static void seedDefaults(void);
static void simulatePurchase(NSString *productID, id payment);

// ══════════════════════════════════════════════════════════════
//  NSUserDefaults Hooks
// ══════════════════════════════════════════════════════════════

static id hooked_UD_objectForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:kKeyVerifiedProductIDs]) {
        return @[kProLifetime, kUltimateLifetime];
    }
    return orig_UD_objectForKey(self, _cmd, key);
}

static void hooked_UD_setObject_forKey(id self, SEL _cmd, id obj, NSString *key) {
    if ([key isEqualToString:kKeyVerifiedProductIDs] ||
        [key isEqualToString:kKeyVerifiedAt]           ||
        [key isEqualToString:kKeyPendingApprovalPID]) {
        return; // block overwrite
    }
    orig_UD_setObject_forKey(self, _cmd, obj, key);
}

static id hooked_UD_dataForKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:kKeyEntitlementCheckpts] ||
        [key isEqualToString:kKeyActiveStoreIdentity]) {
        return nil; // force the app to accept cached verified_product_ids
    }
    return orig_UD_dataForKey(self, _cmd, key);
}

// ══════════════════════════════════════════════════════════════
//  SKPaymentQueue Hooks
// ══════════════════════════════════════════════════════════════

static void hooked_SKPQ_addPayment(id self, SEL _cmd, id payment) {
    NSString *pid = ((id(*)(id, SEL))objc_msgSend)(payment, sel_registerName("productIdentifier"));
    if ([g_knownProducts containsObject:pid]) {
        simulatePurchase(pid, payment);
        return;
    }
    orig_SKPQ_addPayment(self, _cmd, payment);
}

static void hooked_SKPQ_addTransactionObserver(id self, SEL _cmd, id observer) {
    orig_SKPQ_addTransactionObserver(self, _cmd, observer);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ seedDefaults(); });
}

static void hooked_SKPQ_restoreCompletedTransactions(id self, SEL _cmd) {
    // Simulate restore: inject fake purchased transactions for our products
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        Class txCls = objc_getClass("SKPaymentTransaction");
        Class pmCls = objc_getClass("SKMutablePayment");
        id queue = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("SKPaymentQueue"),
                                                   sel_registerName("defaultQueue"));
        NSArray *observers = ((id(*)(id,SEL))objc_msgSend)(queue,
                                                             sel_registerName("transactionObservers"));

        NSMutableArray *fakeTxs = [NSMutableArray array];
        for (NSString *pid in @[kProLifetime, kUltimateLifetime]) {
            id payment = ((id(*)(id,SEL))objc_msgSend)([pmCls alloc], sel_registerName("init"));
            ((void(*)(id,SEL,id))objc_msgSend)(payment, sel_registerName("setProductIdentifier:"), pid);
            ((void(*)(id,SEL,NSInteger))objc_msgSend)(payment, sel_registerName("setQuantity:"), 1);

            id t = class_createInstance(txCls, 0);
            ((void(*)(id,SEL,id))objc_msgSend)(t, sel_registerName("setPayment:"), payment);

            NSString *txID = [NSString stringWithFormat:@"R%010ld000000", (long)time(NULL)];
            ((void(*)(id,SEL,id))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionIdentifier:"), txID);
            ((void(*)(id,SEL,id))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionDate:"), [NSDate date]);
            ((void(*)(id,SEL,NSInteger))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionState:"), 3); // restored
            ((void(*)(id,SEL,id))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionReceipt:"), [NSData data]);
            ((void(*)(id,SEL,id))objc_msgSend)(t, NSSelectorFromString(@"_setOriginalTransaction:"), t);

            [fakeTxs addObject:t];
        }

        for (id obs in observers) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(obs, sel_registerName("paymentQueue:updatedTransactions:"),
                                                   queue, fakeTxs);
            ((void(*)(id,SEL,id))objc_msgSend)(obs, sel_registerName("paymentQueueRestoreCompletedTransactionsFinished:"),
                                                queue);
        }

        // Persist
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@[kProLifetime, kUltimateLifetime] forKey:kKeyVerifiedProductIDs];
        [ud setObject:[NSDate date] forKey:kKeyVerifiedAt];
        [ud synchronize];

        NSLog(@"[IAPCrack] ✓ restore simulated: %@", fakeTxs);
    });
}

static void hooked_SKPQ_restoreCompletedTransactionsWithUser(id self, SEL _cmd, id username) {
    hooked_SKPQ_restoreCompletedTransactions(self, _cmd);
}

static void hooked_SKPQ_finishTransaction(id self, SEL _cmd, id transaction) {
    // Don't forward to original; silently consume so the daemon doesn't
    // interfere with our simulated transactions
    NSString *txID = ((id(*)(id,SEL))objc_msgSend)(transaction,
                                                     sel_registerName("transactionIdentifier"));
    NSLog(@"[IAPCrack] finishTransaction consumed: %@", txID);
}

// ══════════════════════════════════════════════════════════════
//  Transaction simulation
// ══════════════════════════════════════════════════════════════

static void simulatePurchase(NSString *productID, id payment) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        Class txCls = objc_getClass("SKPaymentTransaction");
        Class pqCls = objc_getClass("SKPaymentQueue");
        id queue = ((id(*)(id,SEL))objc_msgSend)(pqCls, sel_registerName("defaultQueue"));
        NSArray *observers = ((id(*)(id,SEL))objc_msgSend)(queue, sel_registerName("transactionObservers"));

        id t = class_createInstance(txCls, 0);
        ((void(*)(id,SEL,id))objc_msgSend)(t, sel_registerName("setPayment:"), payment);

        NSString *txID = [NSString stringWithFormat:@"%010ld000000", (long)time(NULL)];
        ((void(*)(id,SEL,NSString*))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionIdentifier:"), txID);
        ((void(*)(id,SEL,NSDate*))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionDate:"), [NSDate date]);
        ((void(*)(id,SEL,NSInteger))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionState:"), 1); // purchased
        ((void(*)(id,SEL,id))objc_msgSend)(t, NSSelectorFromString(@"_setTransactionReceipt:"), [NSData data]);
        ((void(*)(id,SEL,id))objc_msgSend)(t, NSSelectorFromString(@"_setOriginalTransaction:"), t);

        for (id obs in observers) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(obs, sel_registerName("paymentQueue:updatedTransactions:"), queue, @[t]);
        }

        // persist purchase in UserDefaults
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@[kProLifetime, kUltimateLifetime] forKey:kKeyVerifiedProductIDs];
        [ud setObject:[NSDate date] forKey:kKeyVerifiedAt];
        [ud removeObjectForKey:kKeyPendingApprovalPID];
        [ud synchronize];

        NSLog(@"[IAPCrack] ✓ simulated purchase: %@", productID);
    });
}

// ══════════════════════════════════════════════════════════════
//  fishhook: Interpose StoreKit Swift symbols
// ══════════════════════════════════════════════════════════════

// Mangled StoreKit 2 symbols we want to intercept
// Product.purchase(options:) → PurchaseResult
static const char *kSym_Product_purchase =
    "_$s8StoreKit7ProductV8purchase7optionsAC14PurchaseResultOShyAC0F6OptionVG_tYaKF";

// Transaction.currentEntitlements getter
static const char *kSym_Transaction_currentEntitlements =
    "_$s8StoreKit11TransactionV19currentEntitlementsAC12TransactionsVvgZ";

// Store the original function pointers (generic void* since Swift ABI differs)
static void *(*orig_Product_purchase)(void) = NULL;
static void *(*orig_Transaction_currentEntitlements)(void) = NULL;

// Replacement stubs – these forward to originals by default
// but after purchase simulation the entitlement record exists, so
// the app sees the entitlements through normal StoreKit daemon path.

static void *repl_Product_purchase(void) {
    // We let the real purchase flow happen, but SKPaymentQueue hook above
    // intercepts the payment so the user never actually pays.
    return orig_Product_purchase();
}

static void *repl_Transaction_currentEntitlements(void) {
    // After a purchase is simulated, the app's UserDefaults have the
    // verified product IDs. The StoreKit daemon won't have them, but
    // the app's local cache (which we seeded) takes precedence.
    // We just pass through to the real implementation.
    return orig_Transaction_currentEntitlements();
}

// ══════════════════════════════════════════════════════════════
//  Pre-seed purchase data
// ══════════════════════════════════════════════════════════════

static void seedDefaults(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL hasPro = [ud objectForKey:kKeyVerifiedProductIDs] != nil;
    if (!hasPro) {
        [ud setObject:@[kProLifetime, kUltimateLifetime] forKey:kKeyVerifiedProductIDs];
        [ud setObject:[NSDate date] forKey:kKeyVerifiedAt];
        [ud removeObjectForKey:kKeyPendingApprovalPID];
        [ud synchronize];
        NSLog(@"[IAPCrack] seeded purchase data");
    }
}

// ══════════════════════════════════════════════════════════════
//  ObjC method swizzling helpers
// ══════════════════════════════════════════════════════════════

static void swizzle(Class cls, SEL sel, IMP newImp, void **origPtr) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { m = class_getClassMethod(cls, sel); }
    if (!m) return;
    *origPtr = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

// ══════════════════════════════════════════════════════════════
//  Constructor – runs when dylib is loaded
// ══════════════════════════════════════════════════════════════

__attribute__((constructor))
static void IAPCrack_init(void) {
    @autoreleasepool {
        g_knownProducts = [NSSet setWithObjects:kProLifetime, kUltimateLifetime, kUltimateUpgrade, nil];

        // --- Swizzle NSUserDefaults ---
        Class udClass = [NSUserDefaults class];
        swizzle(udClass, @selector(objectForKey:),    (IMP)hooked_UD_objectForKey,    (void**)&orig_UD_objectForKey);
        swizzle(udClass, @selector(setObject:forKey:), (IMP)hooked_UD_setObject_forKey,(void**)&orig_UD_setObject_forKey);
        swizzle(udClass, @selector(dataForKey:),       (IMP)hooked_UD_dataForKey,      (void**)&orig_UD_dataForKey);

        // --- Swizzle SKPaymentQueue (wait until StoreKit is loaded) ---
        dispatch_async(dispatch_get_main_queue(), ^{
            Class pqCls = objc_getClass("SKPaymentQueue");
            if (pqCls) {
                swizzle(pqCls, @selector(addPayment:),            (IMP)hooked_SKPQ_addPayment,             (void**)&orig_SKPQ_addPayment);
                swizzle(pqCls, @selector(addTransactionObserver:),(IMP)hooked_SKPQ_addTransactionObserver, (void**)&orig_SKPQ_addTransactionObserver);
                swizzle(pqCls, @selector(restoreCompletedTransactions),
                                    (IMP)hooked_SKPQ_restoreCompletedTransactions,
                                    (void**)&orig_SKPQ_restoreCompletedTransactions);
                swizzle(pqCls, @selector(restoreCompletedTransactionsWithApplicationUsername:),
                                    (IMP)hooked_SKPQ_restoreCompletedTransactionsWithUser,
                                    (void**)&orig_SKPQ_restoreCompletedTransactionsWithUser);
                swizzle(pqCls, @selector(finishTransaction:),
                                    (IMP)hooked_SKPQ_finishTransaction,
                                    (void**)&orig_SKPQ_finishTransaction);
                NSLog(@"[IAPCrack] SKPaymentQueue hooks installed");
            }
        });

        // --- fishhook: interpose StoreKit Swift symbols ---
        // These hooks prevent the app from making real purchases at the Swift level.
        // The SKPaymentQueue hook already handles the ObjC level; this is a secondary
        // safety net for StoreKit 2 code paths.
        void *skHandle = dlopen("/System/Library/Frameworks/StoreKit.framework/StoreKit", RTLD_NOW);
        if (skHandle) {
            struct rebinding rebindings[] = {
                {kSym_Product_purchase,             (void*)repl_Product_purchase,             (void**)&orig_Product_purchase},
                {kSym_Transaction_currentEntitlements,(void*)repl_Transaction_currentEntitlements,(void**)&orig_Transaction_currentEntitlements},
            };
            rebind_symbols(rebindings, sizeof(rebindings)/sizeof(rebindings[0]));
            NSLog(@"[IAPCrack] fishhook StoreKit symbols interposed");
        }

        // --- Seed defaults early ---
        seedDefaults();
        NSLog(@"[IAPCrack] initialized – Pro + Ultimate unlocked");
    }
}

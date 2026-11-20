#import "SCSwizzle.h"

IMP SCSwizzle(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector || !replacement) return NULL;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;
    IMP original = method_getImplementation(method);
    // Inherited only: add an override so the superclass (and its other subclasses) are left alone.
    if (class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) return original;
    return method_setImplementation(method, replacement);
}

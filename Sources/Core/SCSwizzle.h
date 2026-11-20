#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// Replaces the implementation of `selector` on `cls` (the class's own method, added from a superclass's
// when the class only inherits it) and answers the previous one. NULL when the class or method is missing.
IMP SCSwizzle(Class cls, SEL selector, IMP replacement);

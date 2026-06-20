// iOS-Simulator-only link stubs.
//
// mbgl-core's Metal renderer (`mtl.cpp`) has static initializers that reference two
// device-only Metal error-domain string constants — `MTLIOErrorDomain` and
// `MTLTensorDomain` — which exist in the iphoneos Metal SDK but are ABSENT from the
// iphonesimulator Metal stub library. Linking the core dylib for the Simulator
// therefore fails with "Undefined symbols ... _MTLIOErrorDomain / _MTLTensorDomain",
// and mbgl links Metal strongly itself (cmake/metal.cmake), so `-weak_framework Metal`
// can't relax it.
//
// mbgl never actually USES MTLIO or MTLTensor for rendering — it only captures these
// domain constants — so providing local definitions on the Simulator is harmless and
// lets the dylib link. On a device this file is empty (the real SDK constants are used).
// Apple-Silicon Simulators run a real host-GPU-backed Metal, so with this stub the core
// renders in the Simulator too. The symbols use C linkage to match mbgl's references and
// are non-const to guarantee external linkage.
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
extern "C" {
NSString *MTLIOErrorDomain = @"MTLIOErrorDomain";
NSString *MTLTensorDomain = @"MTLTensorDomain";
}
#endif

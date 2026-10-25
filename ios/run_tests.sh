#!/bin/bash
# Wrapper: Swift 6.1 toolchain para testear KawaNavProtocol en Linux
export SWIFT=/opt/data/cache/scratch/swift/swift-6.1-RELEASE-ubuntu24.04/usr
export LD_LIBRARY_PATH=/opt/data/cache/scratch/swiftdl/libshim:$SWIFT/lib:$SWIFT/lib/swift:$SWIFT/lib/swift/linux:/usr/lib/x86_64-linux-gnu
export PATH=$SWIFT/bin:$PATH
cd /opt/data/cache/scratch/kawa-nav/ios
swift test "$@"

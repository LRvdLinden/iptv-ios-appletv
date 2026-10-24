import Foundation
import Darwin

/// Build 147: momentopname van de stack van de hoofdthread, gemaakt door de bewaking (eigen thread) als de hoofdthread
/// vastzit. Werkwijze zoals crashreporters: de hoofdthread heel even stilzetten (`thread_suspend`), de registers lezen
/// (`thread_get_state`) en de frame-pointerketen volgen met `vm_read_overwrite` (veilig lezen, nooit een crash bij een
/// kapotte keten), daarna meteen weer verder laten gaan (`thread_resume`). Tussen stilzetten en verder gaan wordt niets
/// gealloceerd of vergrendeld (de hoofdthread kan een lock vasthouden); symbolen (`dladdr`) pas daarna.
/// Alleen code-adressen en symboolnamen, geen gegevens van de gebruiker.
enum MainThreadSampler {
    private static let maxFrames = 40
    nonisolated(unsafe) private static var mainPort: mach_port_t = 0

    /// Op de hoofdthread aanroepen (zo vroeg mogelijk); anders op de hoofdthread ingepland.
    static func captureMainThread() {
        if Thread.isMainThread {
            mainPort = mach_thread_self()
        } else {
            DispatchQueue.main.async { mainPort = mach_thread_self() }
        }
    }

    /// Gesymboliseerde regels (max. 40), leeg als het niet lukt. Niet op de hoofdthread aanroepen.
    static func sample() -> [String] {
        guard !Thread.isMainThread, mainPort != 0 else { return [] }
        let buf = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
        let pair = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
        defer { buf.deallocate(); pair.deallocate() }
        let n = walk(mainPort, buf, pair)
        guard n > 0 else { return [] }
        var lines: [String] = []
        for i in 0..<n {
            lines.append(symbolicate(i, buf[i], isReturn: i > 0))
        }
        return lines
    }

    // MARK: lezen (geen allocaties tussen suspend en resume)

    private static func walk(_ thread: mach_port_t, _ out: UnsafeMutablePointer<UInt>, _ pair: UnsafeMutablePointer<UInt>) -> Int {
        #if arch(arm64) || arch(x86_64)
        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { _ = thread_resume(thread) }
        var pc: UInt = 0, fp: UInt = 0
        var lr: UInt = 0
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, 6 /* ARM_THREAD_STATE64 */, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc); fp = UInt(state.__fp); lr = UInt(state.__lr)
        #else
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { p in
            p.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, 4 /* x86_THREAD_STATE64 */, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip); fp = UInt(state.__rbp)
        #endif
        var n = 0
        out[n] = strip(pc); n += 1
        if lr != 0 { out[n] = strip(lr); n += 1 }
        let pairSize = vm_size_t(2 * MemoryLayout<UInt>.size)
        while n < maxFrames, fp != 0, fp & 0x7 == 0 {
            var got: vm_size_t = 0
            let r = vm_read_overwrite(mach_task_self_, vm_address_t(fp), pairSize, vm_address_t(UInt(bitPattern: pair)), &got)
            guard r == KERN_SUCCESS, got == pairSize else { break }
            let next = pair[0], ret = strip(pair[1])
            guard ret != 0 else { break }
            out[n] = ret; n += 1
            guard next > fp else { break }   // de stack groeit omlaag: de aanroeper staat hoger
            fp = next
        }
        return n
        #else
        return 0
        #endif
    }

    /// Pointer-authenticatie (arm64e-systeemcode) weghalen
    @inline(__always) private static func strip(_ a: UInt) -> UInt {
        #if arch(arm64)
        #if os(macOS)
        return a & 0x0000_7FFF_FFFF_FFFF
        #else
        return a & 0x0000_000F_FFFF_FFFF
        #endif
        #else
        return a
        #endif
    }

    // MARK: symbolen (na het verder laten gaan)

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let demangle: Demangle? = {
        guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(p, to: Demangle.self)
    }()

    private static func symbolicate(_ i: Int, _ addr: UInt, isReturn: Bool) -> String {
        let lookup = isReturn && addr > 0 ? addr - 1 : addr
        var info = Dl_info()
        guard let ptr = UnsafeRawPointer(bitPattern: lookup), dladdr(ptr, &info) != 0 else {
            return "\(i) ? 0x\(String(addr, radix: 16))"
        }
        let image = info.dli_fname.map { String(cString: $0) } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        var symbol: String?
        var offset: UInt = 0
        if let s = info.dli_sname {
            let raw = String(cString: s)
            if let d = demangle, let out = d(s, strlen(s), nil, nil, 0) {
                symbol = String(cString: out)
                free(out)
            } else {
                symbol = raw
            }
            offset = addr &- UInt(bitPattern: info.dli_saddr)
        }
        return StackFormat.line(i, image: image, symbol: symbol, offset: offset, imageOffset: addr &- base)
    }
}

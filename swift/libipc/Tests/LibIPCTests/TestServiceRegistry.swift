// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors

import Testing
import Darwin.POSIX
@testable import LibIPC

@Suite("ServiceRegistry", .serialized)
struct TestServiceRegistry {

    @Test("open succeeds")
    func openSucceeds() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_open")
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_open")
    }

    @Test("register and find")
    func registerFind() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_rf")
        reg.clear()
        let ok = reg.register(name: "svc_a", controlChannel: "ctrl_a", replyChannel: "reply_a")
        #expect(ok == true)
        let entry = reg.find(name: "svc_a")
        #expect(entry != nil)
        #expect(entry?.nameString == "svc_a")
        #expect(entry?.controlChannelString == "ctrl_a")
        #expect(entry?.replyChannelString == "reply_a")
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_rf")
    }

    @Test("duplicate registration returns false when alive")
    func duplicateAlive() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_dup")
        reg.clear()
        #expect(reg.register(name: "svc_dup", controlChannel: "c", replyChannel: "r") == true)
        #expect(reg.register(name: "svc_dup", controlChannel: "c", replyChannel: "r") == false)
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_dup")
    }

    @Test("unregister removes entry")
    func unregister() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_unreg")
        reg.clear()
        reg.register(name: "svc_rm", controlChannel: "c", replyChannel: "r")
        #expect(reg.unregister(name: "svc_rm") == true)
        #expect(reg.find(name: "svc_rm") == nil)
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_unreg")
    }

    @Test("find returns nil for unknown name")
    func findUnknown() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_unknown")
        reg.clear()
        #expect(reg.find(name: "no_such_service") == nil)
        ServiceRegistry.destroyStorage(domain: "test_reg_unknown")
    }

    @Test("list returns all live entries")
    func listEntries() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_list")
        reg.clear()
        reg.register(name: "svc_1", controlChannel: "c1", replyChannel: "r1")
        reg.register(name: "svc_2", controlChannel: "c2", replyChannel: "r2")
        let all = reg.list()
        #expect(all.count == 2)
        #expect(all.map { $0.nameString }.sorted() == ["svc_1", "svc_2"])
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_list")
    }

    @Test("findAll with prefix")
    func findAllPrefix() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_prefix")
        reg.clear()
        reg.register(name: "audio.compute", controlChannel: "c1", replyChannel: "r1")
        reg.register(name: "audio.render",  controlChannel: "c2", replyChannel: "r2")
        reg.register(name: "video.encode",  controlChannel: "c3", replyChannel: "r3")
        let audio = reg.findAll(prefix: "audio.")
        #expect(audio.count == 2)
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_prefix")
    }

    @Test("gc removes dead entries")
    func gcDead() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_gc")
        reg.clear()
        reg.register(name: "dead_svc", controlChannel: "c", replyChannel: "r", pid: 999_999_999)
        let removed = reg.gc()
        #expect(removed >= 1)
        #expect(reg.find(name: "dead_svc") == nil)
        reg.clear()
        ServiceRegistry.destroyStorage(domain: "test_reg_gc")
    }

    @Test("clear empties registry")
    func clearAll() throws {
        let reg = try ServiceRegistry.open(domain: "test_reg_clear")
        reg.clear()
        reg.register(name: "s1", controlChannel: "c", replyChannel: "r")
        reg.register(name: "s2", controlChannel: "c", replyChannel: "r")
        reg.clear()
        #expect(reg.list().isEmpty)
        ServiceRegistry.destroyStorage(domain: "test_reg_clear")
    }
}

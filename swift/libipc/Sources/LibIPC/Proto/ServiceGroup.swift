// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 natyamatsya contributors
//
// Port of cpp-ipc/include/libipc/proto/service_group.h.
// Redundant service group with automatic failover.

import Darwin.POSIX

// MARK: - InstanceRole

public enum InstanceRole: Sendable {
    case primary, standby, dead
}

// MARK: - ManagedInstance

public struct ManagedInstance: Sendable {
    public let id: Int
    public var role: InstanceRole
    public var proc: ProcessHandle
    public var entry: ServiceEntry
    public let instanceName: String

    public var isAlive: Bool { proc.isAlive }
}

// MARK: - ServiceGroupConfig

public struct ServiceGroupConfig: Sendable {
    /// Logical service name (e.g. `"audio_compute"`).
    public var serviceName: String
    /// Path to the service binary.
    public var executable: String
    /// Total instances (1 primary + N-1 standby).
    public var replicas: Int
    /// Automatically respawn dead instances.
    public var autoRespawn: Bool
    /// Timeout waiting for a spawned process to register.
    public var spawnTimeout: Duration

    public init(serviceName: String, executable: String) {
        self.serviceName  = serviceName
        self.executable   = executable
        self.replicas     = 2
        self.autoRespawn  = true
        self.spawnTimeout = .seconds(5)
    }
}

// MARK: - ServiceGroup

/// Manages a group of redundant service instances with automatic failover.
///
/// Port of `ipc::proto::service_group`.
public final class ServiceGroup: @unchecked Sendable {

    private let registry: ServiceRegistry
    private let config: ServiceGroupConfig
    private var instances: [ManagedInstance]
    private var primaryIdx: Int?

    public init(registry: ServiceRegistry, config: ServiceGroupConfig) {
        self.registry = registry
        self.config   = config
        self.instances = (0..<config.replicas).map { i in
            ManagedInstance(
                id: i,
                role: .dead,
                proc: .invalid,
                entry: ServiceEntry(),
                instanceName: "\(config.serviceName).\(i)"
            )
        }
    }

    // MARK: - Lifecycle

    /// Spawn all instances. The first live one becomes primary.
    /// Returns `true` if at least one instance is alive.
    @discardableResult
    public func start() -> Bool {
        for i in 0..<instances.count { spawnInstance(i) }
        return electPrimary()
    }

    /// Shut down all instances gracefully.
    public func stop(grace: Duration = .seconds(5)) {
        for i in 0..<instances.count {
            if instances[i].isAlive { shutdown(instances[i].proc, grace: grace) }
            instances[i].role = .dead
        }
        primaryIdx = nil
    }

    // MARK: - Health

    /// Perform a health check. Returns `true` if a failover occurred.
    @discardableResult
    public func healthCheck() -> Bool {
        var failoverNeeded = false
        for i in 0..<instances.count {
            guard instances[i].role != .dead else { continue }
            if !instances[i].isAlive {
                if instances[i].role == .primary { failoverNeeded = true }
                instances[i].role = .dead
            }
        }
        if failoverNeeded {
            electPrimary()
            if config.autoRespawn { respawnDead() }
            return true
        }
        if config.autoRespawn { respawnDead() }
        return false
    }

    /// Force a failover: kill the primary, promote a standby.
    @discardableResult
    public func forceFailover() -> Bool {
        if let idx = primaryIdx {
            if instances[idx].isAlive { forceKill(instances[idx].proc) }
            instances[idx].role = .dead
        }
        let ok = electPrimary()
        if config.autoRespawn { respawnDead() }
        return ok
    }

    // MARK: - Accessors

    public var primary: ManagedInstance? {
        guard let idx = primaryIdx, instances[idx].role == .primary else { return nil }
        return instances[idx]
    }

    public var allInstances: [ManagedInstance] { instances }

    public var aliveCount: Int { instances.filter { $0.isAlive }.count }

    // MARK: - Private

    @discardableResult
    private func spawnInstance(_ i: Int) -> Bool {
        registry.gc()
        let instanceName = instances[i].instanceName
        let h = spawn(name: instanceName, executable: config.executable, args: ["\(i)"])
        guard h.valid else { return false }

        let deadline = ContinuousClock.now + config.spawnTimeout
        while true {
            if let e = registry.find(name: instanceName) {
                instances[i].proc  = h
                instances[i].entry = e
                instances[i].role  = .standby
                return true
            }
            if !h.isAlive { return false }
            if ContinuousClock.now >= deadline { return false }
            var ts = timespec(tv_sec: 0, tv_nsec: 50_000_000)
            nanosleep(&ts, nil)
        }
    }

    @discardableResult
    private func electPrimary() -> Bool {
        primaryIdx = nil
        for i in 0..<instances.count {
            guard instances[i].isAlive else { continue }
            instances[i].role = .primary
            primaryIdx = i
            for j in 0..<instances.count where j != i {
                if instances[j].isAlive { instances[j].role = .standby }
            }
            return true
        }
        return false
    }

    private func respawnDead() {
        for i in 0..<instances.count where instances[i].role == .dead {
            spawnInstance(i)
        }
    }
}

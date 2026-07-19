import Foundation
import LumenEngineBridge

extension LumenMacWorkspaceCommandPayload {
    var engineKind: LumenWorkspaceCommandPayloadKind {
        switch self {
        case .none:
            LumenWorkspaceCommandPayloadNone
        case .physicalTopology:
            LumenWorkspaceCommandPayloadPhysicalTopology
        case .virtualDisplayIdentity:
            LumenWorkspaceCommandPayloadVirtualDisplayIdentity
        }
    }
}

enum LumenWorkspacePayloadCodec {
    static func decode(
        engine: OpaquePointer,
        command: LumenWorkspaceCommand
    ) throws -> LumenMacWorkspaceCommandPayload {
        switch command.payload_kind {
        case LumenWorkspaceCommandPayloadNone:
            return .none
        case LumenWorkspaceCommandPayloadPhysicalTopology:
            return .physicalTopology(
                try decodeJSON(engine: engine, command: command)
            )
        case LumenWorkspaceCommandPayloadVirtualDisplayIdentity:
            return .virtualDisplayIdentity(
                try decodeJSON(engine: engine, command: command)
            )
        default:
            throw LumenWorkspaceCoordinatorError.engineStatus(
                LumenEngineStatusCorruptData.rawValue
            )
        }
    }

    static func complete(
        engine: OpaquePointer,
        command: LumenWorkspaceCommand,
        result: LumenMacWorkspaceCommandResult
    ) -> LumenEngineStatus {
        let encoded: (Bool, LumenWorkspaceCommandPayloadKind, String?)
        do {
            encoded = try encode(result)
        } catch {
            return LumenEngineStatusCorruptData
        }
        let completion = { (pointer: UnsafePointer<CChar>?) in
            lumen_workspace_engine_complete_command_with_payload(
                engine,
                command,
                LumenWorkspaceCommandCompletion(
                    succeeded: encoded.0,
                    payload_kind: encoded.1,
                    payload_json: pointer
                )
            )
        }
        guard let json = encoded.2 else {
            return completion(nil)
        }
        return json.withCString(completion)
    }

    private static func decodeJSON<T: Decodable>(
        engine: OpaquePointer,
        command: LumenWorkspaceCommand
    ) throws -> T {
        let requiredSize = lumen_workspace_engine_command_payload_json_size(engine, command)
        guard requiredSize > 1 else {
            throw LumenWorkspaceCoordinatorError.engineStatus(
                LumenEngineStatusCorruptData.rawValue
            )
        }
        var buffer = Array<CChar>(repeating: 0, count: requiredSize)
        let status = buffer.withUnsafeMutableBufferPointer { buffer in
            lumen_workspace_engine_copy_command_payload_json(
                engine,
                command,
                buffer.baseAddress,
                buffer.count
            )
        }
        guard status == LumenEngineStatusOk else {
            throw LumenWorkspaceCoordinatorError.engineStatus(status.rawValue)
        }
        return try JSONDecoder().decode(T.self, from: Data(lumenStringFromCString(buffer).utf8))
    }

    private static func encode(
        _ result: LumenMacWorkspaceCommandResult
    ) throws -> (Bool, LumenWorkspaceCommandPayloadKind, String?) {
        switch result {
        case .succeeded:
            return (true, LumenWorkspaceCommandPayloadNone, nil)
        case .failed:
            return (false, LumenWorkspaceCommandPayloadNone, nil)
        case .physicalMutationApplied(let applied):
            return (
                true,
                LumenWorkspaceCommandPayloadPhysicalMutationApplied,
                try jsonString(applied)
            )
        case .physicalTopology(let topology):
            return (
                true,
                LumenWorkspaceCommandPayloadPhysicalTopology,
                try jsonString(topology)
            )
        case .virtualDisplayIdentity(let identity):
            return (
                true,
                LumenWorkspaceCommandPayloadVirtualDisplayIdentity,
                try jsonString(identity)
            )
        }
    }

    private static func jsonString(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw LumenWorkspaceCoordinatorError.engineStatus(
                LumenEngineStatusCorruptData.rawValue
            )
        }
        return json
    }
}

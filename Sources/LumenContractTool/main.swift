import Foundation
import LumenContractToolCore

do {
  try LumenContractTool.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
  FileHandle.standardError.write(Data("lumen-contract-tool: \(error)\n".utf8))
  exit(1)
}

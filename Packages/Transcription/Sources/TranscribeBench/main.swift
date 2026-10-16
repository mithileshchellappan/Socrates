import Foundation
import Transcription

let arguments = Array(CommandLine.arguments.dropFirst())
let exitCode = await Bench.run(arguments)
exit(exitCode)

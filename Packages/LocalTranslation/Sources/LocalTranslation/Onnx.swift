import COnnxRuntime
import Foundation

/// An ONNX Runtime session on the CPU execution provider. Not `Sendable`: sessions live only
/// inside `LocalTranslator` (through `MarianModel`), and every call runs on that actor.
final class OnnxSession {
    private let handle: OpaquePointer
    let inputNames: [String]
    let outputNames: [String]
    private let inputIndex: [String: Int]
    private let outputIndex: [String: Int]

    init(modelAt url: URL, threads: Int) throws {
        var created: OpaquePointer?
        let path = url.path(percentEncoded: false)
        let error = lt_session_create(path, Int32(threads), &created)
        try OnnxRuntime.check(error)
        guard let created else { throw TranslationError.runtime("No session for \(url.lastPathComponent)") }
        handle = created

        var inputs: [String] = []
        var inputIndex: [String: Int] = [:]
        let inputCount: Int = lt_session_input_count(created)
        for index in 0..<inputCount {
            guard let name = lt_session_input_name(created, index) else { continue }
            let text = String(cString: name)
            inputs.append(text)
            inputIndex[text] = index
        }
        var outputs: [String] = []
        var outputIndex: [String: Int] = [:]
        let outputCount: Int = lt_session_output_count(created)
        for index in 0..<outputCount {
            guard let name = lt_session_output_name(created, index) else { continue }
            let text = String(cString: name)
            outputs.append(text)
            outputIndex[text] = index
        }
        inputNames = inputs
        outputNames = outputs
        self.inputIndex = inputIndex
        self.outputIndex = outputIndex
    }

    deinit {
        lt_session_release(handle)
    }

    func hasInput(_ name: String) -> Bool {
        inputIndex[name] != nil
    }

    func hasOutput(_ name: String) -> Bool {
        outputIndex[name] != nil
    }

    /// Runs the graph on `inputs` (by input name) and returns the requested `outputs` by name.
    func run(_ inputs: [String: OnnxTensor], outputs: [String]) throws -> [String: OnnxTensor] {
        var inputIndices: [Int] = []
        var inputHandles: [OpaquePointer?] = []
        inputIndices.reserveCapacity(inputs.count)
        inputHandles.reserveCapacity(inputs.count)
        for (name, tensor) in inputs {
            guard let index = inputIndex[name] else { throw TranslationError.modelUnreadable("No input \(name)") }
            inputIndices.append(index)
            inputHandles.append(tensor.handle)
        }
        var outputIndices: [Int] = []
        outputIndices.reserveCapacity(outputs.count)
        for name in outputs {
            guard let index = outputIndex[name] else { throw TranslationError.modelUnreadable("No output \(name)") }
            outputIndices.append(index)
        }
        var results = [OpaquePointer?](repeating: nil, count: outputs.count)
        let inputCount: Int = inputIndices.count
        let outputCount: Int = outputIndices.count
        let error = withExtendedLifetime(inputs) {
            lt_session_run(handle, inputIndices, inputHandles, inputCount, outputIndices, outputCount, &results)
        }
        try OnnxRuntime.check(error)

        var tensors: [String: OnnxTensor] = [:]
        var missing = false
        for (position, name) in outputs.enumerated() {
            if let result = results[position] {
                tensors[name] = OnnxTensor(owning: result)
            } else {
                missing = true
            }
        }
        if missing { throw TranslationError.runtime("An output is missing") }
        return tensors
    }
}

/// A tensor owned by ONNX Runtime (created here, or an output of a run). Not `Sendable`.
final class OnnxTensor {
    fileprivate let handle: OpaquePointer
    /// The dimensions, outermost first.
    let shape: [Int]

    /// A float tensor holding a copy of `floats`.
    init(floats: [Float], shape: [Int]) throws {
        let dims: [Int64] = shape.map { Int64($0) }
        var created: OpaquePointer?
        let error: UnsafeMutablePointer<CChar>?
        if floats.isEmpty {
            error = lt_tensor_create_float(nil, dims, dims.count, &created)
        } else {
            error = lt_tensor_create_float(floats, dims, dims.count, &created)
        }
        try OnnxRuntime.check(error)
        guard let created else { throw TranslationError.runtime("No tensor") }
        handle = created
        self.shape = shape
    }

    /// An int64 tensor holding a copy of `int64s`.
    init(int64s: [Int64], shape: [Int]) throws {
        let dims: [Int64] = shape.map { Int64($0) }
        var created: OpaquePointer?
        let error: UnsafeMutablePointer<CChar>?
        if int64s.isEmpty {
            error = lt_tensor_create_int64(nil, dims, dims.count, &created)
        } else {
            error = lt_tensor_create_int64(int64s, dims, dims.count, &created)
        }
        try OnnxRuntime.check(error)
        guard let created else { throw TranslationError.runtime("No tensor") }
        handle = created
        self.shape = shape
    }

    /// A one-element bool tensor (shape [1]), as the merged decoder's `use_cache_branch`.
    init(bool value: Bool) throws {
        let dims: [Int64] = [1]
        let values: [Bool] = [value]
        var created: OpaquePointer?
        let error = lt_tensor_create_bool(values, dims, dims.count, &created)
        try OnnxRuntime.check(error)
        guard let created else { throw TranslationError.runtime("No tensor") }
        handle = created
        shape = [1]
    }

    /// A float tensor with no elements (a dimension of 0), as an empty key/value cache.
    convenience init(emptyFloatsShape shape: [Int]) throws {
        try self.init(floats: [], shape: shape)
    }

    fileprivate init(owning handle: OpaquePointer) {
        self.handle = handle
        var dims: [Int] = []
        let rank: Int = lt_tensor_rank(handle)
        for index in 0..<rank {
            let dim: Int64 = lt_tensor_dim(handle, index)
            dims.append(Int(dim))
        }
        shape = dims
    }

    deinit {
        lt_tensor_release(handle)
    }

    /// The number of elements.
    var count: Int {
        var total = 1
        for dim in shape { total *= dim }
        return total
    }

    /// Reads the elements of a float tensor (an empty buffer for any other tensor).
    func withFloats<Result>(_ body: (UnsafeBufferPointer<Float>) throws -> Result) rethrows -> Result {
        let elements: Int = count
        guard elements > 0, let data = lt_tensor_float_data(handle) else {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        return try body(UnsafeBufferPointer(start: data, count: elements))
    }
}

enum OnnxRuntime {
    /// Throws the shim's error message (and frees it), if any.
    static func check(_ error: UnsafeMutablePointer<CChar>?) throws {
        guard let error else { return }
        let message = String(cString: error)
        lt_free_error(error)
        throw TranslationError.runtime(message)
    }
}
